import SwiftUI
import SwiftData

struct TagListView: View {
    @Query private var tags: [E5tag]
    @Environment(\.modelContext) private var context

    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.defaultForTags.rawValue
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner

    @State private var newTagName = ""
    /// カプセルのタップで開く編集画面の対象
    @State private var editTarget: E5tag?
    @State private var showSortDropdown = false

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .defaultForTags }

    /// 初心者ヒントの詳細シート本文（追加・ソートの説明）。
    /// タグ式にしてスワイプ操作が無くなったので、その説明は載せない
    private var beginnerHelpDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("tag.beginner.addText")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerSymbolHelpRow(systemName: "line.3.horizontal.decrease", textKey: "tag.beginner.sortText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// SF Symbol と説明文を並べる（ソートアイコン等）
    private func beginnerSymbolHelpRow(systemName: String, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: 34, height: 34)
            Text(textKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sorted: [E5tag] {
        tags.sortedByTagMode(sortMode)
    }

    /// 入力中は既存タグを絞り込み、探してから追加できるようにする
    private var displayedTags: [E5tag] {
        let input = trimmedNewTagName.normalizedTagLookupName
        guard !input.isEmpty else { return sorted }
        return sorted.filter { $0.zName.normalizedTagLookupName.contains(input) }
    }

    private var trimmedNewTagName: String {
        newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// カプセル1つ = タグ1件。マスタなので選択状態は持たない
    private var bandItems: [TagCapsuleBand.Item] {
        displayedTags.map { tag in
            TagCapsuleBand.Item(
                id: tag.id,
                title: tag.zName,
                isSelected: false,
                action: { editTarget = tag }
            )
        }
    }

    /// タイトル直下へ置く検索兼追加欄
    private var findOrAddSection: some View {
        TagFindOrAddSection(name: $newTagName, onCommit: findOrAddTag)
    }

    var body: some View {
        // 複数選択シートと同じ見栄え・同じ幅にするため、シートと同様に
        // ScrollView へ直接カプセル帯を置く（List の inset 分だけ狭くならないように）
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                // 決済手段・口座マスタと同じく、初心者ヒントを先頭に置く
                if userLevel == .beginner {
                    BeginnerHintView(
                        hintKey: "tag.beginner.hint"
                    ) {
                        beginnerHelpDetail
                    }
                    .padding(.horizontal, TagCapsuleBand.areaHorizontalPadding)
                }
                // タグは複数選択シートと同じタグ式（カプセル）で並べる。
                // タップで編集画面へ進み、履歴へは編集画面上部の「履歴」ボタンから行く
                TagCapsuleBand(items: bandItems)
            }
        }
        // スクロールインジケータは出さない
        .scrollIndicators(.hidden)
        // タグを見比べるためにスクロールしたらキーボードを閉じる
        .scrollDismissesKeyboard(.immediately)
        .background(Color(uiColor: .systemGroupedBackground))
        // 検索兼追加欄とソート条件はタイトル直下へ固定する
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                findOrAddSection

                TagSortModeDropdown(
                    sortModeRaw: $sortModeRaw,
                    isExpanded: $showSortDropdown
                )
            }
            .padding(.horizontal, TagCapsuleBand.areaHorizontalPadding)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .scalableNavigationTitle("tag.list.title") {
            Image(systemName: "tag")
                .foregroundStyle(Color.orange)
        }
        .navigationDestination(item: $editTarget) { tag in
            // カプセルのタップから編集画面へ。履歴へはその画面の「履歴」ボタンで進む
            TagEditView(tag: tag)
        }
    }

    /// 同名があれば既存タグを開き、無ければ新しいタグとして追加する
    private func findOrAddTag() {
        let name = trimmedNewTagName
        guard !name.isEmpty else { return }

        let normalizedName = name.normalizedTagLookupName
        if let existing = tags.first(where: { $0.zName.normalizedTagLookupName == normalizedName }) {
            newTagName = ""
            editTarget = existing
            return
        }

        // 新規追加は「最近順」で先頭表示されるよう作成日時を入れる
        let tag = E5tag(zName: name, sortDate: Date(), sortName: name)
        context.insert(tag)
        context.saveReporting(operation: "TagListView.findOrAddTag")
        newTagName = ""
    }
}

extension String {
    /// 大文字小文字・濁点・文字幅の違いを吸収してタグの検索と重複判定を揃える
    var normalizedTagLookupName: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}

extension Sequence where Element == E5tag {
    /// タグ一覧と各選択シートで共通の並び順を適用する
    func sortedByTagMode(_ mode: SortMode) -> [E5tag] {
        switch mode {
        case .recent:
            sorted { ($1.sortDate ?? .distantPast) < ($0.sortDate ?? .distantPast) }
        case .count:
            sorted { $1.sortCount < $0.sortCount }
        case .amount:
            sorted { $1.sortAmount < $0.sortAmount }
        case .name:
            sorted { $0.zName.localizedStandardCompare($1.zName) == .orderedAscending }
        }
    }

    /// 新規追加ぶんと選択済みを先頭に寄せて、タグ選択用の表示順を作る。
    ///
    /// 先頭寄せは表示時（シートを開いた時）だけに使う。選択のたびに組み直すと
    /// タップしたタグが動いて次を選びにくいので、操作中は並びを保つ
    func orderedForTagSelection(
        mode: SortMode,
        selectedIDs: Set<String> = [],
        prioritizedIDs: Set<String> = []
    ) -> [E5tag] {
        let sorted = sortedByTagMode(mode)
        guard !prioritizedIDs.isEmpty || !selectedIDs.isEmpty else { return sorted }
        let prioritized = sorted.filter { prioritizedIDs.contains($0.id) }
        let selected = sorted.filter {
            !prioritizedIDs.contains($0.id) && selectedIDs.contains($0.id)
        }
        let unselected = sorted.filter {
            !prioritizedIDs.contains($0.id) && !selectedIDs.contains($0.id)
        }
        return prioritized + selected + unselected
    }
}

// MARK: - Tag Capsule Band

/// タグをカプセルで折り返して並べる共通の帯。
/// タグ一覧（マスタ）と複数選択シートで同じ見栄え・同じ幅にするため、
/// 寸法と配色はこの型にまとめる
struct TagCapsuleBand: View {
    /// カプセルの寸法。見栄えを揃えるため両画面でこの値を使う
    static let capsuleSpacing: CGFloat = 8
    static let capsuleHorizontalPadding: CGFloat = 14
    static let capsuleVerticalPadding: CGFloat = 7
    /// 帯の左右・上下余白
    static let areaHorizontalPadding: CGFloat = 16
    static let areaVerticalPadding: CGFloat = 12

    /// 1行ぶんのカプセル高さ（文字サイズ設定に追従する）
    static var capsuleHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight)
            + capsuleVerticalPadding * 2
    }

    /// タグ1つ分のカプセル幅。実際の描画フォントで測るので実寸に一致する
    static func capsuleWidth(for name: String) -> CGFloat {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + capsuleHorizontalPadding * 2
    }

    /// AZFlowLayout(packToFill:) と同じ規則でカプセルを行へ詰め、必要な行数を返す
    static func packedRowCount(names: [String], availableWidth: CGFloat) -> Int {
        let widths = names.map { capsuleWidth(for: $0) }
        guard !widths.isEmpty, availableWidth > 0 else { return 1 }

        var placed = [Bool](repeating: false, count: widths.count)
        var rows = 0
        while let start = placed.firstIndex(of: false) {
            placed[start] = true
            var used = widths[start]
            rows += 1
            while true {
                let free = availableWidth - used - capsuleSpacing
                if free <= 0 { break }
                // packToFill と同じく、収まる“最初の”後方要素を繰り上げる
                guard let idx = ((start + 1)..<widths.count)
                    .first(where: { !placed[$0] && widths[$0] <= free }) else { break }
                placed[idx] = true
                used += capsuleSpacing + widths[idx]
            }
        }
        return rows
    }

    /// 表示するカプセル。選択状態は塗りで示す
    struct Item: Identifiable {
        let id: String
        let title: String
        let isSelected: Bool
        let action: () -> Void
    }

    let items: [Item]

    var body: some View {
        // ソート順を優先しながら、行末の余白に収まる後方のタグを繰り上げて詰める。
        // タグ一覧は常に均等（間隔は固定でカプセル幅を広げる）にする
        AZFlowLayout(
            spacing: Self.capsuleSpacing,
            rowSpacing: Self.capsuleSpacing,
            alignment: .center,
            packToFill: true,
            justified: true
        ) {
            ForEach(items) { item in
                capsule(item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.areaHorizontalPadding)
        .padding(.vertical, Self.areaVerticalPadding)
    }

    /// カプセル1つ分。選択中はアクセント塗りにして、チェックマークの代わりに
    /// 塗りの有無で選択状態を示す（「よくある決済」のカプセルと同じ表現）
    @ViewBuilder
    private func capsule(_ item: Item) -> some View {
        Button(action: item.action) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                // 均等割りで提案された幅までカプセルを広げる。
                // Text は自然幅で止まるので、ここを開けて背景ごと広げる
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.capsuleHorizontalPadding)
                .padding(.vertical, Self.capsuleVerticalPadding)
                .background(
                    Capsule().fill(item.isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .foregroundStyle(item.isSelected ? Color.white : Color.accentColor)
                .overlay(
                    Capsule().stroke(
                        item.isSelected ? Color.clear : Color.accentColor.opacity(0.35),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct TagSortModeDropdown: View {
    @Binding var sortModeRaw: Int
    @Binding var isExpanded: Bool

    private var selection: Binding<SortMode> {
        Binding(
            get: { SortMode(rawValue: sortModeRaw) ?? .defaultForTags },
            set: { sortModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        // タグの並び順はAZDropdownPickerで横幅いっぱいに表示する
        AZDropdownPicker(
            options: SortMode.allCases,
            selection: selection,
            isExpanded: $isExpanded,
            minWidth: 0,
            fillsWidth: true
        ) { mode in
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .imageScale(.medium)
                Text(LocalizedStringKey(mode.localizedKey))
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// タグ一覧と選択シートで共用する検索兼追加欄
struct TagFindOrAddSection: View {
    @Binding var name: String
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("tag.list.findOrAdd")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                TextField("tag.field.name", text: $name)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .trimmingTrailingNewlines($name)

                // 行内ボタンは入力欄のタップ判定と競合しないよう borderless にする
                Button("button.add") { commit() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    isFocused = false
                } label: {
                    // 入力を終えて一覧へ戻る操作をアイコンで示す
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel(Text("button.done"))
            }
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        onCommit()
        isFocused = false
    }
}

/// 複数タグ絞り込みの一致条件（OR／AND）を選ぶラジオボタン
struct TagMatchModePicker: View {
    @Binding var matchModeRaw: Int

    private var selection: Binding<TagMatchMode> {
        Binding(
            get: { TagMatchMode(rawValue: matchModeRaw) ?? .defaultMode },
            set: { matchModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        // 選択肢は2つだけなので、折り返さず横幅を等分する
        AZRadioPicker(
            options: TagMatchMode.allCases,
            selection: selection,
            minOptionWidth: 0,
            horizontalPadding: 4,
            wrapsOptions: false,
            fillsWidth: true
        ) { mode in
            Text(LocalizedStringKey(mode.localizedKey))
                .allowsTightening(true)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity)
    }
}

/// 各画面で共用するタグ選択一覧の見た目とソート領域
struct TagSelectionList: View {
    let tags: [E5tag]
    let selectedIDs: Set<String>
    let showsAllOption: Bool
    let isAllSelected: Bool
    let onSelectAll: () -> Void
    let onSelectTag: (E5tag) -> Void
    /// 指定された選択シートだけ検索兼追加欄を表示する
    private var findOrAddName: Binding<String>?
    private var onFindOrAdd: (() -> Void)?

    @Binding private var sortModeRaw: Int
    @Binding private var isSortExpanded: Bool
    /// 複数タグの一致条件（OR／AND）。単一選択のシートでは nil にして行ごと隠す
    private var matchModeRaw: Binding<Int>?

    init(
        tags: [E5tag],
        selectedIDs: Set<String>,
        sortModeRaw: Binding<Int>,
        isSortExpanded: Binding<Bool>,
        matchModeRaw: Binding<Int>? = nil,
        showsAllOption: Bool = false,
        isAllSelected: Bool = false,
        onSelectAll: @escaping () -> Void = {},
        findOrAddName: Binding<String>? = nil,
        onFindOrAdd: (() -> Void)? = nil,
        onSelectTag: @escaping (E5tag) -> Void
    ) {
        self.tags = tags
        self.selectedIDs = selectedIDs
        self.matchModeRaw = matchModeRaw
        self.showsAllOption = showsAllOption
        self.isAllSelected = isAllSelected
        self.onSelectAll = onSelectAll
        self.findOrAddName = findOrAddName
        self.onFindOrAdd = onFindOrAdd
        self.onSelectTag = onSelectTag
        _sortModeRaw = sortModeRaw
        _isSortExpanded = isSortExpanded
    }

    var body: some View {
        // タグ一覧（マスタ）と同じ TagCapsuleBand を使い、見栄えと幅を揃える
        ScrollView(.vertical) {
            TagCapsuleBand(items: bandItems)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        // スクロールインジケータは出さない
        .scrollIndicators(.hidden)
        // 検索後にタグを見比べるためスクロールしたらキーボードを閉じる
        .scrollDismissesKeyboard(.immediately)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            // 検索兼追加欄・一致条件・ソート領域は一覧外側と同じ薄いグレーで固定する
            VStack(spacing: 8) {
                if let findOrAddName, let onFindOrAdd {
                    TagFindOrAddSection(name: findOrAddName, onCommit: onFindOrAdd)
                }
                if let matchModeRaw {
                    TagMatchModePicker(matchModeRaw: matchModeRaw)
                }
                TagSortModeDropdown(
                    sortModeRaw: $sortModeRaw,
                    isExpanded: $isSortExpanded
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    // MARK: - 表示するカプセル

    private var bandItems: [TagCapsuleBand.Item] {
        var items: [TagCapsuleBand.Item] = []
        if showsAllOption {
            items.append(
                TagCapsuleBand.Item(
                    id: "__all__",
                    title: NSLocalizedString("label.all", comment: ""),
                    isSelected: isAllSelected,
                    action: onSelectAll
                )
            )
        }
        items += displayedTags.map { tag in
            TagCapsuleBand.Item(
                id: tag.id,
                title: tag.zName,
                isSelected: selectedIDs.contains(tag.id),
                action: { onSelectTag(tag) }
            )
        }
        return items
    }

    /// 検索兼追加欄があるシートでは入力に合うタグだけを表示する
    private var displayedTags: [E5tag] {
        guard let findOrAddName else { return tags }
        let input = findOrAddName.wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedTagLookupName
        guard !input.isEmpty else { return tags }
        return tags.filter { $0.zName.normalizedTagLookupName.contains(input) }
    }

    // MARK: - シート高さ

    /// 上部固定領域（ソート行、一致条件行）とツールバーぶんの高さ
    private static let sortRowHeight: CGFloat = 58
    private static let matchModeRowHeight: CGFloat = 50
    private static let findOrAddRowHeight: CGFloat = 78
    private static let navigationBarHeight: CGFloat = 56
    /// これを超える行数になったら最初から全開にする。
    /// タグ式は1行に複数入るので、行数の上限はやや広く取る
    private static let maxCompactRows = 8

    /// タグ名から実際の詰まり方を見積もって、シート高さを返す。
    /// 最終行が隠れるより1行多いほうが良いので、見積もりには1行ぶんの余裕を足す
    static func detents(
        tagNames: [String],
        showsAllOption: Bool = false,
        showsMatchMode: Bool = false,
        showsFindOrAdd: Bool = false,
        availableWidth: CGFloat = UIScreen.main.bounds.width
    ) -> Set<PresentationDetent> {
        var names = tagNames
        if showsAllOption {
            names.insert(NSLocalizedString("label.all", comment: ""), at: 0)
        }
        let contentWidth = availableWidth - TagCapsuleBand.areaHorizontalPadding * 2
        // 端数の丸めや字幅の差で1行ずれても最終行が切れないよう、1行ぶん多めに取る
        let rowCount = TagCapsuleBand.packedRowCount(
            names: names,
            availableWidth: contentWidth
        ) + 1
        guard rowCount <= maxCompactRows else { return [.large] }

        let capsuleArea = TagCapsuleBand.capsuleHeight * CGFloat(rowCount)
            + TagCapsuleBand.capsuleSpacing * CGFloat(rowCount - 1)
            + TagCapsuleBand.areaVerticalPadding * 2

        let chrome = navigationBarHeight + sortRowHeight
            + (showsMatchMode ? matchModeRowHeight : 0)
            + (showsFindOrAdd ? findOrAddRowHeight : 0)
        return [.height(ceil(capsuleArea + chrome))]
    }
}
