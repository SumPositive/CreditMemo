import Foundation
import SwiftData

/// 決済手段の削除処理
@MainActor
enum CardService {
    static func delete(_ card: E1card, context: ModelContext) throws {
        let cardID = card.id
        let recordDesc = FetchDescriptor<E3record>(
            predicate: #Predicate<E3record> { $0.e1card?.id == cardID }
        )
        // 履歴は消さず、決済手段だけ未選択へ戻す
        let records = context.fetchReporting(recordDesc, entity: "E3record")

        for record in records {
            // 先に参照を外してから請求を未選択決済として再構築する
            record.e1card = nil
            RecordService.rebuildBilling(for: record, context: context)
        }

        // 参照先が消えたあとの孤児データを整理する
        RecordService.cleanupOrphanBilling(context: context)

        // 決済手段本体を削除する（履歴側の変更とまとめて1回で保存）
        context.delete(card)

        if context.hasChanges {
            try context.save()
        }
    }
}
