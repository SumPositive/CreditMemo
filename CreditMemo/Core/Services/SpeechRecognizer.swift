import Foundation
@preconcurrency import Speech
import AVFoundation

/// SFSpeechRecognizer の ja-JP ラッパー
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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var isAvailable: Bool { recognizer?.isAvailable == true }

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

        do {
            try beginAudio(into: req)
        } catch {
            state = .denied(reason: "audio")
            return
        }

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
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // タップは音声スレッドから呼ばれるため、@Sendable で MainActor 隔離を外す
        // Speech のリクエストを直接 capture せず、Sendable ラッパー経由で渡す
        let requestBox = SpeechAudioRequestBox(req)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            requestBox.append(buffer)
        }
        audioEngine.prepare()
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
