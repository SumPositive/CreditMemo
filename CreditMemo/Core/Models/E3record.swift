import Foundation
import SwiftData

/// 支払方法（回数）。`nPayType` が支払回数 N をそのまま表す（1=一括, 2..12=分割）。
/// 旧データ（1=一括 / 2=2回払い）はそのまま連続値へ収まるため無変換で互換。
enum PayCount {
    static let min: Int = 1
    static let max: Int = 12

    /// 「N回払い」表示文字列。1回は一括払い表記にする
    static func localizedLabel(_ count: Int) -> String {
        if count <= 1 {
            return String(localized: "payType.lumpSum")
        }
        return String.localizedStringWithFormat(String(localized: "payType.installments"), count)
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
    var nPayType: Int16 {  // 支払回数 N（1=一括, 2..12=分割）
        didSet {
            // 旧データや外部入力の不正値は、モデル境界で 1..12 に正規化する
            nPayType = Self.normalizedPayTypeRawValue(nPayType)
        }
    }
    var nRepeat: Int16     // 繰り返し月数 (0=なし, 1-99)
    var nAnnual: Float     // 年利率 (通常は0)
    var sumNoCheck: Int16  // 未チェック分割数（集計値）

    var e1card: E1card?
    var e5tags: [E5tag] = []
    @Relationship(deleteRule: .cascade) var e6parts: [E6part]

    /// 支払回数 N（1..12）。UI・計算はこちらを使う
    var payCount: Int {
        get { Int(nPayType) }
        set { nPayType = Self.normalizedPayTypeRawValue(Int16(newValue)) }
    }

    /// 2回以上の分割払いか
    var isInstallment: Bool { payCount >= 2 }

    static func normalizedPayTypeRawValue(_ rawValue: Int16) -> Int16 {
        min(max(rawValue, Int16(PayCount.min)), Int16(PayCount.max))
    }

    init(
        id: String = UUID().uuidString,
        dateUse: Date = Date(),
        dateUpdate: Date? = Date(),
        zName: String = "",
        zNote: String = "",
        nAmount: Decimal = 0,
        nPayType: Int16 = 1,
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
