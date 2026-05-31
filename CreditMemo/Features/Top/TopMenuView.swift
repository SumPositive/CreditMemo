import SwiftUI
import SwiftData

struct TopMenuView: View {
    @Binding var selectedDestination: AppDestination?
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.paymentWindowDays) private var paymentWindowDays = 15

    @Query(sort: \E7payment.date, order: .reverse)
    private var allPayments: [E7payment]

    private var unpaidPayments: [E7payment] {
        // 起動直後クラッシュ回避:
        // isPaid は e2invoices 関係を辿るため、旧データ不整合時に落ちることがある。
        // メニュー集計は状態ラベルの関係参照を避け、支払側の所属で判定する。
        allPayments.filter { $0.e8paid == nil }
    }

    private var recentUnpaidTotal: Decimal {
        // メニュー表示は「本日から N 日間の引き落とし合計」を使う
        let windowDays = max(1, min(paymentWindowDays, 30))
        let sorted = unpaidPayments.sorted { $0.date < $1.date }
        let today = Calendar.current.startOfDay(for: Date())
        let end: Date
        if windowDays == 30 {
            end = Calendar.current.date(byAdding: .month, value: 1, to: today) ?? today
        } else {
            end = Calendar.current.date(byAdding: .day, value: windowDays - 1, to: today) ?? today
        }
        return sorted
            .filter {
                let date = Calendar.current.startOfDay(for: $0.date)
                return today <= date && date <= end
            }
            .reduce(.zero) { partialResult, payment in
                partialResult + payment.sumAmount
            }
    }

    private var recentWindowLabel: String {
        let windowText = paymentWindowLabel(max(1, min(paymentWindowDays, 30)))
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if isJapanese {
            return "直近\(windowText)合計"
        }
        return "Recent \(windowText) Total"
    }

    var body: some View {
        List(selection: $selectedDestination) {
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "top.beginner.hint",
                        detailMessageKey: "top.beginner.guide"
                    )
                }
            }
            // 明細
            Section {
                row(.addRecord, icon: "plus.circle.fill", color: .blue, key: "top.addRecord")
                row(.recordList, icon: "list.bullet.circle.fill", color: .cyan, key: "top.recordList")
            }

            // 集計
            Section {
                NavigationLink(value: AppDestination.paymentList) {
                    HStack {
                        ScaledMenuBadge()
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        // タイトル / 直近計 / 金額 を、入る範囲で 1段→2段→3段 と段を増やして表示する
                        ViewThatFits(in: .horizontal) {
                            // 1行版: タイトル + 直近計 + 金額をすべて1行に
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("top.paymentList")
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 8)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(recentWindowLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .allowsTightening(true)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text(recentUnpaidTotal.currencyString())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(COLOR_UNPAID)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            // 2行版: タイトル / 直近計+金額（右寄せ1行）
                            VStack(alignment: .leading, spacing: 4) {
                                Text("top.paymentList")
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Spacer(minLength: 0)
                                    Text(recentWindowLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .allowsTightening(true)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text(recentUnpaidTotal.currencyString())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(COLOR_UNPAID)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            // 3行版: タイトル / 直近計 / 金額（金額は右寄せ）
                            VStack(alignment: .leading, spacing: 4) {
                                Text("top.paymentList")
                                Text(recentWindowLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .allowsTightening(true)
                                HStack {
                                    Spacer(minLength: 0)
                                    Text(recentUnpaidTotal.currencyString())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(COLOR_UNPAID)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }
                }
                .tag(AppDestination.paymentList)
            }

            // マスタメニューは初心者/達人に関係なく常時表示する
            Section {
                row(.cardList, icon: "creditcard", color: .green, key: "top.cardList")
                row(.bankList, icon: "building.columns", color: .teal, key: "top.bankList")
                row(.tagList, icon: "tag", color: .pink, key: "top.tagList")
            }

            // アプリ
            Section {
                row(
                    .settings,
                    icon: "gearshape",
                    color: .gray,
                    key: "top.settings"
                )
            }
        }
        // 先頭セクション前の余白を詰めて、ヘッダ直下をコンパクトにする
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("app.name")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func row(
        _ dest: AppDestination,
        icon: String, color: Color,
        key: LocalizedStringKey
    ) -> some View {
        NavigationLink(value: dest) {
            HStack(alignment: .top, spacing: 12) {
                ScaledMenuIcon(systemName: icon, color: color)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text(key)
            }
        }
        .tag(dest)
    }

    private func paymentWindowLabel(_ days: Int) -> String {
        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"
        if days == 30 {
            return isJapanese ? "1ヶ月" : "1 Month"
        }
        return isJapanese ? "\(days)日" : "\(days) Days"
    }
}

/// メニューの SF Symbol アイコン。文字サイズに連動して拡縮する
/// 呼び出し側で `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` を付けて
/// 「大」を上限にクランプする運用
private struct ScaledMenuIcon: View {
    let systemName: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .font(.system(size: size))
            .foregroundStyle(color)
            .frame(width: size)
    }
}

/// 引き落とし状況用のアプリバッジ。同じくサイズを文字サイズに連動させる
private struct ScaledMenuBadge: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        AppIconBadge(size: size)
            .frame(width: size)
    }
}
