import Foundation
import SwiftData

// 支払方法
enum PayType: Int16, CaseIterable, Codable {
    case lumpSum     = 1  // 一括
    case twoPayments = 2  // 2回払い

    var localizedKey: String {
        switch self {
        case .lumpSum:     return "payType.lumpSum"
        case .twoPayments: return "payType.twoPayments"
        }
    }
}

/// 利用明細
@Model
final class E3record {
    @Attribute(.unique) var id: String
    var dateUse: Date
    // 入力順を安定化するための更新日時（後方互換のためOptional）
    var dateUpdate: Date?
    var zName: String
    var zNote: String
    var nAmount: Decimal
    var nPayType: Int16 {  // PayType.rawValue
        didSet {
            // 旧データや外部入力の不正値は、モデル境界で一括払いへ正規化する
            nPayType = Self.normalizedPayTypeRawValue(nPayType)
        }
    }
    var nRepeat: Int16     // 繰り返し月数 (0=なし, 1-99)
    var nAnnual: Float     // 年利率 (通常は0)
    var sumNoCheck: Int16  // 未チェック分割数（集計値）

    var e1card: E1card?
    var e5tags: [E5tag] = []
    @Relationship(deleteRule: .cascade) var e6parts: [E6part]

    var payType: PayType {
        get { PayType(rawValue: nPayType) ?? .lumpSum }
        set { nPayType = Self.normalizedPayTypeRawValue(newValue.rawValue) }
    }

    static func normalizedPayTypeRawValue(_ rawValue: Int16) -> Int16 {
        rawValue == PayType.twoPayments.rawValue
            ? PayType.twoPayments.rawValue
            : PayType.lumpSum.rawValue
    }

    init(
        id: String = UUID().uuidString,
        dateUse: Date = Date(),
        dateUpdate: Date? = Date(),
        zName: String = "",
        zNote: String = "",
        nAmount: Decimal = 0,
        nPayType: Int16 = PayType.lumpSum.rawValue,
        nRepeat: Int16 = 0,
        nAnnual: Float = 0,
        sumNoCheck: Int16 = 0
    ) {
        self.id = id
        self.dateUse = dateUse
        self.dateUpdate = dateUpdate
        self.zName = zName
        self.zNote = zNote
        self.nAmount = nAmount
        self.nPayType = Self.normalizedPayTypeRawValue(nPayType)
        self.nRepeat = nRepeat
        self.nAnnual = nAnnual
        self.sumNoCheck = sumNoCheck
        self.e6parts = []
    }
}
