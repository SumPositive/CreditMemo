import SwiftUI
import SwiftData

/// 音声入力シートから親画面へ渡すペイロード
/// 親は保存時に matchedToken / originalCardID を見て VoiceAliasStore を更新する
struct VoiceApplyPayload {
    let amount: Decimal?
    let card: E1card?
    let label: String?
    /// 起動元。通常メニューは menu、Siri 起動は siri
    let source: String
    /// 認識テキストから手段判定に使われたトークン（カード名・既存エイリアス・短縮発話のいずれか）
    let matchedToken: String?
    /// matchedToken が VoiceAliasStore に既存だったか
    let matchedWasExistingAlias: Bool
    /// 音声で最後に確定したカード ID。手動で別カードへ変更した場合は旧カードからエイリアス削除に使う
    let originalCardID: String?
    /// 手段をメニューから手動で選び直したか
    let manualCardSelection: Bool
    /// 保存コマンドの発話で確定したか
    let usedSaveCommand: Bool
}

/// 音声入力セッション中に溜める匿名集計
private struct VoiceInputTelemetryState {
    var source = "menu"
    var localeIdentifier = Locale.current.identifier
    var startedAt = Date()
    var startCount = 0
    var contextualHintCount = 0
    var cardCount = 0
    var transcriptUpdateCount = 0
    var finalTranscriptDetected = false
    var cardKeywordSpoken = false
    var saveCommandSpoken = false
    var amountDetected = false
    var labelDetected = false
    var cardDetected = false
    var manualCardSelection = false
    var deniedReason: String?
    var unresolvedCardPhraseLength = 0
    var usedSaveCommand = false
    var didReport = false

    var retryCount: Int {
        max(0, startCount - 1)
    }
}

/// 音声入力シート（統合パーサ方式）
/// 一つの SFSpeechRecognizer セッションで全部聞き取り、transcript を常に丸ごとパースする
/// 「決済手段は」「手段は」で前後を分割し、前を金額+ラベル、後を手段としてマッチする
/// 「保存」「OK」等が出たら即時 apply
struct VoiceInputSheet: View {
    let cards: [E1card]
    /// シートを開いた時点の現在値
    let currentAmount: Decimal
    let currentCard: E1card?
    let currentLabel: String
    /// true の場合、金額が入るまで確定ボタンを押せない
    var requiresAmount = false
    /// 確定ボタンの表示名。入力画面では適用、直接保存では保存にする
    var applyTitleKey: LocalizedStringKey = "voice.apply"
    /// 起動元。通常メニューは menu、Siri 起動は siri
    var telemetrySource = "menu"
    /// 適用時に呼ばれる
    let onApply: (VoiceApplyPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.shareVoiceInputDiagnostics) private var shareVoiceInputDiagnostics = false
    @State private var recognizer = SpeechRecognizer()
    /// 現在の transcript をまとめてパースした最新結果
    @State private var parsed: VoiceInputResult = VoiceInputResult()
    /// 音声で最後に検出されたカード ID（手動変更時の学習用、selectCard では更新しない）
    @State private var originalVoiceCardID: String?
    /// 保存コマンド検出による apply 二重起動防止
    @State private var didTriggerSaveCommand = false
    /// キャンセルコマンド検出による dismiss 二重起動防止
    @State private var didTriggerCancelCommand = false
    @State private var deniedReason: String?
    @State private var telemetry = VoiceInputTelemetryState()
    /// セッション中に一度だけ走る早期失敗リトライのガード
    @State private var didAutoRetry = false
    /// ユーザー操作（停止・適用・キャンセル）による .stopped 遷移かどうか
    @State private var userInitiatedStop = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusArea
                voiceGuideArea
                if !currentTranscript.isEmpty || parsed.hasAnyField {
                    previewArea
                }
                Spacer()
                controlButton
            }
            .padding()
            .navigationTitle("voice.input.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("button.cancel") {
                        if case .listening = recognizer.state {
                            userInitiatedStop = true
                            recognizer.stop()
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applyTitleKey) { apply() }
                        .fontWeight(.semibold)
                        .disabled(!canApply)
                }
            }
            .task { await startListening() }
            .onDisappear {
                reportSessionIfNeeded(dismissalReason: "cancelled")
                if case .listening = recognizer.state {
                    userInitiatedStop = true
                    recognizer.stop()
                }
            }
            .onChange(of: recognizer.partialTranscript) { _, _ in updateParsed() }
            .onChange(of: recognizer.transcript) { _, _ in updateParsed() }
            .onChange(of: recognizer.state) { _, newState in
                // 権限不足だけアラートを出す。"audio"/"unavailable" は Retry で再試行可能
                if case .denied(let reason) = newState,
                   reason == "microphone" || reason == "speech" {
                    deniedReason = reason
                }
                if case .denied(let reason) = newState {
                    // セッション終了時に失敗要因を集計する
                    telemetry.deniedReason = reason
                }
                if shouldAutoRetry(newState: newState) {
                    didAutoRetry = true
                    Task {
                        // tearDownAudio 直後はセッション解放猶予を取る
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        retry()
                    }
                }
            }
            .alert(
                "voice.permission.title",
                isPresented: Binding(
                    get: { deniedReason != nil },
                    set: { if !$0 { deniedReason = nil } }
                ),
                presenting: deniedReason
            ) { _ in
                Button("button.done") { dismiss() }
            } message: { reason in
                Text(NSLocalizedString("voice.permission.\(reason)", comment: ""))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var statusArea: some View {
        VStack(spacing: 10) {
            Image(systemName: isListening ? "waveform" : "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(isListening ? .red : .secondary)
                .symbolEffect(.pulse, isActive: isListening)
            if currentTranscript.isEmpty {
                Text(isListening ? "voice.listening" : "voice.tap.to.start")
                    .foregroundStyle(.secondary)
            } else {
                Text(currentTranscript)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var voiceGuideArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("voice.input.sayAmountAndLabel")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("voice.input.example")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var previewArea: some View {
        VStack(spacing: 14) {
            previewRow(label: "record.field.amount", value: amountPreview, color: amountActive ? .accentColor : .secondary)
            previewRow(label: "record.field.usePoint", value: labelPreview, color: labelActive ? .accentColor : .secondary)
            // 手段は「決済手段は/手段は」が発話されたか手段がマッチしたら表示
            if showCardRow {
                cardMenuRow
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func previewRow(label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color)
        }
    }

    @ViewBuilder private var cardMenuRow: some View {
        Menu {
            ForEach(cards, id: \.id) { card in
                Button(card.zName) { selectCard(card) }
            }
        } label: {
            HStack {
                Text("record.field.card").foregroundStyle(.secondary)
                Spacer()
                Text(cardPreview)
                    .foregroundStyle(cardActive ? Color.accentColor : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var controlButton: some View {
        if isListening {
            Button {
                userInitiatedStop = true
                recognizer.stop()
            } label: {
                Label("voice.stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button {
                retry()
            } label: {
                Label("voice.retry", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    /// `.listening` だけでなく `.authorizing`（権限確認＋オーディオ準備中）も
    /// 「聞き取り中」扱いにして即座にユーザへ視覚フィードバックを返す
    private var isListening: Bool {
        switch recognizer.state {
        case .listening, .authorizing: return true
        default: return false
        }
    }

    private var currentTranscript: String {
        if !recognizer.transcript.isEmpty { return recognizer.transcript }
        return recognizer.partialTranscript
    }

    private var amountPreview: String {
        if let a = parsed.amount, a > 0 { return a.currencyString() }
        return currentAmount == 0 ? "—" : currentAmount.currencyString()
    }

    private var cardPreview: String {
        if let c = parsed.card { return c.zName }
        return currentCard?.zName ?? "—"
    }

    private var labelPreview: String {
        if let l = parsed.label, !l.isEmpty { return l }
        return currentLabel.isEmpty ? "—" : currentLabel
    }

    private var amountActive: Bool { parsed.amount != nil }
    private var cardActive: Bool { parsed.card != nil }
    private var labelActive: Bool { parsed.label != nil }

    /// 「決済手段は/手段は」が発話されたか、手段が確定済みなら手段行を表示
    private var showCardRow: Bool {
        parsed.card != nil || Self.findFirstCardPhaseKeyword(in: currentTranscript) != nil
    }

    /// transcript の「最後の決済手段は/手段は」より後の発話（マッチしなかった時の学習トークン候補）
    private var lastSpokenAfterKeyword: String {
        guard let kwRange = Self.findLastCardPhaseKeyword(in: currentTranscript) else { return "" }
        let after = String(currentTranscript[kwRange.upperBound...])
        let (_, cleaned) = Self.consumeSaveCommand(in: after)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canApply: Bool {
        if requiresAmount {
            let amount = parsed.amount ?? currentAmount
            return 0 < amount.roundedAmount()
        }
        return parsed.amount != nil || parsed.card != nil || parsed.label != nil
    }

    // MARK: - Actions

    private func startListening() async {
        let hints = contextualHints()
        // 開始条件をセッション単位で記録する
        if telemetry.startCount == 0 {
            telemetry.startedAt = Date()
        }
        telemetry.source = telemetrySource
        telemetry.localeIdentifier = recognizer.locale.identifier
        telemetry.contextualHintCount = hints.count
        telemetry.cardCount = cards.count
        let isFirstStart = telemetry.startCount == 0
        telemetry.startCount += 1
        // ユーザーが新しい聞き取りを始めるたびに stop フラグはリセットする
        userInitiatedStop = false

        // Siri 起動直後はマイクハンドオフが間に合わず beginAudio 成功でも無音になる
        // 初回のみ固定で待ってから start する
        if telemetrySource == "siri", isFirstStart {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        await recognizer.start(contextualStrings: hints)
    }

    /// transcript を丸ごとパースする
    /// 1. 保存コマンド検出 → 除去
    /// 2. 「決済手段は/手段は」で前後分割
    /// 3. 前: parseAmountAndLabel, 後: parseCard
    /// 4. 保存コマンドありかつ canApply なら即 apply
    private func updateParsed() {
        let text = currentTranscript
        guard !text.isEmpty else { return }

        // 認識結果が何度更新されたかを集計する
        telemetry.transcriptUpdateCount += 1
        telemetry.finalTranscriptDetected = telemetry.finalTranscriptDetected || !recognizer.transcript.isEmpty

        // キャンセルコマンドは canApply を問わず即時シートを閉じる
        if !didTriggerCancelCommand, Self.containsCancelCommand(in: text) {
            didTriggerCancelCommand = true
            cancelByVoice()
            return
        }

        let (hasSave, cleanedText) = Self.consumeSaveCommand(in: text)
        telemetry.saveCommandSpoken = telemetry.saveCommandSpoken || hasSave

        // 後勝ち上書き: 最後の「手段は/決済手段は」を手段セクションの開始位置にする
        // 金額・ラベルは最初の出現より前のテキストを使い、間に挟まれた古い「手段は X」は捨てる
        let amountLabelText: String
        let cardText: String
        if let firstKw = Self.findFirstCardPhaseKeyword(in: cleanedText),
           let lastKw = Self.findLastCardPhaseKeyword(in: cleanedText) {
            amountLabelText = String(cleanedText[..<firstKw.lowerBound])
            cardText = String(cleanedText[lastKw.upperBound...])
        } else {
            amountLabelText = cleanedText
            cardText = ""
        }
        telemetry.cardKeywordSpoken = telemetry.cardKeywordSpoken || Self.findFirstCardPhaseKeyword(in: cleanedText) != nil

        var r = VoiceInputResult()
        let amountLabel = VoiceInputParser.parseAmountAndLabel(amountLabelText, locale: recognizer.locale)
        r.amount = amountLabel.amount
        r.label = amountLabel.label
        telemetry.amountDetected = telemetry.amountDetected || amountLabel.amount != nil
        telemetry.labelDetected = telemetry.labelDetected || amountLabel.label != nil

        let trimmedCardText = cardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCardText.isEmpty {
            let cardResult = VoiceInputParser.parseCard(trimmedCardText, cards: cards)
            r.card = cardResult.card
            r.matchedToken = cardResult.matchedToken
            r.matchedWasExistingAlias = cardResult.matchedWasExistingAlias
            telemetry.cardDetected = telemetry.cardDetected || cardResult.card != nil
            if cardResult.card == nil {
                telemetry.unresolvedCardPhraseLength = max(telemetry.unresolvedCardPhraseLength, trimmedCardText.count)
            }
        }

        // 音声で新しい手段がマッチした場合は originalVoiceCardID を更新
        // マッチしなかった場合、既にメニューで選択された card があれば保持する
        if let voiceCard = r.card {
            originalVoiceCardID = voiceCard.id
        } else if parsed.card != nil {
            r.card = parsed.card
            r.matchedToken = parsed.matchedToken
            r.matchedWasExistingAlias = parsed.matchedWasExistingAlias
        }

        parsed = r

        if hasSave && !didTriggerSaveCommand && canApply {
            didTriggerSaveCommand = true
            telemetry.usedSaveCommand = true
            apply()
        }
    }

    /// カードフェーズ切替キーワード正規表現
    /// ja: 決済手段は / 手段は
    /// en: payment method is / method is / card is（前後の語境界はあえて入れない、自然な後続を許容）
    private static let cardPhaseKeywordPattern = #"(?i)((?:決済)?手段は|(?:payment )?method is|card is)"#

    /// 最初の出現範囲（金額・ラベルセクション末尾）
    private static func findFirstCardPhaseKeyword(in text: String) -> Range<String.Index>? {
        text.range(of: cardPhaseKeywordPattern, options: .regularExpression)
    }

    /// 最後の出現範囲（手段セクション先頭 = 後勝ち上書き用）
    private static func findLastCardPhaseKeyword(in text: String) -> Range<String.Index>? {
        text.range(of: cardPhaseKeywordPattern, options: [.regularExpression, .backwards])
    }

    /// キャンセルコマンドの検出
    /// ja: キャンセル / 中止
    /// en: cancel（大小文字無視）
    private static func containsCancelCommand(in text: String) -> Bool {
        let keywords = ["キャンセル", "中止", "cancel"]
        for kw in keywords {
            if text.range(of: kw, options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    /// 保存コマンドを検出して取り除く
    /// ja: 保存 / セーブ / オーケー / オッケー
    /// en: save / ok（OK 含む、大小文字無視）
    /// "save" や "ok" は label に紛れにくい想定（家計簿用途なので "save the day" 等は稀）
    private static func consumeSaveCommand(in text: String) -> (found: Bool, cleaned: String) {
        let keywords = ["保存", "セーブ", "オーケー", "オッケー", "OK", "save"]
        var stripped = text
        var found = false
        for kw in keywords {
            while let range = stripped.range(of: kw, options: .caseInsensitive) {
                stripped.replaceSubrange(range, with: " ")
                found = true
            }
        }
        let cleaned = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (found, cleaned)
    }

    /// Siri 起動直後にマイクを取りこぼした時、一度だけ自動再起動する
    /// - 一切 transcript を受け取っていない
    /// - ユーザー操作（停止・適用・キャンセル）由来ではない
    /// - 状態が .stopped か .denied("audio")
    private func shouldAutoRetry(newState: SpeechRecognizer.State) -> Bool {
        guard !didAutoRetry, !userInitiatedStop else { return false }
        guard telemetry.transcriptUpdateCount == 0 else { return false }
        switch newState {
        case .stopped: return true
        case .denied(let reason): return reason == "audio"
        default: return false
        }
    }

    /// 「もう一度」: パース結果と学習スナップショットをクリアして聞き取り再開
    private func retry() {
        parsed = VoiceInputResult()
        originalVoiceCardID = nil
        didTriggerSaveCommand = false
        didTriggerCancelCommand = false
        telemetry.usedSaveCommand = false
        Task { await startListening() }
    }

    /// メニューからカード手動選択。音声で検出無しならキーワード後の発話を学習トークンに据える
    private func selectCard(_ card: E1card) {
        parsed.card = card
        // 手段の選び直しを改善ヒント候補として扱う
        telemetry.manualCardSelection = true
        if parsed.matchedToken == nil {
            let token = lastSpokenAfterKeyword
            if !token.isEmpty {
                parsed.matchedToken = token
                parsed.matchedWasExistingAlias = false
            }
        }
    }

    /// 音声で「キャンセル」「中止」が検出された時の処理（キャンセルボタンと同じ挙動）
    private func cancelByVoice() {
        if case .listening = recognizer.state {
            userInitiatedStop = true
            recognizer.stop()
        }
        dismiss()
    }

    private func apply() {
        if case .listening = recognizer.state {
            userInitiatedStop = true
            recognizer.stop()
        }
        reportSessionIfNeeded(dismissalReason: "applied")
        let payload = VoiceApplyPayload(
            amount: parsed.amount,
            card: parsed.card,
            label: parsed.label,
            source: telemetry.source,
            matchedToken: parsed.matchedToken,
            matchedWasExistingAlias: parsed.matchedWasExistingAlias,
            originalCardID: originalVoiceCardID,
            manualCardSelection: telemetry.manualCardSelection,
            usedSaveCommand: telemetry.usedSaveCommand
        )
        onApply(payload)
        dismiss()
    }

    private func contextualHints() -> [String] {
        var hints: [String] = []
        for card in cards {
            hints.append(card.zName)
            hints.append(contentsOf: VoiceAliasStore.aliases(forCardID: card.id))
        }
        return hints
    }

    private func reportSessionIfNeeded(dismissalReason: String) {
        guard !telemetry.didReport else { return }
        telemetry.didReport = true

        let durationMilliseconds = max(0, Int(Date().timeIntervalSince(telemetry.startedAt) * 1000))
        AppTelemetry.reportVoiceInputSession(
            VoiceInputSessionTelemetry(
                source: telemetry.source,
                localeIdentifier: telemetry.localeIdentifier,
                durationMilliseconds: durationMilliseconds,
                contextualHintCount: telemetry.contextualHintCount,
                cardCount: telemetry.cardCount,
                retryCount: telemetry.retryCount,
                transcriptUpdateCount: telemetry.transcriptUpdateCount,
                finalTranscriptDetected: telemetry.finalTranscriptDetected,
                cardKeywordSpoken: telemetry.cardKeywordSpoken,
                saveCommandSpoken: telemetry.saveCommandSpoken,
                amountDetected: telemetry.amountDetected,
                labelDetected: telemetry.labelDetected,
                cardDetected: telemetry.cardDetected,
                manualCardSelection: telemetry.manualCardSelection,
                dismissalReason: dismissalReason,
                deniedReason: telemetry.deniedReason,
                unresolvedCardPhraseLength: telemetry.unresolvedCardPhraseLength
            )
        )

        reportHintCandidateIfNeeded()
    }

    private func reportHintCandidateIfNeeded() {
        guard shareVoiceInputDiagnostics else { return }
        guard telemetry.manualCardSelection else { return }
        guard !parsed.matchedWasExistingAlias else { return }
        guard let token = parsed.matchedToken, let selectedCard = parsed.card else { return }

        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        guard normalizedToken.compare(selectedCard.zName, options: .caseInsensitive) != .orderedSame else { return }

        // 生の全文ではなく、手段として解釈できなかった短い呼び方だけを送る
        AppTelemetry.reportVoiceInputHintCandidate(
            token: normalizedToken,
            source: telemetry.source,
            localeIdentifier: telemetry.localeIdentifier
        )
    }
}
