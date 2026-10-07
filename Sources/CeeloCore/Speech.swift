import FluidAudio
import Foundation

/// A word with its position in the transcribed audio, in seconds from the start of that audio.
public struct TimedWord: Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Equatable {
    public let text: String
    /// Empty when the transcriber doesn't provide timings.
    public let words: [TimedWord]

    public init(text: String, words: [TimedWord] = []) {
        self.text = text
        self.words = words
    }
}

/// Turns 16 kHz mono samples into text.
public protocol SpeechTranscriber: AnyObject {
    func transcribe(_ samples: [Float]) async throws -> Transcript
}

/// Cheap check for whether a window contains speech, used to skip ASR on silence.
public protocol SpeechDetector: AnyObject {
    func containsSpeech(_ samples: [Float]) async throws -> Bool
}

public let asrSampleRate = 16_000

/// FluidAudio rejects anything shorter than one second, so short windows are zero-padded up to this.
/// The model pads every input to 15s internally, so this costs nothing extra.
public let asrMinimumSamples = 16_000

public func peakNormalized(_ samples: [Float]) -> [Float] {
    var peak: Float = 0
    for sample in samples where abs(sample) > peak {
        peak = abs(sample)
    }
    guard peak > 1e-6 else { return samples }
    let scale = 1 / peak
    return samples.map { $0 * scale }
}

public func paddedForAsr(_ samples: [Float]) -> [Float] {
    guard samples.count < asrMinimumSamples else { return samples }
    return samples + [Float](repeating: 0, count: asrMinimumSamples - samples.count)
}

/// Parakeet TDT 0.6B v2 via FluidAudio.
///
/// `AsrManager` keeps one decoder state and resets it after every call, so calls must not overlap.
/// `SoundboardPipeline` never overlaps them.
public final class FluidSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let asr: AsrManager

    public init(asr: AsrManager) {
        self.asr = asr
    }

    public func transcribe(_ samples: [Float]) async throws -> Transcript {
        let result = try await asr.transcribe(paddedForAsr(peakNormalized(samples)), source: .microphone)
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words(from: result.tokenTimings ?? [])
        )
    }
}

/// Joins Parakeet's subword tokens into words; a token starting with a space (or "▁") starts a new word.
func words(from tokens: [TokenTiming]) -> [TimedWord] {
    var words: [TimedWord] = []
    for token in tokens {
        let startsWord = token.token.hasPrefix(" ") || token.token.hasPrefix("▁")
        let piece = token.token.trimmingCharacters(in: CharacterSet(charactersIn: " ▁"))
        guard !piece.isEmpty else { continue }
        if startsWord || words.isEmpty {
            words.append(TimedWord(text: piece, start: token.startTime, end: token.endTime))
        } else {
            let last = words.removeLast()
            words.append(TimedWord(text: last.text + piece, start: last.start, end: token.endTime))
        }
    }
    return words
}

/// Silero VAD via FluidAudio. Errs towards reporting speech: a false positive only costs one ASR call,
/// a false negative loses a trigger.
public final class FluidSpeechDetector: SpeechDetector, @unchecked Sendable {
    private let vad: VadManager
    private let threshold: Float

    public init(vad: VadManager, threshold: Float = 0.3) {
        self.vad = vad
        self.threshold = threshold
    }

    public func containsSpeech(_ samples: [Float]) async throws -> Bool {
        let results = try await vad.process(samples)
        return results.contains { $0.probability >= threshold }
    }
}

/// What the soundboard needs from the speech models.
public struct SpeechRuntime {
    public let transcriber: SpeechTranscriber
    public let detector: SpeechDetector

    public init(transcriber: SpeechTranscriber, detector: SpeechDetector) {
        self.transcriber = transcriber
        self.detector = detector
    }
}

public let asrModelVersion = AsrModelVersion.v2

public func speechModelsAreDownloaded() -> Bool {
    AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: asrModelVersion), version: asrModelVersion)
}

/// Loads Parakeet and Silero, downloading them on first use. Both cache under
/// ~/Library/Application Support/FluidAudio/Models.
public func loadFluidSpeechRuntime(status: (String) -> Void = { print($0) }) async throws -> SpeechRuntime {
    if !speechModelsAreDownloaded() {
        status("Downloading speech models (about 450 MB, first run only)...")
    }
    status("Loading speech models (the first run after an update compiles them, about 15s)...")
    let models = try await AsrModels.downloadAndLoad(version: asrModelVersion)
    let asr = AsrManager(config: .default)
    try await asr.initialize(models: models)
    let vad = try await VadManager(config: VadConfig(computeUnits: .cpuAndNeuralEngine))
    return SpeechRuntime(transcriber: FluidSpeechTranscriber(asr: asr), detector: FluidSpeechDetector(vad: vad))
}
