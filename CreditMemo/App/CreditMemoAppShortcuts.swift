//
//  Siri ショートカット
//  Siri 起動時に音声入力シートを開く
//

import AppIntents
import Foundation

struct OpenVoiceInputIntent: AppIntent {
    static let title: LocalizedStringResource = "音声で新しい決済"
    static let description = IntentDescription("クレメモを開いて音声入力シートを自動で表示する")
    /// Siri から実行された時に本体アプリを前面に出す（必須）
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // openAppWhenRun で本体起動後に perform が走る
        // AppStorage 用キーを直接立てて TopMenuView の onAppear / onChange で
        // 音声入力シートを開かせる
        //
        // 注意: ProvidesDialog を返すと Siri 画面が残ってマイクが取れない
        // ダイアログ無し（IntentResult のみ）で Siri を即終了させ、本体側へ制御を譲る
        UserDefaults.standard.set(true, forKey: AppStorageKey.openVoiceInputOnActive)
        return .result()
    }
}

struct CreditMemoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 固定フレーズで起動して、入力はアプリ内の音声シートへ寄せる
        // 「に記録」「に保存」「で入力」など Apple メモや他アプリと衝突しやすい一般的フレーズは避け、
        // 「決済」「クレジット」「明細」「音声入力」などクレメモ固有語を含める
        AppShortcut(
            intent: OpenVoiceInputIntent(),
            phrases: [
                "\(.applicationName)で決済",
                "\(.applicationName)で音声入力",
                "\(.applicationName)で新しい決済",
                "Open voice input in \(.applicationName)",
                "Add a new payment in \(.applicationName)",
                "Record a payment with \(.applicationName)",
            ],
            shortTitle: "音声で新しい決済",
            systemImageName: "microphone.badge.plus.fill"
        )
    }
}
