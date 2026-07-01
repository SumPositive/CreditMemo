import SwiftUI

/// 3段組みの日付表示（年・月日・曜日）
/// 履歴・引き落とし状況・カード別一覧などで共通利用する。
struct StackedDateView: View {
    let date: Date

    /// 年は控えめに、曜日は視認性優先で一段大きく
    private static let yearFont:    Font = .caption2   // 約11pt
    private static let weekdayFont: Font = .caption    // 約12pt

    private var yearLine: some View {
        Text(AppDateFormat.yearText(date))
            .font(Self.yearFont)
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(1)
    }

    private var monthDayLine: some View {
        Text(AppDateFormat.monthDayText(date))
            .font(.subheadline)
            .foregroundStyle(Color(.label))
            .lineLimit(1)
    }

    private var weekdayLine: some View {
        Text(AppDateFormat.weekdayText(date))
            .font(Self.weekdayFont)
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 中央=月日は共通。年と曜日の上下だけ読み順に合わせて入れ替える
            if AppDateFormat.usesYearFirstLayout {
                // 日中韓（大エンディアン）: 年 → 月日 → 曜日
                yearLine
                monthDayLine
                weekdayLine
            } else {
                // 西欧: 曜日 → 月日 → 年
                weekdayLine
                monthDayLine
                yearLine
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: true, vertical: false)
    }
}
