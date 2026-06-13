import SwiftUI
import SwiftData

/// 音声入力シートから親画面へ渡すペイロード
/// 親は保存時に matchedToken / originalCardID を見て VoiceAliasStore を更新する
struct VoiceApplyPayload {
    let amount: Decimal?
    let card: E1card?
    let label: String?
    /// 認識テキストから手段判定に使われたトークン（カード名・既存エイリアス・短縮発話のいずれか）
    let matchedToken: String?
    /// matchedToken が VoiceAliasStore に既存だったか
    let matchedWasExistingAlias: Bool
    /// 音声で最後に確定したカード ID。手動で別カードへ変更した場合は旧カードからエイリアス削除に使う
    let originalCardID: String?
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
    /// 適用時に呼ばれる
    let onApply: (VoiceApplyPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recognizer = SpeechRecognizer()
    /// 現在の transcript をまとめてパースした最新結果
    @State private var parsed: VoiceInputResult = VoiceInputResult()
    /// 音声で最後に検出されたカード ID（手動変更時の学習用、selectCard では更新しない）
    @State private var originalVoiceCardID: String?
    /// 保存コマンド検出による apply 二重起動防止
    @State private var didTriggerSaveCommand = false
    @State private var deniedReason: String?

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
                        if case .listening = recognizer.state { recognizer.stop() }
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
                if case .listening = recognizer.state { recognizer.stop() }
            }
            .onChange(of: recognizer.partialTranscript) { _, _ in updateParsed() }
            .onChange(of: recognizer.transcript) { _, _ in updateParsed() }
            .onChange(of: recognizer.state) { _, newState in
                // 権限不足だけアラートを出す。"audio"/"unavailable" は Retry で再試行可能
                if case .denied(let reason) = newState,
                   reason == "microphone" || reason == "speech" {
                    deniedReason = reason
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

        let (hasSave, cleanedText) = Self.consumeSaveCommand(in: text)

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

        var r = VoiceInputResult()
        let amountLabel = VoiceInputParser.parseAmountAndLabel(amountLabelText, locale: recognizer.locale)
        r.amount = amountLabel.amount
        r.label = amountLabel.label

        let trimmedCardText = cardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCardText.isEmpty {
            let cardResult = VoiceInputParser.parseCard(trimmedCardText, cards: cards)
            r.card = cardResult.card
            r.matchedToken = cardResult.matchedToken
            r.matchedWasExistingAlias = cardResult.matchedWasExistingAlias
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

    /// 「もう一度」: パース結果と学習スナップショットをクリアして聞き取り再開
    private func retry() {
        parsed = VoiceInputResult()
        originalVoiceCardID = nil
        didTriggerSaveCommand = false
        Task { await startListening() }
    }

    /// メニューからカード手動選択。音声で検出無しならキーワード後の発話を学習トークンに据える
    private func selectCard(_ card: E1card) {
        parsed.card = card
        if parsed.matchedToken == nil {
            let token = lastSpokenAfterKeyword
            if !token.isEmpty {
                parsed.matchedToken = token
                parsed.matchedWasExistingAlias = false
            }
        }
    }

    private func apply() {
        if case .listening = recognizer.state { recognizer.stop() }
        let payload = VoiceApplyPayload(
            amount: parsed.amount,
            card: parsed.card,
            label: parsed.label,
            matchedToken: parsed.matchedToken,
            matchedWasExistingAlias: parsed.matchedWasExistingAlias,
            originalCardID: originalVoiceCardID
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
}
