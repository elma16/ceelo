import AVFoundation
import Foundation

/// Converts device-format buffers to 16 kHz mono Float32 for ASR.
final class SampleRateConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, sampleRate: Double = Double(asrSampleRate)) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        // Hand the buffer over exactly once. Returning it again when the converter asks for more input
        // feeds the same audio twice.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum MicrophoneError: Error, CustomStringConvertible {
    case accessDenied
    case noInputDevice
    case unsupportedFormat(String)
    case engine(Error)

    var description: String {
        switch self {
        case .accessDenied:
            return """
            Microphone access is denied for the app running ceelo (e.g. Terminal or Visual Studio Code). \
            Allow it in System Settings > Privacy & Security > Microphone, then restart that app.
            """
        case .noInputDevice:
            return "No microphone input is available (the input device reports 0 channels at 0 Hz). "
                + "Check the input device in System Settings > Sound."
        case .unsupportedFormat(let format):
            return "Failed to create an audio converter for the microphone format \(format)."
        case .engine(let error):
            return "Failed to start audio engine: \(error)"
        }
    }
}

/// A live source of 16 kHz mono audio.
protocol AudioInput: AnyObject {
    func start(onSamples: @escaping ([Float]) -> Void) throws
    func stop()
}

/// Streams 16 kHz mono microphone audio.
final class MicrophoneCapture: AudioInput {
    private var engine: AVAudioEngine?

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        // Without access AVAudioEngine doesn't fail; it reports a 0 Hz device, so check first and say why.
        try Self.checkAccess(
            status: AVCaptureDevice.authorizationStatus(for: .audio),
            requestAccess: Self.requestAccessAndWait
        )

        let engine = AVAudioEngine()
        let input = engine.inputNode
        try Self.validate(deviceFormat: input.inputFormat(forBus: 0))

        // A tap on the input node must use the node's output format.
        let tapFormat = input.outputFormat(forBus: 0)
        guard let converter = SampleRateConverter(from: tapFormat) else {
            throw MicrophoneError.unsupportedFormat("\(tapFormat)")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty {
                onSamples(samples)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicrophoneError.engine(error)
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Asks for access the first time (macOS shows the prompt for the terminal app); fails if denied.
    static func checkAccess(status: AVAuthorizationStatus, requestAccess: () -> Bool) throws {
        switch status {
        case .authorized:
            return
        case .notDetermined:
            if !requestAccess() { throw MicrophoneError.accessDenied }
        default:
            throw MicrophoneError.accessDenied
        }
    }

    static func validate(deviceFormat: AVAudioFormat) throws {
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
            throw MicrophoneError.noInputDevice
        }
    }

    private static func requestAccessAndWait() -> Bool {
        let done = DispatchSemaphore(value: 0)
        let granted = GrantBox()
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            granted.value = allowed
            done.signal()
        }
        done.wait()
        return granted.value
    }
}

private final class GrantBox: @unchecked Sendable {
    var value = false
}

/// Thread-safe sample buffer that keeps at most `capacity` recent samples (trimmed in batches).
final class RollingAudioBuffer: @unchecked Sendable {
    /// The latest samples plus where they sit in everything ever appended.
    struct Window {
        let samples: [Float]
        /// Index, counted over all samples ever appended, just past the last sample in `samples`.
        let endPosition: Int
        /// True when older audio precedes the window, i.e. its first word may be cut off.
        let isCutOnTheLeft: Bool

        var startSeconds: TimeInterval {
            Double(endPosition - samples.count) / Double(asrSampleRate)
        }

        var endSeconds: TimeInterval {
            Double(endPosition) / Double(asrSampleRate)
        }
    }

    private var samples: [Float] = []
    private var totalAppended = 0
    private let capacity: Int?
    private let lock = NSLock()

    init(capacity: Int? = nil) {
        self.capacity = capacity
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        totalAppended += chunk.count
        if let capacity, samples.count > capacity * 2 {
            samples.removeFirst(samples.count - capacity)
        }
        lock.unlock()
    }

    func latest(_ count: Int) -> [Float] {
        window(count).samples
    }

    func window(_ count: Int) -> Window {
        lock.lock()
        defer { lock.unlock() }
        return Window(
            samples: Array(samples.suffix(count)),
            endPosition: totalAppended,
            isCutOnTheLeft: samples.count > count
        )
    }

    func all() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Drops buffered audio. Positions keep counting, so later windows never overlap earlier ones.
    func removeAll() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// Picks the words of each overlapping live window that haven't been printed yet, so every spoken word
/// prints once. Successive windows transcribe the same words with slightly different text and with
/// timestamps that drift by up to ~0.3s as more context arrives, so a word counts as already printed
/// when a printed word with the same text started close to it.
struct LiveWordTracker {
    /// Words this close to a cut window edge may be fragments ("uneral" for "funeral").
    var leftEdgeMarginSec: TimeInterval = 0.24
    /// Words ending this close to the newest audio may still change; they print on a later tick.
    var holdBackSec: TimeInterval = 0.32
    /// How far the same word's start time may move between windows.
    var sameWordToleranceSec: TimeInterval = 0.5
    /// Timestamps are quantised to encoder frames of 80ms.
    private let frameSec: TimeInterval = 0.08

    private struct PrintedWord {
        let key: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private var printed: [PrintedWord] = []

    mutating func newWords(in transcript: Transcript, window: RollingAudioBuffer.Window) -> [String] {
        var fresh: [String] = []
        for word in transcript.words {
            let start = window.startSeconds + word.start
            let end = window.startSeconds + word.end
            if window.isCutOnTheLeft && start < window.startSeconds + leftEdgeMarginSec {
                continue
            }
            if end > window.endSeconds - holdBackSec {
                break
            }
            let key = normalizeText(word.text)
            if printed.contains(where: { Self.sameWord($0.key, key) && abs($0.start - start) <= sameWordToleranceSec }) {
                continue
            }
            // A different word placed before what's already printed is a revision of the past; skip it.
            if let last = printed.last, start < last.end - frameSec {
                continue
            }
            fresh.append(word.text)
            printed.append(PrintedWord(key: key, start: start, end: end))
        }

        let horizon = window.startSeconds - sameWordToleranceSec
        if let last = printed.last {
            printed.removeAll { $0.end < horizon }
            if printed.isEmpty { printed = [last] }
        }
        return fresh
    }

    private static func sameWord(_ a: String, _ b: String) -> Bool {
        a == b || (min(a.count, b.count) >= 4 && withinEditDistance(a, b, maxDistance: 1))
    }
}
