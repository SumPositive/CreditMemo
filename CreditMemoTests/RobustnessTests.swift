import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct RobustnessTests {
    @Test("和暦・民国暦の設定でも年の表示に「西暦」などの紀元を付けない")
    func gregorianLocaleOmitsEra() {
        let date = TestStore.date(2026, 10, 3)
        let cases: [(id: String, template: String, expected: String)] = [
            ("ja_JP@calendar=japanese", "yMMMM", "2026年10月"),
            ("en_US@calendar=japanese", "yyyyEEE", "Sat 2026"),
            ("zh_TW@calendar=roc", "yyyyMdEEE", "2026/10/3（週六）"),
            ("ko_KR@calendar=japanese", "yyyyEEE", "2026년 토"),
        ]
        for item in cases {
            let formatter = DateFormatter()
            formatter.locale = AppCalendar.gregorianLocale(Locale(identifier: item.id))
            formatter.calendar = AppCalendar.gregorian
            formatter.setLocalizedDateFormatFromTemplate(item.template)
            #expect(formatter.string(from: date) == item.expected, "\(item.id)")
        }
    }

    @Test("和暦由来の遠未来の引き落とし日を支払状態ごと修復する")
    func repairsJapaneseCalendarDueDate() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let part = try #require(record.e6parts.first)
        let correctDate = try #require(part.e2invoice?.date)
        // 和暦 DatePicker の誤った下限を保存した状態を再現する
        try RecordService.setPartDueDate(part, date: TestStore.date(4018, 1, 1), context: context)
        try RecordService.setPartPaid(part, isPaid: true, context: context)
        part.isChecked = true
        try context.save()

        #expect(try RecordService.repairJapaneseCalendarDueDatesIfNeeded(context: context) == 1)
        let repaired = try #require(try context.fetch(FetchDescriptor<E6part>()).first)
        #expect(repaired.e2invoice?.date == correctDate)
        #expect(repaired.e2invoice?.isPaid == true)
        #expect(repaired.isChecked)
        #expect(repaired.isDueDateLocked)
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).count == 1)
        #expect(RecordService.checkBillingIntegrity(context: context).hasIssue == false)
    }

    @Test("正常な手動引き落とし日は起動時修復の対象にしない")
    func keepsValidManualDueDate() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let part = try #require(record.e6parts.first)
        let manualDate = TestStore.date(2026, 8, 12)
        try RecordService.setPartDueDate(part, date: manualDate, context: context)

        #expect(try RecordService.repairJapaneseCalendarDueDatesIfNeeded(context: context) == 0)
        #expect(part.e2invoice.map { AppCalendar.gregorian.isDate($0.date, inSameDayAs: manualDate) } == true)
    }

    @Test("決済を削除すると孤児の請求・支払も掃除される")
    func deleteRecordRemovesOrphanBilling() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let record = try TestFixtures.saveRecord(
            amount: 5_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).count == 1)

        try RecordService.delete(record, context: context)

        #expect(try context.fetch(FetchDescriptor<E3record>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E6part>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).isEmpty)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("カードの引き落とし口座を変更すると、過去請求も新口座の E7payment に再配置される")
    func cardBankChangeReassignsPayments() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )

        // 初期は A 口座に紐づく
        let payment0 = try #require(try context.fetch(FetchDescriptor<E7payment>()).first)
        #expect(payment0.e8bank?.id == bankA.id)

        // 引き落とし口座を切り替えてから整合性掃除を呼ぶ（CardService 経由ではなく直接で十分）
        card.e8bank = bankB
        RecordService.cleanupOrphanBilling(context: context)

        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 1)
        #expect(paymentsAfter.first?.e8bank?.id == bankB.id)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("cleanupOrphanBilling は冪等（連続呼び出しで状態が変わらない）")
    func cleanupOrphanBillingIsIdempotent() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        for day in [3, 7, 15] {
            _ = try TestFixtures.saveRecord(
                amount: Decimal(day * 1_000),
                dateUse: TestStore.date(2026, 4, day),
                card: card,
                in: context
            )
        }
        RecordService.cleanupOrphanBilling(context: context)
        let snapshot1 = try snapshot(context)
        RecordService.cleanupOrphanBilling(context: context)
        let snapshot2 = try snapshot(context)
        #expect(snapshot1 == snapshot2)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("同一の (日付 + 口座 + 状態) を持つ重複 payment は normalize で 1 件に統合される")
    func duplicatePaymentsAreNormalized() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let originalPayment = try #require(try context.fetch(FetchDescriptor<E7payment>()).first)

        // 同じキーを持つ重複 payment を意図的に挿入してから掃除を呼ぶ
        let dupe = E7payment(date: originalPayment.date)
        dupe.e8unpaid = bank
        bank.e7unpaids.append(dupe)
        context.insert(dupe)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).count == 2)

        RecordService.cleanupOrphanBilling(context: context)
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
        #expect(paymentsAfter.count == 1)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("古い履歴のまとめ削除で、対象だけが消えて整合性は保たれる")
    func deleteRecordsOlderThanYears() async throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let oldDate = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
        let recentDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        _ = try TestFixtures.saveRecord(amount: 1, dateUse: oldDate, card: card, in: context)
        _ = try TestFixtures.saveRecord(amount: 2, dateUse: recentDate, card: card, in: context)

        #expect(try context.fetch(FetchDescriptor<E3record>()).count == 2)
        try await RecordService.deleteRecords(olderThanYears: 3, context: context)
        let remaining = try context.fetch(FetchDescriptor<E3record>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.dateUse == recentDate)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("決済手段の口座変更は、対象記録と兄弟記録の再構築を1回の保存で完了する")
    func cardBankChangeReassignsAllSiblingsInSingleSave() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        // 別月にして請求・支払が記録ごとに分かれる状態を作る
        var records: [E3record] = []
        for month in [4, 5, 6] {
            records.append(try TestFixtures.saveRecord(
                amount: Decimal(month * 1_000),
                dateUse: TestStore.date(2026, month, 5),
                card: card,
                in: context
            ))
        }
        let paymentsBefore = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsBefore.count == 3)
        #expect(paymentsBefore.allSatisfy { $0.e8bank?.id == bankA.id })

        // 編集画面と同じ手順: 保存直前にカードの口座を変え、対象記録＋兄弟をまとめて保存する
        card.e8bank = bankB
        try RecordService.saveFromEditor(records[0], rebuildSiblingsForCard: card, context: context)

        // 単一トランザクションで完了し、未保存変更が残らない
        #expect(context.hasChanges == false)
        // 対象記録だけでなく兄弟記録の支払も全て新口座へ移る（部分更新が起きない）
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 3)
        #expect(paymentsAfter.allSatisfy { $0.e8bank?.id == bankB.id })

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("新規の複数回払いを最初から済みにしても、全明細が1回の保存で済みになる")
    func newInstallmentMarkedPaidCommitsAllPartsInSingleSave() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        // 「済み側から追加」相当の 2 回払い新規記録
        let record = E3record(
            dateUse: TestStore.date(2026, 4, 5),
            zName: "2回払い",
            nAmount: 2_000,
            nPayType: 2,
            nRepeat: 0
        )
        record.e1card = card
        context.insert(record)

        try RecordService.saveFromEditor(record, markAllPartsPaid: true, context: context)

        // 単一トランザクションで完了する
        #expect(context.hasChanges == false)
        // 全明細が済みの請求に属し、途中まで済みの部分更新が残らない
        let parts = try context.fetch(FetchDescriptor<E6part>())
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { $0.e2invoice?.isPaid == true })
        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        #expect(!invoices.isEmpty)
        #expect(invoices.allSatisfy { $0.isPaid })

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("メタ情報だけの編集が保存失敗したら、未保存のラベル・メモ・タグも残らない")
    func metadataSaveFailureRollsBackUnsavedEdits() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let tag = TestFixtures.makeTag(name: "タグ", in: context)

        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            label: "元ラベル",
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        record.zNote = "元メモ"
        try RecordService.saveMetadata(record, context: context)
        let snapshotBefore = try snapshot(context)

        // 編集画面と同じ手順: 保存前に記録モデルへ直接書き込んでから保存を試みる
        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        record.zName = "新ラベル"
        record.zNote = "新メモ"
        record.e5tags = [tag]

        #expect(throws: TestSaveError.self) {
            try RecordService.saveMetadata(record, context: context)
        }

        // 失敗後に未保存変更が残らない（後続の自動保存で確定してしまわない）。
        // これがレビュー指摘の本題で、rollback の有無で結果が変わる
        #expect(context.hasChanges == false)
        // 永続化された値は元のまま（画面の直接変更が DB へ漏れない）。
        // 同じ context の fetch は登録済みインスタンスを返すので、別 context で読み直す
        let stored = try #require(
            try freshContext(of: context).fetch(FetchDescriptor<E3record>()).first
        )
        #expect(stored.zName == "元ラベル")
        #expect(stored.zNote == "元メモ")
        #expect(stored.e5tags.isEmpty)
        // DB 全体の件数も変わらない
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("口座変更の保存が失敗したら、対象記録も兄弟記録も旧口座のまま戻る")
    func editorSaveFailureRollsBackCardBankChange() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        // 成功経路のテストと同じく、別月にして請求・支払を記録ごとに分ける
        var records: [E3record] = []
        for month in [4, 5, 6] {
            records.append(try TestFixtures.saveRecord(
                amount: Decimal(month * 1_000),
                dateUse: TestStore.date(2026, month, 5),
                card: card,
                in: context
            ))
        }
        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        // 編集画面と同じ手順: 保存直前にカードの口座を変えてから保存を試みる
        card.e8bank = bankB
        #expect(throws: TestSaveError.self) {
            try RecordService.saveFromEditor(
                records[0],
                rebuildSiblingsForCard: card,
                context: context
            )
        }

        // 未保存変更が残らない
        #expect(context.hasChanges == false)
        // 兄弟記録を含む全支払が旧口座のまま（部分的な口座移動が残らない）
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 3)
        #expect(paymentsAfter.allSatisfy { $0.e8bank?.id == bankA.id })
        // カードの口座変更も DB へは漏れない。
        // （card.e8bank 自体はメモリ上 B口座のまま残る。rollback は登録済み
        // インスタンスのプロパティを巻き戻さないため。画面は失敗時に閉じない仕様）
        let storedCard = try #require(
            try freshContext(of: context).fetch(FetchDescriptor<E1card>()).first
        )
        #expect(storedCard.e8bank?.id == bankA.id)
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("新規を済みにする保存が失敗したら、記録ごと残らず途中まで済みの明細も出ない")
    func editorSaveFailureRollsBackNewPaidRecord() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        // 「済み側から追加」相当の 2 回払い新規記録
        let record = E3record(
            dateUse: TestStore.date(2026, 4, 5),
            zName: "2回払い",
            nAmount: 2_000,
            nPayType: 2,
            nRepeat: 0
        )
        record.e1card = card
        context.insert(record)

        #expect(throws: TestSaveError.self) {
            try RecordService.saveFromEditor(record, markAllPartsPaid: true, context: context)
        }

        // 未保存の insert ごと破棄され、途中まで済みの明細も残らない
        #expect(context.hasChanges == false)
        #expect(try context.fetch(FetchDescriptor<E3record>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E6part>()).isEmpty)
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("照合の確定保存が失敗したら、仮明細・仮移動・照合済みが残らない")
    func reconciliationApplyFailureRollsBack() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let part = try #require(record.e6parts.first)
        let originalDueDate = try #require(part.e2invoice?.date)
        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        let draft = ReconciliationNewRecordDraft(
            id: UUID(),
            useDate: TestStore.date(2026, 4, 20),
            dueDate: originalDueDate,
            amount: 500,
            name: "差額分",
            card: card
        )
        #expect(throws: TestSaveError.self) {
            try RecordService.applyReconciliation(
                moves: [ReconciliationDueDateMove(part: part, date: TestStore.date(2026, 6, 27))],
                currentParts: [part],
                newRecordDrafts: [draft],
                reconciledAmount: 1_500,
                cardID: card.id,
                dueDate: originalDueDate,
                context: context
            )
        }

        // 失敗後に未保存変更が残らない（後続の自動保存で確定してしまわない）
        #expect(context.hasChanges == false)
        #expect(try snapshot(context) == snapshotBefore)
        // DB 上の明細は照合前のまま（未確認・元の引き落とし日）
        let storedPart = try #require(
            try freshContext(of: context).fetch(FetchDescriptor<E6part>()).first
        )
        #expect(storedPart.isChecked == false)
        #expect(storedPart.e2invoice?.date == originalDueDate)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("照合の途中保存が失敗したら、仮明細・仮移動が残らない")
    func reconciliationProgressFailureRollsBack() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let part = try #require(record.e6parts.first)
        let originalDueDate = try #require(part.e2invoice?.date)
        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        let draft = ReconciliationNewRecordDraft(
            id: UUID(),
            useDate: TestStore.date(2026, 4, 20),
            dueDate: originalDueDate,
            amount: 500,
            name: "差額分",
            card: card
        )
        #expect(throws: TestSaveError.self) {
            try RecordService.saveReconciliationProgress(
                moves: [ReconciliationDueDateMove(part: part, date: TestStore.date(2026, 6, 27))],
                newRecordDrafts: [draft],
                cardID: card.id,
                dueDate: originalDueDate,
                context: context
            )
        }

        #expect(context.hasChanges == false)
        #expect(try snapshot(context) == snapshotBefore)
        let storedPart = try #require(
            try freshContext(of: context).fetch(FetchDescriptor<E6part>()).first
        )
        #expect(storedPart.isDueDateLocked == false)
        #expect(storedPart.e2invoice?.date == originalDueDate)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("照合で追加した差額分の明細も、通常保存と同じくタグの利用統計を更新する")
    func reconciliationDraftUpdatesTagStats() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let tag = TestFixtures.makeTag(name: "タグ", in: context)
        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let part = try #require(record.e6parts.first)
        let dueDate = try #require(part.e2invoice?.date)
        let countBefore = tag.sortCount
        let amountBefore = tag.sortAmount

        let draft = ReconciliationNewRecordDraft(
            id: UUID(),
            useDate: TestStore.date(2026, 4, 20),
            dueDate: dueDate,
            amount: 500,
            name: "差額分",
            card: card,
            tags: [tag]
        )
        try RecordService.applyReconciliation(
            moves: [],
            currentParts: [part],
            newRecordDrafts: [draft],
            reconciledAmount: 1_500,
            cardID: card.id,
            dueDate: dueDate,
            context: context
        )

        #expect(tag.sortCount == countBefore + 1)
        #expect(tag.sortAmount == amountBefore + 500)
        let added = try #require(
            try context.fetch(FetchDescriptor<E3record>()).first { $0.zName == "差額分" }
        )
        #expect(added.dateUpdate != nil)
        #expect(added.e5tags.map(\.id) == [tag.id])
    }

    @Test("照合済みの請求合計は請求に残り、明細を済みへ移しても引き継ぎ、途中保存で取り消される")
    func reconciledAmountIsStoredOnInvoices() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let first = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let second = try TestFixtures.saveRecord(
            amount: 500,
            dateUse: TestStore.date(2026, 4, 6),
            card: card,
            in: context
        )
        let firstPart = try #require(first.e6parts.first)
        let secondPart = try #require(second.e6parts.first)
        let dueDate = try #require(firstPart.e2invoice?.date)
        #expect(secondPart.e2invoice?.date == dueDate)

        try RecordService.applyReconciliation(
            moves: [],
            currentParts: [firstPart, secondPart],
            newRecordDrafts: [],
            reconciledAmount: 1_500,
            cardID: card.id,
            dueDate: dueDate,
            context: context
        )
        #expect(firstPart.e2invoice?.reconciledAmount == 1_500)

        // 1件だけ済みへ移すと請求が未払/済みに分かれるが、どちらにも請求合計が残る
        try RecordService.setPartPaid(firstPart, isPaid: true, context: context)
        let dayInvoices = try context.fetch(FetchDescriptor<E2invoice>())
            .filter { $0.e1card?.id == card.id && $0.date == dueDate }
        #expect(dayInvoices.count == 2)
        #expect(dayInvoices.allSatisfy { $0.reconciledAmount == 1_500 })

        // 差額を残して途中保存すると照合済みは取り消される
        try RecordService.saveReconciliationProgress(
            moves: [],
            newRecordDrafts: [],
            cardID: card.id,
            dueDate: dueDate,
            context: context
        )
        #expect(RecordService.reconciledAmount(in: dayInvoices) == nil)
    }

    @Test("未払と済みに分かれた同じ日の明細は合わせて照合し、済みの明細を未払へ戻さない")
    func reconciliationCoversPaidAndUnpaidOfSameDay() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let paidRecord = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let unpaidRecord = try TestFixtures.saveRecord(
            amount: 500,
            dateUse: TestStore.date(2026, 4, 6),
            card: card,
            in: context
        )
        let paidPart = try #require(paidRecord.e6parts.first)
        let unpaidPart = try #require(unpaidRecord.e6parts.first)
        let dueDate = try #require(paidPart.e2invoice?.date)
        try RecordService.setPartPaid(paidPart, isPaid: true, context: context)

        let dayInvoices = RecordService.reconciliationInvoices(cardID: card.id, date: dueDate, context: context)
        #expect(dayInvoices.count == 2)

        // カード会社の請求額（未払+済み）で差額0になり、未払のまま確定する
        try RecordService.applyReconciliation(
            moves: [],
            currentParts: [paidPart, unpaidPart],
            newRecordDrafts: [],
            reconciledAmount: 1_500,
            cardID: card.id,
            dueDate: dueDate,
            context: context
        )

        #expect(paidPart.e2invoice?.isPaid == true)
        #expect(unpaidPart.e2invoice?.isPaid == false)
        #expect(RecordService.isReconciled(
            RecordService.reconciliationInvoices(cardID: card.id, date: dueDate, context: context)
        ))
    }

    @Test("タグの統合で決済の付け替え・重複除去・重みの合算をして、元のタグを消す")
    func mergeTagMovesRecordsAndDeletesSource() throws {
        let context = try TestStore.makeContext()
        let source = TestFixtures.makeTag(name: "テスト２", in: context)
        let target = TestFixtures.makeTag(name: "テスト2", in: context)
        let other = TestFixtures.makeTag(name: "外食", in: context)
        source.sortCount = 3
        source.sortAmount = 1_000
        target.sortCount = 2
        target.sortAmount = 500
        let onlySource = try TestFixtures.saveRecord(
            amount: 100, dateUse: TestStore.date(2026, 4, 5), card: nil,
            tags: [other, source], in: context
        )
        let both = try TestFixtures.saveRecord(
            amount: 200, dateUse: TestStore.date(2026, 4, 6), card: nil,
            tags: [source, target], in: context
        )
        let countBefore = target.sortCount
        let amountBefore = target.sortAmount
        let sourceCount = source.sortCount
        let sourceAmount = source.sortAmount

        try TagEditView.merge(source, into: target, context: context)
        try context.save()

        // 付け替え、既に付いていれば重複させない（SwiftData の対多関係は並び順を保たないので集合で比べる）
        #expect(Set(onlySource.e5tags.map(\.id)) == [other.id, target.id])
        #expect(both.e5tags.map(\.id) == [target.id])
        #expect(target.sortCount == countBefore + sourceCount)
        #expect(target.sortAmount == amountBefore + sourceAmount)
        let remaining = try context.fetch(FetchDescriptor<E5tag>()).map(\.id)
        #expect(Set(remaining) == [target.id, other.id])
    }

    /// 同じストアを見る別 context。
    /// rollback 後の「DB に何が残っているか」を、登録済みインスタンス越しでなく確認するために使う
    private func freshContext(of context: ModelContext) -> ModelContext {
        ModelContext(context.container)
    }

    private enum TestSaveError: Error {
        case forced
    }

    private func snapshot(_ context: ModelContext) throws -> Snapshot {
        Snapshot(
            recordCount: try context.fetch(FetchDescriptor<E3record>()).count,
            partCount: try context.fetch(FetchDescriptor<E6part>()).count,
            invoiceCount: try context.fetch(FetchDescriptor<E2invoice>()).count,
            paymentCount: try context.fetch(FetchDescriptor<E7payment>()).count
        )
    }

    private struct Snapshot: Equatable {
        let recordCount: Int
        let partCount: Int
        let invoiceCount: Int
        let paymentCount: Int
    }
}

/// 繰り返し：利用日を過ぎたら次の明細を作る（2026/04/01 以降の利用日のみ）
@MainActor
struct RepeatGenerationTests {
    /// 請求を作らずに繰り返し明細だけを置く
    private func insertRepeat(
        dateUse: Date,
        name: String = "サブスク",
        months: Int16 = 1,
        card: E1card,
        in context: ModelContext
    ) throws -> E3record {
        let record = E3record(dateUse: dateUse, zName: name, nAmount: 980, nRepeat: months)
        record.e1card = card
        context.insert(record)
        try context.save()
        return record
    }

    private func records(named name: String, in context: ModelContext) throws -> [E3record] {
        try context.fetch(FetchDescriptor<E3record>(sortBy: [SortDescriptor(\E3record.dateUse)]))
            .filter { $0.zName == name }
    }

    @Test("利用日を過ぎた繰り返しは、日付が変わった時点で支払状態に関係なく次の明細を作る")
    func createsNextWhenUseDateArrives() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", bank: TestFixtures.makeBank(name: "口座", in: context), in: context)
        let source = try insertRepeat(dateUse: TestStore.date(2026, 5, 15), card: card, in: context)

        // 利用日前と利用日当日は作らない
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 10), context: context) == 0)
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 15).addingTimeInterval(60 * 60 * 12), context: context) == 0)
        #expect(source.isRepeatDone == false)

        // 日付が変わって翌日になったら作る
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 16).addingTimeInterval(60 * 60 * 12), context: context) == 1)
        let all = try records(named: "サブスク", in: context)
        #expect(all.count == 2)
        #expect(source.isRepeatDone)
        let next = try #require(all.last)
        #expect(AppCalendar.gregorian.isDate(next.dateUse, equalTo: TestStore.date(2026, 6, 15), toGranularity: .month))
        #expect(next.nRepeat == 1)
        #expect(next.isRepeatDone == false)
        #expect(!next.e6parts.isEmpty)
        #expect(context.hasChanges == false)
    }

    @Test("2026/04/01 より前の利用日は対象外")
    func ignoresRecordsBeforeStartDate() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        let old = try insertRepeat(dateUse: TestStore.date(2026, 3, 15), card: card, in: context)

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 10, 15), context: context) == 0)
        #expect(old.isRepeatDone == false)
        #expect(try records(named: "サブスク", in: context).count == 1)
    }

    @Test("長く開かなかった場合は1回に3件まで作り、次に開いた時に続きを作る")
    func catchesUpAfterLongAbsence() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        _ = try insertRepeat(dateUse: TestStore.date(2026, 4, 15), card: card, in: context)

        // 1回目は 5,6,7 月分まで
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 8, 20), context: context) == 3)
        #expect(try records(named: "サブスク", in: context).count == 4)
        // 2回目で 8 月分と、先の予定の 9/15 分を作って止まる
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 8, 20), context: context) == 2)
        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 8, 20), context: context) == 0)
        let all = try records(named: "サブスク", in: context)
        #expect(all.count == 6)
        #expect(all.dropLast().allSatisfy { $0.isRepeatDone })
        #expect(all.last?.isRepeatDone == false)
    }

    @Test("一度作った後に次の明細を消しても、再作成しない")
    func doesNotRecreateDeletedNext() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        _ = try insertRepeat(dateUse: TestStore.date(2026, 5, 15), card: card, in: context)
        try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 20), context: context)
        let next = try #require(try records(named: "サブスク", in: context).last)
        context.delete(next)
        try context.save()

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 21), context: context) == 0)
        #expect(try records(named: "サブスク", in: context).count == 1)
    }

    @Test("指定月に同じラベル・金額・タグの明細が既にあれば作らず、作成済みにする")
    func skipsWhenSameLabelExistsInTargetMonth() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        let source = try insertRepeat(dateUse: TestStore.date(2026, 5, 15), card: card, in: context)
        // 旧方式で作られた、または手入力された翌月分（繰り返し元と同じ金額・タグ）
        let existing = E3record(dateUse: TestStore.date(2026, 6, 10), zName: "サブスク", nAmount: 980, nRepeat: 0)
        existing.e1card = card
        context.insert(existing)
        // 同じカードの別ラベルは妨げにならない
        _ = try insertRepeat(dateUse: TestStore.date(2026, 6, 1), name: "別", months: 0, card: card, in: context)

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 20), context: context) == 0)
        #expect(source.isRepeatDone)
        #expect(try records(named: "サブスク", in: context).count == 2)
    }

    @Test("同じ決済手段・ラベルでも金額やタグが違う繰り返しは、それぞれ次を作る")
    func independentRepeatsWithSameLabelBothCreateNext() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        let tag = TestFixtures.makeTag(name: "家族", in: context)
        let first = try insertRepeat(dateUse: TestStore.date(2026, 9, 18), card: card, in: context)
        let second = try insertRepeat(dateUse: TestStore.date(2026, 9, 20), card: card, in: context)
        second.nAmount = 1_480
        let third = try insertRepeat(dateUse: TestStore.date(2026, 9, 22), card: card, in: context)
        third.e5tags = [tag]
        try context.save()

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 10, 15), context: context) == 3)
        #expect(try records(named: "サブスク", in: context).count == 6)
        #expect(first.isRepeatDone && second.isRepeatDone && third.isRepeatDone)
    }

    @Test("同じ月に重複した繰り返し元が複数あっても、次は1件だけ作る")
    func duplicatedSourcesCreateSingleNext() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        for _ in 0..<3 {
            _ = try insertRepeat(dateUse: TestStore.date(2026, 9, 18), card: card, in: context)
        }

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 10, 15), context: context) == 1)
        #expect(try records(named: "サブスク", in: context).count == 4)
        #expect(try records(named: "サブスク", in: context).prefix(3).allSatisfy(\.isRepeatDone))
    }

    @Test("旧方式からの移行：済みの明細を含む繰り返しは作成済みとみなす")
    func legacyPaidRepeatsAreMarkedDone() throws {
        let suite = "RepeatGenerationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", bank: TestFixtures.makeBank(name: "口座", in: context), in: context)
        let paid = try TestFixtures.saveRecord(amount: 980, label: "済み", dateUse: TestStore.date(2026, 5, 15), card: card, in: context)
        let unpaid = try TestFixtures.saveRecord(amount: 980, label: "未払", dateUse: TestStore.date(2026, 5, 15), card: card, in: context)
        try RecordService.setPartPaid(try #require(paid.e6parts.first), isPaid: true, context: context)
        paid.nRepeat = 1
        unpaid.nRepeat = 1
        try context.save()

        try RecordService.markLegacyPaidRepeatsDoneIfNeeded(defaults: defaults, context: context)
        #expect(paid.isRepeatDone)
        #expect(unpaid.isRepeatDone == false)

        #expect(try RecordService.generateDueRepeatRecords(now: TestStore.date(2026, 5, 20), context: context) == 1)
        #expect(try records(named: "済み", in: context).count == 1)
        #expect(try records(named: "未払", in: context).count == 2)
    }
}

/// 決済一覧からの確定ロック切り替え
@MainActor
struct RecordLockTests {
    @Test("未払分だけをロック／解除し、済みの分割には触れない")
    func togglesOnlyUnpaidParts() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", bank: TestFixtures.makeBank(name: "口座", in: context), in: context)
        let record = E3record(dateUse: TestStore.date(2026, 4, 5), zName: "2回払い", nAmount: 2_000, nPayType: 2)
        record.e1card = card
        context.insert(record)
        try RecordService.save(record, context: context)
        let parts = record.e6parts.sorted { $0.nPartNo < $1.nPartNo }
        #expect(parts.count == 2)
        try RecordService.setPartPaid(parts[0], isPaid: true, context: context)
        parts[0].isChecked = false
        try context.save()

        try RecordService.setUnpaidPartsChecked(of: record, isChecked: true, context: context)
        #expect(parts[0].isChecked == false)
        #expect(parts[1].isChecked)
        #expect(parts[1].isDueDateLocked)
        // card.sumNoCheck は逆参照（card.e2paids/e2unpaids）から集計するため、インメモリストアでは同期されない
        // （DataIntegrityTests と同じ既知の制約）。請求を fetch して未確認の明細数で確かめる
        #expect(try uncheckedPartCount(cardID: card.id, in: context) == 1)
        #expect(context.hasChanges == false)

        try RecordService.setUnpaidPartsChecked(of: record, isChecked: false, context: context)
        #expect(parts[1].isChecked == false)
        #expect(try uncheckedPartCount(cardID: card.id, in: context) == 2)
    }

    /// 決済手段の請求を fetch して、未確認（未ロック）の明細数を数える
    private func uncheckedPartCount(cardID: String, in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<E2invoice>())
            .filter { $0.e1card?.id == cardID }
            .reduce(0) { $0 + Int($1.sumNoCheck) }
    }
}
