import Foundation
import SwiftData

/// 分割払い明細
/// - nNoCheck: 0=確認済(checked), 1=未確認(unchecked) ← 旧来の符号をそのまま維持
/// - nDueDateLocked: 引き落とし日だけを固定する専用フラグ
@Model
final class E6part {
    @Attribute(.unique) var id: String
    var nPartNo: Int16
    var nAmount: Decimal
    var nInterest: Decimal
    var nNoCheck: Int16   // 0=checked, 1=unchecked (default)
    var nDueDateLocked: Bool?

    var e2invoice: E2invoice?
    var e3record: E3record?

    var isChecked: Bool {
        get { nNoCheck == 0 }
        set { nNoCheck = newValue ? 0 : 1 }
    }

    var isDueDateLocked: Bool {
        get { nDueDateLocked ?? false }
        set { nDueDateLocked = newValue }
    }

    init(
        id: String = UUID().uuidString,
        nPartNo: Int16 = 0,
        nAmount: Decimal = 0,
        nInterest: Decimal = 0,
        nNoCheck: Int16 = 1,
        nDueDateLocked: Bool? = nil
    ) {
        self.id = id
        self.nPartNo = nPartNo
        self.nAmount = nAmount
        self.nInterest = nInterest
        self.nNoCheck = nNoCheck
        self.nDueDateLocked = nDueDateLocked
    }
}
