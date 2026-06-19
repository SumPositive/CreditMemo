import UIKit

/// BadgePreset の選択値と iOS ホーム画面アイコンを同期するヘルパー
/// - japaneseEarth はプライマリ AppIcon を使う（alternateIconName = nil）
/// - その他は Assets に登録した Alternate Icon を使う
/// - iOS は変更時にシステムアラート（"…のアイコンが変更されました"）を表示する
enum AppIconSync {

    /// preset に対応する Alternate Icon 名（プライマリの場合は nil）
    /// プライマリ AppIcon は japaneseEarth に紐づける
    /// Alternate Icon はすべて AppIcon-プリセット名で統一する
    static func iconName(for preset: BadgePreset) -> String? {
        // japaneseEarth は Assets のプライマリアイコンを使う
        guard preset != .japaneseEarth else { return nil }
        return "AppIcon-\(preset.rawValue)"
    }

    /// 現在のアイコンを希望のプリセットに同期する
    /// 既に同じ場合は何もしない
    @MainActor
    static func sync(to preset: BadgePreset) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let desired = iconName(for: preset)

        guard app.alternateIconName != desired else { return }
        app.setAlternateIconName(desired) { error in
            if let error {
                appLog(.error, "AppIcon 切替失敗: \(error.localizedDescription)")
            }
        }
    }
}
