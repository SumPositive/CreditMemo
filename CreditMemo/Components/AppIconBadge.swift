import SwiftUI

/// 引き落とし状況導線で使う共通バッジ。
/// Asset Catalog にベクター PDF（`AppIconBadge.pdf`）として登録してあるので、
/// SwiftUI のピュア描画と違いスワイプアクションなど任意の文脈で確実にレンダリングされ、
/// かつ拡大縮小しても劣化しない。
struct AppIconBadge: View {
    let size: CGFloat

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        Image("AppIconBadge")
            .renderingMode(.original)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .fixedSize()
    }
}
