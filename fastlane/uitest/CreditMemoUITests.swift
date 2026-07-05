//
//  CreditMemoUITests.swift
//  CreditMemoUITests
//
//  fastlane snapshot 用の UI テスト。
//  ※ 現状はまず「起動直後のメイン画面 1 カット」だけ撮る検証用の骨組み。
//    撮影カット（設定画面・カード一覧・明細など）は実機UIを見ながら
//    accessibilityIdentifier を付与しつつ順次追加する。
//
//  言語切替の方針（DialSplit と同じ）:
//   - 言語は SnapshotHelper が language.txt の値で -AppleLanguages に設定済み。
//     ここでは上書きしない（"zh-Hant" のような .lproj 名をそのまま使うため）。
//   - ProcessInfo.environment["FASTLANE_LANGUAGE"] は UITest ランナーには
//     継承されず空になるので使わない。グローバル変数 deviceLanguage を読む。
//
//  通貨の方針:
//   - snapshot の -AppleLocale は Locale.current に確実には効かないため、
//     言語 → 代表地域ロケールへマップし -SNAPSHOT_CURRENCY_LOCALE で明示渡し。
//     アプリ側 Decimal.effectiveCurrencyLocale（DEBUG限定）が最優先で読む。
//   - サンプルデータは SnapshotHelper が付ける -FASTLANE_SNAPSHOT YES を
//     アプリが検知し、in-memory ストアに投入する（AppMain / SnapshotSeed）。
//

import XCTest

final class CreditMemoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 表示言語 → 通貨を出したい代表地域ロケール
    private func currencyLocale(for language: String) -> String {
        // language は "ja", "en-US", "zh-Hant" のような snapshot のフォルダ名
        let lang = language.lowercased()
        if lang.hasPrefix("ja")      { return "ja_JP" }   // ¥
        if lang.hasPrefix("en")      { return "en_US" }   // $
        if lang.hasPrefix("de")      { return "de_DE" }   // €
        if lang.hasPrefix("ko")      { return "ko_KR" }   // ₩
        if lang.hasPrefix("zh-hant") { return "zh_TW"  }  // NT$
        if lang.hasPrefix("zh")      { return "zh_CN"  }
        return ""
    }

    @MainActor
    func testTakeScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)

        // 撮影中の言語。SnapshotHelper が language.txt から読んで
        // グローバル変数 deviceLanguage に入れている（setupSnapshot 後に有効）。
        let language = deviceLanguage
        if !language.isEmpty {
            let currency = currencyLocale(for: language)
            if !currency.isEmpty {
                app.launchArguments += ["-SNAPSHOT_CURRENCY_LOCALE", currency]
            }
        }

        app.launch()

        // メイン画面が描画されるまで待つ
        sleep(2)

        // 1 カット目: メイン画面
        snapshot("01MainScreen")

        // 2 カット目: 新しい決済（入力フォーム）
        // iPad(NavigationSplitView)では詳細ペインに、iPhoneでは push で表示される。
        // 撮影時は金額テンキーの自動表示を抑止済み（RecordEditView 側の SnapshotSeed ガード）。
        openMenu(app, "menu.addRecord")
        snapshot("02NewPayment")

        // 3 カット目: 引き落とし状況（PaymentList）
        openMenu(app, "menu.paymentList")
        snapshot("03PaymentStatus")

        // 4 カット目: 決済手段一覧（CardList）
        openMenu(app, "menu.cardList")
        snapshot("04PayMethods")
    }

    /// サイドバー/メニューの行を識別子でタップして目的の画面を開く。
    /// - iPad(NavigationSplitView): サイドバーが常時見えているのでそのままタップできる。
    /// - iPhone(NavigationStack): 前のカットで push した画面が乗っているので、
    ///   メニュー行が見えるまでナビゲーションバーの戻るを押してから タップする。
    /// NavigationLink 行は環境により button / cell / other のいずれかに現れるため横断で探す。
    @MainActor
    private func openMenu(_ app: XCUIApplication, _ identifier: String) {
        // まず対象行が見えるところまで戻る（iPhone の push 対策。iPad は最初から見えている）
        for _ in 0..<4 {
            if element(app, identifier).waitForExistence(timeout: 2) { break }
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap(); sleep(1) } else { break }
        }
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 10) {
            target.tap()
            sleep(2)
        }
    }

    /// 識別子に一致する最初の要素（button / cell / other を横断）
    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let candidates = [
            app.buttons[identifier],
            app.cells[identifier],
            app.otherElements[identifier]
        ]
        return candidates.first(where: { $0.exists }) ?? app.buttons[identifier]
    }
}
