//
//  旧データ移行処理
//  CoreData版クレメモのデータをSwiftData形式へ移行する
//

import Foundation
import SwiftData
import CoreData
import OSLog

private let migrationLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CreditMemo", category: "Migration")

/// CoreData(旧クレメモ AzCredit.sqlite) → SwiftData マイグレーション
///
/// 主な変換:
/// - E2invoice / E7payment の paid / unpaid 所属を維持
/// - E2invoice.nYearMMDD(Int32) → date: Date
/// - E7payment は「日付 + 口座」単位で再構築
struct MigratingFromCoreData {

    private static let migrationFlagKey = "MigratingFromCoreData.migrated.v1"

    enum Outcome {
        case completed
        case failed     // 旧ファイルはそのまま残す → 次回起動で自動再試行
    }

    enum Phase {
        case checkingExistingData
        case searchingLegacyStore
        case loadingLegacyData
        case convertingData
        case savingData
        case finalizing

        /// 進行状況テキスト（ja/en）
        func message(locale: Locale) -> String {
            let isJapanese = locale.language.languageCode?.identifier == "ja"
            switch self {
            case .checkingExistingData:
                return isJapanese ? "移行確認中…" : "Checking existing data..."
            case .searchingLegacyStore:
                return isJapanese ? "旧アプリデータを検索中…" : "Searching legacy app data..."
            case .loadingLegacyData:
                return isJapanese ? "旧データを読み込み中…" : "Loading legacy data..."
            case .convertingData:
                return isJapanese ? "データを変換中…" : "Converting data..."
            case .savingData:
                return isJapanese ? "保存中…" : "Saving data..."
            case .finalizing:
                return isJapanese ? "最終処理中…" : "Finalizing..."
            }
        }
    }

    @MainActor
    func migrateIfNeeded(
        modelContainer: ModelContainer,
        onPhase: ((Phase) -> Void)? = nil
    ) async -> Outcome {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.migrationFlagKey) == false else { return .completed }

        let context = modelContainer.mainContext
        onPhase?(.checkingExistingData)
        await Task.yield()

        onPhase?(.searchingLegacyStore)
        await Task.yield()
        let candidates = candidateStoreURLs()
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.migrationFlagKey)
            return .completed
        }

        for storeURL in candidates {
            do {
                onPhase?(.loadingLegacyData)
                await Task.yield()

                // WAL/SHM 欠損補修（iCloud バックアップ復元後にメインファイルだけ残るケース対策）
                Self.repairWALIfNeeded(at: storeURL)

                let legacyStack = try LegacyCoreDataStack(storeURL: storeURL)
                let dto = try legacyStack.fetchAll()
                if dto.banks.isEmpty && dto.cards.isEmpty { continue }

                onPhase?(.convertingData)
                await Task.yield()
                importData(dto, into: context)
                if context.hasChanges {
                    onPhase?(.savingData)
                    await Task.yield()
                    try context.save()
                }

                // 成功：旧ファイルを .done にリネーム（失敗時はリネームしない → 次回自動再試行）
                onPhase?(.finalizing)
                await Task.yield()
                Self.archiveOldStore(storeURL)

                defaults.set(true, forKey: Self.migrationFlagKey)
                migrationLogger.info("移行完了: \(storeURL.lastPathComponent)")
                return .completed
            } catch {
                context.rollback()
                migrationLogger.error("移行失敗: \(storeURL.lastPathComponent) - \(error.localizedDescription)")
                // 旧ファイルはそのまま残す → 次回起動で自動再試行
            }
        }
        onPhase?(.finalizing)
        return .failed
    }

    /// 旧データを破棄して新規開始する時に、移行済みフラグを立てる
    static func markMigrationCompleted() {
        UserDefaults.standard.set(true, forKey: migrationFlagKey)
    }

    /// 旧SQLiteをすべてリネームして退避する（再移行防止）
    /// - 失敗ダイアログで「旧データを破棄」を選んだ時に呼ぶ
    static func discardLegacyStores() {
        let candidates = MigratingFromCoreData().candidateStoreURLs()
        for url in candidates {
            let discardURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_discarded.sqlite")
            try? FileManager.default.moveItem(at: url, to: discardURL)
            for suffix in ["-shm", "-wal"] {
                let src = URL(fileURLWithPath: url.path + suffix)
                let dst = URL(fileURLWithPath: discardURL.path + suffix)
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }
        migrationLogger.info("旧ファイルを破棄しました")
    }

    // MARK: - Store URL 候補

    private func candidateStoreURLs() -> [URL] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.applicationSupportDirectory, .documentDirectory]
        let names = ["AzCredit.sqlite"]
        var result: [URL] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            for name in names {
                let url = base.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path), seen.insert(url.path).inserted {
                    result.append(url)
                }
            }
        }
        return result
    }

    // MARK: - WAL 補修（iCloud バックアップ復元後の欠損対策）

    /// `-wal` / `-shm` が存在しない場合は空ファイルを作成して CoreData の open エラーを防ぐ
    private static func repairWALIfNeeded(at storeURL: URL) {
        let fm = FileManager.default
        for ext in ["-wal", "-shm"] {
            let auxURL = URL(fileURLWithPath: storeURL.path + ext)
            if !fm.fileExists(atPath: auxURL.path) {
                fm.createFile(atPath: auxURL.path, contents: Data())
                migrationLogger.info("WAL 補修: \(auxURL.lastPathComponent) を空ファイルで作成")
            }
        }
    }

    // MARK: - 旧SQLiteアーカイブ（成功時のみ呼ぶ）
    //
    // 成功 → .done にリネーム（candidateStoreURLs は .sqlite のみ検索するので再検出されない）
    // 失敗 → リネームしない（.sqlite のまま残す → 次回起動で自動再試行）

    private static func archiveOldStore(_ url: URL) {
        let fm = FileManager.default
        for ext in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: url.path + ext)
            let dst = URL(fileURLWithPath: url.path + ext + ".done")
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                migrationLogger.warning("アーカイブ失敗: \(src.lastPathComponent) - \(error.localizedDescription)")
            }
        }
        migrationLogger.info("旧ファイルを .done にリネーム完了")
    }

    // MARK: - SwiftData へのインポート

    @MainActor
    private func importData(_ dto: LegacyDataDTO, into context: ModelContext) {
        // E8bank
        var bankMap: [NSManagedObjectID: E8bank] = [:]
        for b in dto.banks {
            let bank = E8bank(zName: b.zName, zNote: b.zNote, nRow: b.nRow)
            context.insert(bank)
            bankMap[b.objectID] = bank
        }

        // E5tag（旧分類タグ）
        var catMap: [NSManagedObjectID: E5tag] = [:]
        // 同名カテゴリへ統合するためのインデックス（利用店→分類タグ変換で利用）
        var categoryByName: [String: E5tag] = [:]
        for c in dto.categories {
            let cat = E5tag(
                zName: c.zName, zNote: c.zNote,
                sortAmount: c.sortAmount, sortCount: c.sortCount,
                sortDate: c.sortDate, sortName: c.sortName
            )
            context.insert(cat)
            catMap[c.objectID] = cat
            categoryByName[c.zName] = cat
        }

        // 旧利用店は分類タグへ変換する（同名タグがあれば統合、なければ新規作成）
        var shopToCategoryMap: [NSManagedObjectID: E5tag] = [:]
        for s in dto.shops {
            if let existing = categoryByName[s.zName] {
                // 同名タグがある場合は統計値を統合する
                existing.sortAmount += s.sortAmount
                existing.sortCount += s.sortCount
                if existing.sortDate == nil {
                    existing.sortDate = s.sortDate
                } else if let incoming = s.sortDate, let current = existing.sortDate, current < incoming {
                    existing.sortDate = incoming
                }
                if existing.zNote.isEmpty, s.zNote.isEmpty == false {
                    existing.zNote = s.zNote
                }
                shopToCategoryMap[s.objectID] = existing
                continue
            }

            // 同名タグがない場合は新規タグとして作成する
            let converted = E5tag(
                zName: s.zName,
                zNote: s.zNote,
                sortAmount: s.sortAmount,
                sortCount: s.sortCount,
                sortDate: s.sortDate,
                sortName: s.sortName
            )
            context.insert(converted)
            categoryByName[s.zName] = converted
            shopToCategoryMap[s.objectID] = converted
        }

        // E7payment は旧 payment をそのまま移さず、invoice から日付+口座で再構成する
        var paymentByKey: [String: E7payment] = [:]

        // E1card + E2invoice + E3record + E6part
        for c in dto.cards {
            let isLegacyDebit = c.nClosingDay == 0
            let migratedClosingDay: Int16 = isLegacyDebit ? 0 : c.nClosingDay
            let migratedPayDay: Int16 = isLegacyDebit ? 0 : c.nPayDay
            let migratedPayMonth: Int16 = isLegacyDebit ? 0 : c.nPayMonth
            let card = E1card(
                zName: c.zName, zNote: c.zNote,
                nRow: c.nRow,
                nClosingDay: migratedClosingDay, nPayDay: migratedPayDay,
                nPayMonth: migratedPayMonth,
                nBonus1: c.nBonus1, nBonus2: c.nBonus2,
                dateUpdate: c.dateUpdate,
                sumPaid: c.sumPaid, sumUnpaid: c.sumUnpaid, sumNoCheck: c.sumNoCheck
            )
            if let bankID = c.bankObjectID {
                card.e8bank = bankMap[bankID]
            }
            context.insert(card)

            // E3record
            var recordMap: [NSManagedObjectID: E3record] = [:]
            for r in c.records {
                let record = E3record(
                    dateUse: r.dateUse ?? Date(),
                    dateUpdate: r.dateUse ?? Date(),
                    zName: r.zName, zNote: r.zNote,
                    nAmount: r.nAmount,
                    nPayType: E3record.normalizedPayTypeRawValue(r.nPayType),
                    nRepeat: r.nRepeat,
                    nAnnual: r.nAnnual,
                    sumNoCheck: r.sumNoCheck
                )
                let categoryFromLegacyTag = r.categoryObjectID.flatMap { catMap[$0] }
                let categoryFromLegacyShop = r.shopObjectID.flatMap { shopToCategoryMap[$0] }

                // 旧 利用店/分類タグ を新 分類タグ配列へ統合する
                var mergedCategories: [E5tag] = []
                if let categoryFromLegacyTag {
                    mergedCategories.append(categoryFromLegacyTag)
                }
                if let categoryFromLegacyShop,
                   mergedCategories.contains(where: { $0.id == categoryFromLegacyShop.id }) == false {
                    mergedCategories.append(categoryFromLegacyShop)
                }

                // 新構造では e5tags に集約する
                record.e5tags = mergedCategories
                record.e1card = card
                context.insert(record)
                recordMap[r.objectID] = record
            }

            // E2invoice (paid + unpaid)
            for inv in c.invoicesPaid + c.invoicesUnpaid {
                let invoiceDate = dateFromYearMMDD(inv.nYearMMDD)
                let invoice = E2invoice(date: invoiceDate)
                if inv.isPaid {
                    invoice.e1paid = card
                } else {
                    invoice.e1unpaid = card
                }
                let payment = findOrCreateMigratedPayment(
                    date: invoiceDate,
                    bank: card.e8bank,
                    isPaid: inv.isPaid,
                    paymentByKey: &paymentByKey,
                    context: context
                )
                invoice.e7payment = payment
                context.insert(invoice)

                // E6part
                for part in inv.parts {
                    let p = E6part(
                        nPartNo: part.nPartNo,
                        nAmount: part.nAmount,
                        nInterest: part.nInterest,
                        nNoCheck: part.nNoCheck
                    )
                    p.e2invoice = invoice
                    p.e3record = part.recordObjectID.flatMap { recordMap[$0] }
                    context.insert(p)
                }

                // 口座別支払の集計値をその場で構築する
                payment.sumAmount += invoice.sumAmount
                payment.sumNoCheck += invoice.sumNoCheck
            }
        }
    }

    // MARK: - YYYYMMDD → Date

    private func dateFromYearMMDD(_ yearMMDD: Int32) -> Date {
        guard yearMMDD > 0 else { return Date() }
        let y = Int(yearMMDD) / 10000
        let m = (Int(yearMMDD) % 10000) / 100
        let d = Int(yearMMDD) % 100
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return Calendar.current.date(from: comps) ?? Date()
    }

    @MainActor
    private func findOrCreateMigratedPayment(
        date: Date,
        bank: E8bank?,
        isPaid: Bool,
        paymentByKey: inout [String: E7payment],
        context: ModelContext
    ) -> E7payment {
        let day = Calendar.current.startOfDay(for: date)
        let bankKey = bank?.id ?? "__no_bank__"
        let stateKey = isPaid ? "paid" : "unpaid"
        let key = "\(bankKey)#\(Int(day.timeIntervalSince1970))#\(stateKey)"
        if let existing = paymentByKey[key] {
            return existing
        }

        let payment = E7payment(date: day)
        if let bank {
            if isPaid {
                payment.e8paid = bank
            } else {
                payment.e8unpaid = bank
            }
        }
        context.insert(payment)
        paymentByKey[key] = payment
        return payment
    }
}

// MARK: - Legacy CoreData Stack

private struct LegacyCoreDataStack {
    let context: NSManagedObjectContext

    init(storeURL: URL) throws {
        let model = Self.makeModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options: [String: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true,
            NSSQLitePragmasOption: ["journal_mode": "DELETE"]
        ]
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: options
        )
        let ctx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        ctx.persistentStoreCoordinator = coordinator
        ctx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        self.context = ctx
    }

    func fetchAll() throws -> LegacyDataDTO {
        return try context.performAndWait {
            var result = LegacyDataDTO()
            result.banks = try self.fetch("E8bank")
                .map { LegacyBankDTO(mo: $0) }
            result.shops = try self.fetch("E4shop")
                .map { LegacyShopDTO(mo: $0) }
            result.categories = try self.fetch("E5tag")
                .map { LegacyCategoryDTO(mo: $0) }
            result.cards = try self.fetchCards()
            return result
        }
    }

    private func fetch(_ entity: String) throws -> [NSManagedObject] {
        let req = NSFetchRequest<NSManagedObject>(entityName: entity)
        req.returnsObjectsAsFaults = false
        return try context.fetch(req)
    }

    private func fetchCards() throws -> [LegacyCardDTO] {
        return try fetch("E1card").map { LegacyCardDTO(mo: $0) }
    }

    // MARK: - モデル定義 (AzCredit 4.xcdatamodel と一致)

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let e0 = entity("E0root")
        let e1 = entity("E1card")
        let e2 = entity("E2invoice")
        let e3 = entity("E3record")
        let e4 = entity("E4shop")
        let e5 = entity("E5tag")
        let e6 = entity("E6part")
        let e7 = entity("E7payment")
        let e8 = entity("E8bank")

        e1.properties = [
            str("zName"), str("zNote"),
            int32("nRow"),
            int16("nClosingDay"), int16("nPayDay"), int16("nPayMonth"),
            int16("nBonus1"), int16("nBonus2"),
            date("dateUpdate"),
            decimal("sumPaid"), decimal("sumUnpaid"), int16("sumNoCheck"),
        ]
        e2.properties = [
            int32("nYearMMDD"), decimal("sumAmount"), int16("sumNoCheck"),
        ]
        e3.properties = [
            date("dateUse"), str("zName"), str("zNote"),
            decimal("nAmount"), int16("nPayType"), int16("nRepeat"),
            float("nAnnual"), int16("sumNoCheck"),
        ]
        e4.properties = [
            str("zName"), str("zNote"), str("sortName"),
            decimal("sortAmount"), int32("sortCount"), date("sortDate"),
        ]
        e5.properties = [
            str("zName"), str("zNote"), str("sortName"),
            decimal("sortAmount"), int32("sortCount"), date("sortDate"),
        ]
        e6.properties = [
            int16("nPartNo"), decimal("nAmount"), decimal("nInterest"), int16("nNoCheck"),
        ]
        e7.properties = [
            int32("nYearMMDD"), decimal("sumAmount"), int16("sumNoCheck"),
        ]
        e8.properties = [
            str("zName"), str("zNote"), int32("nRow"),
        ]

        // Relationships
        let e0_e7paids   = rel("e7paids",   dst: e7, many: true)
        let e0_e7unpaids = rel("e7unpaids", dst: e7, many: true)
        let e7_e0paid    = rel("e0paid",    dst: e0, many: false)
        let e7_e0unpaid  = rel("e0unpaid",  dst: e0, many: false)
        e0_e7paids.inverseRelationship   = e7_e0paid
        e7_e0paid.inverseRelationship    = e0_e7paids
        e0_e7unpaids.inverseRelationship = e7_e0unpaid
        e7_e0unpaid.inverseRelationship  = e0_e7unpaids
        e0.properties.append(contentsOf: [e0_e7paids, e0_e7unpaids])
        e7.properties.append(contentsOf: [e7_e0paid, e7_e0unpaid])

        let e8_e1cards = rel("e1cards", dst: e1, many: true)
        let e1_e8bank  = rel("e8bank",  dst: e8, many: false)
        e8_e1cards.inverseRelationship = e1_e8bank
        e1_e8bank.inverseRelationship  = e8_e1cards
        e8.properties.append(e8_e1cards)
        e1.properties.append(e1_e8bank)

        let e1_e2paids   = rel("e2paids",   dst: e2, many: true)
        let e1_e2unpaids = rel("e2unpaids", dst: e2, many: true)
        let e2_e1paid    = rel("e1paid",    dst: e1, many: false)
        let e2_e1unpaid  = rel("e1unpaid",  dst: e1, many: false)
        e1_e2paids.inverseRelationship   = e2_e1paid
        e2_e1paid.inverseRelationship    = e1_e2paids
        e1_e2unpaids.inverseRelationship = e2_e1unpaid
        e2_e1unpaid.inverseRelationship  = e1_e2unpaids
        e1.properties.append(contentsOf: [e1_e2paids, e1_e2unpaids])
        e2.properties.append(contentsOf: [e2_e1paid, e2_e1unpaid])

        let e1_e3records = rel("e3records", dst: e3, many: true)
        let e3_e1card    = rel("e1card",    dst: e1, many: false)
        e1_e3records.inverseRelationship = e3_e1card
        e3_e1card.inverseRelationship    = e1_e3records
        e1.properties.append(e1_e3records)
        e3.properties.append(e3_e1card)

        let e7_e2invoices = rel("e2invoices", dst: e2, many: true)
        let e2_e7payment  = rel("e7payment",  dst: e7, many: false)
        e7_e2invoices.inverseRelationship = e2_e7payment
        e2_e7payment.inverseRelationship  = e7_e2invoices
        e7.properties.append(e7_e2invoices)
        e2.properties.append(e2_e7payment)

        let e2_e6parts   = rel("e6parts",  dst: e6, many: true)
        let e6_e2invoice = rel("e2invoice", dst: e2, many: false)
        e2_e6parts.inverseRelationship   = e6_e2invoice
        e6_e2invoice.inverseRelationship = e2_e6parts
        e2.properties.append(e2_e6parts)
        e6.properties.append(e6_e2invoice)

        let e3_e6parts   = rel("e6parts",  dst: e6, many: true)
        let e6_e3record  = rel("e3record", dst: e3, many: false)
        e3_e6parts.inverseRelationship   = e6_e3record
        e6_e3record.inverseRelationship  = e3_e6parts
        e3.properties.append(e3_e6parts)
        e6.properties.append(e6_e3record)

        let e4_e3records = rel("e3records", dst: e3, many: true)
        let e3_e4shop    = rel("e4shop",    dst: e4, many: false)
        e4_e3records.inverseRelationship = e3_e4shop
        e3_e4shop.inverseRelationship    = e4_e3records
        e4.properties.append(e4_e3records)
        e3.properties.append(e3_e4shop)

        let e5_e3records  = rel("e3records",  dst: e3, many: true)
        let e3_e5category = rel("e5category", dst: e5, many: false)
        e5_e3records.inverseRelationship  = e3_e5category
        e3_e5category.inverseRelationship = e5_e3records
        e5.properties.append(e5_e3records)
        e3.properties.append(e3_e5category)

        model.entities = [e0, e1, e2, e3, e4, e5, e6, e7, e8]
        return model
    }

    // MARK: - ヘルパー

    private static func entity(_ name: String) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = []
        return e
    }

    private static func str(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .stringAttributeType; a.isOptional = true; return a
    }
    private static func int16(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .integer16AttributeType; a.isOptional = true; return a
    }
    private static func int32(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .integer32AttributeType; a.isOptional = true; return a
    }
    private static func decimal(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .decimalAttributeType; a.isOptional = true; return a
    }
    private static func float(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .floatAttributeType; a.isOptional = true; return a
    }
    private static func date(_ name: String) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name
        a.attributeType = .dateAttributeType; a.isOptional = true; return a
    }
    private static func rel(_ name: String, dst: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name; r.destinationEntity = dst
        r.minCount = 0; r.maxCount = many ? 0 : 1
        r.deleteRule = .nullifyDeleteRule; r.isOptional = true
        return r
    }
}

// MARK: - DTO

private struct LegacyDataDTO {
    var banks: [LegacyBankDTO] = []
    var shops: [LegacyShopDTO] = []
    var categories: [LegacyCategoryDTO] = []
    var cards: [LegacyCardDTO] = []
}

private struct LegacyBankDTO {
    let objectID: NSManagedObjectID
    let zName: String; let zNote: String; let nRow: Int32
    init(mo: NSManagedObject) {
        objectID = mo.objectID
        zName = mo.str("zName"); zNote = mo.str("zNote"); nRow = mo.int32("nRow")
    }
}

private struct LegacyShopDTO {
    let objectID: NSManagedObjectID
    let zName: String; let zNote: String; let sortName: String
    let sortAmount: Decimal; let sortCount: Int32; let sortDate: Date?
    init(mo: NSManagedObject) {
        objectID = mo.objectID
        zName = mo.str("zName"); zNote = mo.str("zNote"); sortName = mo.str("sortName")
        sortAmount = mo.decimal("sortAmount"); sortCount = mo.int32("sortCount")
        sortDate = mo.value(forKey: "sortDate") as? Date
    }
}

private struct LegacyCategoryDTO {
    let objectID: NSManagedObjectID
    let zName: String; let zNote: String; let sortName: String
    let sortAmount: Decimal; let sortCount: Int32; let sortDate: Date?
    init(mo: NSManagedObject) {
        objectID = mo.objectID
        zName = mo.str("zName"); zNote = mo.str("zNote"); sortName = mo.str("sortName")
        sortAmount = mo.decimal("sortAmount"); sortCount = mo.int32("sortCount")
        sortDate = mo.value(forKey: "sortDate") as? Date
    }
}

private struct LegacyCardDTO {
    let objectID: NSManagedObjectID
    let zName: String; let zNote: String; let nRow: Int32
    let nClosingDay: Int16; let nPayDay: Int16; let nPayMonth: Int16
    let nBonus1: Int16; let nBonus2: Int16; let dateUpdate: Date?
    let sumPaid: Decimal; let sumUnpaid: Decimal; let sumNoCheck: Int16
    let bankObjectID: NSManagedObjectID?
    let records: [LegacyRecordDTO]
    let invoicesPaid: [LegacyInvoiceDTO]
    let invoicesUnpaid: [LegacyInvoiceDTO]

    init(mo: NSManagedObject) {
        objectID = mo.objectID
        zName = mo.str("zName"); zNote = mo.str("zNote"); nRow = mo.int32("nRow")
        nClosingDay = mo.int16("nClosingDay"); nPayDay = mo.int16("nPayDay")
        nPayMonth = mo.int16("nPayMonth")
        nBonus1 = mo.int16("nBonus1"); nBonus2 = mo.int16("nBonus2")
        dateUpdate = mo.value(forKey: "dateUpdate") as? Date
        sumPaid = mo.decimal("sumPaid"); sumUnpaid = mo.decimal("sumUnpaid")
        sumNoCheck = mo.int16("sumNoCheck")
        bankObjectID = (mo.value(forKey: "e8bank") as? NSManagedObject)?.objectID

        records = Self.toSet(mo, key: "e3records")
            .map { LegacyRecordDTO(mo: $0) }

        let paidSet   = Self.toSet(mo, key: "e2paids")
        let unpaidSet = Self.toSet(mo, key: "e2unpaids")
        invoicesPaid   = paidSet.map   { LegacyInvoiceDTO(mo: $0, isPaid: true) }
        invoicesUnpaid = unpaidSet.map { LegacyInvoiceDTO(mo: $0, isPaid: false) }
    }

    private static func toSet(_ mo: NSManagedObject, key: String) -> [NSManagedObject] {
        if let set = mo.value(forKey: key) as? Set<NSManagedObject> { return Array(set) }
        if let arr = mo.value(forKey: key) as? [NSManagedObject]    { return arr }
        return []
    }
}

private struct LegacyRecordDTO {
    let objectID: NSManagedObjectID
    let dateUse: Date?; let zName: String; let zNote: String
    let nAmount: Decimal; let nPayType: Int16; let nRepeat: Int16
    let nAnnual: Float; let sumNoCheck: Int16
    let shopObjectID: NSManagedObjectID?
    let categoryObjectID: NSManagedObjectID?

    init(mo: NSManagedObject) {
        objectID = mo.objectID
        dateUse = mo.value(forKey: "dateUse") as? Date
        zName = mo.str("zName"); zNote = mo.str("zNote")
        nAmount = mo.decimal("nAmount"); nPayType = mo.int16("nPayType")
        nRepeat = mo.int16("nRepeat"); nAnnual = mo.float("nAnnual")
        sumNoCheck = mo.int16("sumNoCheck")
        shopObjectID     = (mo.value(forKey: "e4shop")     as? NSManagedObject)?.objectID
        categoryObjectID = (mo.value(forKey: "e5category") as? NSManagedObject)?.objectID
    }
}

private struct LegacyInvoiceDTO {
    let objectID: NSManagedObjectID
    let nYearMMDD: Int32; let isPaid: Bool
    let paymentObjectID: NSManagedObjectID?
    let parts: [LegacyPartDTO]

    init(mo: NSManagedObject, isPaid: Bool) {
        objectID = mo.objectID
        nYearMMDD = mo.int32("nYearMMDD"); self.isPaid = isPaid
        paymentObjectID = (mo.value(forKey: "e7payment") as? NSManagedObject)?.objectID
        let set: [NSManagedObject]
        if let s = mo.value(forKey: "e6parts") as? Set<NSManagedObject> { set = Array(s) }
        else if let a = mo.value(forKey: "e6parts") as? [NSManagedObject] { set = a }
        else { set = [] }
        parts = set.map { LegacyPartDTO(mo: $0) }
    }
}

private struct LegacyPartDTO {
    let nPartNo: Int16; let nAmount: Decimal; let nInterest: Decimal; let nNoCheck: Int16
    let recordObjectID: NSManagedObjectID?

    init(mo: NSManagedObject) {
        nPartNo = mo.int16("nPartNo"); nAmount = mo.decimal("nAmount")
        nInterest = mo.decimal("nInterest"); nNoCheck = mo.int16("nNoCheck")
        recordObjectID = (mo.value(forKey: "e3record") as? NSManagedObject)?.objectID
    }
}

// MARK: - NSManagedObject 拡張

private extension NSManagedObject {
    func str(_ key: String)     -> String  { value(forKey: key) as? String ?? "" }
    func int16(_ key: String)   -> Int16   { (value(forKey: key) as? NSNumber)?.int16Value ?? 0 }
    func int32(_ key: String)   -> Int32   { (value(forKey: key) as? NSNumber)?.int32Value ?? 0 }
    func float(_ key: String)   -> Float   { (value(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    func decimal(_ key: String) -> Decimal {
        if let d = value(forKey: key) as? NSDecimalNumber { return d as Decimal }
        if let n = value(forKey: key) as? NSNumber        { return Decimal(n.doubleValue) }
        return .zero
    }
}
