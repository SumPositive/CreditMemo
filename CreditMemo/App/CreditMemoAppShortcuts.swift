//
//  Siri ショートカット
//  自由入力の発話から新しい決済を保存する
//

import AppIntents
import Foundation
import SwiftData

// Siri 実行時にそのまま返す簡易エラー
private enum AddRecordBySiriIntentError: LocalizedError {
    case emptyInput
    case emptyLabel
    case invalidAmount
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "内容を入れてください"
        case .emptyLabel:
            return "ラベルを入れてください"
        case .invalidAmount:
            return "1円以上を指定してください"
        case .saveFailed:
            return "保存できませんでした"
        }
    }
}

struct AddRecordBySiriIntent: AppIntent {
    static let title: LocalizedStringResource = "Siriで決済を記録"
    static let description = IntentDescription("自由入力の発話から金額とラベルを解析して保存する")
    static let openAppWhenRun = false

    @Parameter(title: "内容")
    var inputText: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$inputText) を保存")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 自由入力の空白だけ先に整理する
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            throw AddRecordBySiriIntentError.emptyInput
        }

        do {
            let container = try AppModelContainerFactory.makeContainer()
            let context = ModelContext(container)
            let amountAndLabel = VoiceInputParser.parseAmountAndLabel(trimmedInput, locale: .current)
            guard let amount = amountAndLabel.amount else {
                throw AddRecordBySiriIntentError.invalidAmount
            }
            if amount < 1 {
                throw AddRecordBySiriIntentError.invalidAmount
            }

            // 手段名や終端の動詞を除いてラベルを安定化する
            let trimmedLabel = Self.cleanedLabel(
                amountAndLabel.label
            )
            if trimmedLabel.isEmpty {
                throw AddRecordBySiriIntentError.emptyLabel
            }

            _ = try RecordService.addQuickRecord(
                amount: amount,
                label: trimmedLabel,
                context: context
            )
            return .result(
                dialog: IntentDialog("\(Self.displayAmount(amount)) 円 \(trimmedLabel) を保存しました")
            )
        } catch {
            if let intentError = error as? AddRecordBySiriIntentError {
                throw intentError
            }

            // Siri 保存失敗も通常の診断送信へ流す
            AppTelemetry.reportSwiftDataError(
                error,
                operation: "siri_add_record_save",
                entity: "E3record"
            )
            throw AddRecordBySiriIntentError.saveFailed
        }
    }

    // ラベル末尾に残った命令語だけ軽く除く
    private static func cleanedLabel(_ rawLabel: String?) -> String {
        var label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let trailingCommands = ["保存", "追加", "記録", "save", "add", "record"]
        for command in trailingCommands {
            if label.hasSuffix(command) {
                label.removeLast(command.count)
                break
            }
        }

        return label
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "、。,.・"))
    }

    // 音声結果に合わせて金額表示を簡潔に整える
    private static func displayAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? NSDecimalNumber(decimal: amount).stringValue
    }
}

struct CreditMemoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // App Shortcut は 1 フレーズ 1 パラメータに揃える
        AppShortcut(
            intent: AddRecordBySiriIntent(),
            phrases: [
                // 日本語フレーズ
                "\(.applicationName)で \(\.$inputText) を記録",
                "\(.applicationName)で \(\.$inputText) を追加",
                "\(.applicationName) \(\.$inputText) 保存",
                "\(.applicationName) \(\.$inputText) 追加",
                "\(.applicationName) \(\.$inputText) 記録",
                // 英語フレーズ
                "In \(.applicationName), record \(\.$inputText)",
                "In \(.applicationName), add \(\.$inputText)",
                "With \(.applicationName), save \(\.$inputText)",
            ],
            shortTitle: "Siriで記録",
            systemImageName: "plus.circle.fill"
        )
    }
}
