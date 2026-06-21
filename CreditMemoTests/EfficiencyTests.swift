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

    // 2,000件のImport、Export、再Importを実用的な時間と容量で処理する
    @Test func largeDatasetRoundTripAndReimportRemainEfficient() async throws {
        let recordCount = 2_000
        let inputData = largeImportData(recordCount: recordCount)
        let inputURL = try writeTempJSON(inputData)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let sourceContext = try TestStore.makeContext()

        let importStarted = Date()
        _ = try await JSONImport.importData(from: inputURL, context: sourceContext)
        let firstImportElapsed = Date().timeIntervalSince(importStarted)
        #expect(try sourceContext.fetch(FetchDescriptor<E3record>()).count == recordCount)

        let exportStarted = Date()
        let exportedData = try await JSONExport.exportData(context: sourceContext, style: .compact)
        let exportElapsed = Date().timeIntervalSince(exportStarted)
        // バックアップ容量の異常増加を検出する
        #expect(exportedData.count < 5_000_000)

        let exportedURL = try writeTempJSON(exportedData)
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let targetContext = try TestStore.makeContext()
        let restoreStarted = Date()
        _ = try await JSONImport.importData(from: exportedURL, context: targetContext)
        let restoreElapsed = Date().timeIntervalSince(restoreStarted)
        #expect(try targetContext.fetch(FetchDescriptor<E3record>()).count == recordCount)

        let reimportStarted = Date()
        _ = try await JSONImport.importData(from: exportedURL, context: targetContext)
        let reimportElapsed = Date().timeIntervalSince(reimportStarted)
        #expect(try targetContext.fetch(FetchDescriptor<E3record>()).count == recordCount)
        // CI環境差を許容しつつ、明確な性能退行だけを検出する
        #expect(firstImportElapsed < 60)
        #expect(exportElapsed < 30)
        #expect(restoreElapsed < 60)
        #expect(reimportElapsed < 60)
        #expect(RecordService.checkBillingIntegrity(context: targetContext).hasIssue == false)
    }

    // 件数を2倍にしても処理時間が二次関数的に悪化しない
    @Test func importTimeScalesWithoutQuadraticRegression() async throws {
        // 初回実行時のランタイム初期化を計測外へ出す
        _ = try await measuredImport(recordCount: 10)
        let oneThousand = try await measuredImport(recordCount: 1_000)
        let twoThousand = try await measuredImport(recordCount: 2_000)
        let permittedTime = max(5, oneThousand * 4)

        #expect(twoThousand < permittedTime)
    }

    // Import途中のキャンセルで未保存データをすべて破棄する
    @Test func cancellingImportRollsBackPartialData() async throws {
        let context = try TestStore.makeContext()
        let existingBank = TestFixtures.makeBank(name: "既存口座", in: context)
        try context.save()
        let autosaveBefore = context.autosaveEnabled
        let url = try writeTempJSON(largeImportData(recordCount: 500))
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task { @MainActor in
            try await JSONImport.importData(from: url, context: context) { progress in
                guard case .importingRecords = progress.phase,
                      progress.completed == 50 else {
                    return
                }
                // 実際のImportタスク自身を進行通知からキャンセルする
                withUnsafeCurrentTask { currentTask in
                    currentTask?.cancel()
                }
            }
        }

        do {
            _ = try await task.value
            Issue.record("キャンセルしたImportが成功しました")
        } catch {
            #expect(error is CancellationError)
        }

        let banks = try context.fetch(FetchDescriptor<E8bank>())
        #expect(banks.count == 1)
        #expect(banks.first?.id == existingBank.id)
        #expect(try context.fetch(FetchDescriptor<E1card>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E3record>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E6part>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).isEmpty)
        #expect(context.autosaveEnabled == autosaveBefore)
    }

    private func writeTempJSON(_ data: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("credit-memo-test-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // 指定件数を同じ決済手段へ紐付けた性能計測用JSONを生成する
    private func largeImportData(recordCount: Int) -> Data {
        let records = (0..<recordCount).map { index in
            "{\"id\":\"record-\(index)\",\"dateUse\":\"2026-04-01T00:00:00Z\",\"name\":\"履歴\(index)\",\"note\":\"\",\"amount\":\"\(index + 1)\",\"payType\":1,\"repeatMonths\":0,\"cardID\":\"card-large\",\"tagIDs\":[]}"
        }.joined(separator: ",")
        let json = """
        {
          "banks": [{"id":"bank-large","name":"口座","note":"","row":0}],
          "cards": [
            {"id":"card-large","name":"カード","note":"","row":0,"closingDay":20,"payDay":27,"payMonth":1,"bonus1":0,"bonus2":0,"bankID":"bank-large"}
          ],
          "records": [\(records)]
        }
        """
        return Data(json.utf8)
    }

    // Import単体の経過時間を返す
    private func measuredImport(recordCount: Int) async throws -> TimeInterval {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(largeImportData(recordCount: recordCount))
        defer { try? FileManager.default.removeItem(at: url) }
        let started = Date()
        _ = try await JSONImport.importData(from: url, context: context)
        let elapsed = Date().timeIntervalSince(started)
        #expect(try context.fetch(FetchDescriptor<E3record>()).count == recordCount)
        return elapsed
    }
}
