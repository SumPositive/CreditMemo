import SwiftUI

/// 引き落とし状況導線で使う共通バッジ
/// アプリアイコンのコイン円（金茶／グレージュ 3 段グラデ＋上端ツヤ＋内側影＋
/// クリーム発光ライン＋↓↑ 矢印）を SwiftUI で再現する
/// 色は Config の COLOR_* に追従し、ライト／ダーク自動切替・任意サイズで劣化なし
struct AppIconBadge: View {
    let size: CGFloat

    init(size: CGFloat = 24) {
        self.size = size
    }

    var body: some View {
        ZStack {
            // 上半円: 金茶 3 段グラデ（上が明るく境界へ向けて深い）
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

            // 下半円: グレージュ 3 段グラデ（境界が深く下が明るい）
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

            // ↓↑ 矢印（アプリアイコンと同じ）
            AppIconBadgeArrows()
                .stroke(
                    COLOR_BRAND_CREAM,
                    style: StrokeStyle(
                        lineWidth: max(0.8, size * 0.090),
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
}

/// 上半円=下矢印、下半円=上矢印
/// アプリアイコン (1024 canvas, 円 r=420, 中心 512) のコインバウンディングボックス
/// (x=92..932, y=92..932, 840x840) を rect に正規化する
private struct AppIconBadgeArrows: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        func tx(_ x: CGFloat) -> CGFloat { (x - 92) / 840 * w }
        func ty(_ y: CGFloat) -> CGFloat { (y - 92) / 840 * h }

        // 下矢印（上半円）
        p.move(to: CGPoint(x: tx(512), y: ty(160)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(310)))
        p.move(to: CGPoint(x: tx(400), y: ty(246)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(350)))
        p.addLine(to: CGPoint(x: tx(624), y: ty(246)))

        // 上矢印（下半円）
        p.move(to: CGPoint(x: tx(512), y: ty(864)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(714)))
        p.move(to: CGPoint(x: tx(400), y: ty(778)))
        p.addLine(to: CGPoint(x: tx(512), y: ty(674)))
        p.addLine(to: CGPoint(x: tx(624), y: ty(778)))

        return p
    }
}
