import SwiftUI

extension View {
    /// navigationBarTitleDisplayMode(.large) はスケールしないため、
    /// inline + principal ToolbarItem で可変フォントタイトルを実現する。
    func scalableNavigationTitle(_ key: LocalizedStringKey) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(key)
                        .font(.title3.bold())
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
            }
    }

    /// 日付や名称など、ローカライズキーではない値をそのまま表示する。
    func scalableNavigationTitle(verbatim title: String) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: title)
                        .font(.title3.bold())
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
            }
    }

    /// 左にアイコンを添えたタイトル（メインメニュー由来の画面用）
    /// - Parameters:
    ///   - key: ローカライズキー
    ///   - icon: アイコンを返す ViewBuilder（SF Symbol でも AppIconBadge でも可）
    func scalableNavigationTitle<Icon: View>(
        _ key: LocalizedStringKey,
        @ViewBuilder icon: @escaping () -> Icon
    ) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        icon()
                        Text(key)
                            .font(.title3.bold())
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
            }
    }
}
