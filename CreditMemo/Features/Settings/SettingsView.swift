//
//  設定画面
//  表示、決済・支払、共有、サポートの設定をまとめる
//

import SwiftUI
import SwiftData
import StoreKit
import Observation
import UniformTypeIdentifiers
import SafariServices
import UIKit

#if canImport(GoogleMobileAds)
@preconcurrency import GoogleMobileAds
#endif

struct SettingsView: View {
    @AppStorage(AppStorageKey.userLevel)         private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.appearanceMode)    private var appearanceMode: AppearanceMode = .automatic
    @AppStorage(AppStorageKey.fontScale)         private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.afterSaveAction)   private var afterSaveAction: AfterSaveAction = .goBack
    @AppStorage(AppStorageKey.launchAction)      private var launchActionRaw = LaunchAction.none.rawValue
    @AppStorage(AppStorageKey.autoOpenAmountPad) private var autoOpenAmountPad = true
    @AppStorage(AppStorageKey.enableTwoPayments) private var enableTwoPayments = false
    @AppStorage(AppStorageKey.enableVoiceInput)  private var enableVoiceInput = true
    @AppStorage(AppStorageKey.shareVoiceInputDiagnostics) private var shareVoiceInputDiagnostics = false
    @AppStorage(AppStorageKey.shiftDueDateOffHoliday) private var shiftDueDateOffHoliday = true
    @AppStorage(AppStorageKey.paymentWindowDays) private var paymentWindowDays = 15
    @AppStorage(AppStorageKey.exportFormat)        private var exportFormatRaw = JSONExport.OutputStyle.compact.rawValue
    @AppStorage(AppStorageKey.showCurrencySymbol)  private var showCurrencySymbol = true

    @Environment(\.modelContext) private var context
    @State private var showShareSheet  = false
    @State private var showImportPicker = false
    @State private var showBadgeColorSheet = false
    @State private var exportedURL: URL?
    @State private var showDocsSheet = false
    @State private var showTipSheet = false
    @State private var showAdSheet = false
    @State private var showAdThanks = false
    // 古い履歴の整理（3年）：タップで提案アラート→共通フロー（.retentionCleanup）
    @State private var showRetentionSuggest = false
    /// 整理対象が0件のとき「整理は不要です」を伝えるだけのアラート
    @State private var showRetentionNoTarget = false
    @State private var retentionOldCount = 0
    @State private var retentionCleanupTrigger = false
    @State private var expandedDropdown: SettingsDropdownKind?
    @State private var alertItem: SettingsAlertItem?
    @State private var isWorking = false
    @State private var progressMessage = ""
    @State private var progressHint = ""
    @State private var progressCompleted: Int?
    @State private var progressTotal: Int?

    private let paymentWindowOptions: [PaymentWindowOption] =
        (1...20).map { PaymentWindowOption(days: $0) } + [PaymentWindowOption(days: 30)]

    private var exportFormat: JSONExport.OutputStyle {
        JSONExport.OutputStyle(rawValue: exportFormatRaw) ?? .compact
    }

    private var exportFormatBinding: Binding<JSONExport.OutputStyle> {
        Binding(
            get: { exportFormat },
            set: { exportFormatRaw = $0.rawValue }
        )
    }

    private var launchActionBinding: Binding<LaunchAction> {
        Binding(
            get: { LaunchAction(rawValue: launchActionRaw) ?? .none },
            set: { launchActionRaw = $0.rawValue }
        )
    }

    /// 端末・ロケールで音声入力が使えない場合は「音声で新しい決済」を除外する
    private var launchActionOptions: [LaunchAction] {
        guard SpeechRecognizer.supports() else {
            return LaunchAction.allCases.filter { $0 != .voiceNewPayment }
        }
        return LaunchAction.allCases
    }

    private var dropdownDynamicTypeSize: DynamicTypeSize? {
        fontScale.followsSystem ? nil : fontScale.dynamicTypeSize
    }

    private var versionBuildText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty || build.isEmpty {
            return version.isEmpty ? build : version
        }
        return "\(version).\(build)"
    }

    @ViewBuilder
    private func settingTitle(_ key: LocalizedStringKey, help helpKey: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.subheadline)
            if let helpKey {
                // 設定項目のヘルプは項目名の末尾に置く。
                // 達人モードでも (?) は使えるが控えめサイズで描画される
                BeginnerHintView(detailMessageKey: helpKey)
            }
        }
    }

    var body: some View {
        List {
            Section("settings.panel.display") {
                AZAdaptiveRadioRow(
                    options: UserLevel.allCases,
                    selection: $userLevel,
                    minOptionWidth: 82
                ) {
                    settingTitle("settings.userLevel", help: "settings.help.userLevel")
                } label: { level in
                    Text(LocalizedStringKey(level.localizedKey))
                }

                AZAdaptiveRadioRow(
                    options: AppearanceMode.allCases,
                    selection: $appearanceMode,
                    minOptionWidth: 82
                ) {
                    Text("settings.appearance")
                        .font(.subheadline)
                } label: { mode in
                    Text(LocalizedStringKey(mode.localizedKey))
                }

                AZAdaptiveRadioRow(
                    options: FontScale.allCases,
                    selection: $fontScale,
                    minOptionWidth: 72,
                    horizontalPadding: 8
                ) {
                    settingTitle("settings.fontScale", help: "settings.help.fontScale")
                } label: { scale in
                    Text(LocalizedStringKey(scale.localizedKey))
                }

                Toggle(showCurrencySymbolLabel, isOn: $showCurrencySymbol)

                Button {
                    showBadgeColorSheet = true
                } label: {
                    HStack {
                        Text("settings.badgeColor")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        AppIconBadge(size: 22)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    // 設定行の見えている範囲をそのままタップ領域にする
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("settings.panel.payment") {
                // 音声入力はロケールが SFSpeechRecognizer の対応外なら設定 UI 自体を出さない
                if SpeechRecognizer.supports() {
                    Toggle(isOn: $enableVoiceInput) {
                        settingTitle("settings.enableVoiceInput", help: "settings.help.enableVoiceInput")
                    }

                    Toggle(isOn: $shareVoiceInputDiagnostics) {
                        settingTitle("settings.shareVoiceInputDiagnostics", help: "settings.help.shareVoiceInputDiagnostics")
                    }
                    // 音声入力を使わない時は改善ヒント共有も操作できないようにする
                    .disabled(!enableVoiceInput)
                }

                VStack(alignment: .leading, spacing: 8) {
                    AZAdaptiveControlRow {
                        settingTitle("settings.launchAction", help: "settings.help.launchAction")
                            .fixedSize(horizontal: false, vertical: true)
                    } control: {
                        AZDropdownPicker(
                            options: launchActionOptions,
                            selection: launchActionBinding,
                            isExpanded: dropdownBinding(.launchAction),
                            minWidth: 210,
                            popoverDynamicTypeSize: dropdownDynamicTypeSize
                        ) { action in
                            Text(LocalizedStringKey(action.localizedKey))
                        }
                    }
                    .zIndex(expandedDropdown == .launchAction ? 60 : 0)
                }

                Toggle(isOn: $autoOpenAmountPad) {
                    settingTitle("settings.autoOpenAmountPad", help: "settings.help.autoOpenAmountPad")
                }

                Toggle(isOn: $enableTwoPayments) {
                    settingTitle("settings.enableInstallment", help: "settings.help.enableInstallment")
                }

                // 日本ロケール限定の挙動。他ロケールでは設定 UI 自体を出さない
                if Locale.current.language.languageCode?.identifier == "ja" {
                    Toggle(isOn: $shiftDueDateOffHoliday) {
                        settingTitle("settings.shiftDueDateOffHoliday", help: "settings.help.shiftDueDateOffHoliday")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    AZAdaptiveControlRow {
                        settingTitle("settings.afterSave", help: "settings.help.afterSave")
                            .fixedSize(horizontal: false, vertical: true)
                    } control: {
                        AZDropdownPicker(
                            options: AfterSaveAction.allCases,
                            selection: $afterSaveAction,
                            isExpanded: dropdownBinding(.afterSave),
                            minWidth: 210,
                            popoverDynamicTypeSize: dropdownDynamicTypeSize
                        ) { action in
                            Text(LocalizedStringKey(action.localizedKey))
                        }
                    }
                    .zIndex(expandedDropdown == .afterSave ? 60 : 0)
                }

                // 引き落とし合計期間のプルダウンは「引き落とし状況」画面の絞り込み条件の右側に移動した
            }

            Section("settings.panel.share") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            exportJSON(style: exportFormat)
                        } label: {
                            Label("settings.jsonExport.all", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isWorking)

                        // 共有操作のヘルプは実行ボタンの外に置き、本文色の伝播を避ける
                        BeginnerHintView(detailMessageKey: "settings.help.export")
                    }

                    if userLevel != .beginner {
                        AZAdaptiveRadioRow(
                            options: JSONExport.OutputStyle.allCases,
                            selection: exportFormatBinding,
                            minOptionWidth: 88
                        ) {
                            Text("settings.exportFormat.title")
                                .font(.subheadline)
                        } label: { style in
                            Text(LocalizedStringKey(style.localizedKey))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            showImportPicker = true
                        } label: {
                            Label(importButtonText, systemImage: "square.and.arrow.down")
                        }
                        .disabled(isWorking)

                        // 読み込み操作のヘルプは実行ボタンの外に置き、本文色の伝播を避ける
                        BeginnerHintView(detailMessageKey: "settings.help.import")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // 自動提案と同じ整理フローを、設定からも手動で呼べるようにする。
                        // 対象が0件なら「整理は不要」と伝えるだけにする。
                        Button {
                            let count = RecordService.recordsCount(
                                olderThanYears: RetentionSuggest.years, context: context
                            )
                            retentionOldCount = count
                            if count == 0 {
                                showRetentionNoTarget = true
                            } else {
                                showRetentionSuggest = true
                            }
                        } label: {
                            Label("retention.settings.button", systemImage: "trash")
                        }
                        .disabled(isWorking)

                        BeginnerHintView(detailMessageKey: "settings.help.retention")
                    }
                }
            }

            Section("settings.panel.support") {
                Button {
                    // About画面を挟まず、直接アプリ内シートで取扱説明を開く
                    showDocsSheet = true
                } label: {
                    Label("settings.about", systemImage: "info.circle")
                }
            }

            Section {
                Button("settings.cheer.tip") { showTipSheet = true }
                Button("settings.cheer.ad") { showAdSheet = true }
            } header: {
                Text("settings.panel.cheer")
            } footer: {
                settingsFooter
            }
        }
        .sheet(isPresented: $showBadgeColorSheet) {
            DisplayBadgeColorSheet()
                .appFontScale(fontScale)
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showTipSheet) {
            TipSheetView()
                // シートにもアプリ内文字サイズ設定を明示適用する
                .appFontScale(fontScale)
                // チップ案内シートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showAdSheet) {
            AdSupportSheet {
                showAdThanks = true
            }
            // シートにもアプリ内文字サイズ設定を明示適用する
            .appFontScale(fontScale)
            // 広告応援シートの背面を透かさない
            .presentationBackground(Color(uiColor: .systemBackground))
        }
        .scalableNavigationTitle("top.settings") {
            Image(systemName: "gearshape")
                .foregroundStyle(Color.gray)
        }
        .sheet(isPresented: $showDocsSheet) {
            SafariView(url: helpDocURL())
                .ignoresSafeArea()
                // ヘルプシートの背面を透かさない
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedURL {
                ExportShareSheet(url: url)
                    .ignoresSafeArea()
                    // 共有シートの背面を透かさない
                    .presentationBackground(Color(uiColor: .systemBackground))
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importJSON(from: url)
            case .failure(let error):
                alertItem = .raw(title: errorTitleText, message: error.localizedDescription)
            }
        }
        .alert(item: $alertItem) { item in
            let title: Text = {
                if let titleKey = item.titleKey {
                    return Text(LocalizedStringKey(titleKey))
                }
                return Text(item.rawTitle ?? errorTitleText)
            }()

            let message: Text = {
                if let messageKey = item.messageKey {
                    return Text(LocalizedStringKey(messageKey))
                }
                return Text(item.rawMessage ?? "")
            }()

            return Alert(
                title: title,
                message: message,
                dismissButton: .cancel(Text("button.ok"))
            )
        }
        .alert(String(localized: "support.thanksTitle"), isPresented: $showAdThanks) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(String(localized: "support.ad.thanksMessage"))
        }
        // 古い履歴の整理（3年）：対象が1件以上のとき「整理しませんか？」→エクスポート後に削除
        .alert("retention.suggest.title", isPresented: $showRetentionSuggest) {
            Button("retention.suggest.exportAndClean") {
                retentionCleanupTrigger = true
            }
            Button("retention.suggest.later", role: .cancel) {}
        } message: {
            Text(retentionSuggestMessage)
        }
        // 対象が0件のとき：整理は不要と伝えるだけ（エクスポート案内なし）
        .alert("retention.noTarget.title", isPresented: $showRetentionNoTarget) {
            Button("button.ok", role: .cancel) {}
        } message: {
            Text(retentionSuggestMessage)
        }
        .retentionCleanup(trigger: $retentionCleanupTrigger)
        .overlay {
            if isWorking {
                ZStack {
                    // 入出力処理中は背面操作を受け付けない
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        if let progressCompleted,
                           let progressTotal,
                           0 < progressTotal {
                            // 件数が分かる工程は到達位置をバーで示す
                            ProgressView(
                                value: Double(progressCompleted),
                                total: Double(progressTotal)
                            )
                            .frame(maxWidth: 240)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                        }
                        Text(progressMessage)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(progressHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsFooter: some View {
        VStack(spacing: 2) {
            Text(versionBuildText)
            Text("about.copyright")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private var paymentWindowBinding: Binding<PaymentWindowOption> {
        Binding(
            get: { PaymentWindowOption(days: paymentWindowDays) },
            set: { paymentWindowDays = $0.days }
        )
    }

    private func dropdownBinding(_ kind: SettingsDropdownKind) -> Binding<Bool> {
        Binding(
            get: { expandedDropdown == kind },
            set: { isExpanded in
                // 同時に開くプルダウンは1つだけにする
                if isExpanded {
                    expandedDropdown = kind
                } else if expandedDropdown == kind {
                    expandedDropdown = nil
                }
            }
        )
    }

    /// 設定画面のアラート表示モデル
    private struct SettingsAlertItem: Identifiable {
        let id: String
        let titleKey: String?
        let messageKey: String?
        let rawTitle: String?
        let rawMessage: String?

        /// ローカライズキーを使うアラート
        static func localized(id: String, titleKey: String, messageKey: String) -> SettingsAlertItem {
            SettingsAlertItem(
                id: id,
                titleKey: titleKey,
                messageKey: messageKey,
                rawTitle: nil,
                rawMessage: nil
            )
        }

        /// 任意文字列を使うアラート
        static func raw(title: String, message: String) -> SettingsAlertItem {
            SettingsAlertItem(
                id: "\(title):\(message)",
                titleKey: nil,
                messageKey: nil,
                rawTitle: title,
                rawMessage: message
            )
        }
    }

    private func exportJSON(style: JSONExport.OutputStyle) {
        Task { @MainActor in
            isWorking = true
            progressCompleted = nil
            progressTotal = nil
            progressMessage = exportPreparingText
            progressHint = exportHintText
            // オーバーレイ描画を先に反映する
            await Task.yield()
            defer { isWorking = false }

            do {
                let data = try await JSONExport.exportData(context: context, style: style) { phase in
                    // 工程の説明文を逐次切り替える
                    progressMessage = phase.message(locale: Locale.current)
                }
                let name = ExportFile.jsonName()
                let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                progressMessage = exportWritingText
                await Task.yield()
                try data.write(to: url)
                exportedURL    = url
                showShareSheet = true
            } catch {
                alertItem = .raw(title: errorTitleText, message: error.localizedDescription)
            }
        }
    }

    private func importJSON(from url: URL) {
        Task { @MainActor in
            isWorking = true
            progressCompleted = nil
            progressTotal = nil
            progressHint = importHintText
            progressMessage = importPreparingText
            await Task.yield()
            defer { isWorking = false }

            let startedAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if startedAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let result = try await JSONImport.importData(from: url, context: context) { progress in
                    // 工程の説明文を逐次切り替える
                    progressMessage = progress.message(locale: Locale.current)
                    progressCompleted = progress.completed
                    progressTotal = progress.total
                }
                alertItem = .raw(title: importDoneTitleText, message: importDoneMessage(result))
            } catch {
                alertItem = .raw(title: errorTitleText, message: error.localizedDescription)
            }
        }
    }

    /// エクスポート開始時の説明文
    private var exportPreparingText: String {
        if Locale.current.language.languageCode?.identifier == "ja" {
            return "エクスポート準備中…"
        }
        return "Preparing export..."
    }

    /// ファイル書き込み時の説明文
    private var exportWritingText: String {
        if Locale.current.language.languageCode?.identifier == "ja" {
            return "ファイルへ書き込み中…"
        }
        return "Writing file..."
    }

    /// エクスポート中の補足説明
    private var exportHintText: String {
        if Locale.current.language.languageCode?.identifier == "ja" {
            return "データ量により数秒かかることがあります"
        }
        return "This may take a few seconds depending on data volume."
    }

    /// インポートボタン文言
    private var importButtonText: String {
        String(localized: "settings.import.button")
    }

    /// インポート開始時の説明文
    private var importPreparingText: String {
        String(localized: "settings.import.preparing")
    }

    /// インポート中の補足説明
    private var importHintText: String {
        String(localized: "settings.import.hint")
    }

    /// 共通エラータイトル
    private var errorTitleText: String {
        String(localized: "common.error")
    }

    /// 古い履歴の整理 提案メッセージ（保持年数と対象件数を出す）。
    /// 設定からは件数0でも押せるため、0件のときは専用の案内にする。
    private var retentionSuggestMessage: String {
        if retentionOldCount == 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("retention.suggest.message.none", comment: ""),
                RetentionSuggest.years
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("retention.suggest.message", comment: ""),
            RetentionSuggest.years,
            retentionOldCount
        )
    }

    /// インポート完了タイトル
    private var importDoneTitleText: String {
        String(localized: "settings.import.done.title")
    }

    /// インポート完了メッセージ
    private func importDoneMessage(_ result: JSONImport.Result) -> String {
        // Xcodeの参照検出に乗るよう、完了メッセージ全体を1キーで管理する
        return String.localizedStringWithFormat(
            String(localized: "settings.import.done.message"),
            result.bankCount,
            result.cardCount,
            result.tagCount,
            result.recordCount,
            result.partStateCount,
            result.invoiceStateCount,
            result.paymentStateCount
        )
    }

}

private enum SettingsDropdownKind {
    case afterSave
    case paymentWindow
    case launchAction
}

private struct PaymentWindowOption: Hashable, Identifiable {
    let days: Int
    var id: Int { days }
}

// MARK: - 開発者応援（StoreKit / AdMob）

@Observable
@MainActor
private final class TipStore {
    static let shared = TipStore()

    // 投げ銭商品は少額と通常額の2段だけに絞る
    private let productIds = ["CreditMemo_Tips_1", "CreditMemo_Tips_5"] // 製品ID
    var products: [Product] = []
    var isLoadingProducts = false
    var isPurchasing = false

    private init() {}

    /// StoreKit から商品一覧を読み込む
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        let loaded: [Product]
        do {
            loaded = try await Product.products(for: productIds)
        } catch {
            // 商品一覧取得の失敗を診断送信する
            AppTelemetry.reportRecoverableError(error, operation: "PurchaseManager.loadProducts", category: "storekit")
            loaded = []
        }
        products = loaded.sorted { $0.price < $1.price }
    }

    /// 選択された商品を購入する
    func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result,
               case .verified(let transaction) = verification {
                await transaction.finish()
                return true
            }
        } catch {}
        return false
    }
}

private struct TipSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = TipStore.shared
    @State private var showThanks = false
    @State private var activeThrow: CoinThrow? = nil
    @State private var targetScale: CGFloat = 1.0

    private struct CoinThrow: Identifiable {
        let id = UUID()
        let buttonIndex: Int
        let color: Color
        let product: Product
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    sheetContent(geo: geo)
                    if let toss = activeThrow {
                        let startX = toss.buttonIndex == 0
                            ? geo.size.width * 0.33
                            : geo.size.width * 0.67
                        TossedCoin(
                            key: toss.id,
                            start: CGPoint(x: startX, y: geo.size.height - 130),
                            end: CGPoint(x: geo.size.width * 0.5, y: 90),
                            color: toss.color
                        ) {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.35)) {
                                targetScale = 1.22
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                withAnimation(.spring) { targetScale = 1.0 }
                            }
                            let product = toss.product
                            activeThrow = nil
                            Task {
                                if await store.purchase(product) {
                                    showThanks = true
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "support.tip.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .task { await store.loadProducts() }
            .alert(String(localized: "support.thanksTitle"), isPresented: $showThanks) {
                Button("common.ok") { dismiss() }
            } message: {
                Text(String(localized: "support.tip.thanksMessage"))
            }
        }
    }

    @ViewBuilder
    private func sheetContent(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            developerTarget
                .padding(.top, 32)

            TossArcHint()
                .frame(height: 52)
                .padding(.horizontal, 56)
                .padding(.top, 6)

            Text(String(localized: "support.tip.message"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.top, 16)

            Spacer()
            coinSection
                .padding(.bottom, 56)
        }
    }

    private var developerTarget: some View {
        ZStack {
            Circle()
                .fill(.teal.opacity(0.10))
                .frame(width: 108, height: 108)
            Circle()
                .stroke(.teal.opacity(0.22), lineWidth: 1.5)
                .frame(width: 108, height: 108)
            Image(systemName: "person.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .font(.system(size: 50))
                .foregroundStyle(.teal)
            Image(systemName: "heart.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .font(.system(size: 18))
                .foregroundStyle(.pink)
                .offset(x: 24, y: -24)
        }
        .scaleEffect(targetScale)
    }

    @ViewBuilder
    private var coinSection: some View {
        if store.isLoadingProducts {
            ProgressView()
        } else if store.products.isEmpty {
            Text(String(localized: "support.unavailable"))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 40) {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    let isLarge = index == store.products.count - 1
                    let coinColor: Color = isLarge
                        ? Color(red: 0.90, green: 0.72, blue: 0.18)
                        : Color(red: 0.72, green: 0.45, blue: 0.20)
                    CoinButtonView(
                        price: product.displayPrice,
                        color: coinColor,
                        disabled: activeThrow != nil || store.isPurchasing
                    ) {
                        activeThrow = CoinThrow(
                            buttonIndex: index,
                            color: coinColor,
                            product: product
                        )
                    }
                }
            }
        }
    }
}

// MARK: - コインボタン

private struct CoinButtonView: View {
    let price: String
    let color: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [color.opacity(0.18), color.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [color, color.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: 1)
                        .padding(10)
                    Text(price)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(color)
                }
                .frame(width: 100, height: 100)
                .shadow(color: color.opacity(0.35), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(CoinPressStyle())
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1.0)
    }
}

private struct CoinPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - 軌跡ヒント

private struct TossArcHint: View {
    var body: some View {
        Canvas { ctx, size in
            let width = size.width
            let height = size.height
            for (startRatio, controlRatio) in [(0.25, 0.82), (0.75, 0.18)] as [(Double, Double)] {
                var path = Path()
                path.move(to: CGPoint(x: width * startRatio, y: height))
                path.addQuadCurve(
                    to: CGPoint(x: width * 0.5, y: 0),
                    control: CGPoint(x: width * controlRatio, y: height * 0.12)
                )
                ctx.stroke(
                    path,
                    with: .color(.secondary.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 5])
                )
            }
        }
    }
}

// MARK: - 飛ぶコイン

private struct TossedCoin: View {
    let key: UUID
    let start: CGPoint
    let end: CGPoint
    let color: Color
    let onLanded: () -> Void

    private struct KeyframeValue {
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        var rotation: Double = 0
        var scale: CGFloat = 1
        var opacity: Double = 1
    }

    @State private var fire = false
    private let duration: Double = 1.8
    /// ゆらゆら揺れる横幅
    private let sway: CGFloat = 24

    private var deltaX: CGFloat { end.x - start.x }
    private var deltaY: CGFloat { end.y - start.y }

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.95), color.opacity(0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                ZStack {
                    Circle().stroke(.white.opacity(0.28), lineWidth: 1.5).padding(5)
                    Text(verbatim: "¥").font(.title3.bold()).foregroundStyle(.white)
                }
            )
            .shadow(color: color.opacity(0.55), radius: 10, x: 0, y: 4)
            .frame(width: 50, height: 50)
            .keyframeAnimator(initialValue: KeyframeValue(), trigger: fire) { content, value in
                content
                    .offset(x: value.offsetX, y: value.offsetY)
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
            } keyframes: { _ in
                // 横：直線経路に左右の揺れを乗せる
                KeyframeTrack(\.offsetX) {
                    LinearKeyframe(0,                    duration: 0.01)
                    CubicKeyframe(deltaX * 0.25 + sway,  duration: duration * 0.25)
                    CubicKeyframe(deltaX * 0.50 - sway,  duration: duration * 0.25)
                    CubicKeyframe(deltaX * 0.75 + sway,  duration: duration * 0.25)
                    CubicKeyframe(deltaX,                duration: duration * 0.25)
                }
                // 縦：弧を描かず直線的にアイコンへ向かう
                KeyframeTrack(\.offsetY) {
                    LinearKeyframe(0,      duration: 0.01)
                    LinearKeyframe(deltaY, duration: duration * 0.99)
                }
                // 回転なし
                KeyframeTrack(\.rotation) {
                    LinearKeyframe(0, duration: duration)
                }
                // スケール：アイコンに届いてから縮む
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1.0,  duration: duration * 0.35)
                    CubicKeyframe(1.12,  duration: duration * 0.30)
                    CubicKeyframe(1.0,   duration: duration * 0.25)
                    LinearKeyframe(0.2,  duration: duration * 0.10)
                }
                // 不透明度：アイコン内で消える
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: duration * 0.90)
                    LinearKeyframe(0.0, duration: duration * 0.10)
                }
            }
            .position(start)
            .allowsHitTesting(false)
            .onAppear {
                fire = true
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
                    onLanded()
                }
            }
            .id(key)
    }
}

private struct AdSupportSheet: View {
    let onRewardEarned: () -> Void

    var body: some View {
#if canImport(GoogleMobileAds)
        AdMobRewardedSheet(onRewardEarned: onRewardEarned)
#else
        NavigationStack {
            VStack(spacing: 16) {
                Text(String(localized: "admob.notLinked"))
                    .font(.headline)
                Text(String(localized: "admob.packageMessage"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
#endif
    }
}

#if canImport(GoogleMobileAds)

#if DEBUG
private let ADMOB_BANNER_UNIT_ID = "ca-app-pub-3940256099942544/2435281174"
private let ADMOB_REWARD_UNIT_ID = "ca-app-pub-3940256099942544/1712485313"
#else
private let ADMOB_BANNER_UNIT_ID = "ca-app-pub-7576639777972199/8682776152"
private let ADMOB_REWARD_UNIT_ID = "ca-app-pub-7576639777972199/2664162715"
#endif

private struct AdMobRewardedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = RewardedAdLoader(adUnitID: ADMOB_REWARD_UNIT_ID)
    let onRewardEarned: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                AdMobBannerView(
                    adUnitID: ADMOB_BANNER_UNIT_ID,
                    size: CGSize(width: 300, height: 250)
                )

                Text(String(localized: "support.ad.videoTitle"))
                    .font(.headline)

                Text(String(localized: "support.ad.closeHint"))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if loader.isLoading {
                    ProgressView(String(localized: "support.ad.loading"))
                } else {
                    Button(String(localized: "support.ad.play")) {
                        if let root = UIApplication.topMostViewController() {
                            loader.present(from: root)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!loader.isReady)

                    Label {
                        Text(String(localized: "support.ad.soundWarning"))
                            .font(.footnote.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .foregroundStyle(.red)
                }

                if loader.errorMessage != nil {
                    Button(String(localized: "common.reload")) {
                        loader.loadAd()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding()
            .navigationTitle(String(localized: "support.ad.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .onAppear {
                loader.onRewardEarned = { _ in
                    onRewardEarned()
                }
            }
        }
    }
}

/// Non-personalized ads（NPA）を強制した広告リクエストを生成する。
/// IDFA を使わず、ユーザー属性に依存しない一般広告のみ配信される。
/// これにより ATT（AppTrackingTransparency）プロンプトを表示せずに済む。
private func makeNonPersonalizedAdRequest() -> Request {
    let request = Request()
    let extras = Extras()
    extras.additionalParameters = ["npa": "1"]
    request.register(extras)
    return request
}

private struct AdMobBannerView: View {
    let adUnitID: String
    let size: CGSize

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 8) {
            AdMobBannerRepresentable(
                adUnitID: adUnitID,
                size: size,
                onReceiveAd: {
                    isLoading = false
                    errorMessage = nil
                },
                onFailToReceiveAd: { _ in
                    isLoading = false
                    errorMessage = String(localized: "support.ad.noRewardedAd")
                },
                reloadToken: reloadToken
            )
            .id(reloadToken)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .tertiarySystemBackground))
            )
            .overlay {
                // 読み込み中はバナー領域に重ねて表示し、レイアウト高さを変えない
                if isLoading {
                    ProgressView(String(localized: "support.ad.loading"))
                        .font(.caption)
                }
            }

            if !isLoading, errorMessage != nil {
                Button(String(localized: "common.reload")) {
                    reloadToken = UUID()
                    isLoading = true
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct AdMobBannerRepresentable: UIViewControllerRepresentable {
    let adUnitID: String
    let size: CGSize
    let onReceiveAd: () -> Void
    let onFailToReceiveAd: (Error) -> Void
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(onReceiveAd: onReceiveAd, onFailToReceiveAd: onFailToReceiveAd)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear

        let bannerView = BannerView(adSize: adSizeFor(cgSize: size))
        bannerView.adUnitID = adUnitID
        bannerView.rootViewController = viewController
        bannerView.delegate = context.coordinator
        bannerView.translatesAutoresizingMaskIntoConstraints = false

        viewController.view.addSubview(bannerView)
        NSLayoutConstraint.activate([
            bannerView.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
            bannerView.centerYAnchor.constraint(equalTo: viewController.view.centerYAnchor),
        ])

        context.coordinator.bannerView = bannerView
        bannerView.load(makeNonPersonalizedAdRequest())
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.bannerView?.rootViewController = uiViewController
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        weak var bannerView: BannerView?
        private let onReceiveAd: () -> Void
        private let onFailToReceiveAd: (Error) -> Void

        init(onReceiveAd: @escaping () -> Void, onFailToReceiveAd: @escaping (Error) -> Void) {
            self.onReceiveAd = onReceiveAd
            self.onFailToReceiveAd = onFailToReceiveAd
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            onReceiveAd()
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            onFailToReceiveAd(error)
        }
    }
}

@MainActor
private final class RewardedAdLoader: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?

    var onRewardEarned: ((AdReward) -> Void)?
    private let adUnitID: String
    nonisolated(unsafe) private var rewardedAd: RewardedAd?

    init(adUnitID: String) {
        self.adUnitID = adUnitID
        super.init()
        loadAd()
    }

    /// リワード広告を読み込む
    func loadAd() {
        isLoading = true
        isReady = false
        errorMessage = nil
        // パーソナライズ広告を行わない（npa=1）。ATT プロンプトも不要にする。
        let request = makeNonPersonalizedAdRequest()

        RewardedAd.load(with: adUnitID, request: request) { [weak self] ad, error in
            guard let self else { return }
            self.rewardedAd = ad
            if let ad { ad.fullScreenContentDelegate = self }
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.isLoading = false
                if error != nil {
                    self.errorMessage = String(localized: "support.ad.noRewardedAd")
                    self.rewardedAd = nil
                } else if self.rewardedAd != nil {
                    self.isReady = true
                }
            }
        }
    }

    /// 読み込み済み広告を表示する
    func present(from root: UIViewController) {
        guard let rewardedAd else { return }
        let ad = rewardedAd
        isReady = false
        ad.present(from: root) { [weak self] in
            guard let self else { return }
            self.onRewardEarned?(ad.adReward)
        }
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.rewardedAd = nil
            self.loadAd()
        }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            self.errorMessage = String(localized: "support.ad.noRewardedAd")
            self.rewardedAd = nil
            self.loadAd()
        }
    }
}

private extension UIApplication {
    /// 表示中の最前面ViewControllerを返す
    static func topMostViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })?.rootViewController }
            .first
    ) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topMostViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topMostViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topMostViewController(base: presented)
        }
        return base
    }
}

#endif

private extension SettingsView {
    /// 通貨記号スイッチのラベル（ロケールの記号を括弧内に表示）
    var showCurrencySymbolLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        let symbol = formatter.currencySymbol ?? ""
        return String.localizedStringWithFormat(
            String(localized: "settings.showCurrencySymbol.format"),
            symbol
        )
    }

    /// 集計期間ラベル
    func windowLabel(_ days: Int) -> String {
        if days == 30 {
            return String(localized: "unit.oneMonth")
        }
        return String.localizedStringWithFormat(String(localized: "unit.days"), days)
    }
}


// MARK: - UIActivityViewController ラッパー

