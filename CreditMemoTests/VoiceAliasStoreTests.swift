import Foundation
import Testing
@testable import CreditMemo

/// VoiceAliasStore は UserDefaults.standard の単一キーへ
/// 「辞書全体を load → 変更 → save」する。並列実行すると各テストが
/// 互いの書き込みを stale なコピーで上書きしてしまうため、
/// cardID を分けるだけでは足りず .serialized で直列化する。
/// （アプリ本体は音声入力時にメインアクターからしか呼ばないので実害は無い）
@Suite(.serialized)
struct VoiceAliasStoreTests {
    private func makeCardID() -> String { "test-card-\(UUID().uuidString)" }

    @Test("追加したエイリアスを読み出せる")
    func appendsAndLoadsAlias() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("らくてん", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["らくてん"])
    }

    @Test("未登録のカードは空配列を返す")
    func returnsEmptyForUnknownCard() {
        #expect(VoiceAliasStore.aliases(forCardID: makeCardID()).isEmpty)
    }

    @Test("新しいエイリアスは先頭に入る（新しい順）")
    func insertsNewestFirst() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("いち", forCardID: cardID)
        VoiceAliasStore.append("に", forCardID: cardID)
        VoiceAliasStore.append("さん", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["さん", "に", "いち"])
    }

    @Test("同一エイリアスの再追加は重複せず先頭へ移動する")
    func movesDuplicateToFront() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("いち", forCardID: cardID)
        VoiceAliasStore.append("に", forCardID: cardID)
        VoiceAliasStore.append("いち", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["いち", "に"])
    }

    @Test("大文字小文字違いも同一とみなして重複させない")
    func treatsCaseInsensitiveAsDuplicate() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("Rakuten", forCardID: cardID)
        VoiceAliasStore.append("rakuten", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["rakuten"])
    }

    @Test("前後の空白は取り除いて保存する")
    func trimsWhitespace() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("  らくてん  ", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["らくてん"])
    }

    @Test("空文字・空白だけの追加は無視する")
    func ignoresBlankAlias() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("", forCardID: cardID)
        VoiceAliasStore.append("   ", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID).isEmpty)
    }

    @Test("上限 10 件を超えると古いものから落ちる")
    func keepsAtMostTenAliases() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        for i in 1...12 {
            VoiceAliasStore.append("alias\(i)", forCardID: cardID)
        }
        let aliases = VoiceAliasStore.aliases(forCardID: cardID)
        #expect(aliases.count == 10)
        // 最新が先頭、最も古い alias1/alias2 は落ちている
        #expect(aliases.first == "alias12")
        #expect(!aliases.contains("alias1"))
        #expect(!aliases.contains("alias2"))
    }

    @Test("特定のエイリアスだけを削除できる")
    func removesSingleAlias() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("いち", forCardID: cardID)
        VoiceAliasStore.append("に", forCardID: cardID)
        VoiceAliasStore.removeAlias("いち", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID) == ["に"])
    }

    @Test("最後の 1 件を削除するとカードごと消える")
    func removesCardEntryWhenLastAliasDeleted() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("いち", forCardID: cardID)
        VoiceAliasStore.removeAlias("いち", forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID).isEmpty)
        #expect(VoiceAliasStore.load()[cardID] == nil)
    }

    @Test("カード単位の削除で全エイリアスが消える")
    func removesAllAliasesForCard() {
        let cardID = makeCardID()
        defer { VoiceAliasStore.remove(forCardID: cardID) }

        VoiceAliasStore.append("いち", forCardID: cardID)
        VoiceAliasStore.append("に", forCardID: cardID)
        VoiceAliasStore.remove(forCardID: cardID)
        #expect(VoiceAliasStore.aliases(forCardID: cardID).isEmpty)
    }

    @Test("他のカードのエイリアスには影響しない")
    func keepsOtherCardsIntact() {
        let cardA = makeCardID()
        let cardB = makeCardID()
        defer {
            VoiceAliasStore.remove(forCardID: cardA)
            VoiceAliasStore.remove(forCardID: cardB)
        }

        VoiceAliasStore.append("えー", forCardID: cardA)
        VoiceAliasStore.append("びー", forCardID: cardB)
        VoiceAliasStore.remove(forCardID: cardA)
        #expect(VoiceAliasStore.aliases(forCardID: cardB) == ["びー"])
    }
}
