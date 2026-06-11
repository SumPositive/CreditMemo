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
    /// 音声で最初に確定したカード ID。手動で別カードへ変更した場合は旧カードからエイリアス削除に使う
    let originalCardID: String?
}

/// 音声入力シート
/// 第1フェーズ: 金額とラベルだけを聞き取る
/// 第2フェーズ: 「決済手段を音声入力する」を押すと手段専用の聞き取りに切り替わる
/// 検出した手段は Menu でタップ変更可能。変更時は学習対象として追跡する
struct VoiceInputSheet: View {
    enum Phase {
        case amountAndLabel
        case card
    }

    let cards: [E1card]
    /// シートを開いた時点の現在値。指定が無いコマンドではこの値が保持される
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
    @State private var phase: Phase = .amountAndLabel
    /// 現在認識中フレーズのパース結果
    @State private var parsed: VoiceInputResult = VoiceInputResult()
    /// 確定済みコマンドの累積
    @State private var accumulated: VoiceInputResult = VoiceInputResult()
    /// 手段フェーズで「マッチしなかった発話」を学習トークン候補として覚える
    @State private var lastSpokenInCardPhase: String = ""
    /// 音声で最後に確定したカード ID。手動変更時の学習用に保持
    @State private var originalVoiceCardID: String?
    /// 次に発話が始まった時に手段の累積をリセットする（言い直し対応）
    @State private var resetCardOnNextSpeech: Bool = false
    @State private var deniedReason: String?
    /// セグメント検出用 debounce
    @State private var commitTask: Task<Void, Never>? = nil
    private let commitDebounceSeconds: Double = 1.4

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusArea
                voiceGuideArea
                if !currentTranscript.isEmpty || accumulated.hasAnyField {
                    previewArea
                }
                if showCardPhaseButton {
                    cardPhaseSwitchButton
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
                commitTask?.cancel()
                if case .listening = recognizer.state { recognizer.stop() }
            }
            .onChange(of: recognizer.partialTranscript) { _, _ in updateParsed() }
            .onChange(of: recognizer.transcript) { _, _ in updateParsed() }
            .onChange(of: recognizer.state) { _, newState in
                if case .denied(let reason) = newState { deniedReason = reason }
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
            Text(phase == .amountAndLabel ? "voice.input.sayAmountAndLabel" : "voice.input.sayCard")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(phase == .amountAndLabel ? "voice.input.example" : "voice.input.exampleCard")
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
            // 手段は第2フェーズに入った、もしくは手段が既に設定済みなら表示する
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

    @ViewBuilder private var cardPhaseSwitchButton: some View {
        Button {
            switchToCardPhase()
        } label: {
            Label("voice.cardInputButton", systemImage: "creditcard.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
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

    private var isListening: Bool {
        if case .listening = recognizer.state { return true }
        return false
    }

    private var currentTranscript: String {
        if !recognizer.transcript.isEmpty { return recognizer.transcript }
        return recognizer.partialTranscript
    }

    /// 累積 + 現在パース中の合成結果（プレビューと適用に使う）
    private var merged: VoiceInputResult {
        var m = accumulated
        Self.merge(from: parsed, into: &m)
        return m
    }

    private var amountPreview: String {
        let m = merged
        if let a = m.amount, a > 0 { return a.currencyString() }
        return currentAmount == 0 ? "—" : currentAmount.currencyString()
    }

    private var cardPreview: String {
        let m = merged
        if let c = m.card { return c.zName }
        return currentCard?.zName ?? "—"
    }

    private var labelPreview: String {
        let m = merged
        if let l = m.label, !l.isEmpty { return l }
        return currentLabel.isEmpty ? "—" : currentLabel
    }

    private var amountActive: Bool { merged.amount != nil }
    private var cardActive: Bool { merged.card != nil }
    private var labelActive: Bool { merged.label != nil }

    /// 手段フェーズに入った、または手段が既にセットされていれば表示
    private var showCardRow: Bool {
        phase == .card || accumulated.card != nil
    }

    /// 第1フェーズで amount または label が入った時に「決済手段を音声入力する」ボタンを出す
    private var showCardPhaseButton: Bool {
        phase == .amountAndLabel && (accumulated.amount != nil || accumulated.label != nil)
    }

    private var canApply: Bool {
        let m = merged
        if requiresAmount {
            let amount = m.amount ?? currentAmount
            return 0 < amount.roundedAmount()
        }
        return m.amount != nil || m.card != nil || m.label != nil
    }

    // MARK: - Actions

    private func startListening() async {
        let hints = contextualHints()
        await recognizer.start(contextualStrings: hints)
    }

    private func updateParsed() {
        let text = currentTranscript
        guard !text.isEmpty else { return }
        // 手段フェーズの言い直し: 新しい発話が始まったタイミングで累積をクリア
        if resetCardOnNextSpeech && phase == .card {
            accumulated.card = nil
            accumulated.matchedToken = nil
            accumulated.matchedWasExistingAlias = false
            originalVoiceCardID = nil
            lastSpokenInCardPhase = ""
            resetCardOnNextSpeech = false
        }
        let r: VoiceInputResult
        switch phase {
        case .amountAndLabel:
            r = VoiceInputParser.parseAmountAndLabel(text, locale: recognizer.locale)
        case .card:
            r = VoiceInputParser.parseCard(text, cards: cards)
            if r.card == nil {
                // マッチしなかった発話を学習トークン候補として保持
                lastSpokenInCardPhase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                lastSpokenInCardPhase = ""
            }
        }
        parsed = r
        if r.hasAnyField {
            scheduleCommit()
        } else {
            commitTask?.cancel()
            commitTask = nil
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [debounce = commitDebounceSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { commitCurrentPhrase() }
        }
    }

    /// 現在の parsed を accumulated へ統合し、recognizer を再起動して認識テキストをクリアする
    private func commitCurrentPhrase() {
        guard parsed.hasAnyField else { return }
        // 手段フェーズで音声マッチした場合、最新のカードを original として覚える
        if phase == .card, let card = parsed.card {
            originalVoiceCardID = card.id
        }
        Self.merge(from: parsed, into: &accumulated)
        parsed = VoiceInputResult()
        commitTask = nil
        // 手段フェーズでは次の発話が始まった時点でクリアする（言い直し対応）
        if phase == .card {
            resetCardOnNextSpeech = true
        }
        if case .listening = recognizer.state {
            recognizer.stop()
            Task { await startListening() }
        }
    }

    private static func merge(from src: VoiceInputResult, into dst: inout VoiceInputResult) {
        if src.amount != nil {
            dst.amount = src.amount
        }
        if src.card != nil {
            dst.card = src.card
            dst.matchedToken = src.matchedToken
            dst.matchedWasExistingAlias = src.matchedWasExistingAlias
        }
        if src.label != nil {
            dst.label = src.label
        }
    }

    /// 「もう一度」タップ時: 手段の累積をクリアして第1フェーズへ戻し、再聞き取りを開始する
    /// 金額・ラベルは保持して、必要なら話し直しで上書きできるようにする
    private func retry() {
        commitTask?.cancel()
        commitTask = nil
        accumulated.card = nil
        accumulated.matchedToken = nil
        accumulated.matchedWasExistingAlias = false
        originalVoiceCardID = nil
        lastSpokenInCardPhase = ""
        resetCardOnNextSpeech = false
        parsed = VoiceInputResult()
        phase = .amountAndLabel
        Task { await startListening() }
    }

    /// 手段フェーズへ切り替えて再聞き取りを開始する
    private func switchToCardPhase() {
        commitTask?.cancel()
        Self.merge(from: parsed, into: &accumulated)
        parsed = VoiceInputResult()
        phase = .card
        resetCardOnNextSpeech = false  // 切替直後は累積無いのでクリア対象なし
        if case .listening = recognizer.state {
            recognizer.stop()
        }
        Task { await startListening() }
    }

    /// メニューからカードを選択した時の処理。学習用トークンも更新する
    private func selectCard(_ card: E1card) {
        accumulated.card = card
        // 学習トークン: 既に音声マッチ済みならその token を維持
        // 無ければ手段フェーズで聞き取った発話を新規エイリアスとして使う
        if accumulated.matchedToken == nil, !lastSpokenInCardPhase.isEmpty {
            accumulated.matchedToken = lastSpokenInCardPhase
            accumulated.matchedWasExistingAlias = false
        }
    }

    private func apply() {
        commitTask?.cancel()
        commitTask = nil
        if case .listening = recognizer.state {
            recognizer.stop()
            updateParsed()
        }
        Self.merge(from: parsed, into: &accumulated)
        let m = accumulated

        let payload = VoiceApplyPayload(
            amount: m.amount,
            card: m.card,
            label: m.label,
            matchedToken: m.matchedToken,
            matchedWasExistingAlias: m.matchedWasExistingAlias,
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
