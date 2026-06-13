import Foundation
@preconcurrency import Speech
import AVFoundation

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

    let locale: Locale
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
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
        state = .listening

        // 認識タスクのコールバックも非メインスレッドから呼ばれる
        // @Sendable で MainActor 隔離を外し、内部で Task { @MainActor } でホップする
        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let isFinal = result?.isFinal == true
            let formatted = result?.bestTranscription.formattedString
            let hasError = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let formatted {
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
