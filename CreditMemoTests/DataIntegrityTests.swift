import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct DataIntegrityTests {
    @Test("1件の保存で E3record / E6part / E2invoice / E7payment が想定どおり生成される")
    func singleRecordSaveCreatesBilling() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "メイン口座", in: context)
        let card = TestFixtures.makeCard(name: "Visa", bank: bank, in: context)

        let record = try TestFixtures.saveRecord(
            amount: 12_345,
            label: "コンビニ",
            dateUse: TestStore.date(2026, 4, 10),
            card: card,
            in: context
        )

        #expect(record.e6parts.count == 1)
        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        #expect(invoices.count == 1)
        let payments = try context.fetch(FetchDescriptor<E7payment>())
        #expect(payments.count == 1)

        let invoice = try #require(invoices.first)
        #expect(invoice.e1card?.id == card.id)
        #expect(invoice.isPaid == false)
        #expect(invoice.sumAmount == 12_345)

        let payment = try #require(payments.first)
        #expect(payment.e8bank?.id == bank.id)
        #expect(payment.e2invoices.count == 1)
        #expect(payment.sumAmount == 12_345)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("同じカード・同じ請求月の2件は1つの請求にまとまる")
    func samePeriodInvoicesAreMerged() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カードA", bank: bank, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        _ = try TestFixtures.saveRecord(
            amount: 2_000,
            dateUse: TestStore.date(2026, 4, 10),
            card: card,
            in: context
        )

        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        #expect(invoices.count == 1)
        let invoice = try #require(invoices.first)
        #expect(invoice.e6parts.count == 2)
        #expect(invoice.sumAmount == 3_000)

        let payments = try context.fetch(FetchDescriptor<E7payment>())
        #expect(payments.count == 1)
        #expect(payments.first?.sumAmount == 3_000)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("異なる口座へぶら下がるカードの請求は、別の E7payment にまとまる")
    func differentBanksProduceSeparatePayments() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let cardA = TestFixtures.makeCard(name: "カードA", bank: bankA, in: context)
        let cardB = TestFixtures.makeCard(name: "カードB", bank: bankB, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: cardA,
            in: context
        )
        _ = try TestFixtures.saveRecord(
            amount: 2_000,
            dateUse: TestStore.date(2026, 4, 6),
            card: cardB,
            in: context
        )

        let payments = try context.fetch(FetchDescriptor<E7payment>())
        // 引き落とし日が同じでも口座が違うなら別の支払として扱う
        #expect(payments.count == 2)
        let banksOfPayments = Set(payments.compactMap { $0.e8bank?.id })
        #expect(banksOfPayments == Set([bankA.id, bankB.id]))

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("未払 → 済み切替で invoice / payment の所属が排他的に切り替わる")
    func togglePaidUpdatesRelationships() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_500,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )

        let invoice = try #require(try context.fetch(FetchDescriptor<E2invoice>()).first)
        #expect(invoice.e1paid == nil)
        #expect(invoice.e1unpaid?.id == card.id)
        #expect(invoice.isPaid == false)

        try RecordService.setInvoicesPaid([invoice], isPaid: true, context: context)
        #expect(invoice.isPaid == true)
        #expect(invoice.e1paid?.id == card.id)
        #expect(invoice.e1unpaid == nil)
        // 対応する payment も済み側へ移っているか確認
        #expect(invoice.e7payment?.e8paid?.id == bank.id)
        #expect(invoice.e7payment?.e8unpaid == nil)

        // 済み → 未払 へ戻す
        try RecordService.setInvoicesPaid([invoice], isPaid: false, context: context)
        #expect(invoice.isPaid == false)
        #expect(invoice.e1paid == nil)
        #expect(invoice.e1unpaid?.id == card.id)
        #expect(invoice.e7payment?.e8paid == nil)
        #expect(invoice.e7payment?.e8unpaid?.id == bank.id)

        // 集計値 (card.sumPaid 等) は SwiftData の inverse 同期が
        // インメモリストアで効かない既知の制約のため、ここでは検証しない
        // 整合性チェックで派生関係に矛盾がないことだけ確認する
        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.orphanPartCount == 0)
        #expect(report.duplicateInvoiceCount == 0)
        #expect(report.duplicatePaymentCount == 0)
        #expect(report.emptyInvoiceCount == 0)
        #expect(report.invoiceMissingPaymentCount == 0)
    }

    @Test("範囲外の nPayType は 1...12 にクランプされる")
    func invalidPayTypeIsNormalized() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        let record = E3record(
            dateUse: TestStore.date(2026, 4, 5),
            zName: "test",
            nAmount: 1_000,
            nPayType: 99
        )
        record.e1card = card
        context.insert(record)
        try RecordService.save(record, context: context)

        // 99 は上限 12 にクランプされる（1 回=一括, 2..12=分割）
        #expect(record.nPayType == Int16(PayCount.max))
        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.invalidPayTypeCount == 0)
    }
}
