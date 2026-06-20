import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct JSONRoundTripTests {
    // Export → 新コンテナへ Import で件数・関係・状態が等価
    @Test func fullRoundTripPreservesDataset() async throws {
        let sourceContext = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "口座A", in: sourceContext)
        let bankB = TestFixtures.makeBank(name: "口座B", in: sourceContext)
        let cardA = TestFixtures.makeCard(name: "カードA", bank: bankA, in: sourceContext)
        let cardB = TestFixtures.makeCard(name: "カードB", bank: bankB, in: sourceContext)
        let tag = TestFixtures.makeTag(name: "食費", in: sourceContext)

        _ = try TestFixtures.saveRecord(
            amount: 1_200,
            label: "コンビニ",
            dateUse: TestStore.date(2026, 4, 5),
            card: cardA,
            tags: [tag],
            in: sourceContext
        )
        _ = try TestFixtures.saveRecord(
            amount: 5_400,
            label: "書店",
            dateUse: TestStore.date(2026, 4, 10),
            card: cardB,
            in: sourceContext
        )
        // 1件は引き落とし済みにして状態も伝わるか確認する
        let invoiceB = try #require(
            try sourceContext.fetch(FetchDescriptor<E2invoice>())
                .first(where: { $0.e1card?.id == cardB.id })
        )
        try RecordService.setInvoicesPaid([invoiceB], isPaid: true, context: sourceContext)

        let data = try await JSONExport.exportData(context: sourceContext, style: .compact)
        let url = try writeTempJSON(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let targetContext = try TestStore.makeContext()
        let result = try await JSONImport.importData(from: url, context: targetContext)
        // 取り込み件数が一致
        #expect(result.bankCount == 2)
        #expect(result.cardCount == 2)
        #expect(result.tagCount == 1)
        #expect(result.recordCount == 2)

        // 関係も復元される
        let targetInvoices = try targetContext.fetch(FetchDescriptor<E2invoice>())
        #expect(targetInvoices.count == 2)
        let paidCount = targetInvoices.filter(\.isPaid).count
        #expect(paidCount == 1)

        let targetPayments = try targetContext.fetch(FetchDescriptor<E7payment>())
        // 口座が違うので payment は 2 件残る
        #expect(targetPayments.count == 2)

        let report = RecordService.checkBillingIntegrity(context: targetContext)
        #expect(report.hasIssue == false)
    }

    // 同じ JSON を 2 度取り込んでも重複しない（id 単位 upsert）
    @Test func reimportingSameJSONIsIdempotent() async throws {
        let sourceContext = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: sourceContext)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: sourceContext)
        _ = try TestFixtures.saveRecord(
            amount: 999,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: sourceContext
        )
        let data = try await JSONExport.exportData(context: sourceContext, style: .compact)
        let url = try writeTempJSON(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let targetContext = try TestStore.makeContext()
        _ = try await JSONImport.importData(from: url, context: targetContext)
        let afterFirst = try counts(targetContext)
        _ = try await JSONImport.importData(from: url, context: targetContext)
        let afterSecond = try counts(targetContext)
        #expect(afterFirst == afterSecond)

        let report = RecordService.checkBillingIntegrity(context: targetContext)
        #expect(report.hasIssue == false)
    }

    // マスタ（口座）だけの部分 JSON を受け入れる
    @Test func partialJSONMastersOnly() async throws {
        let json = """
        {
          "banks": [
            {"id":"bank-1","name":"テスト口座","note":"","row":0}
          ]
        }
        """
        let data = Data(json.utf8)
        let url = try writeTempJSON(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let context = try TestStore.makeContext()
        let result = try await JSONImport.importData(from: url, context: context)
        #expect(result.bankCount == 1)
        #expect(result.cardCount == 0)
        #expect(result.recordCount == 0)

        let banks = try context.fetch(FetchDescriptor<E8bank>())
        #expect(banks.contains { $0.id == "bank-1" })
    }

    // N日後型 (closingDay=0) で payMonth が非0で来ても、現行正規形 0 に整形される
    @Test func cardBillingFormNormalizedOnImport() async throws {
        // closingDay=0 / payMonth=2 の不整合を含む JSON
        let json = """
        {
          "cards": [
            {
              "id":"card-x","name":"N日後カード","note":"","row":0,
              "closingDay":0,"payDay":15,"payMonth":2,
              "bonus1":0,"bonus2":0,"bankID":null
            }
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let context = try TestStore.makeContext()
        _ = try await JSONImport.importData(from: url, context: context)

        let card = try #require(
            try context.fetch(FetchDescriptor<E1card>()).first(where: { $0.id == "card-x" })
        )
        #expect(card.nClosingDay == 0)
        #expect(card.nPayDay == 15)
        // closingDay==0 の N日後型は payMonth==0 を強制する
        #expect(card.nPayMonth == 0)
    }

    // 旧 JSON の "categories" キーを "tags" として取り込む
    @Test func legacyCategoriesAreImportedAsTags() async throws {
        let json = """
        {
          "categories": [
            {"id":"tag-1","name":"食費","note":""},
            {"id":"tag-2","name":"娯楽","note":""}
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let context = try TestStore.makeContext()
        let result = try await JSONImport.importData(from: url, context: context)
        #expect(result.tagCount == 2)
        let tags = try context.fetch(FetchDescriptor<E5tag>())
        #expect(Set(tags.map(\.id)) == Set(["tag-1", "tag-2"]))
    }

    private func writeTempJSON(_ data: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("credit-memo-test-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func counts(_ context: ModelContext) throws -> Counts {
        Counts(
            banks: try context.fetch(FetchDescriptor<E8bank>()).count,
            cards: try context.fetch(FetchDescriptor<E1card>()).count,
            tags: try context.fetch(FetchDescriptor<E5tag>()).count,
            records: try context.fetch(FetchDescriptor<E3record>()).count,
            parts: try context.fetch(FetchDescriptor<E6part>()).count,
            invoices: try context.fetch(FetchDescriptor<E2invoice>()).count,
            payments: try context.fetch(FetchDescriptor<E7payment>()).count
        )
    }

    private struct Counts: Equatable {
        let banks: Int
        let cards: Int
        let tags: Int
        let records: Int
        let parts: Int
        let invoices: Int
        let payments: Int
    }
}
