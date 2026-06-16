import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
struct AppIconBadge: View {
    let size: CGFloat
    /// 他の丸アイコンと見た目の密度を揃えるため少しだけ拡大する
    private let visualScale: CGFloat = 1.14

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        // アプリアイコン由来のベクター画像を少しだけ大きめに見せる
        Image("AppIconBadge")
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size * visualScale, height: size * visualScale)
            .frame(width: size, height: size)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
