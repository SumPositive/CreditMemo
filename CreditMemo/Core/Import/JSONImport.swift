//
//  JSONインポート処理
//  バックアップJSONの読み込み、既存データ更新、請求再構築をまとめる
//

import Foundation
import SwiftData

/// JSON インポート
///
/// - 既存データは削除せず、id 単位で追記・更新する
/// - 配列キーは省略可能とし、マスタのみ・一部データのみの JSON も受け入れる
/// - record から請求を再構築した後、part / invoice / payment の状態を反映する
@MainActor
enum JSONImport {

    enum ImportError: LocalizedError {
        case invalidDecimal(String)

        var errorDescription: String? {
            switch self {
            case .invalidDecimal(let value):
                return "数値として読み込めない値があります: \(value)"
            }
        }
    }

    struct ImportData: Decodable {
        var exportDate: Date?
        var banks: [BankData]?
        var cards: [CardData]?
        // 旧JSON互換: 利用店配列は読み込めても現行アプリでは使用しない
        var shops: [ShopData]?
        var tags: [TagData]?
        var categories: [CategoryData]?  // 旧JSON互換キー
        var records: [RecordData]?
        var parts: [PartData]?
        var invoices: [InvoiceData]?
        var payments: [PaymentData]?
    }

    struct BankData: Decodable {
        var id: String
        var name: String
        var note: String
        var row: Int
    }

    struct CardData: Decodable {
        var id: String
        var name: String
        var note: String
        var row: Int
        var closingDay: Int
        var payDay: Int
        var payMonth: Int
        var bonus1: Int
        var bonus2: Int
        var bankID: String?

        enum CodingKeys: String, CodingKey {
            case id, name, note, row, closingDay, payDay, payMonth, bonus1, bonus2, bankID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            row = try c.decodeIfPresent(Int.self, forKey: .row) ?? 0
            closingDay = try c.decodeIfPresent(Int.self, forKey: .closingDay) ?? 20
            payDay = try c.decodeIfPresent(Int.self, forKey: .payDay) ?? 27
            payMonth = try c.decodeIfPresent(Int.self, forKey: .payMonth) ?? 1
            bonus1 = try c.decodeIfPresent(Int.self, forKey: .bonus1) ?? 0
            bonus2 = try c.decodeIfPresent(Int.self, forKey: .bonus2) ?? 0
            bankID = try c.decodeIfPresent(String.self, forKey: .bankID)
        }
    }

    struct ShopData: Decodable {
        var id: String
        var name: String
        var note: String
    }

    struct TagData: Decodable {
        var id: String
        var name: String
        var note: String
    }

    // 旧JSON互換: "categories" キーで書き出された JSON の読み込みに使用
    struct CategoryData: Decodable {
        var id: String
        var name: String
        var note: String
    }

    struct RecordData: Decodable {
        var id: String
        var dateUse: Date
        var dateUpdate: Date?
        var name: String
        var note: String
        var amount: String
        var payType: Int
        var repeatMonths: Int
        var cardID: String?
        // 旧JSON互換: 利用店IDは受け取れるが現行アプリでは無視する
        var shopID: String?
        var categoryID: String?    // 旧JSON互換
        var categoryIDs: [String]? // 旧JSON互換
        var tagIDs: [String]?      // 新キー
    }

    struct InvoiceData: Decodable {
        var id: String
        var date: Date
        var isPaid: Bool
        var cardID: String?
        var paymentID: String?
    }

    struct PartData: Decodable {
        var id: String?
        var recordID: String?
        var partNo: Int
        var amount: String?
        var interest: String?
        var noCheck: Int?
        var dueDate: Date?
        var dueDateLocked: Bool?
    }

    struct PaymentData: Decodable {
        var id: String
        var date: Date
        var bankID: String?
        var sumAmount: String?
        var sumNoCheck: Int?
        var isPaid: Bool
    }

    enum Phase {
        case readingFile
        case decoding
        case importingMasters
        case importingRecords
        case rebuildingBilling
        case applyingParts
        case applyingStates
        case saving

        /// インポート進行テキスト（ja/en）
        func message(locale: Locale) -> String {
            let isJapanese = locale.language.languageCode?.identifier == "ja"
            switch self {
            case .readingFile:
                return isJapanese ? "JSONファイルを読み込み中…" : "Reading JSON file..."
            case .decoding:
                return isJapanese ? "JSONを解析中…" : "Decoding JSON..."
            case .importingMasters:
                return isJapanese ? "マスタデータを取り込み中…" : "Importing master data..."
            case .importingRecords:
                return isJapanese ? "決済履歴を取り込み中…" : "Importing records..."
            case .rebuildingBilling:
                return isJapanese ? "請求データを再構築中…" : "Rebuilding billing..."
            case .applyingParts:
                return isJapanese ? "明細状態を反映中…" : "Applying part states..."
            case .applyingStates:
                return isJapanese ? "未払/済み状態を反映中…" : "Applying paid states..."
            case .saving:
                return isJapanese ? "保存中…" : "Saving..."
            }
        }
    }

    struct Result {
        var bankCount: Int
        var cardCount: Int
        var tagCount: Int
        var recordCount: Int
        var partStateCount: Int
        var invoiceStateCount: Int
        var paymentStateCount: Int
    }

    static func importData(
        from url: URL,
        context: ModelContext,
        onPhase: ((Phase) -> Void)? = nil
    ) async throws -> Result {
        onPhase?(.readingFile)
        await Task.yield()
        let data = try Data(contentsOf: url)

        onPhase?(.decoding)
        await Task.yield()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ImportData.self, from: data)

        do {
            let banks = context.fetchReporting(FetchDescriptor<E8bank>(), entity: "E8bank")
            let cards = context.fetchReporting(FetchDescriptor<E1card>(), entity: "E1card")
            let categories = context.fetchReporting(FetchDescriptor<E5tag>(), entity: "E5tag")
            let records = context.fetchReporting(FetchDescriptor<E3record>(), entity: "E3record")

            var bankByID = Dictionary(uniqueKeysWithValues: banks.map { ($0.id, $0) })
            var cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            var tagByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            var recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

            onPhase?(.importingMasters)
            await Task.yield()
            let importedBankCount = importBanks(payload.banks ?? [], bankByID: &bankByID, context: context)
            let importedCardCount = importCards(payload.cards ?? [], cardByID: &cardByID, bankByID: bankByID, context: context)
            // tags（新）または categories（旧JSON互換）のどちらかを読み込む
            let importedTagCount = importTags(
                payload.tags ?? payload.categories?.map { TagData(id: $0.id, name: $0.name, note: $0.note) } ?? [],
                tagByID: &tagByID, context: context
            )

            onPhase?(.importingRecords)
            await Task.yield()
            let importedRecordCount = try importRecords(
                payload.records ?? [],
                recordByID: &recordByID,
                cardByID: cardByID,
                tagByID: tagByID,
                context: context
            )

            // record が入った場合や、状態 JSON を反映する場合は請求を正規状態へ作り直す
            if 0 < importedRecordCount || payload.parts != nil || payload.invoices != nil || payload.payments != nil {
                onPhase?(.rebuildingBilling)
                await Task.yield()
                RecordService.rebuildBilling(context: context)
            }

            onPhase?(.applyingParts)
            await Task.yield()
            let appliedPartStateCount = try applyPartStates(payload.parts ?? [], context: context)

            onPhase?(.applyingStates)
            await Task.yield()
            let appliedInvoiceStateCount = applyInvoiceStates(payload.invoices ?? [], context: context)
            let appliedPaymentStateCount = applyPaymentStates(payload.payments ?? [], context: context)
            RecordService.cleanupOrphanBilling(context: context)

            onPhase?(.saving)
            await Task.yield()
            if context.hasChanges {
                try context.save()
            }

            return Result(
                bankCount: importedBankCount,
                cardCount: importedCardCount,
                tagCount: importedTagCount,
                recordCount: importedRecordCount,
                partStateCount: appliedPartStateCount,
                invoiceStateCount: appliedInvoiceStateCount,
                paymentStateCount: appliedPaymentStateCount
            )
        } catch {
            // インポート途中の未保存変更を残さず、呼び出し元へ原因を返す
            context.rollback()
            throw error
        }
    }

    private static func importBanks(
        _ items: [BankData],
        bankByID: inout [String: E8bank],
        context: ModelContext
    ) -> Int {
        for item in items {
            let bank = bankByID[item.id] ?? {
                let value = E8bank(id: item.id)
                context.insert(value)
                bankByID[item.id] = value
                return value
            }()
            // 口座マスタの基本項目を上書きする
            bank.zName = item.name
            bank.zNote = item.note
            bank.nRow = Int32(item.row)
        }
        return items.count
    }

    private static func importCards(
        _ items: [CardData],
        cardByID: inout [String: E1card],
        bankByID: [String: E8bank],
        context: ModelContext
    ) -> Int {
        for item in items {
            let card = cardByID[item.id] ?? {
                let value = E1card(id: item.id)
                context.insert(value)
                cardByID[item.id] = value
                return value
            }()
            // 締日0はN日後型なので、支払月は常に0へ正規化する
            let normalizedPayMonth = item.closingDay == 0 ? 0 : item.payMonth
            // 決済手段マスタの基本項目を上書きする
            card.zName = item.name
            card.zNote = item.note
            card.nRow = Int32(item.row)
            // closingDay/payDay/payMonth の正規形だけを読む
            card.nClosingDay = Int16(item.closingDay)
            card.nPayDay = Int16(item.payDay)
            card.nPayMonth = Int16(normalizedPayMonth)
            card.nBonus1 = Int16(item.bonus1)
            card.nBonus2 = Int16(item.bonus2)
            card.e8bank = item.bankID.flatMap { bankByID[$0] }
        }
        return items.count
    }

    private static func importTags(
        _ items: [TagData],
        tagByID: inout [String: E5tag],
        context: ModelContext
    ) -> Int {
        for item in items {
            let tag = tagByID[item.id] ?? {
                let value = E5tag(id: item.id)
                context.insert(value)
                tagByID[item.id] = value
                return value
            }()
            // タグマスタの基本項目を上書きする
            tag.zName = item.name
            tag.zNote = item.note
            tag.sortName = item.name
        }
        return items.count
    }

    private static func importRecords(
        _ items: [RecordData],
        recordByID: inout [String: E3record],
        cardByID: [String: E1card],
        tagByID: [String: E5tag],
        context: ModelContext
    ) throws -> Int {
        for item in items {
            let record = recordByID[item.id] ?? {
                let value = E3record(id: item.id)
                context.insert(value)
                recordByID[item.id] = value
                return value
            }()

            // 明細の正本を id 単位で更新する
            record.dateUse = item.dateUse
            // 入力順が無い旧JSONは利用日を代替値として使う
            record.dateUpdate = item.dateUpdate ?? item.dateUse
            record.zName = item.name
            record.zNote = item.note
            record.nAmount = try decimalValue(item.amount)
            // 旧アプリ由来のボーナス払い等は現行モデルに無いので一括払いへ正規化する
            record.nPayType = E3record.normalizedPayTypeRawValue(Int16(item.payType))
            record.nRepeat = Int16(item.repeatMonths)
            record.e1card = item.cardID.flatMap { cardByID[$0] }

            // tagIDs（新）→ categoryIDs（旧互換）→ categoryID（最旧互換）の順で読む
            let resolvedIDs = item.tagIDs ?? item.categoryIDs ?? item.categoryID.map { [$0] } ?? []
            record.e5tags = resolvedIDs.compactMap { tagByID[$0] }
        }
        return items.count
    }

    private static func applyPartStates(
        _ items: [PartData],
        context: ModelContext
    ) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let parts = context.fetchReporting(FetchDescriptor<E6part>(), entity: "E6part")
        let partByRecordAndNo = Dictionary(
            uniqueKeysWithValues: parts.compactMap { part -> (String, E6part)? in
                guard let recordID = part.e3record?.id else { return nil }
                return ("\(recordID)#\(part.nPartNo)", part)
            }
        )
        var amountByRecordID: [String: [Int16: Decimal]] = [:]
        for item in items {
            guard let recordID = item.recordID, let amountString = item.amount else { continue }
            amountByRecordID[recordID, default: [:]][Int16(item.partNo)] = try decimalValue(amountString)
        }
        let validAmountByRecordAndNo = validTwoPaymentAmounts(
            amountByRecordID: amountByRecordID,
            partByRecordAndNo: partByRecordAndNo
        )

        var updatedCount = 0
        for item in items {
            guard let recordID = item.recordID else { continue }
            guard let part = partByRecordAndNo["\(recordID)#\(Int16(item.partNo))"] else { continue }

            // 2回払いの手動配分は、合計が正しい場合だけ復元する
            let amountKey = "\(recordID)#\(part.nPartNo)"
            if let restored = validAmountByRecordAndNo[amountKey] {
                part.nAmount = restored
            }

            let shouldLockDueDate = item.dueDateLocked ?? false
            if let dueDate = item.dueDate {
                // 日付復元中だけ専用ロックを外し、移動後にエクスポート時の状態へ戻す
                part.isDueDateLocked = false
                RecordService.movePartDueDateWithoutCommit(part, date: dueDate, context: context)
            }
            part.isDueDateLocked = shouldLockDueDate
            if let noCheck = item.noCheck {
                // チェック状態は支払日移動を妨げるため、日付復元後に反映する
                part.nNoCheck = Int16(noCheck)
            }
            updatedCount += 1
        }
        return updatedCount
    }

    private static func applyInvoiceStates(
        _ items: [InvoiceData],
        context: ModelContext
    ) -> Int {
        guard !items.isEmpty else { return 0 }
        let invoices = context.fetchReporting(FetchDescriptor<E2invoice>(), entity: "E2invoice")
        let invoiceGroups = Dictionary(grouping: invoices) {
            invoiceKey(cardID: $0.e1card?.id, date: $0.date)
        }

        var updatedCount = 0
        for item in items {
            let key = invoiceKey(cardID: item.cardID, date: item.date)
            let targetInvoices = (invoiceGroups[key] ?? []).filter { $0.isPaid != item.isPaid }
            for invoice in targetInvoices {
                moveInvoice(invoice, toPaid: item.isPaid, context: context)
                updatedCount += 1
            }
        }
        return updatedCount
    }

    private static func applyPaymentStates(
        _ items: [PaymentData],
        context: ModelContext
    ) -> Int {
        guard !items.isEmpty else { return 0 }
        let payments = context.fetchReporting(FetchDescriptor<E7payment>(), entity: "E7payment")
        let paymentGroups = Dictionary(grouping: payments) {
            paymentKey(bankID: $0.e8bank?.id, date: $0.date)
        }

        var updatedCount = 0
        for item in items {
            let key = paymentKey(bankID: item.bankID, date: item.date)
            let targetInvoices = (paymentGroups[key] ?? [])
                .flatMap(\.e2invoices)
                .filter { $0.isPaid != item.isPaid }
            guard !targetInvoices.isEmpty else { continue }
            for invoice in targetInvoices {
                moveInvoice(invoice, toPaid: item.isPaid, context: context)
                updatedCount += 1
            }
        }
        return updatedCount
    }

    private static func invoiceKey(cardID: String?, date: Date) -> String {
        let rawCardID = cardID ?? "__no_card__"
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        return "\(rawCardID)#\(day)"
    }

    private static func paymentKey(bankID: String?, date: Date) -> String {
        let rawBankID = bankID ?? "__no_bank__"
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        return "\(rawBankID)#\(day)"
    }

    private static func validTwoPaymentAmounts(
        amountByRecordID: [String: [Int16: Decimal]],
        partByRecordAndNo: [String: E6part]
    ) -> [String: Decimal] {
        var validAmounts: [String: Decimal] = [:]
        for (recordID, amountsByPartNo) in amountByRecordID {
            guard amountsByPartNo.count == 2,
                  let first = amountsByPartNo[1],
                  let second = amountsByPartNo[2],
                  let record = partByRecordAndNo["\(recordID)#1"]?.e3record,
                  record.payType == .twoPayments else {
                continue
            }
            let total = record.nAmount.roundedAmount()
            guard 1 < total,
                  0 < first,
                  0 < second,
                  first < total,
                  second < total,
                  first + second == total else {
                continue
            }
            validAmounts["\(recordID)#1"] = first
            validAmounts["\(recordID)#2"] = second
        }
        return validAmounts
    }

    private static func decimalValue(_ rawValue: String) throws -> Decimal {
        guard let value = Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ImportError.invalidDecimal(rawValue)
        }
        return value
    }

    private static func moveInvoice(_ invoice: E2invoice, toPaid: Bool, context: ModelContext) {
        let bank = invoice.e1card?.e8bank
        let oldPayment = invoice.e7payment
        setInvoiceState(invoice, isPaid: toPaid)
        let newPayment = findOrCreatePayment(
            date: invoice.date,
            bank: bank,
            isPaid: toPaid,
            context: context
        )
        invoice.e7payment = newPayment
        recalculatePayment(newPayment)
        if let oldPayment, oldPayment.id != newPayment.id {
            recalculatePayment(oldPayment)
            if oldPayment.e2invoices.isEmpty {
                clearPaymentState(oldPayment)
                context.delete(oldPayment)
            }
        }
    }

    private static func findOrCreatePayment(
        date: Date,
        bank: E8bank?,
        isPaid: Bool,
        context: ModelContext
    ) -> E7payment {
        let day = Calendar.current.startOfDay(for: date)
        let desc = FetchDescriptor<E7payment>(predicate: #Predicate { $0.date == day })
        let payments = context.fetchReporting(desc, entity: "E7payment")
        if let payment = payments.first(where: { $0.e8bank?.id == bank?.id && $0.isPaid == isPaid }) {
            return payment
        }
        let payment = E7payment(date: day)
        setPaymentBank(payment, bank: bank, isPaid: bank != nil && isPaid)
        context.insert(payment)
        return payment
    }

    private static func setInvoiceState(_ invoice: E2invoice, isPaid: Bool) {
        invoice.e1paid = nil
        invoice.e1unpaid = nil
        guard let card = invoice.e1card else { return }
        if isPaid {
            invoice.e1paid = card
            return
        }
        invoice.e1unpaid = card
    }

    private static func setPaymentBank(_ payment: E7payment, bank: E8bank?, isPaid: Bool) {
        payment.e8paid = nil
        payment.e8unpaid = nil
        guard let bank else { return }
        if isPaid {
            payment.e8paid = bank
            return
        }
        payment.e8unpaid = bank
    }

    private static func clearPaymentState(_ payment: E7payment) {
        payment.e8paid = nil
        payment.e8unpaid = nil
    }

    private static func recalculatePayment(_ payment: E7payment) {
        payment.sumAmount = payment.e2invoices.reduce(.zero) { $0 + $1.sumAmount }
        payment.sumNoCheck = payment.e2invoices.reduce(0) { $0 + $1.sumNoCheck }
    }
}
