import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
/// トリコロール構成（上/中/下）。色は `Environment(\.badgeTheme)` から、
/// 中央バンドの高さは `AppStorageKey.badgeMiddleHeight` から読み込んでライブ反映する
struct AppIconBadge: View {
    let size: CGFloat
    /// 他の丸アイコンと見た目の密度を揃えるため少しだけ拡大する
    private let visualScale: CGFloat = 1.14

    @Environment(\.badgeTheme) private var theme
    @AppStorage(AppStorageKey.badgeMiddleHeight) private var middleHeight: Double = BadgeMiddleHeight.default

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        let drawSize = size * visualScale
        VStack(spacing: 0) {
            Rectangle().fill(theme.topColor)
                .frame(width: drawSize, height: bandHeight(in: drawSize))
            Rectangle().fill(theme.middleColor)
                .frame(width: drawSize, height: middleBandHeight(in: drawSize))
            Rectangle().fill(theme.bottomColor)
                .frame(width: drawSize, height: bandHeight(in: drawSize))
        }
        .frame(width: drawSize, height: drawSize)
        .clipShape(Circle())
        .frame(width: size, height: size)
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// base 64 で middleHeight をスライダー値（8..24）として、描画サイズに比率で換算する
    private func middleBandHeight(in drawSize: CGFloat) -> CGFloat {
        let clamped = max(BadgeMiddleHeight.min, min(BadgeMiddleHeight.max, middleHeight))
        return CGFloat(clamped) / 64 * drawSize
    }

    private func bandHeight(in drawSize: CGFloat) -> CGFloat {
        (drawSize - middleBandHeight(in: drawSize)) / 2
    }
}

#Preview("各プリセット") {
    VStack(spacing: 16) {
        ForEach(BadgePreset.allCases) { preset in
            HStack {
                AppIconBadge(size: 56)
                    .environment(\.badgeTheme, preset.theme)
                Text(preset.rawValue).font(.subheadline)
            }
        }
    }
    .padding()
}
