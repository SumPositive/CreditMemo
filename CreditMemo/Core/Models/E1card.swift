import Foundation
import SwiftData

/// クレジットカード
///
/// 締日 (nClosingDay): 1-28=締日, 29=末日, 0=N日後型
/// 支払日 (nPayDay):   1-28=支払日, 29=末日, nClosingDay=0 のときは N日後のN
/// 支払月 (nPayMonth): 0/1/2 = 支払月(利用月からの月数), nClosingDay=0 のときは 0
/// ボーナス月 (nBonus1/2): 0=なし, 1-12=月
/// 請求方式:
/// - nClosingDay != 0: 締日/支払日/支払月を利用
/// - nClosingDay == 0: N日後型として nPayDay を使う
///
@Model
final class E1card {
    @Attribute(.unique) var id: String
    var zName: String
    var zNote: String
    var nRow: Int32
    var nClosingDay: Int16
    var nPayDay: Int16
    var nPayMonth: Int16
    var nBonus1: Int16
    var nBonus2: Int16
    var dateUpdate: Date?
    /// 解約済みか。済みの履歴を残したまま、新しい決済の選択肢から外す（旧データは nil）
    var nCancelled: Bool?
    // 集計値（子レコード変更時に更新）
    var sumPaid: Decimal
    var sumUnpaid: Decimal
    var sumNoCheck: Int16

    var e8bank: E8bank?
    @Relationship(deleteRule: .cascade) var e2paids: [E2invoice]
    @Relationship(deleteRule: .cascade) var e2unpaids: [E2invoice]
    // 履歴は残し、決済手段だけ未選択化できるよう nullify にする
    @Relationship(deleteRule: .nullify) var e3records: [E3record]

    var isCancelled: Bool {
        get { nCancelled ?? false }
        set { nCancelled = newValue }
    }
    // 互換参照用に請求全体を返す
    var e2invoices: [E2invoice] { e2paids + e2unpaids }

    init(
        id: String = UUID().uuidString,
        zName: String = "",
        zNote: String = "",
        nRow: Int32 = 0,
        nClosingDay: Int16 = 20,
        nPayDay: Int16 = 27,
        nPayMonth: Int16 = 1,
        nBonus1: Int16 = 0,
        nBonus2: Int16 = 0,
        dateUpdate: Date? = nil,
        sumPaid: Decimal = 0,
        sumUnpaid: Decimal = 0,
        sumNoCheck: Int16 = 0
    ) {
        self.id = id
        self.zName = zName
        self.zNote = zNote
        self.nRow = nRow
        self.nClosingDay = nClosingDay
        self.nPayDay = nPayDay
        self.nPayMonth = nPayMonth
        self.nBonus1 = nBonus1
        self.nBonus2 = nBonus2
        self.dateUpdate = dateUpdate
        self.sumPaid = sumPaid
        self.sumUnpaid = sumUnpaid
        self.sumNoCheck = sumNoCheck
        self.e2paids = []
        self.e2unpaids = []
        self.e3records = []
    }
}
