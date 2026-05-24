import SwiftUI
import SwiftData

struct TagListView: View {
    @Query private var tags: [E5tag]
    @Environment(\.modelContext) private var context

    @AppStorage(AppStorageKey.tagSortMode) private var sortModeRaw: Int = SortMode.recent.rawValue

    @State private var showAddSheet  = false
    @State private var historyTarget: E5tag?

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
                // 右スワイプメニュー「履歴」。ロングスワイプで即時実行。
                // ラベルテキストは省略しアイコンのみで配置する。
                // アイコン・色はメインメニューの「履歴」と統一（list.bullet / indigo）。
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        historyTarget = tag
                    } label: {
                        Label("", systemImage: "list.bullet")
                    }
                    .tint(.indigo)
                    .accessibilityLabel(Text("tag.action.recordList"))
                }
            }
        }
        .scalableNavigationTitle("tag.list.title")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("shop.field.sortMode", selection: $sortModeRaw) {
                        ForEach(SortMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.localizedKey)).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { TagEditView(tag: nil) }
                // タグ追加シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .navigationDestination(item: $historyTarget) { tag in
            // タグ一覧のスワイプから、該当タグで絞り込んだ履歴へ遷移する
            RecordListView(initialTag: tag)
        }
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
