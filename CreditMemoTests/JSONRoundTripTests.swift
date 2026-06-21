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

    // 不正な数値で失敗した場合は、途中まで追加した全データを破棄する
    @Test func invalidDecimalRollsBackEntireImport() async throws {
        let context = try TestStore.makeContext()
        let existingBank = TestFixtures.makeBank(name: "既存口座", in: context)
        existingBank.zNote = "変更前"
        try context.save()
        let before = try databaseSnapshot(context)
        let autosaveBefore = context.autosaveEnabled

        let json = """
        {
          "banks": [
            {"id":"bank-new","name":"新規口座","note":"","row":0}
          ],
          "cards": [
            {
              "id":"card-new","name":"新規カード","note":"","row":0,
              "closingDay":20,"payDay":27,"payMonth":1,
              "bonus1":0,"bonus2":0,"bankID":"bank-new"
            }
          ],
          "tags": [
            {"id":"tag-new","name":"新規タグ","note":""}
          ],
          "records": [
            {
              "id":"record-valid","dateUse":"2026-04-01T00:00:00Z",
              "name":"正常","note":"","amount":"1000","payType":1,
              "repeatMonths":0,"cardID":"card-new","tagIDs":["tag-new"]
            },
            {
              "id":"record-invalid","dateUse":"2026-04-02T00:00:00Z",
              "name":"不正","note":"","amount":"invalid","payType":1,
              "repeatMonths":0,"cardID":"card-new","tagIDs":[]
            }
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await expectImportFailure(from: url, context: context)

        #expect(try databaseSnapshot(context) == before)
        #expect(context.autosaveEnabled == autosaveBefore)
    }

    // 初期プリセットを削除した後に失敗しても、削除を含む変更を巻き戻す
    @Test func failedFullRestoreKeepsInitialSeedData() async throws {
        let context = try TestStore.makeContext()
        SeedData.seedIfNeeded(context: context)
        let before = try databaseSnapshot(context)

        let json = """
        {
          "banks": [],
          "cards": [],
          "tags": [],
          "records": [
            {
              "id":"record-invalid","dateUse":"2026-04-01T00:00:00Z",
              "name":"不正","note":"","amount":"invalid","payType":1,
              "repeatMonths":0,"cardID":null,"tagIDs":[]
            }
          ],
          "parts": [],
          "invoices": [],
          "payments": []
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await expectImportFailure(from: url, context: context)

        #expect(try databaseSnapshot(context) == before)
    }

    // 既存データ更新後に失敗した場合は、各値と関連を保存済み状態へ戻す
    @Test func failedUpdateRestoresExistingValuesAndRelationships() async throws {
        let context = try TestStore.makeContext()
        let bank = E8bank(id: "bank-existing", zName: "既存口座", zNote: "変更前")
        let card = E1card(id: "card-existing", zName: "既存カード")
        let tag = E5tag(id: "tag-existing", zName: "既存タグ", sortName: "既存タグ")
        let record = E3record(
            id: "record-existing",
            dateUse: TestStore.date(2026, 3, 1),
            zName: "既存履歴",
            zNote: "変更前",
            nAmount: 500
        )
        card.e8bank = bank
        record.e1card = card
        record.e5tags = [tag]
        context.insert(bank)
        context.insert(card)
        context.insert(tag)
        context.insert(record)
        try context.save()
        let before = try databaseSnapshot(context)

        let json = """
        {
          "banks": [
            {"id":"bank-existing","name":"更新口座","note":"更新後","row":9}
          ],
          "cards": [
            {
              "id":"card-existing","name":"更新カード","note":"更新後","row":9,
              "closingDay":15,"payDay":10,"payMonth":2,
              "bonus1":6,"bonus2":12,"bankID":null
            }
          ],
          "tags": [
            {"id":"tag-existing","name":"更新タグ","note":"更新後"}
          ],
          "records": [
            {
              "id":"record-existing","dateUse":"2026-04-01T00:00:00Z",
              "name":"更新履歴","note":"更新後","amount":"9999","payType":2,
              "repeatMonths":3,"cardID":null,"tagIDs":[]
            },
            {
              "id":"record-invalid","dateUse":"2026-04-02T00:00:00Z",
              "name":"不正","note":"","amount":"invalid","payType":1,
              "repeatMonths":0,"cardID":null,"tagIDs":[]
            }
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        await expectImportFailure(from: url, context: context)

        #expect(try databaseSnapshot(context) == before)
    }

    // 構文、ルート型、必須値、日付、数値の破損で既存DBを変更しない
    @Test func malformedJSONDoesNotChangeDatabase() async throws {
        let invalidJSONs = [
            "",
            "{",
            "[]",
            "{\"banks\":[{\"name\":\"IDなし\",\"note\":\"\",\"row\":0}]}",
            "{\"banks\":[{\"id\":\"bank\",\"name\":\"口座\",\"note\":\"\",\"row\":\"0\"}]}",
            "{\"records\":[{\"id\":\"record\",\"dateUse\":\"not-a-date\",\"name\":\"履歴\",\"note\":\"\",\"amount\":\"100\",\"payType\":1,\"repeatMonths\":0}]}",
            "{\"records\":[{\"id\":\"record\",\"dateUse\":\"2026-04-01T00:00:00Z\",\"name\":\"履歴\",\"note\":\"\",\"amount\":\"\",\"payType\":1,\"repeatMonths\":0}]}"
        ]

        for json in invalidJSONs {
            let context = try TestStore.makeContext()
            _ = TestFixtures.makeBank(name: "既存口座", in: context)
            try context.save()
            let before = try databaseSnapshot(context)
            let url = try writeTempJSON(Data(json.utf8))
            defer { try? FileManager.default.removeItem(at: url) }

            await expectImportFailure(from: url, context: context)

            #expect(try databaseSnapshot(context) == before)
        }

        // 存在しないファイルもDBへ影響しない
        let context = try TestStore.makeContext()
        _ = TestFixtures.makeBank(name: "既存口座", in: context)
        try context.save()
        let before = try databaseSnapshot(context)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        await expectImportFailure(from: missingURL, context: context)
        #expect(try databaseSnapshot(context) == before)
    }

    // 存在しない参照IDは関連を作らず、安全に無視する
    @Test func unresolvedReferenceIDsAreIgnored() async throws {
        let json = """
        {
          "cards": [
            {
              "id":"card-1","name":"カード","note":"","row":0,
              "closingDay":20,"payDay":27,"payMonth":1,
              "bonus1":0,"bonus2":0,"bankID":"missing-bank"
            }
          ],
          "records": [
            {
              "id":"record-1","dateUse":"2026-04-01T00:00:00Z",
              "name":"履歴","note":"","amount":"1000","payType":1,
              "repeatMonths":0,"cardID":"missing-card","tagIDs":["missing-tag"]
            }
          ],
          "parts": [
            {"id":"part-1","recordID":"missing-record","partNo":1,"amount":"1000"}
          ],
          "invoices": [
            {"id":"invoice-1","date":"2026-05-27T00:00:00Z","isPaid":true,"cardID":"missing-card","paymentID":"missing-payment"}
          ],
          "payments": [
            {"id":"payment-1","date":"2026-05-27T00:00:00Z","bankID":"missing-bank","isPaid":true}
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try TestStore.makeContext()

        let result = try await JSONImport.importData(from: url, context: context)

        let card = try #require(try context.fetch(FetchDescriptor<E1card>()).first)
        let record = try #require(try context.fetch(FetchDescriptor<E3record>()).first)
        #expect(card.e8bank == nil)
        #expect(record.e1card == nil)
        #expect(record.e5tags.isEmpty)
        #expect(result.partStateCount == 0)
        #expect(result.invoiceStateCount == 0)
        #expect(result.paymentStateCount == 0)
        #expect(RecordService.checkBillingIntegrity(context: context).hasIssue == false)
    }

    // 同一JSON内でIDが重複した場合は最後の値で更新し、実体は重複させない
    @Test func duplicateIDsUseLastValueWithoutCreatingDuplicates() async throws {
        let json = """
        {
          "banks": [
            {"id":"bank-1","name":"口座1","note":"先","row":1},
            {"id":"bank-1","name":"口座2","note":"後","row":2}
          ],
          "cards": [
            {"id":"card-1","name":"カード1","note":"先","row":1,"closingDay":20,"payDay":27,"payMonth":1,"bonus1":0,"bonus2":0,"bankID":null},
            {"id":"card-1","name":"カード2","note":"後","row":2,"closingDay":15,"payDay":10,"payMonth":2,"bonus1":6,"bonus2":12,"bankID":"bank-1"}
          ],
          "tags": [
            {"id":"tag-1","name":"タグ1","note":"先"},
            {"id":"tag-1","name":"タグ2","note":"後"}
          ],
          "records": [
            {"id":"record-1","dateUse":"2026-04-01T00:00:00Z","name":"履歴1","note":"先","amount":"100","payType":1,"repeatMonths":0,"cardID":null,"tagIDs":[]},
            {"id":"record-1","dateUse":"2026-04-02T00:00:00Z","name":"履歴2","note":"後","amount":"200","payType":1,"repeatMonths":0,"cardID":"card-1","tagIDs":["tag-1"]}
          ]
        }
        """
        let url = try writeTempJSON(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try TestStore.makeContext()

        let result = try await JSONImport.importData(from: url, context: context)

        let banks = try context.fetch(FetchDescriptor<E8bank>())
        let cards = try context.fetch(FetchDescriptor<E1card>())
        let tags = try context.fetch(FetchDescriptor<E5tag>())
        let records = try context.fetch(FetchDescriptor<E3record>())
        #expect(banks.count == 1)
        #expect(cards.count == 1)
        #expect(tags.count == 1)
        #expect(records.count == 1)
        #expect(banks.first?.zName == "口座2")
        #expect(cards.first?.zName == "カード2")
        #expect(cards.first?.e8bank?.id == "bank-1")
        #expect(tags.first?.zName == "タグ2")
        #expect(records.first?.zName == "履歴2")
        #expect(records.first?.nAmount == 200)
        #expect(records.first?.e1card?.id == "card-1")
        #expect(records.first?.e5tags.map(\.id) == ["tag-1"])
        // Resultは一意件数ではなく、処理した入力要素数を返す現行仕様
        #expect(result.bankCount == 2)
        #expect(result.cardCount == 2)
        #expect(result.tagCount == 2)
        #expect(result.recordCount == 2)
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

    // Import失敗を要求し、成功した場合はテスト失敗として記録する
    private func expectImportFailure(from url: URL, context: ModelContext) async {
        do {
            _ = try await JSONImport.importData(from: url, context: context)
            Issue.record("Importが成功しました")
        } catch {
            // 期待した失敗なので処理を続ける
        }
    }

    // ロールバック前後で永続データと主要関連を比較する
    private func databaseSnapshot(_ context: ModelContext) throws -> DatabaseSnapshot {
        let banks = try context.fetch(FetchDescriptor<E8bank>())
        let cards = try context.fetch(FetchDescriptor<E1card>())
        let tags = try context.fetch(FetchDescriptor<E5tag>())
        let records = try context.fetch(FetchDescriptor<E3record>())
        return DatabaseSnapshot(
            banks: banks.map { "\($0.id)|\($0.zName)|\($0.zNote)|\($0.nRow)" }.sorted(),
            cards: cards.map {
                "\($0.id)|\($0.zName)|\($0.zNote)|\($0.nRow)|\($0.nClosingDay)|\($0.nPayDay)|\($0.nPayMonth)|\($0.nBonus1)|\($0.nBonus2)|\($0.e8bank?.id ?? "")"
            }.sorted(),
            tags: tags.map { "\($0.id)|\($0.zName)|\($0.zNote)|\($0.sortName)" }.sorted(),
            records: records.map {
                let tagIDs = $0.e5tags.map(\.id).sorted().joined(separator: ",")
                return "\($0.id)|\($0.dateUse.timeIntervalSinceReferenceDate)|\($0.zName)|\($0.zNote)|\($0.nAmount)|\($0.nPayType)|\($0.nRepeat)|\($0.e1card?.id ?? "")|\(tagIDs)"
            }.sorted(),
            partCount: try context.fetch(FetchDescriptor<E6part>()).count,
            invoiceCount: try context.fetch(FetchDescriptor<E2invoice>()).count,
            paymentCount: try context.fetch(FetchDescriptor<E7payment>()).count
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

    private struct DatabaseSnapshot: Equatable {
        let banks: [String]
        let cards: [String]
        let tags: [String]
        let records: [String]
        let partCount: Int
        let invoiceCount: Int
        let paymentCount: Int
    }
}
