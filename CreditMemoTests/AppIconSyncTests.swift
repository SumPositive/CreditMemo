import Foundation
import Testing
@testable import CreditMemo

/// アプリアイコン切り替えの命名規約と、Info.plist への登録漏れ検出。
///
/// AppIconSync.sync は UIApplication を触るのでテストしないが、
/// 「どの名前を要求するか」を決める iconName(for:) は純粋関数なので検証できる。
/// 名前が Info.plist の CFBundleAlternateIcons に無いと
/// setAlternateIconName は実行時に失敗するだけで、ビルドは通ってしまう。
/// プリセット追加時の登録漏れをここで捕まえる。
struct AppIconSyncTests {
    // MARK: - 命名規約

    /// japaneseEarth だけはプライマリ AppIcon（nil）を使う
    @Test("japaneseEarth はプライマリアイコン（nil）を返す")
    func primaryPresetReturnsNil() {
        #expect(AppIconSync.iconName(for: .japaneseEarth) == nil)
    }

    @Test("その他のプリセットは AppIcon-<rawValue> を返す")
    func alternatePresetsUsePrefixedName() {
        for preset in BadgePreset.allCases where preset != .japaneseEarth {
            #expect(AppIconSync.iconName(for: preset) == "AppIcon-\(preset.rawValue)")
        }
    }

    @Test("プライマリを使うプリセットはちょうど1つ")
    func exactlyOnePresetUsesPrimaryIcon() {
        let primaries = BadgePreset.allCases.filter { AppIconSync.iconName(for: $0) == nil }
        #expect(primaries == [.japaneseEarth])
    }

    @Test("生成されるアイコン名は重複しない")
    func iconNamesAreUnique() {
        let names = BadgePreset.allCases.compactMap { AppIconSync.iconName(for: $0) }
        #expect(Set(names).count == names.count)
    }

    // MARK: - Info.plist との整合

    /// 代替アイコン名が Info.plist に登録されていないと、実行時に切り替えが失敗する
    @Test("全プリセットの代替アイコンが Info.plist に登録されている")
    func everyAlternateIconIsRegisteredInInfoPlist() throws {
        let registered = try alternateIconNamesFromInfoPlist()
        let required = Set(BadgePreset.allCases.compactMap { AppIconSync.iconName(for: $0) })

        let missing = required.subtracting(registered).sorted()
        #expect(missing.isEmpty, "Info.plist に未登録の代替アイコン: \(missing.joined(separator: ", "))")
    }

    /// 逆に、使われない登録が残っていないかも見る（プリセット削除時の掃除漏れ）
    @Test("Info.plist に未使用の代替アイコン登録が残っていない")
    func noUnusedAlternateIconRegistrations() throws {
        let registered = try alternateIconNamesFromInfoPlist()
        let required = Set(BadgePreset.allCases.compactMap { AppIconSync.iconName(for: $0) })

        let unused = registered.subtracting(required).sorted()
        #expect(unused.isEmpty, "使われていない代替アイコン登録: \(unused.joined(separator: ", "))")
    }

    /// 各エントリの CFBundleIconName がキー名と一致していないと、実行時に解決できない
    @Test("代替アイコンの CFBundleIconName がキー名と一致する")
    func alternateIconNamesMatchTheirKeys() throws {
        let icons = try alternateIconsDictionary()
        var mismatched: [String] = []
        for (key, value) in icons {
            let entry = value as? [String: Any]
            let iconName = (entry?["CFBundleIconName"] as? String)
                ?? (entry?["CFBundleIconFiles"] as? [String])?.first
            if iconName != key {
                mismatched.append("\(key) -> \(iconName ?? "nil")")
            }
        }
        #expect(mismatched.isEmpty, "キー名と不一致: \(mismatched.sorted().joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// リポジトリ相対で Info.plist を読む（LocalizationIntegrityTests と同じ方式）
    private func alternateIconsDictionary() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CreditMemoTests/
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("CreditMemo/Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let icons = plist?["CFBundleIcons"] as? [String: Any]
        return (icons?["CFBundleAlternateIcons"] as? [String: Any]) ?? [:]
    }

    private func alternateIconNamesFromInfoPlist() throws -> Set<String> {
        Set(try alternateIconsDictionary().keys)
    }
}
