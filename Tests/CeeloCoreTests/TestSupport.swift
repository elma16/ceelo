import AVFoundation
import Foundation
import XCTest
@testable import CeeloCore

let t0 = Date(timeIntervalSinceReferenceDate: 0)

/// Thread-safe list for recording calls made from background tasks.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    var values: [T] {
        lock.withLock { items }
    }
}

final class RecordingPlayer: SoundPlaying {
    private(set) var played: [URL] = []

    func play(url: URL) {
        played.append(url)
    }

    var playedNames: [String] {
        played.map { $0.deletingPathExtension().lastPathComponent }
    }
}

final class RecordingHandler: TranscriptHandler {
    private(set) var texts: [String] = []
    private(set) var times: [Date] = []

    func handle(text: String, at now: Date) {
        texts.append(text)
        times.append(now)
    }
}

struct TranscriberFailure: Error {}

/// Returns scripted results in order, then `fallback` forever.
final class ScriptedTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<Transcript, Error>]
    private let fallback: Result<Transcript, Error>
    private let delay: TimeInterval
    private var recordedCalls: [[Float]] = []

    init(_ responses: [String], fallback: String = "", delay: TimeInterval = 0) {
        self.responses = responses.map { .success(Transcript(text: $0)) }
        self.fallback = .success(Transcript(text: fallback))
        self.delay = delay
    }

    init(transcripts: [Transcript]) {
        self.responses = transcripts.map { .success($0) }
        self.fallback = .success(Transcript(text: ""))
        self.delay = 0
    }

    init(results: [Result<String, Error>], fallback: Result<String, Error> = .success("")) {
        self.responses = results.map { $0.map { Transcript(text: $0) } }
        self.fallback = fallback.map { Transcript(text: $0) }
        self.delay = 0
    }

    var calls: [[Float]] {
        lock.withLock { recordedCalls }
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        let result = lock.withLock { () -> Result<Transcript, Error> in
            recordedCalls.append(samples)
            return responses.isEmpty ? fallback : responses.removeFirst()
        }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        }
        return try result.get()
    }
}

/// Blocks inside `transcribe` until `release()` is called.
final class GatedTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
        return Transcript(text: "gated")
    }

    func release() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }
}

final class FixedDetector: SpeechDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var isSpeech: Bool
    private var callCount = 0

    init(speech: Bool) {
        self.isSpeech = speech
    }

    var speech: Bool {
        get { lock.withLock { isSpeech } }
        set { lock.withLock { isSpeech = newValue } }
    }

    var calls: Int {
        lock.withLock { callCount }
    }

    func containsSpeech(_ samples: [Float]) async throws -> Bool {
        lock.withLock {
            callCount += 1
            return isSpeech
        }
    }
}

/// A mutable clock for code that takes `() -> Date`.
final class TestClock: @unchecked Sendable {
    var now = t0

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

struct MicrophoneFailure: Error {}

final class FakeAudioInput: AudioInput, @unchecked Sendable {
    private let lock = NSLock()
    private var onSamples: (([Float]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var failToStart = false

    var isRunning: Bool {
        lock.withLock { onSamples != nil }
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        try lock.withLock {
            startCount += 1
            if failToStart { throw MicrophoneFailure() }
            self.onSamples = onSamples
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            onSamples = nil
        }
    }

    func feed(_ samples: [Float]) {
        lock.withLock { onSamples }?(samples)
    }
}

/// A test environment with fakes everywhere; the speech runtime is whatever `loadRuntime` returns.
final class TestEnvironment: @unchecked Sendable {
    let audioInput = FakeAudioInput()
    let player = SoundPlayer()
    let terminated = Recorder<Int32>()
    var loadRuntime: () async throws -> SpeechRuntime

    init(transcriber: SpeechTranscriber = ScriptedTranscriber([]), detector: SpeechDetector = FixedDetector(speech: true)) {
        let runtime = SpeechRuntime(transcriber: transcriber, detector: detector)
        loadRuntime = { runtime }
        player.volume = 0
    }

    var environment: CeeloEnvironment {
        CeeloEnvironment(
            loadRuntime: { [self] in try await loadRuntime() },
            makeAudioInput: { [audioInput] in audioInput },
            makeSoundPlayer: { [player] in player },
            terminate: { [terminated] in terminated.append($0) }
        )
    }
}

/// A temporary directory, optionally with empty placeholder files; deleted when released.
final class TempSoundsDirectory {
    let url: URL

    init(files: [String] = []) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ceelo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            let fileURL = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    /// Writes a short sine tone, a real playable sound, at `name` inside the directory.
    @discardableResult
    func writeTone(_ name: String, seconds: Double = 0.25) throws -> URL {
        let url = self.url.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func write(_ name: String, contents: String) throws {
        try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("timed out waiting for condition", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

func pause(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

func seconds(_ value: Double) -> Int {
    Int(value * Double(asrSampleRate))
}
