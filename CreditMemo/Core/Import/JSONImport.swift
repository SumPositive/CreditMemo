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
        case applyingInvoiceStates
        case applyingPaymentStates
        case cleaningBilling
        case saving
        case completed

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
            case .applyingInvoiceStates:
                return isJapanese ? "請求状態を反映中…" : "Applying invoice states..."
            case .applyingPaymentStates:
                return isJapanese ? "支払状態を反映中…" : "Applying payment states..."
            case .cleaningBilling:
                return isJapanese ? "請求・支払データを整理中…" : "Cleaning up billing data..."
            case .saving:
                return isJapanese ? "保存中…" : "Saving..."
            case .completed:
                return isJapanese ? "インポート完了" : "Import complete"
            }
        }
    }

    struct Progress {
        let phase: Phase
        let completed: Int?
        let total: Int?

        /// 工程名に処理件数を加えて進行位置を示す
        func message(locale: Locale) -> String {
            let base = phase.message(locale: locale)
            guard let completed, let total, 0 < total else { return base }
            return "\(base)\n\(completed.formatted()) / \(total.formatted())"
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
        onProgress: ((Progress) -> Void)? = nil
    ) async throws -> Result {
        // 中断時に取込途中のデータが自動保存されないよう明示保存まで止める
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        func report(_ phase: Phase, completed: Int? = nil, total: Int? = nil) {
            let progress = Progress(phase: phase, completed: completed, total: total)
            onProgress?(progress)
            // クラッシュ直前の工程と件数を診断情報へ残す
            AppTelemetry.logImportProgress(
                phase: String(describing: phase),
                completed: completed,
                total: total
            )
        }

        report(.readingFile)
        await Task.yield()
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)

        report(.decoding)
        await Task.yield()
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ImportData.self, from: data)

        do {
            // 新規ストアの初期プリセットは完全バックアップの内容へ置き換える
            try removeInitialSeedDataForFullRestoreIfNeeded(payload, context: context)

            let banks = context.fetchReporting(FetchDescriptor<E8bank>(), entity: "E8bank")
            let cards = context.fetchReporting(FetchDescriptor<E1card>(), entity: "E1card")
            let categories = context.fetchReporting(FetchDescriptor<E5tag>(), entity: "E5tag")
            let records = context.fetchReporting(FetchDescriptor<E3record>(), entity: "E3record")

            var bankByID = Dictionary(uniqueKeysWithValues: banks.map { ($0.id, $0) })
            var cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            var tagByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            var recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

            report(.importingMasters)
            await Task.yield()
            try Task.checkCancellation()
            let importedBankCount = importBanks(payload.banks ?? [], bankByID: &bankByID, context: context)
            let importedCardCount = importCards(payload.cards ?? [], cardByID: &cardByID, bankByID: bankByID, context: context)
            // tags（新）または categories（旧JSON互換）のどちらかを読み込む
            let importedTagCount = importTags(
                payload.tags ?? payload.categories?.map { TagData(id: $0.id, name: $0.name, note: $0.note) } ?? [],
                tagByID: &tagByID, context: context
            )

            report(.importingRecords, completed: 0, total: payload.records?.count ?? 0)
            await Task.yield()
            let importedRecordCount = try await importRecords(
                payload.records ?? [],
                recordByID: &recordByID,
                cardByID: cardByID,
                tagByID: tagByID,
                context: context
            ) { completed, total in
                report(.importingRecords, completed: completed, total: total)
            }

            // record が入った場合や、状態 JSON を反映する場合は請求を正規状態へ作り直す
            if 0 < importedRecordCount || payload.parts != nil || payload.invoices != nil || payload.payments != nil {
                report(.rebuildingBilling, completed: 0, total: importedRecordCount)
                await Task.yield()
                try await RecordService.rebuildBilling(context: context) { completed, total in
                    report(.rebuildingBilling, completed: completed, total: total)
                }
            }

            report(.applyingParts, completed: 0, total: payload.parts?.count ?? 0)
            await Task.yield()
            let appliedPartStateCount = try await applyPartStates(
                payload.parts ?? [],
                context: context
            ) { completed, total in
                report(.applyingParts, completed: completed, total: total)
            }

            report(.applyingInvoiceStates, completed: 0, total: payload.invoices?.count ?? 0)
            await Task.yield()
            let appliedInvoiceStateCount = try await applyInvoiceStates(
                payload.invoices ?? [],
                context: context
            ) { completed, total in
                report(.applyingInvoiceStates, completed: completed, total: total)
            }
            report(.applyingPaymentStates, completed: 0, total: payload.payments?.count ?? 0)
            let appliedPaymentStateCount = try await applyPaymentStates(
                payload.payments ?? [],
                context: context
            ) { completed, total in
                report(.applyingPaymentStates, completed: completed, total: total)
            }
            report(.cleaningBilling)
            await Task.yield()
            try Task.checkCancellation()
            RecordService.cleanupOrphanBilling(context: context)

            report(.saving)
            await Task.yield()
            try Task.checkCancellation()
            if context.hasChanges {
                try context.save()
            }
            report(.completed)

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

    private static func removeInitialSeedDataForFullRestoreIfNeeded(
        _ payload: ImportData,
        context: ModelContext
    ) throws {
        // 一部データの追記ではなく、請求状態を含む完全バックアップだけを対象にする
        guard payload.banks != nil,
              payload.cards != nil,
              payload.records != nil,
              payload.invoices != nil,
              payload.payments != nil else {
            return
        }

        let records = try context.fetch(FetchDescriptor<E3record>())
        let parts = try context.fetch(FetchDescriptor<E6part>())
        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        let payments = try context.fetch(FetchDescriptor<E7payment>())
        guard records.isEmpty,
              parts.isEmpty,
              invoices.isEmpty,
              payments.isEmpty else {
            return
        }

        let banks = try context.fetch(FetchDescriptor<E8bank>())
        let cards = try context.fetch(FetchDescriptor<E1card>())
        let tags = try context.fetch(FetchDescriptor<E5tag>())
        guard matchesInitialBanks(banks),
              matchesInitialCards(cards),
              matchesInitialTags(tags) else {
            return
        }

        // IDの異なる初期プリセットを残すと同名マスタが重複するため先に除去する
        cards.forEach { context.delete($0) }
        tags.forEach { context.delete($0) }
        banks.forEach { context.delete($0) }
    }

    private static func matchesInitialBanks(_ banks: [E8bank]) -> Bool {
        let actualNames = banks.map(\.zName).sorted()
        let initialNames = SeedData.bankPresetsForCurrentLocale().map(\.name).sorted()
        return actualNames == initialNames
            && banks.allSatisfy { $0.zNote.isEmpty && $0.e1cards.isEmpty && $0.e7payments.isEmpty }
    }

    private static func matchesInitialCards(_ cards: [E1card]) -> Bool {
        let presets = SeedData.presetsForCurrentLocale()
        let presetByName = Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0) })
        guard cards.count == presets.count else { return false }
        return cards.allSatisfy { card in
            guard let preset = presetByName[card.zName] else { return false }
            return card.zNote == preset.note
                && card.nClosingDay == preset.closingDay
                && card.nPayDay == preset.payDay
                && card.nPayMonth == preset.payMonth
                && card.e8bank == nil
                && card.e2invoices.isEmpty
                && card.e3records.isEmpty
        }
    }

    private static func matchesInitialTags(_ tags: [E5tag]) -> Bool {
        let actualNames = tags.map(\.zName).sorted()
        let initialNames = SeedData.categoryPresetsForCurrentLocale().map(\.name).sorted()
        return actualNames == initialNames
            && tags.allSatisfy { $0.zNote.isEmpty && $0.e3records.isEmpty }
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
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        for (index, item) in items.enumerated() {
            // 大量Importを利用者が中断できるよう各要素で確認する
            try Task.checkCancellation()
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
            let completed = index + 1
            if completed.isMultiple(of: 50) || completed == items.count {
                onProgress?(completed, items.count)
                // 大量履歴でも画面の進行表示を更新できるようにする
                await Task.yield()
            }
        }
        return items.count
    }

    private static func applyPartStates(
        _ items: [PartData],
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let parts = context.fetchReporting(FetchDescriptor<E6part>(), entity: "E6part")
        var partByRecordAndNo: [String: E6part] = [:]
        var duplicatePartCount = 0
        for part in parts {
            guard let recordID = part.e3record?.id else { continue }
            let key = "\(recordID)#\(part.nPartNo)"
            if partByRecordAndNo[key] == nil {
                partByRecordAndNo[key] = part
            } else {
                // 重複明細があっても辞書生成でクラッシュせず先頭を採用する
                duplicatePartCount += 1
            }
        }
        if 0 < duplicatePartCount {
            let error = NSError(
                domain: "CreditMemo.JSONImport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Duplicate billing parts detected during import"]
            )
            AppTelemetry.reportRecoverableError(
                error,
                operation: "applyPartStates",
                category: "json_import",
                detail: "duplicate_count=\(duplicatePartCount)"
            )
        }
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
        for (index, item) in items.enumerated() {
            // 明細状態の復元中もキャンセルを受け付ける
            try Task.checkCancellation()
            if let recordID = item.recordID,
               let part = partByRecordAndNo["\(recordID)#\(Int16(item.partNo))"] {
                // 2回払いの手動配分は、合計が正しい場合だけ復元する
                let amountKey = "\(recordID)#\(part.nPartNo)"
                if let restored = validAmountByRecordAndNo[amountKey] {
                    part.nAmount = restored
                }
                if let interestString = item.interest {
                    // Exportした分割払い利息を欠落させず復元する
                    part.nInterest = try decimalValue(interestString)
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
            let completed = index + 1
            if completed.isMultiple(of: 25) || completed == items.count {
                onProgress?(completed, items.count)
                await Task.yield()
            }
        }
        return updatedCount
    }

    private static func applyInvoiceStates(
        _ items: [InvoiceData],
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let invoices = context.fetchReporting(FetchDescriptor<E2invoice>(), entity: "E2invoice")
        let invoiceGroups = Dictionary(grouping: invoices) {
            invoiceKey(cardID: $0.e1card?.id, date: $0.date)
        }

        var updatedCount = 0
        for (index, item) in items.enumerated() {
            // 請求状態の復元中もキャンセルを受け付ける
            try Task.checkCancellation()
            let key = invoiceKey(cardID: item.cardID, date: item.date)
            let targetInvoices = (invoiceGroups[key] ?? []).filter { $0.isPaid != item.isPaid }
            for invoice in targetInvoices {
                moveInvoice(invoice, toPaid: item.isPaid, context: context)
                updatedCount += 1
            }
            let completed = index + 1
            if completed.isMultiple(of: 25) || completed == items.count {
                onProgress?(completed, items.count)
                await Task.yield()
            }
        }
        return updatedCount
    }

    private static func applyPaymentStates(
        _ items: [PaymentData],
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let payments = context.fetchReporting(FetchDescriptor<E7payment>(), entity: "E7payment")
        let paymentGroups = Dictionary(grouping: payments) {
            paymentKey(bankID: $0.e8bank?.id, date: $0.date)
        }

        var updatedCount = 0
        for (index, item) in items.enumerated() {
            // 支払状態の復元中もキャンセルを受け付ける
            try Task.checkCancellation()
            let key = paymentKey(bankID: item.bankID, date: item.date)
            let targetInvoices = (paymentGroups[key] ?? [])
                .flatMap(\.e2invoices)
                .filter { $0.isPaid != item.isPaid }
            for invoice in targetInvoices {
                moveInvoice(invoice, toPaid: item.isPaid, context: context)
                updatedCount += 1
            }
            let completed = index + 1
            if completed.isMultiple(of: 25) || completed == items.count {
                onProgress?(completed, items.count)
                await Task.yield()
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
        // 状態を外す前に決済手段を退避し、済み復元時の関連切れを防ぐ
        let card = invoice.e1card
        invoice.e1paid = nil
        invoice.e1unpaid = nil
        guard let card else { return }
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
