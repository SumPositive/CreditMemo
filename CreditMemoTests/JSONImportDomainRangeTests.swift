import Foundation
import SwiftData
import Testing
@testable import CreditMemo

/// JSON Import の「業務上の値域」検証。
///
/// JSONRoundTripTests 側はストレージ型（Int16/Int32）に収まるかの境界テストで、
/// こちらは Int16 に収まっていても業務上あり得ない値を弾けるかを見る。
/// 例: bonus1=32767 は Int16 としては有効だが、ボーナス月としては不正

private func cardJSON(
    closingDay: Int,
    payDay: Int,
    payMonth: Int,
    bonus1: Int = 0,
    bonus2: Int = 0
) -> String {
    """
    {"cards":[{"id":"card-1","name":"カード","note":"","row":0,
     "closingDay":\(closingDay),"payDay":\(payDay),"payMonth":\(payMonth),
     "bonus1":\(bonus1),"bonus2":\(bonus2),"bankID":null}]}
    """
}

private func recordJSON(payType: Int, repeatMonths: Int) -> String {
    """
    {"records":[{"id":"record-1","dateUse":"2026-04-01T00:00:00Z","name":"履歴","note":"",
     "amount":"1000","payType":\(payType),"repeatMonths":\(repeatMonths),
     "cardID":null,"tagIDs":[]}]}
    """
}

private func partJSON(partNo: Int, noCheck: Int) -> String {
    """
    {"cards":[{"id":"card-p","name":"カード","note":"","row":0,
     "closingDay":20,"payDay":27,"payMonth":1,"bonus1":0,"bonus2":0,"bankID":null}],
     "records":[{"id":"record-p","dateUse":"2026-04-01T00:00:00Z","name":"履歴","note":"",
      "amount":"1000","payType":1,"repeatMonths":0,"cardID":"card-p","tagIDs":[]}],
     "parts":[{"recordID":"record-p","partNo":\(partNo),"noCheck":\(noCheck)}]}
    """
}

@MainActor
struct JSONImportDomainRangeTests {
    // MARK: - 取り込まれない値（業務上の範囲外）

    @Test("業務上あり得ない値は取り込まず、既存DBも変更しない", arguments: [
        // 締日: 0=N日後型, 1-28=締日, 29=末日
        ("closingDay=30", cardJSON(closingDay: 30, payDay: 27, payMonth: 1)),
        ("closingDay=-1", cardJSON(closingDay: -1, payDay: 27, payMonth: 1)),
        ("closingDay=100", cardJSON(closingDay: 100, payDay: 27, payMonth: 1)),
        // 支払日（締日ありの通常型）: 1-28=支払日, 29=末日
        ("payDay=0", cardJSON(closingDay: 20, payDay: 0, payMonth: 1)),
        ("payDay=30", cardJSON(closingDay: 20, payDay: 30, payMonth: 1)),
        ("payDay=-5", cardJSON(closingDay: 20, payDay: -5, payMonth: 1)),
        // 支払月: 0/1/2
        ("payMonth=3", cardJSON(closingDay: 20, payDay: 27, payMonth: 3)),
        ("payMonth=-1", cardJSON(closingDay: 20, payDay: 27, payMonth: -1)),
        // ボーナス月: 0=なし, 1-12=月
        ("bonus1=13", cardJSON(closingDay: 20, payDay: 27, payMonth: 1, bonus1: 13)),
        ("bonus1=32767", cardJSON(closingDay: 20, payDay: 27, payMonth: 1, bonus1: 32767)),
        ("bonus2=-1", cardJSON(closingDay: 20, payDay: 27, payMonth: 1, bonus2: -1)),
        ("bonus2=-32768", cardJSON(closingDay: 20, payDay: 27, payMonth: 1, bonus2: -32768)),
        // N日後型（締日0）の日数は 0...120
        ("N日後 payDay=121", cardJSON(closingDay: 0, payDay: 121, payMonth: 0)),
        ("N日後 payDay=-1", cardJSON(closingDay: 0, payDay: -1, payMonth: 0)),
        // 繰り返し月数: 0=なし, 1-99
        ("repeatMonths=100", recordJSON(payType: 1, repeatMonths: 100)),
        ("repeatMonths=-1", recordJSON(payType: 1, repeatMonths: -1)),
        // 確認状態: 0=確認済, 1=未確認
        ("noCheck=2", partJSON(partNo: 1, noCheck: 2)),
        ("noCheck=-1", partJSON(partNo: 1, noCheck: -1)),
        // 分割番号: 1 起点、支払回数の上限（12）まで
        ("partNo=0", partJSON(partNo: 0, noCheck: 1)),
        ("partNo=13", partJSON(partNo: 13, noCheck: 1)),
        ("partNo=-1", partJSON(partNo: -1, noCheck: 1)),
    ])
    func rejectsOutOfDomainValues(field: String, json: String) async throws {
        let context = try TestStore.makeContext()
        // 既存データを1件置き、失敗時に巻き戻ることまで確認する
        let existing = TestFixtures.makeBank(name: "既存口座", in: context)
        existing.zNote = "変更前"
        try context.save()
        let before = try snapshot(context)

        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        await expectImportFailure(from: url, context: context, field: field)
        #expect(try snapshot(context) == before, "\(field) の取り込み後にDBが変化しました")
    }

    // MARK: - 取り込まれる値（業務上の境界内）

    @Test("業務上の境界値は正しく取り込む", arguments: [
        // 締日・支払日の下限/上限（29=末日）
        ("closingDay=1", 1, 1, 0),
        ("closingDay=29(末日)", 29, 29, 2),
        ("payMonth=0", 20, 27, 0),
        ("payMonth=2", 20, 27, 2),
    ])
    func acceptsDomainBoundaryValues(
        field: String,
        closingDay: Int,
        payDay: Int,
        payMonth: Int
    ) async throws {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(
            cardJSON(closingDay: closingDay, payDay: payDay, payMonth: payMonth)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await JSONImport.importData(from: url, context: context)

        let card = try #require(try context.fetch(FetchDescriptor<E1card>()).first)
        #expect(card.nClosingDay == Int16(closingDay), "\(field)")
        #expect(card.nPayDay == Int16(payDay), "\(field)")
        #expect(card.nPayMonth == Int16(payMonth), "\(field)")
    }

    @Test("ボーナス月の境界値（0=なし, 12）を取り込む")
    func acceptsBonusMonthBoundaries() async throws {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(
            cardJSON(closingDay: 20, payDay: 27, payMonth: 1, bonus1: 12, bonus2: 0)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await JSONImport.importData(from: url, context: context)

        let card = try #require(try context.fetch(FetchDescriptor<E1card>()).first)
        #expect(card.nBonus1 == 12)
        #expect(card.nBonus2 == 0)
    }

    /// 締日0（N日後型）は支払日を「N日後の日数」として扱うため、通常型より広い
    @Test("N日後型の日数は 0...120 を受け入れる", arguments: [0, 1, 60, 120])
    func acceptsDaysLaterRange(daysLater: Int) async throws {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(
            cardJSON(closingDay: 0, payDay: daysLater, payMonth: 0)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await JSONImport.importData(from: url, context: context)

        let card = try #require(try context.fetch(FetchDescriptor<E1card>()).first)
        #expect(card.nClosingDay == 0)
        #expect(card.nPayDay == Int16(daysLater))
    }

    @Test("繰り返し月数の境界値（0, 99）を取り込む", arguments: [0, 1, 99])
    func acceptsRepeatMonthsRange(repeatMonths: Int) async throws {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(recordJSON(payType: 1, repeatMonths: repeatMonths))
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await JSONImport.importData(from: url, context: context)

        let record = try #require(try context.fetch(FetchDescriptor<E3record>()).first)
        #expect(record.nRepeat == Int16(repeatMonths))
    }

    /// payType はモデル境界（normalizedPayTypeRawValue）で 1...12 に丸められる。
    /// 他項目と違い例外にはならないので、丸め後の値を検証する
    @Test("支払回数はモデル境界で 1...12 に正規化される", arguments: [
        (0, Int16(1)), (13, Int16(12)), (1, Int16(1)), (12, Int16(12)),
    ])
    func normalizesPayTypeAtModelBoundary(payType: Int, expected: Int16) async throws {
        let context = try TestStore.makeContext()
        let url = try writeTempJSON(recordJSON(payType: payType, repeatMonths: 0))
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await JSONImport.importData(from: url, context: context)

        let record = try #require(try context.fetch(FetchDescriptor<E3record>()).first)
        #expect(record.nPayType == expected)
    }

    // MARK: - Helpers

    private func writeTempJSON(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("credit-memo-domain-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url, options: .atomic)
        return url
    }

    private func expectImportFailure(
        from url: URL,
        context: ModelContext,
        field: String
    ) async {
        do {
            _ = try await JSONImport.importData(from: url, context: context)
            Issue.record("\(field): 範囲外の値で Import が成功してしまいました")
        } catch {
            // 期待どおりの失敗
        }
    }

    private func snapshot(_ context: ModelContext) throws -> DomainSnapshot {
        DomainSnapshot(
            banks: try context.fetch(FetchDescriptor<E8bank>())
                .map { "\($0.id)|\($0.zName)|\($0.zNote)" }.sorted(),
            cards: try context.fetch(FetchDescriptor<E1card>())
                .map { "\($0.id)|\($0.nClosingDay)|\($0.nPayDay)|\($0.nPayMonth)|\($0.nBonus1)|\($0.nBonus2)" }
                .sorted(),
            records: try context.fetch(FetchDescriptor<E3record>())
                .map { "\($0.id)|\($0.nPayType)|\($0.nRepeat)" }.sorted(),
            partCount: try context.fetch(FetchDescriptor<E6part>()).count
        )
    }

    private struct DomainSnapshot: Equatable {
        let banks: [String]
        let cards: [String]
        let records: [String]
        let partCount: Int
    }
}
