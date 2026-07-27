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

    /// アプリは iPhone / iPad 両対応（TARGETED_DEVICE_FAMILY = 1,2）なので、
    /// 代替アイコンは CFBundleIcons と CFBundleIcons~ipad の両方に登録が要る。
    /// 片方だけ更新されると、その端末でだけアイコン切り替えが失敗する
    private static let iconDictionaryKeys = ["CFBundleIcons", "CFBundleIcons~ipad"]

    /// 代替アイコン名が Info.plist に登録されていないと、実行時に切り替えが失敗する
    @Test("全プリセットの代替アイコンが Info.plist に登録されている", arguments: iconDictionaryKeys)
    func everyAlternateIconIsRegisteredInInfoPlist(dictionaryKey: String) throws {
        let registered = try alternateIconNames(in: dictionaryKey)
        let required = Set(BadgePreset.allCases.compactMap { AppIconSync.iconName(for: $0) })

        let missing = required.subtracting(registered).sorted()
        #expect(missing.isEmpty, "\(dictionaryKey) に未登録の代替アイコン: \(missing.joined(separator: ", "))")
    }

    /// 逆に、使われない登録が残っていないかも見る（プリセット削除時の掃除漏れ）
    @Test("Info.plist に未使用の代替アイコン登録が残っていない", arguments: iconDictionaryKeys)
    func noUnusedAlternateIconRegistrations(dictionaryKey: String) throws {
        let registered = try alternateIconNames(in: dictionaryKey)
        let required = Set(BadgePreset.allCases.compactMap { AppIconSync.iconName(for: $0) })

        let unused = registered.subtracting(required).sorted()
        #expect(unused.isEmpty, "\(dictionaryKey) の使われていない代替アイコン登録: \(unused.joined(separator: ", "))")
    }

    /// 各エントリの CFBundleIconName がキー名と一致していないと、実行時に解決できない
    @Test("代替アイコンの CFBundleIconName がキー名と一致する", arguments: iconDictionaryKeys)
    func alternateIconNamesMatchTheirKeys(dictionaryKey: String) throws {
        let icons = try alternateIconsDictionary(in: dictionaryKey)
        var mismatched: [String] = []
        for (key, value) in icons {
            if iconName(of: value) != key {
                mismatched.append("\(key) -> \(iconName(of: value) ?? "nil")")
            }
        }
        #expect(mismatched.isEmpty, "\(dictionaryKey) でキー名と不一致: \(mismatched.sorted().joined(separator: ", "))")
    }

    /// iPhone 用と iPad 用で登録内容がずれていないことを直接突き合わせる。
    /// 片方にだけプリセットを足す／消す変更を検出する
    @Test("iPhone 用と iPad 用の代替アイコン登録が一致する")
    func iPhoneAndIPadRegistrationsMatch() throws {
        let phone = try alternateIconsDictionary(in: "CFBundleIcons")
        let pad = try alternateIconsDictionary(in: "CFBundleIcons~ipad")

        // どちらも空でないこと（辞書ごと消えた場合に気付けるように）
        #expect(!phone.isEmpty)
        #expect(!pad.isEmpty)

        let onlyPhone = Set(phone.keys).subtracting(pad.keys).sorted()
        let onlyPad = Set(pad.keys).subtracting(phone.keys).sorted()
        #expect(onlyPhone.isEmpty, "iPad 側に無い代替アイコン: \(onlyPhone.joined(separator: ", "))")
        #expect(onlyPad.isEmpty, "iPhone 側に無い代替アイコン: \(onlyPad.joined(separator: ", "))")

        // 同じキーなら CFBundleIconName も揃っている
        var mismatched: [String] = []
        for key in Set(phone.keys).intersection(pad.keys) {
            let phoneName = phone[key].flatMap { iconName(of: $0) }
            let padName = pad[key].flatMap { iconName(of: $0) }
            if phoneName != padName {
                mismatched.append("\(key): iPhone=\(phoneName ?? "nil") / iPad=\(padName ?? "nil")")
            }
        }
        #expect(mismatched.isEmpty, "CFBundleIconName が不一致: \(mismatched.sorted().joined(separator: ", "))")
    }

    /// プライマリアイコンも両方に登録されている必要がある
    @Test("プライマリアイコンが iPhone/iPad 両方に登録されている", arguments: iconDictionaryKeys)
    func primaryIconIsRegistered(dictionaryKey: String) throws {
        let icons = try iconsDictionary(in: dictionaryKey)
        let primary = try #require(
            icons["CFBundlePrimaryIcon"],
            "\(dictionaryKey) に CFBundlePrimaryIcon がありません"
        )
        #expect(iconName(of: primary) == "AppIcon", "\(dictionaryKey) のプライマリアイコンが AppIcon ではありません")
    }

    // MARK: - Helpers

    /// CFBundleIconName（無ければ CFBundleIconFiles の先頭）を取り出す
    private func iconName(of value: Any) -> String? {
        let entry = value as? [String: Any]
        return (entry?["CFBundleIconName"] as? String)
            ?? (entry?["CFBundleIconFiles"] as? [String])?.first
    }

    /// リポジトリ相対で Info.plist を読む（LocalizationIntegrityTests と同じ方式）
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CreditMemoTests/
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("CreditMemo/Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        return plist ?? [:]
    }

    private func iconsDictionary(in dictionaryKey: String) throws -> [String: Any] {
        (try infoPlist()[dictionaryKey] as? [String: Any]) ?? [:]
    }

    private func alternateIconsDictionary(in dictionaryKey: String) throws -> [String: Any] {
        (try iconsDictionary(in: dictionaryKey)["CFBundleAlternateIcons"] as? [String: Any]) ?? [:]
    }

    private func alternateIconNames(in dictionaryKey: String) throws -> Set<String> {
        Set(try alternateIconsDictionary(in: dictionaryKey).keys)
    }
}
