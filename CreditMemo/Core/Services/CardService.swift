import Foundation
import SwiftData

/// 決済手段（カード）の作成・編集・削除
@MainActor
enum CardService {
    /// 1 バッチで再構築する E3record 件数
    private static let billingRebuildBatchSize = 50

    /// 新規カードを 1 件作成して保存する
    @discardableResult
    static func create(
        zName: String,
        zNote: String = "",
        nRow: Int32 = 0,
        nClosingDay: Int16,
        nPayDay: Int16,
        nPayMonth: Int16,
        bank: E8bank? = nil,
        context: ModelContext
    ) throws -> E1card {
        let card = E1card(
            zName: zName,
            zNote: zNote,
            nRow: nRow,
            nClosingDay: nClosingDay,
            nPayDay: nPayDay,
            nPayMonth: nPayMonth,
            nBonus1: 0,
            nBonus2: 0,
            dateUpdate: Date()
        )
        card.e8bank = bank
        context.insert(card)
        if context.hasChanges {
            try context.save()
        }
        return card
    }

    /// 既存カードへ編集内容を反映し、請求への影響があれば配下の履歴を再構築してから保存する
    /// - Parameter onBillingProgress: 再構築バッチごとに (完了件数, 総件数) を通知する
    static func applyEdits(
        to card: E1card,
        zName: String,
        zNote: String,
        nClosingDay: Int16,
        nPayDay: Int16,
        nPayMonth: Int16,
        bank: E8bank?,
        context: ModelContext,
        onBillingProgress: ((Int, Int) -> Void)? = nil
    ) async throws {
        let needsRebuild =
            card.e8bank?.id != bank?.id ||
            card.nClosingDay != nClosingDay ||
            card.nPayDay != nPayDay ||
            card.nPayMonth != nPayMonth

        card.zName = zName
        card.zNote = zNote
        card.nClosingDay = nClosingDay
        card.nPayDay = nPayDay
        card.nPayMonth = nPayMonth
        // ボーナス月は廃止し、常に 0 で保存する
        card.nBonus1 = 0
        card.nBonus2 = 0
        card.e8bank = bank
        card.dateUpdate = Date()

        if needsRebuild {
            try await rebuildBilling(for: card, context: context, onProgress: onBillingProgress)
        } else if context.hasChanges {
            try context.save()
        }
    }

    /// 配下の請求を全削除し、未選択決済のままにする
    /// - Note: 履歴 (E3record) は残し、決済手段だけ nil に戻す
    static func delete(_ card: E1card, context: ModelContext) throws {
        let cardID = card.id
        let recordDesc = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e1card?.id == cardID }
        )
        let records = context.fetchReporting(recordDesc, entity: "E3record")

        for record in records {
            // 先に参照を外してから請求を未選択決済として再構築する
            record.e1card = nil
            RecordService.rebuildBilling(for: record, context: context)
        }

        // 参照先が消えたあとの孤児データを整理する
        RecordService.cleanupOrphanBilling(context: context)

        // 決済手段本体を削除する（履歴側の変更とまとめて 1 回で保存）
        context.delete(card)

        if context.hasChanges {
            try context.save()
        }
    }

    /// カード配下の履歴を batch 単位で再構築する
    /// 途中のバッチ保存に失敗した場合は context.rollback() してから例外を投げる
    private static func rebuildBilling(
        for card: E1card,
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)?
    ) async throws {
        let records = fetchRecords(for: card, context: context)
        let total = records.count
        var batch: [E3record] = []
        var completed = 0

        for record in records {
            batch.append(record)
            if billingRebuildBatchSize <= batch.count {
                do {
                    try saveBatch(batch, context: context)
                } catch {
                    context.rollback()
                    throw error
                }
                completed += batch.count
                onProgress?(completed, total)
                batch.removeAll(keepingCapacity: true)
                // 長い再構築中もメインスレッドを譲り、UI 更新を進める
                await Task.yield()
            }
        }
        if !batch.isEmpty {
            do {
                try saveBatch(batch, context: context)
            } catch {
                context.rollback()
                throw error
            }
            completed += batch.count
            onProgress?(completed, total)
        }

        // 古い請求・支払を最後に掃除する
        RecordService.cleanupOrphanBilling(context: context)
        if context.hasChanges {
            try context.save()
        }
    }

    private static func saveBatch(_ records: [E3record], context: ModelContext) throws {
        for record in records {
            RecordService.rebuildBilling(for: record, context: context)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    private static func fetchRecords(for card: E1card, context: ModelContext) -> [E3record] {
        let cardID = card.id
        let descriptor = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e1card?.id == cardID },
            sortBy: [SortDescriptor(\E3record.dateUse)]
        )
        // 逆参照配列だけでは SwiftData の関係同期が遅れた履歴を取りこぼすので明示 fetch する
        return context.fetchReporting(descriptor, entity: "E3record")
    }
}
