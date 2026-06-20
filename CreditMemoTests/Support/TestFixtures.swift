import Foundation
import SwiftData
@testable import CreditMemo

@MainActor
enum TestFixtures {
    @discardableResult
    static func makeBank(
        name: String,
        in context: ModelContext
    ) -> E8bank {
        let bank = E8bank(zName: name)
        context.insert(bank)
        return bank
    }

    @discardableResult
    static func makeCard(
        name: String,
        bank: E8bank? = nil,
        closingDay: Int16 = 20,
        payDay: Int16 = 27,
        payMonth: Int16 = 1,
        in context: ModelContext
    ) -> E1card {
        let card = E1card(
            zName: name,
            nClosingDay: closingDay,
            nPayDay: payDay,
            nPayMonth: payMonth
        )
        card.e8bank = bank
        context.insert(card)
        return card
    }

    @discardableResult
    static func makeTag(
        name: String,
        in context: ModelContext
    ) -> E5tag {
        let tag = E5tag(zName: name)
        context.insert(tag)
        return tag
    }

    /// 1件の決済を保存して、関連請求・支払まで作り終えるショートカット
    @discardableResult
    static func saveRecord(
        amount: Decimal,
        label: String = "",
        dateUse: Date,
        card: E1card?,
        tags: [E5tag] = [],
        in context: ModelContext
    ) throws -> E3record {
        let record = E3record(
            dateUse: dateUse,
            zName: label,
            nAmount: amount
        )
        record.e1card = card
        record.e5tags = tags
        context.insert(record)
        try RecordService.save(record, context: context)
        return record
    }
}
