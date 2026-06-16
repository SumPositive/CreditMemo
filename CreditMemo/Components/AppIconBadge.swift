import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
/// アプリアイコンのコイン円（金茶／グレージュ 3 段グラデ＋上端ツヤ＋内側影＋
/// クリーム発光ライン＋彫り込み風 ↓↑ 矢印）を SwiftUI で再現する
/// 色は Config の COLOR_* に追従し、ライト／ダーク自動切替・任意サイズで劣化なし
struct AppIconBadge: View {
    let size: CGFloat

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        ZStack {
            // 上半円: 金茶 3 段グラデ
            LinearGradient(
                stops: [
                    .init(color: Self.topLight, location: 0),
                    .init(color: COLOR_UNPAID, location: 0.45),
                    .init(color: Self.topDeep, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: size, height: size / 2)
            .offset(y: -size / 4)

            // 下半円: グレージュ 3 段グラデ
            LinearGradient(
                stops: [
                    .init(color: Self.bottomDeep, location: 0),
                    .init(color: COLOR_PAID, location: 0.45),
                    .init(color: Self.bottomLight, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: size, height: size / 2)
            .offset(y: size / 4)

            // 上端コインツヤ
            RadialGradient(
                colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.05),
                startRadius: 0,
                endRadius: size * 0.45
            )
            .frame(width: size, height: size)

            // 内側影で縁を締める
            RadialGradient(
                stops: [
                    .init(color: Color.black.opacity(0), location: 0.86),
                    .init(color: Color.black.opacity(0.30), location: 1.0)
                ],
                center: .center,
                startRadius: 0,
                endRadius: size / 2
            )
            .frame(width: size, height: size)

            // 中央クリーム発光ライン
            Rectangle()
                .fill(COLOR_BRAND_CREAM)
                .frame(width: size, height: max(0.5, size * 0.04))
                .shadow(color: COLOR_BRAND_CREAM.opacity(0.6), radius: size * 0.06)

            // ↓↑ 矢印 彫り込み（intaglio）: 左上から光、右下に細いクリーム反射
            // 1) 下にクリーム反射（溝の底に届く光）
            AppIconBadgeArrows()
                .stroke(
                    Self.engraveHighlight,
                    style: StrokeStyle(
                        lineWidth: max(0.7, size * 0.071),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size, height: size)
                .offset(x: size * 0.0071, y: size * 0.0107)
            // 2) 本来位置にダーク影（溝の中の陰影）
            AppIconBadgeArrows()
                .stroke(
                    Self.engraveShadow,
                    style: StrokeStyle(
                        lineWidth: max(0.7, size * 0.071),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .frame(width: size, height: size)
        .fixedSize()
    }

    // MARK: - 半円グラデ用の色

    /// 金茶（明）: #D4A848 / dark 少し明るめ
    private static let topLight: Color = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.910, green: 0.749, blue: 0.412, alpha: 1)
            : UIColor(red: 0.831, green: 0.659, blue: 0.282, alpha: 1)
    })

    /// 金茶（深）: #8B6308 / dark やや持ち上げ
    private static let topDeep: Color = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.659, green: 0.486, blue: 0.118, alpha: 1)
            : UIColor(red: 0.545, green: 0.388, blue: 0.031, alpha: 1)
    })

    /// グレージュ（深）: #6E635A / dark やや持ち上げ
    private static let bottomDeep: Color = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.541, green: 0.490, blue: 0.439, alpha: 1)
            : UIColor(red: 0.431, green: 0.388, blue: 0.353, alpha: 1)
    })

    /// グレージュ（明）: #A89A8E / dark やや明るく
    private static let bottomLight: Color = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.745, green: 0.690, blue: 0.635, alpha: 1)
            : UIColor(red: 0.659, green: 0.604, blue: 0.557, alpha: 1)
    })

    // MARK: - 彫り込み用の色

    /// 矢印彫り込みのハイライト: #FFF5DC を 92% 不透明
    private static let engraveHighlight: Color =
        Color(red: 1.0, green: 0.961, blue: 0.863).opacity(0.92)

    /// 矢印彫り込みの影: #0F0903 を 80% 不透明
    private static let engraveShadow: Color =
        Color(red: 0.059, green: 0.035, blue: 0.012).opacity(0.80)
}

/// 上半円=下矢印、下半円=上矢印（アプリアイコンの最新位置）
/// アプリアイコン (1024 canvas, 円 r=420) のコインバウンディングボックス
/// (x=92..932, y=92..932, 840x840) を rect に正規化する
private struct AppIconBadgeArrows: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        func tx(_ x: CGFloat) -> CGFloat { (x - 92) / 840 * w }
        func ty(_ y: CGFloat) -> CGFloat { (y - 92) / 840 * h }

        // 下矢印（上半円）
        p.move(to: CGPoint(x: tx(512), y: ty(238)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(358)))
        p.move(to: CGPoint(x: tx(422), y: ty(307)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(390)))
        p.addLine(to: CGPoint(x: tx(602), y: ty(307)))

        // 上矢印（下半円）
        p.move(to: CGPoint(x: tx(512), y: ty(786)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(666)))
        p.move(to: CGPoint(x: tx(422), y: ty(717)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(634)))
        p.addLine(to: CGPoint(x: tx(602), y: ty(717)))

        return p
    }
}
