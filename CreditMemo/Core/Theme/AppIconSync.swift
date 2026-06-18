import UIKit

/// BadgePreset の選択値と iOS ホーム画面アイコンを同期するヘルパー
/// - monoBlue / custom はプライマリ AppIcon を使う（alternateIconName = nil）
/// - その他は Info.plist の CFBundleAlternateIcons に登録された Alternate Icon を使う
/// - iOS は変更時にシステムアラート（"…のアイコンが変更されました"）を表示する
enum AppIconSync {

    /// preset に対応する Alternate Icon 名（プライマリの場合は nil）
    /// プライマリ AppIcon は japaneseEarth に紐づく。他は loose PNG として alternate に登録
    static func iconName(for preset: BadgePreset) -> String? {
        switch preset {
        case .japaneseEarth: return nil       // プライマリ（Asset Catalog の AppIcon）
        case .monoBlue:      return "monoBlue"
        case .french:        return "french"
        case .sunset:        return "sunset"
        case .chic:          return "chic"
        case .candy:         return "candy"
        case .ocean:         return "ocean"
        case .forest:        return "forest"
        case .mono:          return "mono"
        case .pastel:        return "pastel"
        case .berry:         return "berry"
        case .lagoon:        return "lagoon"
        }
    }

    /// 現在のアイコンを希望のプリセットに同期する
    /// 既に同じ場合は何もしない
    /// PNG がバンドルに無い場合はプライマリにフォールバック（グレーアイコン状態から復帰）
    @MainActor
    static func sync(to preset: BadgePreset) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        var desired = iconName(for: preset)

        // 希望の alternate PNG がバンドルに無ければプライマリに落とす
        // 実ファイル名は "AppIcon-{name}@2x.png" / "AppIcon-{name}@3x.png"
        if let name = desired, Bundle.main.url(forResource: "AppIcon-\(name)@2x", withExtension: "png") == nil {
            appLog(.warning, "AppIcon-\(name)@2x.png がバンドルに見つからないのでプライマリにフォールバック")
            desired = nil
        }

        guard app.alternateIconName != desired else { return }
        app.setAlternateIconName(desired) { error in
            if let error {
                appLog(.error, "AppIcon 切替失敗: \(error.localizedDescription)")
            }
        }
    }
}
