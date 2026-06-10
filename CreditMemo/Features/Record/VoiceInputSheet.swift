import SwiftUI
import SwiftData

/// 音声入力シートから親画面へ渡すペイロード
/// 親は保存時に matchedToken を見て VoiceAliasStore を更新する
struct VoiceApplyPayload {
    let amount: Decimal?
    let card: E1card?
    let label: String?
    /// 認識テキストから手段判定に使われたトークン（カード名・既存エイリアス・短縮発話のいずれか）
    let matchedToken: String?
    /// matchedToken が VoiceAliasStore に既存だったか
    let matchedWasExistingAlias: Bool
}

/// 音声入力シート
/// 認識結果を 金額・手段・ラベル に振り分けてプレビュー、適用で親へ返す
/// コマンドが確定する（"金額は300" 等の値が揃う）と認識テキストをクリアして次のコマンドを待つ
struct VoiceInputSheet: View {
    let cards: [E1card]
    /// シートを開いた時点の現在値。指定が無いコマンドではこの値が保持される
    let currentAmount: Decimal
    let currentCard: E1card?
    let currentLabel: String
    /// true の場合、金額が入るまで確定ボタンを押せない
    var requiresAmount = false
    /// 確定ボタンの表示名。入力画面では適用、直接保存では保存にする
    var applyTitleKey: LocalizedStringKey = "voice.apply"
    /// 適用時に呼ばれる。学習は親側で保存時にまとめて行うため、マッチ情報も含めて渡す
    let onApply: (VoiceApplyPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recognizer = SpeechRecognizer()
    /// 現在認識中フレーズのパース結果
    @State private var parsed: VoiceInputResult = VoiceInputResult()
    /// 確定済みコマンドの累積。フレーズ確定のたびに parsed をマージする
    @State private var accumulated: VoiceInputResult = VoiceInputResult()
    @State private var deniedReason: String?
    /// セグメント検出用 debounce。フレーズが落ち着いたタイミングで accumulated へ統合
    @State private var commitTask: Task<Void, Never>? = nil
    /// debounce 待ち時間（秒）。短すぎるとフレーズの途中で確定し、長すぎると次のコマンドが入り込む
    private let commitDebounceSeconds: Double = 1.4

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusArea
                voiceGuideArea
                if !currentTranscript.isEmpty || accumulated.hasAnyField {
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
            .task {
                await startListening()
            }
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
            // 手段は音声で検出された時だけ表示する（"決済手段/手段" + 候補マッチが必要）
            if cardActive {
                previewRow(label: "record.field.card", value: cardPreview, color: .accentColor)
            }
            previewRow(label: "record.field.usePoint", value: labelPreview, color: labelActive ? .accentColor : .secondary)
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
                Task { await startListening() }
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

    /// 音声で値が設定されたフィールドはアクセントカラーで強調
    private var amountActive: Bool { merged.amount != nil }
    private var cardActive: Bool { merged.card != nil }
    private var labelActive: Bool { merged.label != nil }

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
        let r = VoiceInputParser.parse(text, cards: cards)
        parsed = r
        // 何らかのコマンドが検出されたら、debounce 経過後に accumulated へ統合し
        // 認識テキストをクリアして次のコマンドを待つ
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
        Self.merge(from: parsed, into: &accumulated)
        parsed = VoiceInputResult()
        commitTask = nil
        // 認識中なら再起動して transcript を空にする。停止中なら何もしない
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

    private func apply() {
        commitTask?.cancel()
        commitTask = nil
        if case .listening = recognizer.state {
            recognizer.stop()
            updateParsed()
        }
        // 最終フレーズを accumulated へ統合
        Self.merge(from: parsed, into: &accumulated)
        let m = accumulated

        let payload = VoiceApplyPayload(
            amount: m.amount,
            card: m.card,
            label: m.label,
            matchedToken: m.matchedToken,
            matchedWasExistingAlias: m.matchedWasExistingAlias
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
