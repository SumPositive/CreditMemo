import SwiftUI
import SwiftData

struct TagListView: View {
    @Query private var tags: [E5tag]
    @Environment(\.modelContext) private var context

    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.recent.rawValue
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system

    @State private var showAddSheet  = false
    @State private var historyTarget: E5tag?
    @State private var showSortDropdown = false

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .recent }

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
        // 上部のソート指定との間にList既定の余白が入らないようにする
        .contentMargins(.top, 0, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
            // セクション余白を避け、タイトル直下に詰めて配置する
            TagSortModeDropdown(
                sortModeRaw: $sortModeRaw,
                isExpanded: $showSortDropdown
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .scalableNavigationTitle("tag.list.title")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
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
                Image(systemName: "line.3.horizontal.decrease")
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
