//
//  アプリ診断送信サービス
//  起動時チェックや自動修復の匿名イベント送信をまとめる
//

import Foundation
import SwiftData

#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

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
