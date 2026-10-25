import AVFoundation
import Foundation
import Observation
import Speech

/// Records the microphone to an `.m4a` in the asset store. Keeps recording with the screen locked (background audio).
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    /// Input level, 0…1, for the meter.
    private(set) var level: Float = 0
    private(set) var fileURL: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw TranscriptionError.noMicrophone
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let url = AssetStore.newFileURL(ext: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw TranscriptionError.recordingFailed }
        recorder = r
        fileURL = url
        isRecording = true
        isPaused = false
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func togglePause() {
        guard let recorder else { return }
        if isPaused { recorder.record() } else { recorder.pause() }
        isPaused.toggle()
    }

    /// Stop and return the file.
    @discardableResult
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        if let recorder { elapsed = recorder.currentTime }
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return fileURL
    }

    /// Stop and delete the file.
    func discard() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        elapsed = 0
    }

    private func tick() {
        guard let recorder, recorder.isRecording || isPaused else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = isPaused ? 0 : max(0, min(1, (db + 55) / 55))
        elapsed = recorder.currentTime
    }
}

enum TranscriptionError: LocalizedError {
    case noMicrophone
    case recordingFailed
    case unavailable
    case unsupportedLanguage(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Synapse needs microphone access to record. Allow it in Settings › Synapse."
        case .recordingFailed: return "Recording couldn't start."
        case .unavailable: return "On-device transcription isn't available on this iPhone."
        case .unsupportedLanguage(let l): return "On-device transcription doesn't support \(l) yet."
        case .empty: return "No speech was found in the recording."
        }
    }
}

/// On-device speech-to-text with Apple's SpeechAnalyzer (iOS 26). Works offline once the language is downloaded.
enum Transcriber {
    /// Languages the on-device transcriber supports, by display name.
    static func supportedLocales() async -> [Locale] {
        let all = await SpeechTranscriber.supportedLocales
        return all.sorted { name(of: $0) < name(of: $1) }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The best supported locale for the user's language.
    static func defaultLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    /// Transcribe a whole file. Paragraphs break at pauses longer than a second and a half.
    /// - Parameter progress: a phase label and a 0…1 fraction when known; called on the main actor.
    static func transcribe(_ url: URL, locale wanted: Locale,
                           progress: @escaping @MainActor (String, Double?) -> Void) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriptionError.unsupportedLanguage(name(of: wanted))
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // The first time a language is used, iOS downloads its speech model.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let label = "Downloading the \(name(of: locale)) speech model…"
            await progress(label, 0)
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    progress(label, request.progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / max(1, file.processingFormat.sampleRate)
        await progress("Transcribing on device…", 0)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text = collect(transcriber, duration: duration, progress: progress)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let result = try await text
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TranscriptionError.empty }
        return result
    }

    private static func collect(_ transcriber: SpeechTranscriber, duration: Double,
                                progress: @escaping @MainActor (String, Double?) -> Void) async throws -> String {
        var paragraphs: [String] = []
        var current = ""
        var lastEnd = 0.0
        for try await result in transcriber.results where result.isFinal {
            let piece = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let start = result.range.start.seconds
            if !current.isEmpty && (start - lastEnd > 1.5 || current.count > 700) {
                paragraphs.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : " " + piece
            lastEnd = result.range.end.seconds
            if duration > 0 {
                let fraction = min(1, lastEnd / duration)
                await progress("Transcribing on device…", fraction)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }
}
