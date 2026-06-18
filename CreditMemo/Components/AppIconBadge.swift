import SwiftUI

/// 引き落とし状況導線で使う共通バッジ（缶バッジ風）
/// トリコロール構成（上/中/下）。色は `Environment(\.badgeTheme)` から、
/// 中央バンドの高さは `AppStorageKey.badgeMiddleHeight` から読み込んでライブ反映する
/// 4 層のラジアルグラデ（ドーム明暗 + 上の反射 + 下の影 + 外周の縁）で立体感を出す
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
        ZStack {
            // 3 色の帯
            VStack(spacing: 0) {
                Rectangle().fill(theme.topColor)
                    .frame(width: drawSize, height: bandHeight(in: drawSize))
                Rectangle().fill(theme.middleColor)
                    .frame(width: drawSize, height: middleBandHeight(in: drawSize))
                Rectangle().fill(theme.bottomColor)
                    .frame(width: drawSize, height: bandHeight(in: drawSize))
            }

            // ドーム: 全体に上明→下暗
            RadialGradient(
                stops: [
                    .init(color: .white.opacity(0.30), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.55),
                    .init(color: .black.opacity(0.18), location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.335),
                startRadius: 0,
                endRadius: drawSize * 0.625
            )

            // 上の反射光
            RadialGradient(
                stops: [
                    .init(color: .white.opacity(0.70), location: 0),
                    .init(color: .white.opacity(0.20), location: 0.45),
                    .init(color: .white.opacity(0), location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.135),
                startRadius: 0,
                endRadius: drawSize * 0.375
            )

            // 下の影
            RadialGradient(
                stops: [
                    .init(color: .black.opacity(0.38), location: 0),
                    .init(color: .black.opacity(0.10), location: 0.6),
                    .init(color: .black.opacity(0), location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.885),
                startRadius: 0,
                endRadius: drawSize * 0.525
            )

            // 外周の縁
            RadialGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0.86),
                    .init(color: .black.opacity(0.30), location: 0.96),
                    .init(color: .black.opacity(0.55), location: 1)
                ],
                center: .center,
                startRadius: 0,
                endRadius: drawSize * 0.5
            )
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
