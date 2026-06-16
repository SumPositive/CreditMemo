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

    private var beginnerHelpDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("bank.beginner.line1")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("bank.beginner.line2")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("bank.beginner.statusSwipeIntro")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            beginnerStatusHelpRow(textKey: "bank.beginner.statusSwipeText")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginnerStatusHelpRow(textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // スワイプ用も共通バッジ画像を使う
            Image("AppIconBadge")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
            Text(textKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    // 追加・並び替え・状況表示の説明は詳細にまとめる
                    BeginnerHintView(
                        hintKey: "bank.beginner.hint"
                    ) {
                        beginnerHelpDetail
                    }
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
                        // スワイプ用も共通バッジ画像を使う
                        Label("", image: "AppIconBadge")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("card.action.status"))
                }
            }
            .onMove(perform: move)
        }
        .scalableNavigationTitle("bank.list.title") {
            Image(systemName: "building.columns")
                .foregroundStyle(Color.brown)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
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
