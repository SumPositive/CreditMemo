import SwiftUI
import SwiftData

struct CardListView: View {
    @Query(sort: \E1card.nRow) private var cards: [E1card]
    @Environment(\.modelContext) private var context
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system

    @State private var showAddSheet    = false
    /// スワイプ「状況」で開く決済手段。設定されると引き落とし状況画面へ push する。
    @State private var statusCard: E1card?
    /// スワイプ「新しい決済」で開くシートに渡すプリセット決済手段。
    @State private var newPaymentCard: E1card?

    var body: some View {
        List {
            if userLevel == .beginner {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("card.beginner.line1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("card.beginner.line2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 「状況」スワイプの案内
                        Text("card.beginner.statusSwipe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            ForEach(cards) { card in
                NavigationLink {
                    // 決済手段マスタは、選択時に状況ではなく編集画面を開く。
                    CardEditView(card: card)
                } label: {
                    CardRow(card: card)
                }
                // 右スワイプメニュー：ロングスワイプの即時実行は使わない
                // ラベルテキストは省略しアイコンのみで配置する。
                // 新しい決済のアイコンはメインメニューと統一し、背景は白にする
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        statusCard = card
                    } label: {
                        Label("", image: "AppIconBadgeSwipe")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("card.action.status"))

                    Button {
                        newPaymentCard = card
                    } label: {
                        Label("", image: "AddRecordIcon")
                    }
                    .tint(Color(uiColor: .systemBackground))
                    .accessibilityLabel(Text("record.edit.title.add"))
                }
            }
            .onMove(perform: move)
        }
        .scalableNavigationTitle("card.list.title")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { CardEditView(card: nil) }
                // シートにもアプリ内文字サイズ設定を明示適用する
                .appFontScale(fontScale)
                // 決済手段追加シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        // 状況スワイプから引き落とし状況画面（初期絞り込み付き）へ push
        .navigationDestination(item: $statusCard) { card in
            PaymentListView(initialCardFilter: card)
        }
        // 「新しい決済」スワイプから、決済手段プリセット済みの新規追加シートを開く。
        // 金額未入力（nAmount == 0）のため、自動的にテンキーが表示される。
        .sheet(item: $newPaymentCard) { card in
            NavigationStack {
                RecordEditView(mode: .addNew, presetCard: card)
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 新規決済シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = cards
        list.move(fromOffsets: source, toOffset: destination)
        for (i, c) in list.enumerated() { c.nRow = Int32(i) }
    }
}

// MARK: - Row

private struct CardRow: View {
    let card: E1card
    private var isEnglishLocale: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en") == "en"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(card.zName).font(.body)
                Spacer()
                if card.sumUnpaid != .zero {
                    Text(card.sumUnpaid.currencyString())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(COLOR_UNPAID)
                }
            }
            HStack(spacing: 8) {
                Text(scheduleBadgeText)
                    .font(.caption2)
                    .foregroundStyle(scheduleBadgeForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(scheduleBadgeBackgroundColor)
                    .clipShape(Capsule())
                    // 請求方式カプセルは改行させず、内容を優先して保持する
                    .fixedSize(horizontal: true, vertical: false)
                Text(card.e8bank?.zName ?? NSLocalizedString("payment.bank.noSelection", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 口座名だけを可変幅にして、末尾省略の対象にする
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 2行目カプセル文言を請求方式ごとに出し分ける
    private var scheduleBadgeText: String {
        if card.nClosingDay == 0 {
            let daysLater = Int(card.nPayDay)
            if daysLater == 0 {
                return NSLocalizedString("card.schedule.sameDay", comment: "")
            }
            return String(format: NSLocalizedString("card.schedule.afterDays", comment: ""), daysLater)
        }

        // 締日/支払日型
        let closingDayText: String
        if card.nClosingDay == 29 {
            closingDayText = NSLocalizedString("card.schedule.closing.end", comment: "")
        } else {
            closingDayText = String(format: NSLocalizedString("card.schedule.closing.day", comment: ""), card.nClosingDay)
        }

        let payMonthText: String
        if card.nPayMonth == 0 {
            payMonthText = NSLocalizedString("card.payMonth.current", comment: "")
        } else if card.nPayMonth == 1 {
            payMonthText = NSLocalizedString("card.payMonth.next", comment: "")
        } else {
            payMonthText = NSLocalizedString("card.payMonth.twoMonths", comment: "")
        }

        let payDayText: String
        if card.nPayDay == 29 {
            payDayText = NSLocalizedString("card.schedule.pay.end", comment: "")
        } else {
            payDayText = String(format: NSLocalizedString("card.schedule.pay.day", comment: ""), card.nPayDay)
        }

        let separator = isEnglishLocale ? " / " : "/"
        return "\(closingDayText)\(separator)\(payMonthText)\(separator)\(payDayText)"
    }

    /// 請求方式別のカプセル背景色
    private var scheduleBadgeBackgroundColor: Color {
        if card.nClosingDay == 0 {
            return Color.cyan.opacity(0.16)
        }
        return Color.indigo.opacity(0.14)
    }

    /// 請求方式別のカプセル文字色
    private var scheduleBadgeForegroundColor: Color {
        if card.nClosingDay == 0 {
            return Color.cyan.opacity(0.95)
        }
        return Color.indigo.opacity(0.95)
    }
}
