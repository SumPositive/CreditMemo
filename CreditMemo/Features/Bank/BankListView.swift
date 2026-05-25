import SwiftUI
import SwiftData

struct BankListView: View {
    @Query(sort: \E8bank.nRow) private var banks: [E8bank]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system

    @State private var showAddSheet    = false
    /// 左スワイプ「状況」で開く口座。設定されると引き落とし状況画面へ push する。
    @State private var statusBank: E8bank?

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("bank.beginner.line1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("bank.beginner.line2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 「状況」スワイプの案内
                        Text("bank.beginner.statusSwipe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            ForEach(banks) { bank in
                NavigationLink {
                    BankEditView(bank: bank)
                } label: {
                    BankRow(bank: bank)
                }
                // 右スワイプメニュー「状況」。ロングスワイプの即時実行は使わない
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        statusBank = bank
                    } label: {
                        Label("", image: "AppIconBadgeSwipe")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("card.action.status"))
                }
            }
            .onMove(perform: move)
        }
        .scalableNavigationTitle("bank.list.title")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.large) }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { BankEditView(bank: nil) }
                // シートにもアプリ内文字サイズ設定を明示適用する
                .appFontScale(fontScale)
                // 口座追加シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 状況スワイプから引き落とし状況画面（初期絞り込み付き）へ push
        .navigationDestination(item: $statusBank) { bank in
            PaymentListView(initialBankFilter: bank)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = banks
        list.move(fromOffsets: source, toOffset: destination)
        for (i, b) in list.enumerated() { b.nRow = Int32(i) }
    }
}

private struct BankRow: View {
    let bank: E8bank
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bank.zName)
            if !bank.zNote.isEmpty {
                Text(bank.zNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
