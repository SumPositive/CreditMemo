import SwiftUI
import SwiftData

struct TagListView: View {
    @Query private var tags: [E5tag]
    @Environment(\.modelContext) private var context

    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.defaultForTags.rawValue
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner

    @State private var showAddSheet  = false
    @State private var historyTarget: E5tag?
    @State private var showSortDropdown = false

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .defaultForTags }

    /// 初心者ヒントの詳細シート本文（追加・ソート・スワイプ操作の説明）
    private var beginnerHelpDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("tag.beginner.addText")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerSymbolHelpRow(systemName: "line.3.horizontal.decrease", textKey: "tag.beginner.sortText")
            Text("tag.beginner.swipeIntro")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerImageHelpRow(imageName: "RecordListIconSwipe", textKey: "tag.beginner.recordListSwipeText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// アセット画像（スワイプ用アイコン等）と説明文を並べる
    private func beginnerImageHelpRow(imageName: String, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
            Text(textKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        List {
            // 決済手段・口座マスタと同じく、初心者ヒントを先頭 Section に置く
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "tag.beginner.hint"
                    ) {
                        beginnerHelpDetail
                    }
                }
            }
            // ソート条件はヒントの下、明細リストの上に置く
            Section {
                TagSortModeDropdown(
                    sortModeRaw: $sortModeRaw,
                    isExpanded: $showSortDropdown
                )
            }
            ForEach(sorted) { tag in
                NavigationLink {
                    TagEditView(tag: tag)
                } label: {
                    TagRow(tag: tag)
                }
                // 右スワイプメニュー「履歴」。ロングスワイプの即時実行は使わない
                // ラベルテキストは省略しアイコンのみで配置する。
                // アイコン・色はメインメニューの「履歴」と統一し、背景は白にする
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        historyTarget = tag
                    } label: {
                        Label("", image: "RecordListIconSwipe")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("tag.action.recordList"))
                }
            }
        }
        .scalableNavigationTitle("tag.list.title") {
            Image(systemName: "tag")
                .foregroundStyle(Color.orange)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { TagEditView(tag: nil) }
                // シートにもアプリ内文字サイズ設定を明示適用する
                .appFontScale(fontScale)
                // タグ追加シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .navigationDestination(item: $historyTarget) { tag in
            // タグ一覧のスワイプから、該当タグで絞り込んだ履歴へ遷移する
            RecordListView(initialTag: tag)
        }
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
        onSelectTag: @escaping (E5tag) -> Void
    ) {
        self.tags = tags
        self.selectedIDs = selectedIDs
        self.matchModeRaw = matchModeRaw
        self.showsAllOption = showsAllOption
        self.isAllSelected = isAllSelected
        self.onSelectAll = onSelectAll
        self.onSelectTag = onSelectTag
        _sortModeRaw = sortModeRaw
        _isSortExpanded = isSortExpanded
    }

    var body: some View {
        // タグは「よくある決済」のラベル一覧と同じタグ式（カプセル）で並べる。
        // AZFlowLayout の packToFill で、ソート順を優先しながら行末の余白に
        // 収まる後方のタグを繰り上げて詰める。
        ScrollView(.vertical) {
            AZFlowLayout(
                spacing: capsuleSpacing,
                rowSpacing: capsuleSpacing,
                alignment: .center,
                packToFill: true
            ) {
                if showsAllOption {
                    tagCapsule(
                        title: NSLocalizedString("label.all", comment: ""),
                        isSelected: isAllSelected,
                        action: onSelectAll
                    )
                }
                ForEach(tags) { tag in
                    tagCapsule(
                        title: tag.zName,
                        isSelected: selectedIDs.contains(tag.id),
                        action: { onSelectTag(tag) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.capsuleAreaHorizontalPadding)
            .padding(.vertical, Self.capsuleAreaVerticalPadding)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            // 一致条件とソート領域は一覧外側と同じ薄いグレーで固定する
            VStack(spacing: 8) {
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

    // MARK: - シート高さ

    /// カプセルの寸法。tagCapsule の指定と揃える（変えたら両方直す）
    private static let capsuleSpacingValue: CGFloat = 8
    private static let capsuleHorizontalPadding: CGFloat = 14
    private static let capsuleVerticalPadding: CGFloat = 7
    /// カプセル帯の左右余白（body の padding と揃える）
    private static let capsuleAreaHorizontalPadding: CGFloat = 16
    /// カプセル帯の上下余白（body の padding と揃える）
    private static let capsuleAreaVerticalPadding: CGFloat = 12
    /// 上部固定領域（ソート行、一致条件行）とツールバーぶんの高さ
    private static let sortRowHeight: CGFloat = 58
    private static let matchModeRowHeight: CGFloat = 50
    private static let navigationBarHeight: CGFloat = 56
    /// これを超える行数になったら最初から全開にする。
    /// タグ式は1行に複数入るので、行数の上限はやや広く取る
    private static let maxCompactRows = 8

    /// タグ名1つ分のカプセル幅。実際の描画フォントで測るので、
    /// 文字種（全角・半角・英大文字）や文字サイズ設定によらず実寸に一致する
    private static func capsuleWidth(for name: String) -> CGFloat {
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
                let free = availableWidth - used - capsuleSpacingValue
                if free <= 0 { break }
                // packToFill と同じく、収まる“最初の”後方要素を繰り上げる
                guard let idx = ((start + 1)..<widths.count)
                    .first(where: { !placed[$0] && widths[$0] <= free }) else { break }
                placed[idx] = true
                used += capsuleSpacingValue + widths[idx]
            }
        }
        return rows
    }

    /// タグ名から実際の詰まり方を見積もって、シート高さを返す。
    /// 最終行が隠れるより1行多いほうが良いので、見積もりには1行ぶんの余裕を足す
    static func detents(
        tagNames: [String],
        showsAllOption: Bool = false,
        showsMatchMode: Bool = false,
        availableWidth: CGFloat = UIScreen.main.bounds.width
    ) -> Set<PresentationDetent> {
        var names = tagNames
        if showsAllOption {
            names.insert(NSLocalizedString("label.all", comment: ""), at: 0)
        }
        let contentWidth = availableWidth - capsuleAreaHorizontalPadding * 2
        // 端数の丸めや字幅の差で1行ずれても最終行が切れないよう、1行ぶん多めに取る
        let rowCount = packedRowCount(names: names, availableWidth: contentWidth) + 1
        guard rowCount <= maxCompactRows else { return [.large] }

        // カプセル1行の高さ = 文字の行高 + 上下余白
        let lineHeight = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let capsuleHeight = ceil(lineHeight) + capsuleVerticalPadding * 2
        let capsuleArea = capsuleHeight * CGFloat(rowCount)
            + capsuleSpacingValue * CGFloat(rowCount - 1)
            + capsuleAreaVerticalPadding * 2

        let chrome = navigationBarHeight + sortRowHeight
            + (showsMatchMode ? matchModeRowHeight : 0)
        return [.height(ceil(capsuleArea + chrome)), .large]
    }

    /// カプセル間の横スペース（AZFlowLayout に渡す）
    private var capsuleSpacing: CGFloat { Self.capsuleSpacingValue }

    /// タグ1つ分のカプセル。選択中はアクセント塗りにして、チェックマークの代わりに
    /// 塗りの有無で選択状態を示す（「よくある決済」のカプセルと同じ表現）
    @ViewBuilder
    private func tagCapsule(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.capsuleHorizontalPadding)
                .padding(.vertical, Self.capsuleVerticalPadding)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.clear : Color.accentColor.opacity(0.35),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TagRow: View {
    let tag: E5tag

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.zName)
                if !tag.zNote.isEmpty {
                    Text(tag.zNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
