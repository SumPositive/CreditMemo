import Foundation
@preconcurrency import Speech
import AVFoundation

/// 認識語の時刻から、間を置いて話された発話へ分割する
enum SpeechTranscriptSegmenter {
    struct Segment: Sendable {
        let range: NSRange
        let timestamp: TimeInterval
        let duration: TimeInterval
    }

    /// 通常の語間より長い無音を、言い直しの区切りとして扱う。
    ///
    /// 一続きの発話の語間は 0.1〜0.2 秒程度なのに対し、
    /// 言い直しで置く間は 0.4 秒以上になることが多い。
    /// ここが長すぎると「スーパー（間）カフェ」が 1 つの発話として連結され、
    /// ラベルが上書きされずに追記されてしまう
    static let restatementPause: TimeInterval = 0.4

    /// 認識結果のタイムスタンプが使えるか。
    ///
    /// 部分認識では timestamp / duration が全て 0 で届くことがあり、
    /// そのときは語間を計算できない（無音がどれだけ長くても分割されない）。
    /// 呼び出し側はこれを見て、実時間ベースの分割へ切り替える
    static func hasUsableTimestamps(_ segments: [Segment]) -> Bool {
        segments.contains { 0 < $0.timestamp || 0 < $0.duration }
    }

    /// タイムスタンプが使えないときに、認識更新の実時間の間隔で発話を区切る。
    ///
    /// 部分認識は話している間ほぼ連続で届くので、更新が途切れた＝間を置いた、とみなせる。
    /// 更新のたびに `append` を呼び、区切り済みの発話の並びを受け取る
    struct WallClockSplitter {
        private var lastUpdate: Date?
        private var lastText = ""
        /// 区切り終えた発話
        private var phrases: [String] = []
        /// 区切り終えた部分に対応する認識テキストの先頭（ここから後ろが未確定）
        private var closedPrefix = ""

        init() {}

        mutating func reset() {
            self = WallClockSplitter()
        }

        mutating func append(_ formatted: String, at now: Date = Date()) -> [String] {
            let previousUpdate = lastUpdate
            let previousText = lastText
            lastUpdate = now
            lastText = formatted

            guard !formatted.isEmpty else { return [] }
            // 直前の結果を引き継いでいない（認識が作り直された）場合は区切りを諦める
            guard let previousUpdate, formatted.hasPrefix(closedPrefix) else {
                return [formatted]
            }
            // 間が空いた後に「新しい語」が足されていれば、そこまでを 1 つの発話として確定する。
            //
            // 認識は "食" → "食費" のように語の途中でも伸びるので、単に文字が増えたかで
            // 判定すると単語が割れてしまう（"食費" が "食" と "費" になる）。
            // 新しい語は必ず区切り（空白）を挟んで足されるので、それを条件にする
            let appended = String(formatted.dropFirst(previousText.count))
            let startsNewWord = previousText.count < formatted.count
                && appended.first?.isWhitespace == true
            if restatementPause <= now.timeIntervalSince(previousUpdate), startsNewWord {
                let closed = String(previousText.dropFirst(closedPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !closed.isEmpty {
                    phrases.append(closed)
                    closedPrefix = previousText
                }
            }
            let tail = String(formatted.dropFirst(closedPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? phrases : phrases + [tail]
        }
    }

    static func split(
        _ text: String,
        segments: [Segment],
        pause: TimeInterval = restatementPause
    ) -> [String] {
        guard let first = segments.first else {
            return text.isEmpty ? [] : [text]
        }

        let source = text as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        var results: [String] = []
        var phraseStart = first.range.location
        var phraseEnd = NSMaxRange(first.range)
        var previousEndTime = first.timestamp + first.duration

        for segment in segments.dropFirst() {
            if pause <= segment.timestamp - previousEndTime {
                appendPhrase(
                    from: source,
                    range: NSRange(location: phraseStart, length: phraseEnd - phraseStart),
                    sourceRange: sourceRange,
                    to: &results
                )
                phraseStart = segment.range.location
            }
            phraseEnd = NSMaxRange(segment.range)
            previousEndTime = segment.timestamp + segment.duration
        }

        appendPhrase(
            from: source,
            range: NSRange(location: phraseStart, length: phraseEnd - phraseStart),
            sourceRange: sourceRange,
            to: &results
        )
        return results
    }

    private static func appendPhrase(
        from source: NSString,
        range: NSRange,
        sourceRange: NSRange,
        to results: inout [String]
    ) {
        let validRange = NSIntersectionRange(range, sourceRange)
        guard validRange.length != 0 else { return }
        let phrase = source.substring(with: validRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrase.isEmpty {
            results.append(phrase)
        }
    }
}

/// SFSpeechRecognizer のロケール対応ラッパー
/// パーシャル結果をリアルタイムに更新し、停止時に最終結果を確定する
@MainActor
@Observable
final class SpeechRecognizer {
    enum State: Equatable {
        case idle
        case authorizing
        case listening
        case stopped
        case denied(reason: String)
    }

    private(set) var state: State = .idle
    /// 認識中のパーシャル結果。停止時に transcript へ反映
    private(set) var partialTranscript: String = ""
    /// 停止後の確定テキスト
    private(set) var transcript: String = ""
    /// 少し間を置いて話された単位へ分けた認識結果
    private(set) var pauseSeparatedTranscripts: [String] = []

    let locale: Locale
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// タイムスタンプが使えないときの実時間ベース分割用
    private var wallClockSplitter = SpeechTranscriptSegmenter.WallClockSplitter()
    private let audioEngine = AVAudioEngine()

    /// 端末ロケールで初期化。サポート外なら recognizer が nil で isAvailable = false
    init(locale: Locale = .current) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }


    var isAvailable: Bool { recognizer?.isAvailable == true }

    /// 指定ロケールで音声認識が使えるか。端末・iOS バージョン依存
    /// SFSpeechRecognizer の init は未対応ロケールで nil を返すので、それで判定する
    static func supports(_ locale: Locale = .current) -> Bool {
        SFSpeechRecognizer(locale: locale) != nil
    }

    /// 認識を開始。contextualStrings はカード名・エイリアスなどの語彙ヒントを渡す
    func start(contextualStrings: [String]) async {
        state = .authorizing
        let micGranted = await requestMicAuthorization()
        guard micGranted else {
            state = .denied(reason: "microphone")
            return
        }
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            state = .denied(reason: "speech")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .denied(reason: "unavailable")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = contextualStrings
        req.taskHint = .dictation
        request = req

        // Siri 起動直後は Siri 側が音声リソースを握っているため beginAudio が失敗しやすい
        // バックオフ付きで複数回リトライする
        var audioStarted = false
        let backoffsNs: [UInt64] = [0, 400_000_000, 900_000_000, 1_500_000_000]
        for (i, delay) in backoffsNs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                try beginAudio(into: req)
                audioStarted = true
                break
            } catch {
                if i == backoffsNs.count - 1 {
                    state = .denied(reason: "audio")
                    return
                }
            }
        }
        guard audioStarted else { return }

        partialTranscript = ""
        transcript = ""
        pauseSeparatedTranscripts = []
        wallClockSplitter.reset()
        state = .listening

        // 認識タスクのコールバックも非メインスレッドから呼ばれる
        // @Sendable で MainActor 隔離を外し、内部で Task { @MainActor } でホップする
        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let isFinal = result?.isFinal == true
            let formatted = result?.bestTranscription.formattedString
            let segments = result?.bestTranscription.segments.map {
                SpeechTranscriptSegmenter.Segment(
                    range: $0.substringRange,
                    timestamp: $0.timestamp,
                    duration: $0.duration
                )
            } ?? []
            // タイムスタンプが使えるときはそれで分ける。
            // 使えない（全て 0）ときは実時間ベースへ切り替えるので、ここでは分けない
            let canUseTimestamps = SpeechTranscriptSegmenter.hasUsableTimestamps(segments)
            let pauseSeparated = canUseTimestamps
                ? formatted.map { SpeechTranscriptSegmenter.split($0, segments: segments) } ?? []
                : []
            let hasError = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let formatted {
                    self.pauseSeparatedTranscripts = canUseTimestamps
                        ? pauseSeparated
                        : self.wallClockSplitter.append(formatted)
                    self.partialTranscript = formatted
                    if isFinal { self.transcript = formatted }
                }
                if hasError || isFinal {
                    self.tearDownAudio()
                    if self.state == .listening { self.state = .stopped }
                }
            }
        }
    }

    /// 手動停止。パーシャル結果を transcript に確定する
    func stop() {
        if transcript.isEmpty { transcript = partialTranscript }
        tearDownAudio()
        state = .stopped
    }

    // MARK: - Audio

    private func beginAudio(into req: SFSpeechAudioBufferRecognitionRequest) throws {
        let session = AVAudioSession.sharedInstance()
        // Siri 直後など、前のセッション状態が残っているとフォーマットが不正になることがあるため
        // 一度解除してから設定し直す
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // inputNode へのアクセスでエンジンに lazy にノードが作られる
        // この前に prepare を呼ぶと inputNode/outputNode が nullptr でクラッシュする
        let input = audioEngine.inputNode
        audioEngine.prepare()

        let format = input.outputFormat(forBus: 0)

        // sampleRate/channelCount が 0 だと installTap で
        // IsFormatSampleRateAndChannelCountValid アサーションでクラッシュする
        // フォーマット不正時は throw して .denied(reason: "audio") に落とす
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "SpeechRecognizer.audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format (sr=\(format.sampleRate) ch=\(format.channelCount))"]
            )
        }

        // タップは音声スレッドから呼ばれるため、@Sendable で MainActor 隔離を外す
        // Speech のリクエストを直接 capture せず、Sendable ラッパー経由で渡す
        let requestBox = SpeechAudioRequestBox(req)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            requestBox.append(buffer)
        }
        try audioEngine.start()
    }

    private func tearDownAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permissions
    // システム API のコールバックは非メインスレッドから呼ばれるため、nonisolated にして
    // MainActor 隔離のアサーションを避ける

    private nonisolated func requestMicAuthorization() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private nonisolated func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }
}

/// 音声タップの @Sendable クロージャへ Speech リクエストを渡すための薄い箱
private final class SpeechAudioRequestBox: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}
