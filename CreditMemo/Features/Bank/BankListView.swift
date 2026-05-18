import SwiftUI
import SwiftData

struct BankListView: View {
    @Query(sort: \E8bank.nRow) private var banks: [E8bank]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner

    @State private var showAddSheet    = false
    @State private var deleteTarget: E8bank?
    @State private var showDeleteAlert = false
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
                        // 状況スワイプは削除スワイプより前に説明する
                        Text("bank.beginner.statusSwipe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("bank.beginner.line3")
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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget    = bank
                        showDeleteAlert = true
                    } label: {
                        Label("button.delete", systemImage: "trash")
                    }
                }
                // 「状況」は削除と隣接させない（誤タップ防止）ため、左スワイプ側に分離して配置する
                // 背景セル色 + アイコンのみ。テキストは system が白色強制してしまうため省略。
                // ロングスワイプで即時実行。
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        statusBank = bank
                    } label: {
                        Label("", image: "AppIconBadge")
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
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { BankEditView(bank: nil) }
        }
        // 状況スワイプから引き落とし状況画面（初期絞り込み付き）へ push
        .navigationDestination(item: $statusBank) { bank in
            PaymentListView(initialBankFilter: bank)
        }
        // 特大フォント・長文でも全文が見える独自ダイアログを使用
        .deleteConfirmation(
            isPresented: $showDeleteAlert,
            title: "alert.deleteConfirm.title",
            message: "alert.deleteConfirm.bank.message"
        ) {
            if let b = deleteTarget {
                try? BankService.delete(b, context: context)
            }
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
