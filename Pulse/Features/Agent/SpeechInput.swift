import Foundation
import AVFoundation
import Speech

/// Live dictation in Simplified Chinese. Uses on-device recognition when the device supports it,
/// so speech does not leave the phone.
@MainActor
@Observable
final class SpeechInput {
    var transcript = ""
    var isRecording = false
    var level: Float = 0
    var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var onDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        errorMessage = nil
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK else {
            errorMessage = "需要麦克风和语音识别权限。可以在「设置 › Pulse」中开启，或直接输入文字。"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "语音识别暂时不可用，请改用文字输入。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            req.addsPunctuation = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            transcript = ""
            isRecording = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.finish() }
                }
            }
        } catch {
            errorMessage = "无法开始录音：\(error.localizedDescription)"
            finish()
        }
    }

    /// Stops listening; the final transcript stays in `transcript`.
    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        finish()
    }

    private func finish() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.finish()
        task = nil
        request = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 8)
    }
}
