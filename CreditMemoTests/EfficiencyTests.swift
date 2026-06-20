import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct EfficiencyTests {
    // 200件を 1 枚のカードに保存しても、請求は重複せず月単位にまとまる
    @Test func bulkSaveDoesNotDuplicateBilling() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        for index in 0..<200 {
            // 利用日を約 200 日に分散させる
            let day = TestStore.date(2026, 1, 1).addingTimeInterval(Double(index) * 86_400)
            _ = try TestFixtures.saveRecord(
                amount: Decimal(index + 1),
                dateUse: day,
                card: card,
                in: context
            )
        }

        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        let payments = try context.fetch(FetchDescriptor<E7payment>())

        // 請求は (日付 + カード + 状態) でユニーク。同一日付の請求が複数並ばないこと
        let invoiceKeys = invoices.map { "\($0.date.timeIntervalSinceReferenceDate)-\($0.e1card?.id ?? "")-\($0.isPaid)" }
        #expect(invoiceKeys.count == Set(invoiceKeys).count)

        // 支払も同様に (日付 + 口座 + 状態) でユニーク
        let paymentKeys = payments.map { "\($0.date.timeIntervalSinceReferenceDate)-\($0.e8bank?.id ?? "")-\($0.e8paid != nil)" }
        #expect(paymentKeys.count == Set(paymentKeys).count)

        // 1請求ごとに対応 payment が必ず存在する
        for invoice in invoices {
            #expect(invoice.e7payment != nil)
        }

        // 200日に分散した利用日は同一カードなら少数の月別請求に集約される
        #expect(invoices.count < 20)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    // Export → Import 往復が緩い時間閾値（30 秒）内で完了する
    @Test func roundTripWithinReasonableTime() async throws {
        let sourceContext = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: sourceContext)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: sourceContext)
        for index in 0..<200 {
            let day = TestStore.date(2026, 1, 1).addingTimeInterval(Double(index) * 86_400)
            _ = try TestFixtures.saveRecord(
                amount: Decimal(index + 1),
                dateUse: day,
                card: card,
                in: sourceContext
            )
        }

        let started = Date()
        let data = try await JSONExport.exportData(context: sourceContext, style: .compact)
        let url = try writeTempJSON(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let targetContext = try TestStore.makeContext()
        _ = try await JSONImport.importData(from: url, context: targetContext)
        let elapsed = Date().timeIntervalSince(started)

        // CI の遅さも見越して 30 秒の緩い閾値
        #expect(elapsed < 30.0)

        // 取り込み結果の同型性も軽く検証
        #expect(try targetContext.fetch(FetchDescriptor<E3record>()).count == 200)
        let report = RecordService.checkBillingIntegrity(context: targetContext)
        #expect(report.hasIssue == false)
    }

    private func writeTempJSON(_ data: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("credit-memo-test-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
