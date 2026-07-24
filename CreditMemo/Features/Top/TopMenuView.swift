//
//  メインメニュー画面
//  新しい決済、各一覧、設定への導線をまとめる
//

import SwiftUI
import SwiftData

struct TopMenuView: View {
    @Binding var selectedDestination: AppDestination?
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.badgeTheme) private var badgeTheme
    @AppStorage(AppStorageKey.userLevel) private var userLevel: UserLevel = .beginner
    @AppStorage(AppStorageKey.fontScale) private var fontScale: FontScale = .system
    @AppStorage(AppStorageKey.paymentWindowDays) private var paymentWindowDays = 15
    @AppStorage(AppStorageKey.enableVoiceInput)  private var enableVoiceInput = true
    @AppStorage(AppStorageKey.openVoiceInputOnActive) private var openVoiceInputOnActive = false
    // 音声入力の保存後も「新しい決済入力後」設定を適用する
    @AppStorage(AppStorageKey.afterSaveAction)   private var afterSaveAction: AfterSaveAction = .goBack
    @State private var showVoiceRecordSheet = false
    /// 音声保存成功時に、シート dismiss 後へ持ち越す保存後アクション
    @State private var pendingVoiceAfterSave: AfterSaveAction?
    @State private var voiceInputSource = "menu"

    // 古い履歴の自動整理提案まわり（実行フローは .retentionCleanup modifier に委譲）
    @AppStorage(AppStorageKey.retentionSuggestSnoozeUntil) private var retentionSnoozeUntil: Double = 0
    @State private var showRetentionSuggest = false
    @State private var retentionOldCount = 0
    /// true にすると整理フロー（エクスポート→成功時のみ削除→完了トースト）が始まる
    @State private var retentionCleanupTrigger = false

    @Query(sort: \E7payment.date, order: .reverse)
    private var allPayments: [E7payment]
    @Query(sort: \E1card.nRow)
    private var cards: [E1card]

    private var unpaidPayments: [E7payment] {
        // 起動直後クラッシュ回避:
        // isPaid は e2invoices 関係を辿るため、旧データ不整合時に落ちることがある。
        // メニュー集計は状態ラベルの関係参照を避け、支払側の所属で判定する。
        allPayments.filter { $0.e8paid == nil }
    }

    private var recentUnpaidTotal: Decimal {
        // メニュー表示は「本日から N 日間の引き落とし合計」を使う
        let windowDays = max(1, min(paymentWindowDays, 60))
        let sorted = unpaidPayments.sorted { $0.date < $1.date }
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: windowDays - 1, to: today) ?? today
        return sorted
            .filter {
                let date = Calendar.current.startOfDay(for: $0.date)
                return today <= date && date <= end
            }
            .reduce(.zero) { partialResult, payment in
                partialResult + payment.sumAmount
            }
    }

    private var recentWindowLabel: String {
        let days = max(1, min(paymentWindowDays, 60))
        return String.localizedStringWithFormat(
            String(localized: "payment.window.recentDaysTotal"),
            days
        )
    }

    private var hasOverdueUnpaidPayments: Bool {
        // PaymentList の確認待ち判定（!isPaid + 直近1年）と一致させる
        // unpaidPayments は e8paid==nil の物理判定で、旧データや口座未設定で
        // isPaid と乖離しうるため、ここでは allPayments から直接判定する
        let today = Calendar.current.startOfDay(for: Date())
        let earliest = Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
        return allPayments.contains { payment in
            let date = Calendar.current.startOfDay(for: payment.date)
            guard earliest <= date && date < today else { return false }
            return !payment.isPaid
        }
    }

    private var overdueAccentColor: Color {
        // 状況画面の確認待ちセクションと同じ警告色
        Color(red: 0.78, green: 0.28, blue: 0.36)
    }

    private var overdueLabelColor: Color {
        colorScheme == .dark ? overdueAccentColor.opacity(0.92) : overdueAccentColor.opacity(0.88)
    }

    private var supportsVoiceInput: Bool {
        guard enableVoiceInput else { return false }
        #if targetEnvironment(simulator)
        // シミュレータでは音声認識を使わずシートのデザインだけ確認可能にする
        return true
        #else
        // 端末ロケールが SFSpeechRecognizer に対応しているか
        return SpeechRecognizer.supports()
        #endif
    }

    var body: some View {
        List(selection: $selectedDestination) {
            if userLevel == .beginner {
                Section {
                    BeginnerHintView(
                        hintKey: "top.beginner.hint",
                        detailMessageKey: "top.beginner.guide"
                    )
                }
            }
            // 明細
            Section {
                if supportsVoiceInput {
                    voiceRecordRow()
                }
                row(.addRecord, icon: "plus.circle.fill", color: .blue, key: "top.addRecord")
                row(.recordList, icon: "list.bullet.circle.fill", color: .cyan, key: "top.recordList")
            }

            // 集計
            Section {
                NavigationLink(value: AppDestination.paymentList) {
                    HStack(spacing: 12) {
                        ScaledMenuBadge()
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        // タイトル / 直近計 / 金額 を、入る範囲で 1段→2段→3段 と段を増やして表示する
                        ViewThatFits(in: .horizontal) {
                            // 1行版: タイトル + 直近計 + 金額をすべて1行に
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("top.paymentList")
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 8)
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(recentWindowLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.5)
                                            .allowsTightening(true)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Text(recentUnpaidTotal.currencyString())
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(badgeTheme.unpaidText)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                overdueConfirmationRow
                            }
                            // 2行版: タイトル / 直近計+金額（右寄せ1行）
                            VStack(alignment: .leading, spacing: 3) {
                                Text("top.paymentList")
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Spacer(minLength: 0)
                                    Text(recentWindowLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .allowsTightening(true)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text(recentUnpaidTotal.currencyString())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(badgeTheme.unpaidText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                overdueConfirmationRow
                            }
                            // 3行版: タイトル / 直近計 / 金額（金額は右寄せ）
                            VStack(alignment: .leading, spacing: 3) {
                                Text("top.paymentList")
                                Text(recentWindowLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .allowsTightening(true)
                                HStack {
                                    Spacer(minLength: 0)
                                    Text(recentUnpaidTotal.currencyString())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(badgeTheme.unpaidText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                overdueConfirmationRow
                            }
                        }
                    }
                }
                .tag(AppDestination.paymentList)
                // fastlane snapshot 用: 他のメニュー行と同じ命名で識別子を付ける
                .accessibilityIdentifier("menu.\(AppDestination.paymentList.rawValue)")
            }

            // マスタメニューは初心者/達人に関係なく常時表示する
            Section {
                row(.cardList, icon: "creditcard", color: .indigo, key: "top.cardList")
                row(.bankList, icon: "building.columns", color: .brown, key: "top.bankList")
                row(.tagList, icon: "tag", color: .orange, key: "top.tagList")
            }

            // アプリ
            Section {
                row(
                    .settings,
                    icon: "gearshape",
                    color: .gray,
                    key: "top.settings"
                )
            }
        }
        // 先頭セクション前の余白を詰めて、ヘッダ直下をコンパクトにする
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("app.name")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $showVoiceRecordSheet, onDismiss: { handleVoiceAfterSave() }) {
            VoiceInputSheet(
                cards: cards,
                currentAmount: 0,
                currentCard: nil,
                currentLabel: "",
                requiresAmount: true,
                applyTitleKey: "button.save",
                telemetrySource: voiceInputSource,
                onApply: { payload in saveVoiceRecord(payload) }
            )
            .appFontScale(fontScale)
            // 音声入力シートは背面を透かさない
            .presentationBackground(Color(uiColor: .systemGroupedBackground))
        }
        .onAppear {
            openVoiceInputSheetIfNeeded()
            checkRetentionSuggestion()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                openVoiceInputSheetIfNeeded()
                checkRetentionSuggestion()
            }
        }
        .onChange(of: openVoiceInputOnActive) { _, newValue in
            if newValue {
                openVoiceInputSheetIfNeeded()
            }
        }
        // 古い履歴の自動整理提案（2ボタン）。実行フローは .retentionCleanup へ委譲する
        .alert("retention.suggest.title", isPresented: $showRetentionSuggest) {
            Button("retention.suggest.exportAndClean") {
                retentionCleanupTrigger = true
            }
            Button("retention.suggest.later", role: .cancel) {
                snoozeRetentionSuggestion()
            }
        } message: {
            Text(retentionSuggestMessage)
        }
        // 整理フロー（エクスポート→成功時のみ削除→完了トースト）。整理後は当面再提案しない
        .retentionCleanup(trigger: $retentionCleanupTrigger) { _ in
            snoozeRetentionSuggestion()
        }
    }

    // MARK: - 古い履歴の自動整理提案

    /// 提案メッセージ（件数と保持年数を出し、書き出し＝手元に残ることを明示）
    private var retentionSuggestMessage: String {
        String.localizedStringWithFormat(
            NSLocalizedString("retention.suggest.message", comment: ""),
            RetentionSuggest.years,
            retentionOldCount
        )
    }

    /// 起動/復帰時に、条件を満たしていれば提案を出す。
    /// - 無効化されていない
    /// - スヌーズ期間を過ぎている
    /// - しきい値以上の古い決済がある
    private func checkRetentionSuggestion() {
        // 既に提案表示中・整理フロー起動済みのときは二重に走らせない
        guard !showRetentionSuggest, !retentionCleanupTrigger else { return }
        guard Date().timeIntervalSinceReferenceDate >= retentionSnoozeUntil else { return }
        // 集計はメニュー描画を邪魔しないよう次の runloop に逃がす
        DispatchQueue.main.async {
            let count = RecordService.recordsCount(
                olderThanYears: RetentionSuggest.years,
                context: context
            )
            guard count >= RetentionSuggest.thresholdCount else { return }
            retentionOldCount = count
            showRetentionSuggest = true
        }
    }

    /// 「あとで」：次に提案してよい日時を snoozeDays 先へ進める
    private func snoozeRetentionSuggestion() {
        let next = Calendar.current.date(
            byAdding: .day, value: RetentionSuggest.snoozeDays, to: Date()
        ) ?? Date()
        retentionSnoozeUntil = next.timeIntervalSinceReferenceDate
    }

    @ViewBuilder
    private func row(
        _ dest: AppDestination,
        icon: String, color: Color,
        key: LocalizedStringKey
    ) -> some View {
        NavigationLink(value: dest) {
            HStack(alignment: .top, spacing: 12) {
                ScaledMenuIcon(systemName: icon, color: color)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text(key)
            }
        }
        .tag(dest)
        // fastlane snapshot 用: ローカライズ文言に依存せず行を特定できるよう
        // 言語非依存の識別子を付ける（例 "menu.addRecord"）。
        .accessibilityIdentifier("menu.\(dest.rawValue)")
    }

    @ViewBuilder
    private func voiceRecordRow() -> some View {
        Button {
            // 通常メニューから開いた時の起動元を記録する
            voiceInputSource = "menu"
            showVoiceRecordSheet = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ScaledMenuIcon(systemName: "microphone.badge.plus.fill", color: .blue)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text("top.addRecordByVoice")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var overdueConfirmationRow: some View {
        if hasOverdueUnpaidPayments {
            HStack {
                Spacer(minLength: 0)
                Text("payment.section.overdue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(overdueLabelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
            }
        }
    }

    private func openVoiceInputSheetIfNeeded() {
        guard openVoiceInputOnActive else { return }

        // 設定 OFF または端末未対応なら主メニュー表示だけにする
        guard supportsVoiceInput else {
            openVoiceInputOnActive = false
            return
        }

        guard !showVoiceRecordSheet else { return }

        // Siri 起動時だけ自動で聞き取りシートを開く
        openVoiceInputOnActive = false
        // 自動展開は Siri 起動由来として扱う
        voiceInputSource = "siri"
        showVoiceRecordSheet = true
    }

    /// 音声入力シートが閉じた後、「新しい決済入力後」設定に応じて動く
    private func handleVoiceAfterSave() {
        guard let action = pendingVoiceAfterSave else { return }
        pendingVoiceAfterSave = nil
        switch action {
        case .goBack:
            break
        case .continuous, .sameDayCard:
            // 続けて音声入力できるよう、シートを開き直す
            DispatchQueue.main.async { showVoiceRecordSheet = true }
        case .showHistory:
            // 決済一覧へ遷移する
            selectedDestination = .recordList
        }
    }

    private func saveVoiceRecord(_ payload: VoiceApplyPayload) {
        let amount = (payload.amount ?? .zero).roundedAmount()
        guard 0 < amount else { return }

        let usePoint = payload.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            // 音声入力も Siri と同じ簡易保存ヘルパーへ揃える
            let _ = try RecordService.addQuickRecord(
                amount: amount,
                label: usePoint,
                card: payload.card,
                context: context
            )
            commitVoiceLearning(payload: payload, savedCard: payload.card)
            // 保存成功時のみ「新しい決済入力後」設定を dismiss 後に適用する
            pendingVoiceAfterSave = afterSaveAction
            AppTelemetry.reportVoiceInputSave(
                VoiceInputSaveTelemetry(
                    source: payload.source,
                    saveResult: "success",
                    hasCard: payload.card != nil,
                    hasLabel: !usePoint.isEmpty,
                    manualCardSelection: payload.manualCardSelection,
                    matchedExistingAlias: payload.matchedWasExistingAlias,
                    usedSaveCommand: payload.usedSaveCommand
                )
            )
        } catch {
            appLog(.error, "音声入力からの新規保存に失敗しました: \(error)")
            AppTelemetry.reportSwiftDataError(
                error,
                operation: "top_voice_record_save",
                entity: "E3record"
            )
            AppTelemetry.reportVoiceInputSave(
                VoiceInputSaveTelemetry(
                    source: payload.source,
                    saveResult: "failure",
                    hasCard: payload.card != nil,
                    hasLabel: !usePoint.isEmpty,
                    manualCardSelection: payload.manualCardSelection,
                    matchedExistingAlias: payload.matchedWasExistingAlias,
                    usedSaveCommand: payload.usedSaveCommand
                )
            )
            context.rollback()
        }
    }

    private func commitVoiceLearning(payload: VoiceApplyPayload, savedCard: E1card?) {
        guard let token = payload.matchedToken else { return }
        // 音声で最初に確定したカードと、最終的に保存したカードが違う場合
        // 既存エイリアス由来なら旧カードのリストから外す
        if let originalID = payload.originalCardID,
           originalID != savedCard?.id,
           payload.matchedWasExistingAlias {
            VoiceAliasStore.removeAlias(token, forCardID: originalID)
        }
        guard let cardID = savedCard?.id else { return }
        if !tokenMatchesCardName(token, cardID: cardID) {
            // 保存まで手段が確定した発話だけを次回候補として学習する
            VoiceAliasStore.append(token, forCardID: cardID)
        }
    }

    private func tokenMatchesCardName(_ token: String, cardID: String) -> Bool {
        guard let card = cards.first(where: { $0.id == cardID }) else { return false }
        return token.compare(card.zName, options: .caseInsensitive) == .orderedSame
    }
}

/// メニューの SF Symbol アイコン。文字サイズに連動して拡縮する
/// 呼び出し側で `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` を付けて
/// 「大」を上限にクランプする運用
private struct ScaledMenuIcon: View {
    let systemName: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemName).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .font(.system(size: size))
            .foregroundStyle(color)
            .frame(width: size)
    }
}

/// 引き落とし状況用のアプリバッジ。同じくサイズを文字サイズに連動させる
private struct ScaledMenuBadge: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        // AppIconBadge は視覚的に size×1.14 の円で描くため、その分の幅を確保して
        // 隣のラベルへはみ出さないようにする（他アイコン行と間隔を揃える）
        AppIconBadge(size: size)
            .frame(width: size * 1.14)
    }
}
