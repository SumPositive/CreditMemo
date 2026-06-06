//
//  決済保存サービス
//  決済保存、請求再構築、繰り返し生成、派生集計をまとめる
//

import Foundation
import SwiftData

/// E3record 保存・削除・繰り返し処理と集計再計算
@MainActor
enum RecordService {
    /// 1件の明細から影響範囲を再構築するための退避情報
    private struct BillingSnapshot {
        var touchedCardIDs: Set<String> = []
        var touchedPaymentKeys: Set<String> = []
        var invoicePaidByKey: [String: Bool] = [:]
        var paymentPaidByKey: [String: Bool] = [:]
        var partNoCheckByPartNo: [Int16: Int16] = [:]
        var partDueDateLockedByPartNo: [Int16: Bool] = [:]
        var partDueDateByPartNo: [Int16: Date] = [:]
    }

    // MARK: - Save

    static func save(_ record: E3record, context: ModelContext) throws {
        // 1回の保存操作で派生データ更新まで完結させる
        // 新規/修正の入力順を更新日時で保持する
        record.dateUpdate = Date()
        rebuildBilling(for: record, context: context)
        let cats = record.e5tags
        for cat in cats { updateCategoryStats(cat, amount: record.nAmount, date: Date()) }
        try commit(context)
    }

    /// 支払日変更ドラフトを含めて、明細保存と請求再構築を同じ保存単位で行う
    static func save(
        _ record: E3record,
        partDueDateOverridesByPartNo: [Int16: Date],
        partAmountOverridesByPartNo: [Int16: Decimal] = [:],
        partDueDateLockOverridesByPartNo: [Int16: Bool] = [:],
        context: ModelContext
    ) throws {
        // 通常保存で E6part を再構築した後、画面で指定された支払日を同じ保存単位で反映する
        record.dateUpdate = Date()
        rebuildBilling(
            for: record,
            partAmountOverridesByPartNo: partAmountOverridesByPartNo,
            context: context
        )
        let cats = record.e5tags
        for cat in cats { updateCategoryStats(cat, amount: record.nAmount, date: Date()) }
        applyPartDueDateOverrides(
            to: record,
            overridesByPartNo: partDueDateOverridesByPartNo,
            context: context
        )
        applyPartDueDateLockOverrides(
            to: record,
            overridesByPartNo: partDueDateLockOverridesByPartNo
        )
        try commit(context)
    }

    /// 請求を作り直さず、明細のメタ情報だけを保存する
    static func saveMetadata(_ record: E3record, context: ModelContext) throws {
        // 手動で調整した E6part の引き落とし日を保つため、請求再構築は行わない
        record.dateUpdate = Date()
        let cats = record.e5tags
        for cat in cats { updateCategoryStats(cat, amount: record.nAmount, date: Date()) }
        try commit(context)
    }

    /// メタ情報と支払日変更ドラフトだけを、請求再構築なしで同じ保存単位に反映する
    static func saveMetadata(
        _ record: E3record,
        partDueDateOverridesByPartNo: [Int16: Date],
        partDueDateLockOverridesByPartNo: [Int16: Bool] = [:],
        context: ModelContext
    ) throws {
        // メタ情報だけの保存でも、画面で指定された支払日だけは同じ保存単位で反映する
        record.dateUpdate = Date()
        let cats = record.e5tags
        for cat in cats { updateCategoryStats(cat, amount: record.nAmount, date: Date()) }
        applyPartDueDateOverrides(
            to: record,
            overridesByPartNo: partDueDateOverridesByPartNo,
            context: context
        )
        applyPartDueDateLockOverrides(
            to: record,
            overridesByPartNo: partDueDateLockOverridesByPartNo
        )
        try commit(context)
    }

    private static func applyPartDueDateOverrides(
        to record: E3record,
        overridesByPartNo: [Int16: Date],
        context: ModelContext
    ) {
        // 保存ボタンを押すまでは画面側の辞書で保持し、ここで初めて E6part へ反映する
        if overridesByPartNo.isEmpty {
            return
        }
        for part in record.e6parts {
            guard let date = overridesByPartNo[part.nPartNo] else {
                continue
            }
            movePartDueDate(part, date: date, ignoresDueDateLock: true, context: context)
        }
    }

    private static func applyPartDueDateLockOverrides(
        to record: E3record,
        overridesByPartNo: [Int16: Bool]
    ) {
        // 支払日を固定した新規保存では、再構築後の E6part にロック状態も明示反映する
        if overridesByPartNo.isEmpty {
            return
        }
        for part in record.e6parts {
            guard let isLocked = overridesByPartNo[part.nPartNo] else {
                continue
            }
            part.isDueDateLocked = isLocked
        }
    }

    // MARK: - Delete

    static func delete(_ record: E3record, context: ModelContext) throws {
        deleteWithoutCommit(record, context: context)
        try commit(context)
    }

    /// 指定年数より古い履歴を削除する
    static func deleteRecords(olderThanYears years: Int, context: ModelContext) throws {
        let calendar = Calendar.current
        let now = Date()
        guard let cutoff = calendar.date(byAdding: .year, value: -years, to: now) else {
            return
        }

        let descriptor = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.dateUse < cutoff }
        )
        let oldRecords = (try? context.fetch(descriptor)) ?? []
        if oldRecords.isEmpty {
            return
        }

        for record in oldRecords {
            deleteWithoutCommit(record, context: context)
        }
        try commit(context)
    }

    /// 編集前の旧パーツだけを除去し、請求・支払の孤児データを掃除する
    static func removeParts(of record: E3record, context: ModelContext) {
        let snapshot = snapshot(for: record)
        removeExistingParts(of: record, context: context)
        cleanupBilling(snapshot: snapshot, context: context)
    }

    /// 既存データの整合性を保つため、明細が空の請求/支払を掃除する
    static func cleanupOrphanBilling(context: ModelContext) {
        let invoiceDesc = FetchDescriptor<E2invoice>()
        let paymentDesc = FetchDescriptor<E7payment>()
        let cardDesc = FetchDescriptor<E1card>()
        var invoices = (try? context.fetch(invoiceDesc)) ?? []
        var payments = (try? context.fetch(paymentDesc)) ?? []
        let cards = (try? context.fetch(cardDesc)) ?? []

        for invoice in invoices where invoice.e6parts.isEmpty {
            deleteInvoice(invoice, context: context)
        }
        // 同一の請求キーを1件へ統合する
        invoices = (try? context.fetch(invoiceDesc)) ?? []
        normalizeInvoices(invoices, context: context)
        // 決済手段の口座変更後、既存請求が古い支払先へ残るケースを修復する
        invoices = (try? context.fetch(invoiceDesc)) ?? []
        payments = (try? context.fetch(paymentDesc)) ?? []
        repairPaymentMembership(invoices, payments: payments, context: context)
        // 張り替え後の支払配列を読み直し、空になった古い支払を確実に消す
        payments = (try? context.fetch(paymentDesc)) ?? []
        for payment in payments where payment.e2invoices.isEmpty {
            deletePayment(payment, context: context)
        }
        // 同一の支払キーを1件へ統合する
        payments = (try? context.fetch(paymentDesc)) ?? []
        normalizePayments(payments, context: context)
        payments = (try? context.fetch(paymentDesc)) ?? []
        for payment in payments where !payment.e2invoices.isEmpty {
            recalculatePayment(payment)
        }
        for card in cards {
            recalculateCard(card)
        }
    }

    /// 請求パーツ未作成の明細を補完する（決済手段の有無を問わない）
    static func ensureBillingGenerated(context: ModelContext) {
        let recordDesc = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e6parts.isEmpty }
        )
        let records = (try? context.fetch(recordDesc)) ?? []
        for record in records {
            rebuildBilling(for: record, context: context)
        }
    }

    // MARK: - Repeat (nRepeat > 0: mark-paid でコピーを翌月以降に作成)

    static func makeRepeatRecord(from source: E3record, context: ModelContext) throws {
        // 既存呼び出し互換のため公開するが、保存は最後に1回だけ行う
        _ = insertRepeatRecordIfNeeded(from: source, context: context)
        try commit(context)
    }

    /// 請求グループ単位で未払/済みを切り替える
    static func setInvoicesPaid(
        _ invoices: [E2invoice],
        isPaid: Bool,
        context: ModelContext
    ) throws {
        let records = uniqueRecords(in: invoices)
        for invoice in invoices {
            if isPaid {
                lockDueDates(in: invoice)
            }
            moveInvoice(invoice, toPaid: isPaid, context: context)
        }

        if isPaid {
            for record in records {
                _ = insertRepeatRecordIfNeeded(from: record, context: context)
            }
        } else {
            for record in records {
                deleteRepeatRecordIfNeeded(from: record, context: context)
            }
        }

        for invoice in invoices {
            if let card = invoice.e1card {
                recalculateCard(card)
            }
        }

        try commit(context)
    }

    /// 請求1件単位で未払/済みを切り替える
    static func setInvoicePaid(
        _ invoice: E2invoice,
        isPaid: Bool,
        context: ModelContext
    ) throws {
        let records = uniqueRecords(in: [invoice])
        if isPaid {
            lockDueDates(in: invoice)
        }
        moveInvoice(invoice, toPaid: isPaid, context: context)
        if isPaid {
            for record in records {
                _ = insertRepeatRecordIfNeeded(from: record, context: context)
            }
        } else {
            for record in records {
                deleteRepeatRecordIfNeeded(from: record, context: context)
            }
        }
        if let card = invoice.e1card {
            recalculateCard(card)
        }
        try commit(context)
    }

    /// 明細1件だけを反対状態の請求へ移す
    static func setPartPaid(
        _ part: E6part,
        isPaid: Bool,
        context: ModelContext
    ) throws {
        guard let sourceInvoice = part.e2invoice else {
            return
        }
        if sourceInvoice.isPaid == isPaid {
            return
        }
        // 決済手段未選択は未払のまま保持する
        if sourceInvoice.e1card == nil && isPaid {
            return
        }

        let card = sourceInvoice.e1card
        let bank = card?.e8bank
        let date = sourceInvoice.date
        let oldPayment = sourceInvoice.e7payment

        let targetInvoice = findOrCreateInvoice(
            card: card,
            date: date,
            fallbackInvoicePaid: isPaid,
            fallbackPaymentPaid: isPaid,
            context: context
        )
        setInvoiceState(targetInvoice, isPaid: isPaid)

        let targetPayment = findOrCreatePayment(
            date: date,
            bank: bank,
            isPaid: isPaid,
            fallbackPaid: isPaid,
            context: context
        )
        // SwiftData は逆参照（oldPayment.e2invoices）を自動更新しないため明示的に除去する
        if targetInvoice.e7payment?.id != targetPayment.id {
            targetInvoice.e7payment?.e2invoices.removeAll { $0.id == targetInvoice.id }
            targetInvoice.e7payment = targetPayment
            // SwiftData は順参照（newPayment.e2invoices への追加）も自動更新しないことがあるため明示的に追加する
            if !targetPayment.e2invoices.contains(where: { $0.id == targetInvoice.id }) {
                targetPayment.e2invoices.append(targetInvoice)
            }
        } else {
            targetInvoice.e7payment = targetPayment
        }
        setPaymentBank(targetPayment, bank: bank, isPaid: bank == nil ? false : isPaid)

        // 明細を移し替える
        sourceInvoice.e6parts.removeAll { $0.id == part.id }
        if isPaid {
            // 済みにした明細は引き落とし日を自動更新しない状態にする
            part.isDueDateLocked = true
        }
        part.e2invoice = targetInvoice

        recalculatePayment(targetPayment)
        if let oldPayment {
            recalculatePayment(oldPayment)
        }
        if sourceInvoice.e6parts.isEmpty {
            deleteInvoice(sourceInvoice, context: context)
        }
        if let oldPayment, oldPayment.e2invoices.isEmpty {
            deletePayment(oldPayment, context: context)
        }
        if let card {
            recalculateCard(card)
        }

        if let record = part.e3record {
            if isPaid {
                _ = insertRepeatRecordIfNeeded(from: record, context: context)
            } else {
                deleteRepeatRecordIfNeeded(from: record, context: context)
            }
        }

        try commit(context)
    }

    /// 明細1件だけを指定した引き落とし日の請求へ移す
    static func setPartDueDate(
        _ part: E6part,
        date: Date,
        context: ModelContext
    ) throws {
        // ユーザーの明示操作なので、引き落とし日ロック中でも手動変更は許可する
        movePartDueDate(part, date: date, ignoresDueDateLock: true, context: context)
        try commit(context)
    }

    /// 明細1件だけを指定した引き落とし日の請求へ移す（呼び出し元でまとめて保存する）
    static func movePartDueDateWithoutCommit(
        _ part: E6part,
        date: Date,
        context: ModelContext
    ) {
        // インポート中は途中保存せず、最後の保存失敗で全体を巻き戻せるようにする
        movePartDueDate(part, date: date, ignoresDueDateLock: true, context: context)
    }

    private static func movePartDueDate(
        _ part: E6part,
        date: Date,
        ignoresDueDateLock: Bool = false,
        context: ModelContext
    ) {
        guard let sourceInvoice = part.e2invoice else {
            return
        }
        // 済み・明細ロック中・引き落とし日ロック中の明細は支払日を変更しない
        if sourceInvoice.isPaid || part.isChecked || (part.isDueDateLocked && !ignoresDueDateLock) {
            return
        }

        let targetDate = Calendar.current.startOfDay(for: date)
        if Calendar.current.isDate(sourceInvoice.date, inSameDayAs: targetDate) {
            return
        }

        let card = sourceInvoice.e1card
        let bank = card?.e8bank
        let oldPayment = sourceInvoice.e7payment
        let targetInvoice = findOrCreateInvoice(
            card: card,
            date: targetDate,
            fallbackInvoicePaid: false,
            fallbackPaymentPaid: false,
            context: context
        )
        setInvoiceState(targetInvoice, isPaid: false)

        let targetPayment = findOrCreatePayment(
            date: targetDate,
            bank: bank,
            isPaid: false,
            fallbackPaid: false,
            context: context
        )
        if targetInvoice.e7payment?.id != targetPayment.id {
            // 支払先変更時は古い支払から請求を外してから張り替える
            targetInvoice.e7payment?.e2invoices.removeAll { $0.id == targetInvoice.id }
            targetInvoice.e7payment = targetPayment
        }
        if !targetPayment.e2invoices.contains(where: { $0.id == targetInvoice.id }) {
            // SwiftData の逆参照が追従しない場合に備えて明示的に追加する
            targetPayment.e2invoices.append(targetInvoice)
        }
        setPaymentBank(targetPayment, bank: bank, isPaid: false)

        // 明細を指定日の請求へ移し替える
        sourceInvoice.e6parts.removeAll { $0.id == part.id }
        part.e2invoice = targetInvoice
        if !targetInvoice.e6parts.contains(where: { $0.id == part.id }) {
            targetInvoice.e6parts.append(part)
        }

        recalculatePayment(targetPayment)
        if let oldPayment {
            recalculatePayment(oldPayment)
        }
        if sourceInvoice.e6parts.isEmpty {
            deleteInvoice(sourceInvoice, context: context)
        }
        if let oldPayment, oldPayment.e2invoices.isEmpty {
            deletePayment(oldPayment, context: context)
        }
        if let card {
            recalculateCard(card)
        }
    }

    // MARK: - Repeat (nRepeat > 0: mark-paid でコピーを翌月以降に作成)

    private static func insertRepeatRecordIfNeeded(from source: E3record, context: ModelContext) -> E3record? {
        guard 0 < source.nRepeat else { return nil }
        guard let nextDate = Calendar.current.date(
            byAdding: .month, value: Int(source.nRepeat), to: source.dateUse
        ) else { return nil }

        let existsNext = source.e1card?.e3records.contains(where: {
            Calendar.current.isDate($0.dateUse, equalTo: nextDate, toGranularity: .month)
        }) ?? false
        if existsNext {
            return nil
        }

        let next = E3record(
            dateUse:  nextDate,
            zName:    source.zName,
            zNote:    source.zNote,
            nAmount:  source.nAmount,
            nPayType: source.nPayType,
            nRepeat:  source.nRepeat,
            nAnnual:  source.nAnnual
        )
        next.e1card        = source.e1card
        next.e5tags  = source.e5tags
        context.insert(next)
        // 繰り返し生成も同じ保存単位に含める
        rebuildBilling(for: next, context: context)
        let cats = next.e5tags
        for cat in cats {
            updateCategoryStats(cat, amount: next.nAmount, date: Date())
        }
        return next
    }

    /// 済みから未払へ戻した時、条件一致する自動追加候補を消す
    private static func deleteRepeatRecordIfNeeded(from source: E3record, context: ModelContext) {
        guard 0 < source.nRepeat else { return }
        guard let targetDate = Calendar.current.date(
            byAdding: .month, value: Int(source.nRepeat), to: source.dateUse
        ) else { return }

        let descriptor = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.dateUse == targetDate }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        guard let generated = candidates.first(where: { candidate in
            candidate.id != source.id &&
            candidate.nAmount == source.nAmount &&
            candidate.nRepeat == source.nRepeat &&
            candidate.e1card?.id == source.e1card?.id
        }) else { return }
        deleteWithoutCommit(generated, context: context)
    }

    // MARK: - Rebuild

    static func rebuildBilling(context: ModelContext) {
        let recordDesc = FetchDescriptor<E3record>(sortBy: [SortDescriptor(\E3record.dateUse)])
        let records = (try? context.fetch(recordDesc)) ?? []
        for record in records {
            rebuildBilling(for: record, context: context)
        }
        cleanupOrphanBilling(context: context)
    }

    static func rebuildBilling(
        for record: E3record,
        partAmountOverridesByPartNo: [Int16: Decimal] = [:],
        context: ModelContext
    ) {
        let snapshot = snapshot(for: record)
        removeExistingParts(of: record, context: context)

        let dates = BillingService.partDates(record: record, card: record.e1card)
        let amounts = BillingService.partAmounts(record: record)
        let validPartAmountOverrides = validatedPartAmountOverrides(
            for: record,
            overridesByPartNo: partAmountOverridesByPartNo
        )
        var rebuiltDates: [Date] = []
        for (index, pair) in zip(dates.indices, zip(dates, amounts)) {
            let partNo = Int16(index + 1)
            let lockedDate = snapshot.partDueDateLockedByPartNo[partNo] == true
                ? snapshot.partDueDateByPartNo[partNo]
                : nil
            // 引き落とし日ロック済みの明細は、請求方式変更時も旧日付を維持する
            let billingDate = Calendar.current.startOfDay(for: lockedDate ?? pair.0)
            // 2回払いで画面側が手動配分した金額を優先する
            let amount = validPartAmountOverrides[partNo] ?? pair.1
            rebuiltDates.append(billingDate)
            let bank = record.e1card?.e8bank
            let invoicePaid = snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: billingDate, isPaid: true)
            ] ?? snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: billingDate, isPaid: false)
            ] ?? false
            let invoice = findOrCreateInvoice(
                card: record.e1card,
                date: billingDate,
                fallbackInvoicePaid: invoicePaid,
                fallbackPaymentPaid: snapshot.paymentPaidByKey[
                    paymentKey(bankID: bank?.id, date: billingDate, isPaid: invoicePaid)
                ],
                context: context
            )
            let payment = findOrCreatePayment(
                date: billingDate,
                bank: bank,
                isPaid: invoice.isPaid,
                fallbackPaid: snapshot.paymentPaidByKey[
                    paymentKey(bankID: bank?.id, date: billingDate, isPaid: invoice.isPaid)
                ],
                context: context
            )
            // 口座変更時は既存invoiceでも支払先を最新のpaymentへ張り替える
            if invoice.e7payment?.id != payment.id {
                // SwiftData は逆参照（oldPayment.e2invoices）を自動更新しないため明示的に除去する
                invoice.e7payment?.e2invoices.removeAll { $0.id == invoice.id }
                invoice.e7payment = payment
                // SwiftData は順参照（newPayment.e2invoices への追加）も自動更新しないことがあるため明示的に追加する
                if !payment.e2invoices.contains(where: { $0.id == invoice.id }) {
                    payment.e2invoices.append(invoice)
                }
            }
            let part = E6part(nPartNo: partNo, nAmount: amount)
            part.nNoCheck = snapshot.partNoCheckByPartNo[partNo] ?? 1
            part.isDueDateLocked = snapshot.partDueDateLockedByPartNo[partNo] ?? false
            part.e2invoice = invoice
            part.e3record = record
            context.insert(part)
        }

        var touchedCardIDs = snapshot.touchedCardIDs
        if let cardID = record.e1card?.id {
            touchedCardIDs.insert(cardID)
        }
        var touchedPaymentKeys = snapshot.touchedPaymentKeys
        for date in rebuiltDates {
            let day = Calendar.current.startOfDay(for: date)
            let paid = snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: day, isPaid: true)
            ] ?? snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: day, isPaid: false)
            ] ?? false
            touchedPaymentKeys.insert(paymentKey(bankID: record.e1card?.e8bank?.id, date: day, isPaid: paid))
        }
        recalculateTouchedBilling(cardIDs: touchedCardIDs, paymentKeys: touchedPaymentKeys, context: context)
    }

    private static func validatedPartAmountOverrides(
        for record: E3record,
        overridesByPartNo: [Int16: Decimal]
    ) -> [Int16: Decimal] {
        guard record.payType == .twoPayments,
              overridesByPartNo.count == 2,
              let first = overridesByPartNo[1],
              let second = overridesByPartNo[2] else {
            return [:]
        }
        let total = record.nAmount.roundedAmount()
        guard 1 < total,
              0 < first,
              0 < second,
              first < total,
              second < total,
              first + second == total else {
            return [:]
        }
        // Service 境界で不正な分割金額を捨て、集計不整合を防ぐ
        return [1: first, 2: second]
    }

    // MARK: - Recalculate

    static func recalculateCard(_ card: E1card) {
        var paid: Decimal = 0, unpaid: Decimal = 0, noCheck: Int16 = 0
        for inv in card.e2invoices {
            if inv.isPaid { paid += inv.sumAmount } else { unpaid += inv.sumAmount }
            noCheck += inv.sumNoCheck
        }
        card.sumPaid    = paid
        card.sumUnpaid  = unpaid
        card.sumNoCheck = noCheck
    }

    static func recalculatePayments(for card: E1card) {
        var seen = Set<String>()
        for inv in card.e2invoices {
            guard let payment = inv.e7payment else { continue }
            if seen.contains(payment.id) { continue }
            seen.insert(payment.id)
            recalculatePayment(payment)
        }
    }

    // MARK: - Private

    private static func snapshot(for record: E3record) -> BillingSnapshot {
        var snapshot = BillingSnapshot()
        for part in record.e6parts {
            snapshot.partNoCheckByPartNo[part.nPartNo] = part.nNoCheck
            snapshot.partDueDateLockedByPartNo[part.nPartNo] = part.isDueDateLocked
            if let invoice = part.e2invoice {
                snapshot.partDueDateByPartNo[part.nPartNo] = invoice.date
                snapshot.invoicePaidByKey[
                    invoiceKey(cardID: invoice.e1card?.id, date: invoice.date, isPaid: invoice.isPaid)
                ] = invoice.isPaid
                if let cardID = invoice.e1card?.id {
                    snapshot.touchedCardIDs.insert(cardID)
                }
                if let payment = invoice.e7payment {
                    // findOrCreatePayment と同じ基準（物理フィールド）で判定する
                    let physicalIsPaid = payment.e8paid != nil
                    let key = paymentKey(bankID: payment.e8bank?.id, date: payment.date, isPaid: physicalIsPaid)
                    snapshot.touchedPaymentKeys.insert(key)
                    snapshot.paymentPaidByKey[key] = physicalIsPaid
                }
            }
        }
        if let cardID = record.e1card?.id {
            snapshot.touchedCardIDs.insert(cardID)
        }
        for date in BillingService.partDates(record: record, card: record.e1card) {
            let day = Calendar.current.startOfDay(for: date)
            let paid = snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: day, isPaid: true)
            ] ?? snapshot.invoicePaidByKey[
                invoiceKey(cardID: record.e1card?.id, date: day, isPaid: false)
            ] ?? false
            snapshot.touchedPaymentKeys.insert(paymentKey(bankID: record.e1card?.e8bank?.id, date: day, isPaid: paid))
        }
        return snapshot
    }

    private static func removeExistingParts(of record: E3record, context: ModelContext) {
        for part in record.e6parts {
            if let invoice = part.e2invoice {
                invoice.e6parts.removeAll { $0.id == part.id }
            }
            part.e2invoice = nil
            part.e3record = nil
            context.delete(part)
        }
        record.e6parts.removeAll()
    }

    private static func cleanupBilling(snapshot: BillingSnapshot, context: ModelContext) {
        recalculateTouchedBilling(
            cardIDs: snapshot.touchedCardIDs,
            paymentKeys: snapshot.touchedPaymentKeys,
            context: context
        )
    }

    private static func invoiceKey(cardID: String?, date: Date, isPaid: Bool) -> String {
        let rawCardID = cardID ?? "__no_card__"
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let state = isPaid ? "paid" : "unpaid"
        return "\(rawCardID)#\(day)#\(state)"
    }

    private static func paymentKey(bankID: String?, date: Date, isPaid: Bool) -> String {
        let rawBankID = bankID ?? "__no_bank__"
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let state = isPaid ? "paid" : "unpaid"
        return "\(rawBankID)#\(day)#\(state)"
    }

    private static func recalculateTouchedBilling(
        cardIDs: Set<String>,
        paymentKeys: Set<String>,
        context: ModelContext
    ) {
        let cardDesc = FetchDescriptor<E1card>()
        let paymentDesc = FetchDescriptor<E7payment>()
        let invoiceDesc = FetchDescriptor<E2invoice>()
        let cards = (try? context.fetch(cardDesc)) ?? []
        var payments = (try? context.fetch(paymentDesc)) ?? []
        var invoices = (try? context.fetch(invoiceDesc)) ?? []

        for invoice in invoices where invoice.e6parts.isEmpty {
            deleteInvoice(invoice, context: context)
        }
        invoices = (try? context.fetch(invoiceDesc)) ?? []
        normalizeInvoices(
            invoices.filter { cardIDs.contains($0.e1card?.id ?? "") },
            context: context
        )

        for card in cards where cardIDs.contains(card.id) {
            recalculateCard(card)
        }

        payments = (try? context.fetch(paymentDesc)) ?? []
        normalizePayments(
            payments.filter { payment in
                // findOrCreatePayment と同じ基準（物理フィールド）でキーを構築する
                let key = paymentKey(bankID: payment.e8bank?.id, date: payment.date, isPaid: payment.e8paid != nil)
                return paymentKeys.contains(key)
            },
            context: context
        )
        payments = (try? context.fetch(paymentDesc)) ?? []
        for payment in payments {
            let key = paymentKey(bankID: payment.e8bank?.id, date: payment.date, isPaid: payment.e8paid != nil)
            if payment.e2invoices.isEmpty {
                deletePayment(payment, context: context)
                continue
            }
            if paymentKeys.contains(key) {
                recalculatePayment(payment)
            }
        }
    }

    private static func findOrCreateInvoice(
        card: E1card?,
        date: Date,
        fallbackInvoicePaid: Bool?,
        fallbackPaymentPaid: Bool?,
        context: ModelContext
    ) -> E2invoice {
        let day = Calendar.current.startOfDay(for: date)
        if let card {
            if let ex = card.e2invoices.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: day) && $0.isPaid == (fallbackInvoicePaid ?? fallbackPaymentPaid ?? false)
            }) {
                return ex
            }
            let inv = E2invoice(date: day)
            setInvoiceCard(inv, card: card, isPaid: fallbackInvoicePaid ?? fallbackPaymentPaid ?? false)
            context.insert(inv)
            return inv
        }

        let desc = FetchDescriptor<E2invoice>(
            predicate: #Predicate { $0.date == day && $0.e1paid == nil && $0.e1unpaid == nil }
        )
        if let ex = try? context.fetch(desc).first {
            return ex
        }

        let inv = E2invoice(date: day)
        context.insert(inv)
        return inv
    }

    private static func findOrCreatePayment(
        date: Date,
        bank: E8bank?,
        isPaid: Bool,
        fallbackPaid: Bool?,
        context: ModelContext
    ) -> E7payment {
        let day  = Calendar.current.startOfDay(for: date)
        // 口座未選択は物理的な paid/unpaid 所属を持てないため、内部キーは未払側へ寄せる
        let physicalIsPaid = bank == nil ? false : isPaid
        let desc = FetchDescriptor<E7payment>(predicate: #Predicate { $0.date == day })
        let payments = (try? context.fetch(desc)) ?? []
        if let ex = payments.first(where: {
            // invoice 集計の見かけ状態でなく、所属先そのものを見る
            $0.e8bank?.id == bank?.id && (($0.e8paid != nil) == physicalIsPaid)
        }) {
            return ex
        }
        let p = E7payment(date: day)
        setPaymentBank(p, bank: bank, isPaid: bank == nil ? false : (fallbackPaid ?? physicalIsPaid))
        context.insert(p)
        return p
    }

    private static func recalculatePayment(_ payment: E7payment) {
        payment.sumAmount = payment.e2invoices.reduce(.zero) { $0 + $1.sumAmount }
        payment.sumNoCheck = payment.e2invoices.reduce(0) { $0 + $1.sumNoCheck }
    }

    private static func normalizeInvoices(_ invoices: [E2invoice], context: ModelContext) {
        var canonicalByKey: [String: E2invoice] = [:]

        for invoice in invoices {
            let key = invoiceKey(cardID: invoice.e1card?.id, date: invoice.date, isPaid: invoice.isPaid)
            if let canonical = canonicalByKey[key] {
                // 同一請求へ part を集約する
                for part in invoice.e6parts {
                    part.e2invoice = canonical
                }
                // 親 payment が無ければ引き継ぐ
                if canonical.e7payment == nil, let p = invoice.e7payment {
                    canonical.e7payment = p
                    // SwiftData は順参照（p.e2invoices への追加）も自動更新しないことがあるため明示的に追加する
                    if !p.e2invoices.contains(where: { $0.id == canonical.id }) {
                        p.e2invoices.append(canonical)
                    }
                }
                deleteInvoice(invoice, context: context)
            } else {
                canonicalByKey[key] = invoice
            }
        }
    }

    private static func normalizePayments(_ payments: [E7payment], context: ModelContext) {
        var canonicalByKey: [String: E7payment] = [:]

        for payment in payments {
            // findOrCreatePayment と同じ基準（物理フィールド）でキーを構築する
            let key = paymentKey(bankID: payment.e8bank?.id, date: payment.date, isPaid: payment.e8paid != nil)
            if let canonical = canonicalByKey[key] {
                // ループ中に payment.e2invoices が変化しないよう先にコピーを取る
                let invoicesToMove = Array(payment.e2invoices)
                // 同一支払へ invoice を集約する
                for invoice in invoicesToMove {
                    invoice.e7payment = canonical
                    // SwiftData は順参照（canonical.e2invoices への追加）も自動更新しないことがあるため明示的に追加する
                    if !canonical.e2invoices.contains(where: { $0.id == invoice.id }) {
                        canonical.e2invoices.append(invoice)
                    }
                }
                deletePayment(payment, context: context)
            } else {
                canonicalByKey[key] = payment
            }
        }
    }

    private static func repairPaymentMembership(
        _ invoices: [E2invoice],
        payments: [E7payment],
        context: ModelContext
    ) {
        var paymentByKey: [String: E7payment] = [:]
        for payment in payments {
            let key = paymentKey(bankID: payment.e8bank?.id, date: payment.date, isPaid: payment.e8paid != nil)
            // 重複支払は後続の normalizePayments で統合するため、ここでは先頭だけを代表にする
            if paymentByKey[key] == nil {
                paymentByKey[key] = payment
            }
        }
        for invoice in invoices {
            if invoice.e6parts.isEmpty {
                continue
            }
            let bank = invoice.e1card?.e8bank
            // 口座未選択は物理的な paid/unpaid 所属を持てないため、内部キーは未払側へ寄せる
            let physicalIsPaid = bank == nil ? false : invoice.isPaid
            let key = paymentKey(bankID: bank?.id, date: invoice.date, isPaid: physicalIsPaid)
            let payment: E7payment
            if let existingPayment = paymentByKey[key] {
                payment = existingPayment
            } else {
                let newPayment = E7payment(date: Calendar.current.startOfDay(for: invoice.date))
                setPaymentBank(newPayment, bank: bank, isPaid: bank == nil ? false : invoice.isPaid)
                context.insert(newPayment)
                paymentByKey[key] = newPayment
                payment = newPayment
            }
            // 決済手段の口座変更後も、請求が古い支払先に残っていれば現在の口座へ張り替える
            if invoice.e7payment?.id != payment.id {
                invoice.e7payment?.e2invoices.removeAll { $0.id == invoice.id }
                invoice.e7payment = payment
            }
            // SwiftData の逆参照が追従しない場合に備え、支払側にも明示的に追加する
            if !payment.e2invoices.contains(where: { $0.id == invoice.id }) {
                payment.e2invoices.append(invoice)
            }
            setPaymentBank(payment, bank: bank, isPaid: bank == nil ? false : invoice.isPaid)
        }
    }

    private static func setInvoiceCard(_ invoice: E2invoice, card: E1card?, isPaid: Bool) {
        invoice.e1paid = nil
        invoice.e1unpaid = nil
        guard let card else { return }
        if isPaid {
            invoice.e1paid = card
        } else {
            invoice.e1unpaid = card
        }
    }

    private static func clearInvoiceState(_ invoice: E2invoice) {
        invoice.e1paid = nil
        invoice.e1unpaid = nil
    }

    private static func setInvoiceState(_ invoice: E2invoice, isPaid: Bool) {
        guard let card = invoice.e1card else {
            clearInvoiceState(invoice)
            return
        }
        setInvoiceCard(invoice, card: card, isPaid: isPaid)
    }

    private static func lockDueDates(in invoice: E2invoice) {
        // 済みにした請求配下の明細は引き落とし日を自動更新しない状態にする
        for part in invoice.e6parts {
            part.isDueDateLocked = true
        }
    }

    private static func setPaymentBank(_ payment: E7payment, bank: E8bank?, isPaid: Bool) {
        payment.e8paid = nil
        payment.e8unpaid = nil
        guard let bank else { return }
        if isPaid {
            payment.e8paid = bank
        } else {
            payment.e8unpaid = bank
        }
    }

    private static func clearPaymentState(_ payment: E7payment) {
        payment.e8paid = nil
        payment.e8unpaid = nil
    }

    /// Invoice を安全に削除する
    /// - 逆参照 payment.e2invoices を手動で除去してから関係を nil にし、その後削除する
    /// - cleanupOrphanBilling / recalculateTouchedBilling / normalizeInvoices で統一して使う
    private static func deleteInvoice(_ invoice: E2invoice, context: ModelContext) {
        if let payment = invoice.e7payment {
            payment.e2invoices.removeAll { $0.id == invoice.id }
        }
        clearInvoiceState(invoice)
        invoice.e7payment = nil
        context.delete(invoice)
    }

    /// Payment を安全に削除する
    /// - cascade 削除に invoice が巻き込まれないよう配列を空にしてから削除する
    /// - cleanupOrphanBilling / recalculateTouchedBilling / normalizePayments / moveInvoice で統一して使う
    private static func deletePayment(_ payment: E7payment, context: ModelContext) {
        payment.e2invoices.removeAll()
        clearPaymentState(payment)
        context.delete(payment)
    }

    private static func moveInvoice(_ invoice: E2invoice, toPaid: Bool, context: ModelContext) {
        let bank = invoice.e1card?.e8bank
        let oldPayment = invoice.e7payment
        setInvoiceState(invoice, isPaid: toPaid)
        let newPayment = findOrCreatePayment(
            date: invoice.date,
            bank: bank,
            isPaid: toPaid,
            fallbackPaid: toPaid,
            context: context
        )
        // SwiftData は逆参照（oldPayment.e2invoices）を自動更新しないため明示的に除去する
        oldPayment?.e2invoices.removeAll { $0.id == invoice.id }
        invoice.e7payment = newPayment
        // SwiftData は順参照（newPayment.e2invoices への追加）も自動更新しないことがあるため明示的に追加する
        if !newPayment.e2invoices.contains(where: { $0.id == invoice.id }) {
            newPayment.e2invoices.append(invoice)
        }
        // 再利用された payment でも paid/unpaid 所属を正に戻す
        setPaymentBank(newPayment, bank: bank, isPaid: bank == nil ? false : toPaid)
        recalculatePayment(newPayment)
        if let oldPayment, oldPayment.id != newPayment.id {
            recalculatePayment(oldPayment)
            if oldPayment.e2invoices.isEmpty {
                deletePayment(oldPayment, context: context)
            }
        }
    }

    private static func commit(_ context: ModelContext) throws {
        if context.hasChanges {
            try context.save()
        }
    }

    /// 同一操作の中で使う、保存を伴わない削除
    private static func deleteWithoutCommit(_ record: E3record, context: ModelContext) {
        let snapshot = snapshot(for: record)
        // 請求/支払の孤児掃除が効くよう、先に part を明示的に外す
        removeExistingParts(of: record, context: context)
        context.delete(record)
        cleanupBilling(snapshot: snapshot, context: context)
    }

    /// 請求配下の元レコードを重複なく集める
    private static func uniqueRecords(in invoices: [E2invoice]) -> [E3record] {
        var seen: Set<String> = []
        var records: [E3record] = []
        for invoice in invoices {
            for part in invoice.e6parts {
                guard let record = part.e3record else { continue }
                if seen.contains(record.id) {
                    continue
                }
                seen.insert(record.id)
                records.append(record)
            }
        }
        return records
    }

    private static func updateCategoryStats(_ cat: E5tag?, amount: Decimal, date: Date) {
        guard let cat else { return }
        // 並び順用の重みとして単純加算する
        // 正確な累計ではないため、編集差分や削除では減算しない
        // 将来は順序を保ったままリセットする機能を追加する
        // date には Date()（保存日時）を渡す。利用日では数ヶ月先の明細が「最近」に来てしまうため。
        cat.sortDate    = date
        cat.sortCount  += 1
        cat.sortAmount += amount
        cat.sortName    = cat.zName
    }
}
