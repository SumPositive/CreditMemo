import Foundation
import Testing
@testable import CreditMemo

/// 設定の移行ロジック（旧キー → 新キー）。
///
/// LaunchAction.resolve(defaults:) は UserDefaults を引数で受け取れるので、
/// UserDefaults.standard を汚さないようテスト専用スイートを使う
/// （＝並列実行でも他テストと干渉しないため直列化は不要）。
struct SettingsMigrationTests {
    /// テストごとに独立した UserDefaults を作る
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let name = "test.launchAction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    // MARK: - 新キーが保存済みのとき

    @Test("新キーが保存済みなら、そのまま採用する", arguments: [
        LaunchAction.none, .mainMenu, .voiceNewPayment, .newPayment, .paymentList,
    ])
    func adoptsStoredNewKey(action: LaunchAction) {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set(action.rawValue, forKey: AppStorageKey.launchAction)
        #expect(LaunchAction.resolve(defaults: defaults) == action)
    }

    /// 新キーが優先され、旧キーは無視される
    @Test("新キーが保存済みなら、旧キーONでも新キーを優先する")
    func newKeyTakesPrecedenceOverLegacyKey() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set(LaunchAction.paymentList.rawValue, forKey: AppStorageKey.launchAction)
        defaults.set(true, forKey: AppStorageKey.openAddOnActive)
        #expect(LaunchAction.resolve(defaults: defaults) == .paymentList)
    }

    @Test("新キーが不正な文字列なら、旧キーの解決へフォールバックする")
    func fallsBackWhenStoredValueIsUnknown() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set("nonexistentAction", forKey: AppStorageKey.launchAction)
        // 旧キー OFF → .none
        #expect(LaunchAction.resolve(defaults: defaults) == .none)

        // 旧キー ON → 旧挙動の .newPayment
        defaults.set(true, forKey: AppStorageKey.openAddOnActive)
        #expect(LaunchAction.resolve(defaults: defaults) == .newPayment)
    }

    // MARK: - 旧設定からの移行

    /// 旧 openAddOnActive が ON だったユーザーは、新キー未設定でも旧挙動を維持する
    @Test("新キー未設定＋旧キーONなら newPayment へ移行する")
    func migratesLegacyOpenAddOnActive() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set(true, forKey: AppStorageKey.openAddOnActive)
        #expect(LaunchAction.resolve(defaults: defaults) == .newPayment)
    }

    @Test("新キー未設定＋旧キーOFFなら none（既定）")
    func resolvesToNoneWhenLegacyDisabled() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set(false, forKey: AppStorageKey.openAddOnActive)
        #expect(LaunchAction.resolve(defaults: defaults) == .none)
    }

    @Test("どちらのキーも未設定なら none（既定）")
    func resolvesToNoneWhenNothingStored() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        #expect(LaunchAction.resolve(defaults: defaults) == .none)
    }

    /// 移行は「新キー未設定のときだけ」効く。
    /// 利用者が明示的に none を選んだ後は、旧キーONでも none のまま戻らない
    @Test("利用者が none を選んだ後は、旧キーONでも none のまま")
    func doesNotResurrectLegacyAfterUserChoseNone() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set(true, forKey: AppStorageKey.openAddOnActive)
        defaults.set(LaunchAction.none.rawValue, forKey: AppStorageKey.launchAction)
        #expect(LaunchAction.resolve(defaults: defaults) == .none)
    }

    // MARK: - rawValue の互換

    /// 保存値は rawValue なので、綴りが変わると既存ユーザーの設定が失われる
    @Test("rawValue は保存互換のため固定")
    func rawValuesAreStable() {
        #expect(LaunchAction.none.rawValue == "none")
        #expect(LaunchAction.mainMenu.rawValue == "mainMenu")
        #expect(LaunchAction.voiceNewPayment.rawValue == "voiceNewPayment")
        #expect(LaunchAction.newPayment.rawValue == "newPayment")
        #expect(LaunchAction.paymentList.rawValue == "paymentList")
    }

    @Test("全ケースが rawValue から復元できる")
    func allCasesRoundTripThroughRawValue() {
        for action in LaunchAction.allCases {
            #expect(LaunchAction(rawValue: action.rawValue) == action)
        }
    }
}
