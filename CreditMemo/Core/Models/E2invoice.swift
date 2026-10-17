import Foundation
import SwiftData

/// 請求書（カード・月別）
/// - date: 旧 nYearMMDD(Int32 YYYYMMDD形式) から Date に変換
/// - 旧方式に合わせ、paid/unpaid の所属で状態を表す
@Model
final class E2invoice {
    @Attribute(.unique) var id: String
    var date: Date

    var e1paid: E1card?
    var e1unpaid: E1card?
    var e7payment: E7payment?
    @Relationship(deleteRule: .cascade) var e6parts: [E6part]
    /// 照合モードで差額0にして確定した時の請求合計。未照合・照合途中は nil。
    /// 同じ決済手段・同じ引き落とし日の請求（未払/済み）すべてに同じ値を持たせ、
    /// 明細を済みへ移して請求が分かれたり片方が消えたりしても値が残るようにする
    var reconciledAmount: Decimal?

    // 分割明細の集計（都度計算）
    var sumAmount: Decimal { e6parts.reduce(.zero) { $0 + $1.nAmount } }
    var sumNoCheck: Int16  { Int16(e6parts.filter { $0.nNoCheck != 0 }.count) }
    var e1card: E1card? { e1paid ?? e1unpaid }
    var isPaid: Bool { e1paid != nil && e1unpaid == nil }

    init(
        id: String = UUID().uuidString,
        date: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.e6parts = []
    }
}
