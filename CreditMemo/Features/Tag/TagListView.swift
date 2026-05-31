import SwiftUI
import SwiftData

struct TagListView: View {
    @Query private var tags: [E5tag]
    @Environment(\.modelContext) private var context

    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.recent.rawValue
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner

    @State private var showAddSheet  = false
    @State private var historyTarget: E5tag?
    @State private var showSortDropdown = false

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .recent }

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
        switch sortMode {
        case .recent: tags.sorted { ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast) }
        case .count:  tags.sorted { $0.sortCount > $1.sortCount }
        case .amount: tags.sorted { $0.sortAmount > $1.sortAmount }
        case .name:   tags.sorted { $0.zName.localizedStandardCompare($1.zName) == .orderedAscending }
        }
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
                .foregroundStyle(Color.pink)
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

struct TagSortModeDropdown: View {
    @Binding var sortModeRaw: Int
    @Binding var isExpanded: Bool

    private var selection: Binding<SortMode> {
        Binding(
            get: { SortMode(rawValue: sortModeRaw) ?? .recent },
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
