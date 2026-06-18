import SwiftUI
import UIKit

/// AppIconBadge / 引き落とし状況画面で使うトリコロール配色プリセット
enum BadgePreset: String, CaseIterable, Identifiable {
    case french        // T1 クラシック・フレンチ
    case monoBlue      // T2 モノクロマティック・ブルー
    case sunset        // T3 サンセット
    case japaneseEarth // T4 ジャパニーズ・アース
    case chic          // T5 シック・モダン
    case candy         // T6 キャンディ
    case custom        // ユーザー編集色

    var id: String { rawValue }

    /// 設定表示で使うローカライズキー
    var localizedKey: String {
        switch self {
        case .french:        "settings.badgePreset.french"
        case .monoBlue:      "settings.badgePreset.monoBlue"
        case .sunset:        "settings.badgePreset.sunset"
        case .japaneseEarth: "settings.badgePreset.japaneseEarth"
        case .chic:          "settings.badgePreset.chic"
        case .candy:         "settings.badgePreset.candy"
        case .custom:        "settings.badgePreset.custom"
        }
    }

    /// プリセットタイル用（.custom を除く 6 つ）
    static var presetCases: [BadgePreset] {
        allCases.filter { $0 != .custom }
    }

    /// この preset の派生 BadgeTheme を取得。.custom は monoBlue を返すので使用側で個別処理
    var theme: BadgeTheme { BadgeTheme.from(preset: self) }
}

/// 引き落とし状況導線で参照される色のセット
/// 上半（未払）／中央（境界）／下半（済み）の 3 色から、用途別の派生色を提供する
struct BadgeTheme: Equatable {
    /// バッジ上半・帯背景: 未払（アイコン背景レベル）
    let topColor: Color
    /// バッジ中央・境界線
    let middleColor: Color
    /// バッジ下半・帯背景: 済み（アイコン背景レベル）
    let bottomColor: Color

    /// 未払テキスト・stroke 用（やや濃い派生）
    let unpaidText: Color
    /// 済みテキスト・stroke 用（やや濃い派生）
    let paidText: Color

    static func from(preset: BadgePreset) -> BadgeTheme {
        switch preset {
        case .french:
            // 国旗準拠。ダーク bg では navy / red を明るく
            return BadgeTheme(
                topColor:    dyn(light: 0x0055A4, dark: 0x4A8BD9),
                middleColor: dyn(light: 0xFFFFFF, dark: 0xF0F0F0),
                bottomColor: dyn(light: 0xEF4135, dark: 0xF26B5E),
                unpaidText:  dyn(light: 0x003E78, dark: 0x7BA8DA),
                paidText:    dyn(light: 0xC42B22, dark: 0xF26B5E)
            )
        case .monoBlue:
            // 同系統。ダーク時は底をしっかり持ち上げて見えるように
            return BadgeTheme(
                topColor:    dyn(light: 0x5BB0FF, dark: 0x7BBEFF),
                middleColor: dyn(light: 0x0A84FF, dark: 0x4FA0FF),
                bottomColor: dyn(light: 0x003D80, dark: 0x4A86C2),
                unpaidText:  dyn(light: 0x0066CC, dark: 0x7BBEFF),
                paidText:    dyn(light: 0x002C5C, dark: 0x6FA0CC)
            )
        case .sunset:
            // 暖色グラデ。ダークは全体明るめに
            return BadgeTheme(
                topColor:    dyn(light: 0xFFD662, dark: 0xFFE070),
                middleColor: dyn(light: 0xFF8C42, dark: 0xFFA266),
                bottomColor: dyn(light: 0xA03969, dark: 0xD87196),
                unpaidText:  dyn(light: 0xC78E1E, dark: 0xFFE070),
                paidText:    dyn(light: 0x802C53, dark: 0xD87196)
            )
        case .japaneseEarth:
            // 和の三色。ダーク時は底（藍鉄）をぐっと明るく
            return BadgeTheme(
                topColor:    dyn(light: 0xA8412B, dark: 0xD86B52),
                middleColor: dyn(light: 0xE8D5B7, dark: 0xC9B898),
                bottomColor: dyn(light: 0x3D4F5C, dark: 0x7090A8),
                unpaidText:  dyn(light: 0x802E1E, dark: 0xD86B52),
                paidText:    dyn(light: 0x2A3742, dark: 0x88A5BD)
            )
        case .chic:
            // ダーク bg では上のチャコールが背景と同化するので、明度差を確保したアンスラサイト〜銀へ反転
            return BadgeTheme(
                topColor:    dyn(light: 0x1A1A1A, dark: 0xC5C5C0),
                middleColor: dyn(light: 0xF5F5F0, dark: 0x3E3E3A),
                bottomColor: dyn(light: 0xD4A848, dark: 0xE5BD68),
                unpaidText:  dyn(light: 0x0A0A0A, dark: 0xE5E5E0),
                paidText:    dyn(light: 0xA88332, dark: 0xE5BD68)
            )
        case .candy:
            // パステル三色。ダークでも明るさ十分
            return BadgeTheme(
                topColor:    dyn(light: 0xFF6B9D, dark: 0xFF89B5),
                middleColor: dyn(light: 0xFFE066, dark: 0xFFE57F),
                bottomColor: dyn(light: 0x5BC4E8, dark: 0x7BD0EE),
                unpaidText:  dyn(light: 0xCC4877, dark: 0xFF89B5),
                paidText:    dyn(light: 0x2D8FB8, dark: 0x7BD0EE)
            )
        case .custom:
            // .custom は ContentView 側で makeCustom を呼び出すこと。
            // フォールバックとして monoBlue を返す
            return Self.from(preset: .monoBlue)
        }
    }

    // MARK: - Custom theme construction

    /// 3 色とその作成モードから動的 BadgeTheme を組み立てる。
    /// 逆モードの色は明度自動調整される
    static func makeCustom(
        topHex: String,
        middleHex: String,
        bottomHex: String,
        authoredIn: ColorScheme
    ) -> BadgeTheme {
        let topAuthored    = UIColor(hexString: topHex)    ?? .systemBlue
        let middleAuthored = UIColor(hexString: middleHex) ?? .gray
        let bottomAuthored = UIColor(hexString: bottomHex) ?? .systemRed

        let topL    = authoredIn == .light ? topAuthored    : topAuthored.adjustedForOppositeMode()
        let topD    = authoredIn == .dark  ? topAuthored    : topAuthored.adjustedForOppositeMode()
        let midL    = authoredIn == .light ? middleAuthored : middleAuthored.adjustedForOppositeMode()
        let midD    = authoredIn == .dark  ? middleAuthored : middleAuthored.adjustedForOppositeMode()
        let botL    = authoredIn == .light ? bottomAuthored : bottomAuthored.adjustedForOppositeMode()
        let botD    = authoredIn == .dark  ? bottomAuthored : bottomAuthored.adjustedForOppositeMode()

        return BadgeTheme(
            topColor:    dynamicColor(light: topL, dark: topD),
            middleColor: dynamicColor(light: midL, dark: midD),
            bottomColor: dynamicColor(light: botL, dark: botD),
            unpaidText:  dynamicColor(light: topL.textContrasted(for: .light), dark: topD.textContrasted(for: .dark)),
            paidText:    dynamicColor(light: botL.textContrasted(for: .light), dark: botD.textContrasted(for: .dark))
        )
    }

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// 16進カラーをライト/ダーク両対応の動的 Color に
    private static func dyn(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red:   CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8)  & 0xFF) / 255,
                blue:  CGFloat(value & 0xFF)         / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Environment

private struct BadgeThemeKey: EnvironmentKey {
    static let defaultValue: BadgeTheme = BadgePreset.monoBlue.theme
}

extension EnvironmentValues {
    var badgeTheme: BadgeTheme {
        get { self[BadgeThemeKey.self] }
        set { self[BadgeThemeKey.self] = newValue }
    }
}

// MARK: - 設定値

/// 中央バンドの高さ範囲（base size = 64 の場合）
enum BadgeMiddleHeight {
    static let min: Double = 8
    static let max: Double = 24
    static let `default`: Double = 16
}

// MARK: - UIColor / Color hex 変換ヘルパー（カスタム配色専用）

extension UIColor {
    /// "RRGGBB" or "#RRGGBB" の hex 文字列から UIColor を作る
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value & 0xFF)         / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }

    /// 現在の RGB を 6 桁 hex 文字列 ("RRGGBB", 大文字) に変換
    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "000000" }
        let R = Int(round(max(0, min(1, r)) * 255))
        let G = Int(round(max(0, min(1, g)) * 255))
        let B = Int(round(max(0, min(1, b)) * 255))
        return String(format: "%02X%02X%02X", R, G, B)
    }

    /// 作成モードと逆モード向けに明度を自動調整した色を返す
    func adjustedForOppositeMode() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let target: CGFloat
        if b < 0.5 {
            target = min(1.0, b + (1.0 - b) * 0.45)
        } else {
            target = max(0.0, b * 0.65)
        }
        return UIColor(hue: h, saturation: s, brightness: target, alpha: a)
    }

    /// 指定モードの背景に対してテキストとして読みやすい色にする
    func textContrasted(for scheme: ColorScheme) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let target: CGFloat
        if scheme == .light {
            target = min(b, 0.42)
        } else {
            target = max(b, 0.72)
        }
        return UIColor(hue: h, saturation: s, brightness: target, alpha: a)
    }
}

extension Color {
    /// "RRGGBB" hex から Color を作る
    init(hexString: String) {
        if let ui = UIColor(hexString: hexString) {
            self.init(uiColor: ui)
        } else {
            self.init(uiColor: .systemBlue)
        }
    }
}
