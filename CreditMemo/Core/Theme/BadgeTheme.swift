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
    case ocean         // T7 海
    case forest        // T8 森
    case mono          // T9 モノクロ
    case pastel        // T10 パステル
    case berry         // T11 ベリー
    case lagoon        // T12 ラグーン

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
        case .ocean:         "settings.badgePreset.ocean"
        case .forest:        "settings.badgePreset.forest"
        case .mono:          "settings.badgePreset.mono"
        case .pastel:        "settings.badgePreset.pastel"
        case .berry:         "settings.badgePreset.berry"
        case .lagoon:        "settings.badgePreset.lagoon"
        }
    }

    /// プリセットタイル用（全 12 件）
    static var presetCases: [BadgePreset] { allCases }

    /// Asset Catalog に登録された缶バッジ画像名（Image(badge.assetImageName) で参照）
    var assetImageName: String { "AppIconBadge-\(rawValue)" }

    /// この preset の派生 BadgeTheme を取得
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
        case .ocean:
            // 海と夕日。中央はゴールドの反射
            return BadgeTheme(
                topColor:    dyn(light: 0x4A8FBC, dark: 0x6CABD5),
                middleColor: dyn(light: 0xFFC97A, dark: 0xFFD89A),
                bottomColor: dyn(light: 0x1F4D6E, dark: 0x4A78A0),
                unpaidText:  dyn(light: 0x2A6F95, dark: 0x6CABD5),
                paidText:    dyn(light: 0x143850, dark: 0x6E96B8)
            )
        case .forest:
            // 森。葉/樹幹/苔（中央は濃いブラウン）
            return BadgeTheme(
                topColor:    dyn(light: 0x5A8A3D, dark: 0x7CAA5E),
                middleColor: dyn(light: 0x8B5A2B, dark: 0xA67A4A),
                bottomColor: dyn(light: 0x3D4A2C, dark: 0x6E7E5C),
                unpaidText:  dyn(light: 0x3F6B26, dark: 0x7CAA5E),
                paidText:    dyn(light: 0x2A361E, dark: 0x88987A)
            )
        case .mono:
            // 灰階。中央を中銀にして明度差を確保
            return BadgeTheme(
                topColor:    dyn(light: 0x5A5A5A, dark: 0xB8B8B8),
                middleColor: dyn(light: 0x9C9C9C, dark: 0x5C5C5C),
                bottomColor: dyn(light: 0x1F1F1F, dark: 0x6E6E6E),
                unpaidText:  dyn(light: 0x3A3A3A, dark: 0xD0D0D0),
                paidText:    dyn(light: 0x0F0F0F, dark: 0x9C9C9C)
            )
        case .pastel:
            // 淡 3 色。中央をミントパステルに
            return BadgeTheme(
                topColor:    dyn(light: 0xFFC1CC, dark: 0xFFD0D8),
                middleColor: dyn(light: 0xA8E6CF, dark: 0xBEEED9),
                bottomColor: dyn(light: 0xC2DEFF, dark: 0xA8CFFA),
                unpaidText:  dyn(light: 0xC97889, dark: 0xFFD0D8),
                paidText:    dyn(light: 0x6E9AC9, dark: 0xA8CFFA)
            )
        case .berry:
            // 果実。中央はビビッドベリー
            return BadgeTheme(
                topColor:    dyn(light: 0xA04088, dark: 0xC062A8),
                middleColor: dyn(light: 0xE03A6E, dark: 0xF06080),
                bottomColor: dyn(light: 0x5A1E5C, dark: 0x8C4A8E),
                unpaidText:  dyn(light: 0x7A2C68, dark: 0xC062A8),
                paidText:    dyn(light: 0x3D1240, dark: 0xA068A4)
            )
        case .lagoon:
            // トロピカル。中央はコーラル（ターコイズの補色）
            return BadgeTheme(
                topColor:    dyn(light: 0x5DBFA8, dark: 0x7FD4BD),
                middleColor: dyn(light: 0xFF8C5A, dark: 0xFFA67C),
                bottomColor: dyn(light: 0x1E6F70, dark: 0x4A9899),
                unpaidText:  dyn(light: 0x3D8A78, dark: 0x7FD4BD),
                paidText:    dyn(light: 0x144C4D, dark: 0x6CB0B1)
            )
        }
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
    static let defaultValue: BadgeTheme = BadgePreset.japaneseEarth.theme
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
    static let min: Double = 4
    static let max: Double = 24
    static let `default`: Double = 16
}

