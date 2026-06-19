//
//  アプリ診断送信サービス
//  起動時チェックや自動修復の匿名イベント送信をまとめる
//

import Foundation
import SwiftData

//#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
//#endif
//#if canImport(FirebaseCore)
import FirebaseCore
//#endif
//#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
//#endif

/// 音声入力セッションの匿名要約
struct VoiceInputSessionTelemetry {
    let source: String
    let localeIdentifier: String
    let durationMilliseconds: Int
    let contextualHintCount: Int
    let cardCount: Int
    let retryCount: Int
    let transcriptUpdateCount: Int
    let finalTranscriptDetected: Bool
    let cardKeywordSpoken: Bool
    let saveCommandSpoken: Bool
    let amountDetected: Bool
    let labelDetected: Bool
    let cardDetected: Bool
    let manualCardSelection: Bool
    let dismissalReason: String
    let deniedReason: String?
    let unresolvedCardPhraseLength: Int
}

/// 音声入力保存の匿名要約
struct VoiceInputSaveTelemetry {
    let source: String
    let saveResult: String
    let hasCard: Bool
    let hasLabel: Bool
    let manualCardSelection: Bool
    let matchedExistingAlias: Bool
    let usedSaveCommand: Bool
}

enum AppTelemetry {
    static func configureIfAvailable() {
        #if canImport(FirebaseCore)
        guard FirebaseApp.app() == nil else { return }
        // Firebase 設定ファイルが無い開発環境では送信を無効化する
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        FirebaseApp.configure()
        #endif
    }

    static func reportBillingIntegrityRepair(_ result: RecordService.BillingIntegrityRepairResult) {
        let parameters = analyticsParameters(result)

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("billing_integrity_repair", parameters: parameters)
        #endif

        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log("billing_integrity_repair issue_count=\(result.before.issueCount) remaining=\(result.after.issueCount)")
        for (key, value) in parameters {
            crashlytics.setCustomValue(value, forKey: key)
        }
        // 自動修復の発生を非致命エラーとして集計し、クラッシュとは分けて確認できるようにする
        let error = NSError(
            domain: "CreditMemo.BillingIntegrity",
            code: result.isRepaired ? 1 : 2,
            userInfo: [
                NSLocalizedDescriptionKey: result.isRepaired
                ? "Startup billing integrity repair completed"
                : "Startup billing integrity repair left remaining issues"
            ]
        )
        crashlytics.record(error: error)
        #endif
    }

    static func reportSwiftDataError(
        _ error: Error,
        operation: String,
        entity: String? = nil,
        detail: String? = nil
    ) {
        let nsError = error as NSError
        var parameters: [String: Any] = [
            "operation": limited(operation),
            "error_domain": limited(nsError.domain),
            "error_code": nsError.code
        ]
        if let entity {
            parameters["entity"] = limited(entity)
        }
        if let detail {
            parameters["detail"] = limited(detail)
        }

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("swiftdata_error", parameters: parameters)
        #endif

        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log("swiftdata_error operation=\(operation) entity=\(entity ?? "-") domain=\(nsError.domain) code=\(nsError.code)")
        for (key, value) in parameters {
            crashlytics.setCustomValue(value, forKey: key)
        }
        // SwiftData の失敗を非致命エラーとして集計する
        crashlytics.record(error: nsError)
        #endif
    }

    static func reportRecoverableError(
        _ error: Error,
        operation: String,
        category: String,
        detail: String? = nil
    ) {
        let nsError = error as NSError
        var parameters: [String: Any] = [
            "category": limited(category),
            "operation": limited(operation),
            "error_domain": limited(nsError.domain),
            "error_code": nsError.code
        ]
        if let detail {
            parameters["detail"] = limited(detail)
        }

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("recoverable_error", parameters: parameters)
        #endif

        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log("recoverable_error category=\(category) operation=\(operation) domain=\(nsError.domain) code=\(nsError.code)")
        for (key, value) in parameters {
            crashlytics.setCustomValue(value, forKey: key)
        }
        // 復帰可能な失敗も傾向確認のため非致命エラーに残す
        crashlytics.record(error: nsError)
        #endif
    }

    static func reportVoiceInputSession(_ telemetry: VoiceInputSessionTelemetry) {
        let parameters = voiceInputSessionParameters(telemetry)

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("voice_input_session", parameters: parameters)
        #endif
    }

    static func reportVoiceInputSave(_ telemetry: VoiceInputSaveTelemetry) {
        let parameters = voiceInputSaveParameters(telemetry)

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("voice_input_save", parameters: parameters)
        #endif
    }

    static func reportVoiceInputHintCandidate(
        token: String,
        source: String,
        localeIdentifier: String
    ) {
        let normalized = normalizedHintToken(token)
        guard !normalized.isEmpty else { return }

        let parameters: [String: Any] = [
            "source": limited(source),
            "locale": limited(localeIdentifier),
            "token": limited(normalized, maxLength: 32),
            "token_length": normalized.count
        ]

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("voice_input_hint_candidate", parameters: parameters)
        #endif
    }

    /// 引き落とし状況の現在の配色設定を匿名属性として同期する
    static func syncBadgeDisplaySetting(
        preset: BadgePreset,
        middleHeight: Double
    ) {
        #if canImport(FirebaseAnalytics)
        Analytics.setUserProperty(preset.rawValue, forName: "badge_preset")
        Analytics.setUserProperty(String(Int(middleHeight)), forName: "badge_middle_height")
        #endif
    }

    /// 引き落とし状況の配色設定変更を匿名イベントとして記録する
    static func reportBadgeDisplaySettingChange(
        preset: BadgePreset,
        middleHeight: Double,
        changedField: String
    ) {
        syncBadgeDisplaySetting(preset: preset, middleHeight: middleHeight)

        let parameters: [String: Any] = [
            "preset": limited(preset.rawValue),
            "middle_height": Int(middleHeight),
            "changed_field": limited(changedField)
        ]

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent("badge_display_setting", parameters: parameters)
        #endif
    }

    private static func analyticsParameters(_ result: RecordService.BillingIntegrityRepairResult) -> [String: Any] {
        var parameters: [String: Any] = [
            "before_issue_count": result.before.issueCount,
            "after_issue_count": result.after.issueCount,
            "repaired": result.isRepaired
        ]
        appendReport(result.before, prefix: "before", to: &parameters)
        appendReport(result.after, prefix: "after", to: &parameters)
        return parameters
    }

    private static func appendReport(
        _ report: RecordService.BillingIntegrityReport,
        prefix: String,
        to parameters: inout [String: Any]
    ) {
        parameters["\(prefix)_orphan_part_count"] = report.orphanPartCount
        parameters["\(prefix)_empty_invoice_count"] = report.emptyInvoiceCount
        parameters["\(prefix)_duplicate_invoice_count"] = report.duplicateInvoiceCount
        parameters["\(prefix)_invoice_missing_payment_count"] = report.invoiceMissingPaymentCount
        parameters["\(prefix)_empty_payment_count"] = report.emptyPaymentCount
        parameters["\(prefix)_duplicate_payment_count"] = report.duplicatePaymentCount
        parameters["\(prefix)_payment_amount_mismatch_count"] = report.paymentAmountMismatchCount
        parameters["\(prefix)_payment_no_check_mismatch_count"] = report.paymentNoCheckMismatchCount
        parameters["\(prefix)_card_amount_mismatch_count"] = report.cardAmountMismatchCount
        parameters["\(prefix)_card_no_check_mismatch_count"] = report.cardNoCheckMismatchCount
        parameters["\(prefix)_invalid_pay_type_count"] = report.invalidPayTypeCount
    }

    private static func voiceInputSessionParameters(_ telemetry: VoiceInputSessionTelemetry) -> [String: Any] {
        var parameters: [String: Any] = [
            "source": limited(telemetry.source),
            "locale": limited(telemetry.localeIdentifier),
            "duration_ms": telemetry.durationMilliseconds,
            "contextual_hint_count": telemetry.contextualHintCount,
            "card_count": telemetry.cardCount,
            "retry_count": telemetry.retryCount,
            "transcript_update_count": telemetry.transcriptUpdateCount,
            "final_transcript_detected": telemetry.finalTranscriptDetected,
            "card_keyword_spoken": telemetry.cardKeywordSpoken,
            "save_command_spoken": telemetry.saveCommandSpoken,
            "amount_detected": telemetry.amountDetected,
            "label_detected": telemetry.labelDetected,
            "card_detected": telemetry.cardDetected,
            "manual_card_selection": telemetry.manualCardSelection,
            "dismissal_reason": limited(telemetry.dismissalReason),
            "unresolved_card_phrase_length": telemetry.unresolvedCardPhraseLength
        ]

        if let deniedReason = telemetry.deniedReason, !deniedReason.isEmpty {
            parameters["denied_reason"] = limited(deniedReason)
        }
        return parameters
    }

    private static func voiceInputSaveParameters(_ telemetry: VoiceInputSaveTelemetry) -> [String: Any] {
        [
            "source": limited(telemetry.source),
            "save_result": limited(telemetry.saveResult),
            "has_card": telemetry.hasCard,
            "has_label": telemetry.hasLabel,
            "manual_card_selection": telemetry.manualCardSelection,
            "matched_existing_alias": telemetry.matchedExistingAlias,
            "used_save_command": telemetry.usedSaveCommand
        ]
    }

    private static func normalizedHintToken(_ token: String) -> String {
        let trimmed = token
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count < 33 else { return "" }
        guard trimmed.components(separatedBy: " ").count < 4 else { return "" }
        return trimmed
    }

    private static func limited(_ value: String, maxLength: Int = 100) -> String {
        if value.count <= maxLength {
            return value
        }
        return String(value.prefix(maxLength))
    }
}

extension ModelContext {
    func fetchReporting<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        entity: String,
        operation: String = #function,
        detail: String? = nil
    ) -> [T] {
        do {
            return try fetch(descriptor)
        } catch {
            // 既存動作は維持しつつ、SwiftData の失敗を診断送信する
            AppTelemetry.reportSwiftDataError(error, operation: operation, entity: entity, detail: detail)
            return []
        }
    }

    func fetchCountReporting<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        entity: String,
        operation: String = #function,
        detail: String? = nil
    ) -> Int {
        do {
            return try fetchCount(descriptor)
        } catch {
            // 件数取得の失敗も fetch と同じ経路で診断送信する
            AppTelemetry.reportSwiftDataError(error, operation: operation, entity: entity, detail: detail)
            return 0
        }
    }

    @discardableResult
    func saveReporting(
        operation: String = #function,
        detail: String? = nil
    ) -> Bool {
        do {
            try save()
            return true
        } catch {
            // 保存失敗はユーザーデータに直結するため非致命エラーとして残す
            AppTelemetry.reportSwiftDataError(error, operation: operation, detail: detail)
            return false
        }
    }
}
