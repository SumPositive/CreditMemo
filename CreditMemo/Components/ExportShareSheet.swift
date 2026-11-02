import SwiftUI
import UIKit

/// エクスポートした JSON ファイルを共有シート（UIActivityViewController）で開くラッパー。
/// 設定画面・引き落とし状況画面など複数箇所から使う。
///
/// - onComplete: 共有が完了したか（保存/送信成功=true, キャンセル/失敗=false）を返す。
///   「エクスポート成功後にだけ削除する」といった後続処理の分岐に使う。
///   注意：この完了ハンドラと `.sheet` の onDismiss は呼ばれる順序が保証されない
///   （共有先やiOSにより前後する／稀に completion が呼ばれない）。
///   呼び出し側は両方が揃った時点で判定するなど、順序に依存しない実装にすること。
struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in
            // completed: ユーザーが実際に保存/送信を完了したか（キャンセルは false）
            onComplete?(completed)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// エクスポート用のユーティリティ。ファイル名の組み立てを1か所にまとめる。
enum ExportFile {
    /// エクスポートJSONのファイル名。「(アプリ表示名)_yyyyMMdd_HHmmss.json」。
    /// アプリ表示名は現在の言語の CFBundleDisplayName（ja=クレメモ / en=Deferin）を使う。
    static func jsonName(date: Date = Date()) -> String {
        let fmt = DateFormatter()
        // 書き出しファイル名も和暦設定に左右されず西暦にする
        fmt.calendar = AppCalendar.gregorian
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return "\(appDisplayName)_\(fmt.string(from: date)).json"
    }

    /// 共有用の一時JSONを置く専用フォルダ。決済情報を含むので、共有後はフォルダごと消す
    private static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
    }

    /// 共有用の一時JSONを書き出す。前回の削除漏れ（強制終了など）もここで消してから書く
    static func writeTemporaryJSON(_ data: Data) throws -> URL {
        removeTemporaryFiles()
        let directory = temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(jsonName())
        // 端末ロック中は読めないようにする
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// 共有用の一時JSONをすべて削除する。共有シートを閉じたとき（キャンセル含む）に呼ぶ
    static func removeTemporaryFiles() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporaryDirectory)
        // 旧版は一時フォルダ直下に書いていたので、残っている JSON も消す
        let legacyFiles = (try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in legacyFiles where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    /// 現在の言語のアプリ表示名。取得できない場合は英語名にフォールバックする。
    private static var appDisplayName: String {
        let info = Bundle.main
        let localized = info.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        let base = info.infoDictionary?["CFBundleDisplayName"] as? String
        return localized ?? base ?? "Deferin"
    }
}
