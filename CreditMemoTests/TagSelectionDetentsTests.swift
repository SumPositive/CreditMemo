import Foundation
import Testing
@testable import CreditMemo

/// タグ選択シート（タグ式）の行数見積もり。
///
/// シート高さは TagCapsuleBand.packedRowCount の行数で決まる。この関数は
/// AZFlowLayout(packToFill:) と同じ規則でカプセルを詰める前提なので、ズレると
/// 実際の表示より高い／低いシートが開いてしまう。ビルドは通ってしまうため、
/// 規則そのものをここで固定する。
@MainActor
struct TagSelectionDetentsTests {
    /// iPhone 15 相当の幅から、カプセル帯の左右余白を引いた実効幅
    private let contentWidth: CGFloat = 393 - TagCapsuleBand.areaHorizontalPadding * 2

    @Test("タグが無いときも1行ぶんは確保する")
    func emptyKeepsOneRow() {
        #expect(TagCapsuleBand.packedRowCount(names: [], availableWidth: contentWidth) == 1)
    }

    @Test("短いタグは1行に複数入る")
    func shortNamesShareRow() {
        let names = ["食費", "日用品", "交通"]
        let rows = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        // 実フォントで測るので厳密な行数は文字サイズ設定で前後する。
        // 1行に複数入る（＝件数より行数が少ない）ことを不変条件として見る
        #expect(rows < names.count)
    }

    @Test("タグが増えれば行が増える")
    func moreTagsNeedMoreRows() {
        let few = TagCapsuleBand.packedRowCount(
            names: ["食費", "日用品", "交通"],
            availableWidth: contentWidth
        )
        let many = TagCapsuleBand.packedRowCount(
            names: ["食費", "日用品", "交通", "通信費", "医療", "娯楽",
                    "本", "サブスク", "外食", "旅行", "衣類", "美容"],
            availableWidth: contentWidth
        )
        #expect(many > few)
    }

    @Test("幅が狭いほど行数は増える")
    func narrowerWidthNeedsMoreRows() {
        let names = ["食費", "日用品", "交通", "通信費", "医療", "娯楽"]
        let wide = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        let narrow = TagCapsuleBand.packedRowCount(names: names, availableWidth: 200)
        #expect(narrow >= wide)
    }

    @Test("1つでは収まらない長いタグ名でも1行として数える")
    func overlongNameStillOccupiesARow() {
        let rows = TagCapsuleBand.packedRowCount(
            names: [String(repeating: "長", count: 40)],
            availableWidth: contentWidth
        )
        #expect(rows == 1)
    }

    @Test("全角のタグは同じ文字数の半角より幅を取る")
    func fullWidthNamesWrapSooner() {
        let names = Array(repeating: "あいうえお", count: 8)
        let ascii = Array(repeating: "abcde", count: 8)
        let fullWidthRows = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        let asciiRows = TagCapsuleBand.packedRowCount(names: ascii, availableWidth: contentWidth)
        #expect(fullWidthRows >= asciiRows)
    }

    /// 実機で最終行が隠れた回帰。平均字幅の概算で詰めると実際より少ない行数になり、
    /// シートが低く出て下が切れた。実フォント測定では件数に見合う行数になる
    @Test("実機のタグ19件は概算より多い行数になる")
    func realWorldTagsNeedEnoughRows() {
        let names = ["車関係", "食材", "投資", "チャージ", "ETC", "重要", "000", "注意", "水泳",
                     "2回払いテスト", "キャンプ", "Hobby", "シルバー", "スキー", "EG立替金",
                     "洗車", "ガソリン", "医療費", "税金"]
        let rows = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        // 文字サイズ設定で前後するため、切れない側（多め）に収まっていることを見る
        #expect(rows >= 4)
    }

    @Test("シート高さは実測行数より1行ぶん多く取る")
    func heightKeepsOneSpareRow() {
        // 最終行が隠れるより1行多いほうが良い、という方針を固定する
        let names = ["食費", "交通", "医療", "娯楽", "本", "外食"]
        let rows = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        let detents = TagSelectionList.detents(tagNames: names, availableWidth: 393)
        // 余裕を足しても上限内なら、中身ぶんの高さが返る（全開にはしない）
        if rows + 1 <= 8 {
            #expect(detents != [.large])
        }
    }

    @Test("ソート順は保ったまま、行末の余白に収まる後方タグを繰り上げる")
    func packToFillPullsUpLaterTags() {
        // 先頭に長いタグ、続けて短いタグを並べる。単純な折り返しなら
        // 長いタグの行に余白が残るが、packToFill では短いタグが繰り上がる
        let names = [String(repeating: "あ", count: 14), "本", "外食", "医療"]
        let rows = TagCapsuleBand.packedRowCount(names: names, availableWidth: contentWidth)
        #expect(rows <= 2)
    }

    @Test("行数が上限を超えるタグ数では全開のみを返す")
    func manyTagsOpenFull() {
        let names = (1...120).map { "タグ\($0)" }
        let detents = TagSelectionList.detents(tagNames: names, availableWidth: 393)
        #expect(detents == [.large])
    }

    /// 少ないタグでは中身ぶんの高さだけを返す。
    /// .large を候補に含めるとキーボード表示時に昇格して大きな余白ができるため、
    /// 高さ指定は1つだけにしてある
    @Test("少ないタグでは中身ぶんの高さだけを返す")
    func fewTagsUseContentHeight() {
        let detents = TagSelectionList.detents(tagNames: ["食費", "交通"], availableWidth: 393)
        #expect(detents.count == 1)
        #expect(detents != [.large])
    }

    @Test("一致条件の行を出すぶんだけシートは高くなる")
    func matchModeAddsHeight() {
        let names = ["食費", "交通"]
        let without = TagSelectionList.detents(tagNames: names, availableWidth: 393)
        let with = TagSelectionList.detents(
            tagNames: names,
            showsMatchMode: true,
            availableWidth: 393
        )
        // .large 以外の高さ指定が、一致条件ありの方で変わっていることを確認する
        #expect(without != with)
    }
}
