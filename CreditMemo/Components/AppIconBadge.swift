import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
struct AppIconBadge: View {
    let size: CGFloat

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        // アプリアイコン由来のベクター画像をそのまま縮尺表示
        Image("AppIconBadge")
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
