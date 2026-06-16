import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
/// 「上半分=未払（金茶）」「下半分=済み（グレージュ）」「中央=クリーム発光ライン」
/// 「外周=小豆色」のブランド意匠を SwiftUI で描画する。色は Config の COLOR_* に追従し、
/// ライト／ダーク自動切替・任意サイズでの劣化なしを両立する
struct AppIconBadge: View {
    let size: CGFloat

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        ZStack {
            // 上半分: 未払色（金茶）
            Rectangle()
                .fill(COLOR_UNPAID)
                .frame(width: size, height: size / 2)
                .offset(y: -size / 4)
            // 下半分: 済み色（グレージュ）
            Rectangle()
                .fill(COLOR_PAID)
                .frame(width: size, height: size / 2)
                .offset(y: size / 4)
            // 中央のクリーム発光ライン
            Rectangle()
                .fill(COLOR_BRAND_CREAM)
                .frame(width: size, height: max(0.5, size * 0.04))
                .shadow(color: COLOR_BRAND_CREAM.opacity(0.6), radius: size * 0.06)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .frame(width: size, height: size)
        .fixedSize()
    }
}
