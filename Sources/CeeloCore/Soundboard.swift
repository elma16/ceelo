import Foundation

public struct SoundboardTiming: Equatable {
    public var liveWindowSec: Double
    public var liveUpdateSec: Double
    public var minAudioSec: Double
    public var maxBufferSec: Double

    public init(liveWindowSec: Double, liveUpdateSec: Double, minAudioSec: Double, maxBufferSec: Double) {
        self.liveWindowSec = liveWindowSec
        self.liveUpdateSec = liveUpdateSec
        self.minAudioSec = minAudioSec
        self.maxBufferSec = maxBufferSec
    }

    /// Measured with ceelo-bench on an M4: with the speech gate, a 0.15s update fires about 130ms before the
    /// end of the spoken keyword on average (worst case ~70ms before) at ~13% Neural Engine time. 0.2s fires
    /// ~30ms later for ~10%; 0.1s ~25ms sooner for ~20%.
    public static let `default` = SoundboardTiming(
        liveWindowSec: 2.0,
        liveUpdateSec: 0.15,
        minAudioSec: 0.4,
        maxBufferSec: 6.0
    )

    /// The model can recognise a word from a fragment at either edge of the window, so a spoken phrase can
    /// show up in transcripts for up to a window plus the phrase's own length. One extra second covers
    /// trigger phrases; with only the window length, a 10-minute run double-fired 3 of 39 times.
    public var refireGuardSec: TimeInterval {
        liveWindowSec + 1.0
    }

    public func sanitized() -> SoundboardTiming {
        let window = max(0.5, liveWindowSec)
        return SoundboardTiming(
            liveWindowSec: window,
            liveUpdateSec: max(0.1, liveUpdateSec),
            minAudioSec: min(max(0.2, minAudioSec), window),
            maxBufferSec: max(window * 3.0, maxBufferSec)
        )
    }
}

/// What the live transcript display should show.
public enum LiveOutput: Equatable {
    /// Newly heard words, each reported once.
    case words(String)
    /// Speech stopped after some words were shown; a good place for a line break.
    case pause
}

/// One soundboard tick: take the latest window, skip it if it holds no speech, transcribe it and pass
/// the transcript to the handler. Ticks never overlap; a tick that arrives mid-transcription is dropped.
public final class SoundboardPipeline: @unchecked Sendable {
    public enum TickOutcome: Equatable {
        case paused
        case busy
        case tooShort
        case silent
        case transcribed(String)
        case failed(String)
    }

    private let handler: TranscriptHandler
    private let transcriber: SpeechTranscriber
    private let detector: SpeechDetector?
    private let clock: () -> Date
    private let onLive: ((LiveOutput) -> Void)?
    private let windowSamples: Int
    private let minSamples: Int
    private let buffer: RollingAudioBuffer
    private let lock = NSLock()
    private var isTranscribing = false
    private var pausedUntil: Date?
    private var tracker = LiveWordTracker()
    private var wordsSincePause = false

    public init(
        handler: TranscriptHandler,
        timing: SoundboardTiming,
        transcriber: SpeechTranscriber,
        detector: SpeechDetector? = nil,
        clock: @escaping () -> Date = Date.init,
        onLive: ((LiveOutput) -> Void)? = nil
    ) {
        self.handler = handler
        self.transcriber = transcriber
        self.detector = detector
        self.clock = clock
        self.onLive = onLive
        self.windowSamples = Int(timing.liveWindowSec * Double(asrSampleRate))
        self.minSamples = Int(timing.minAudioSec * Double(asrSampleRate))
        self.buffer = RollingAudioBuffer(capacity: Int(timing.maxBufferSec * Double(asrSampleRate)))
    }

    public func append(_ samples: [Float]) {
        guard !isPaused(at: clock()) else { return }
        buffer.append(samples)
    }

    /// Drops buffered audio and ignores the microphone for `duration`, e.g. while a sound plays.
    /// Overlapping pauses never shorten one already running.
    public func pauseRecording(for duration: TimeInterval) {
        let until = clock().addingTimeInterval(duration)
        lock.withLock { pausedUntil = max(pausedUntil ?? until, until) }
        buffer.removeAll()
    }

    public func tick() async -> TickOutcome {
        let now = clock()
        if isPaused(at: now) {
            return .paused
        }
        let began = lock.withLock { () -> Bool in
            if isTranscribing { return false }
            isTranscribing = true
            return true
        }
        guard began else { return .busy }
        defer { lock.withLock { isTranscribing = false } }

        let window = buffer.window(windowSamples)
        guard window.samples.count >= minSamples else { return .tooShort }

        do {
            if let detector, try await !detector.containsSpeech(window.samples) {
                endOfSpeech()
                return .silent
            }
            let transcript = try await transcriber.transcribe(window.samples)
            guard !transcript.text.isEmpty else {
                endOfSpeech()
                return .transcribed("")
            }

            let fresh = lock.withLock { () -> [String] in
                let fresh = tracker.newWords(in: transcript, window: window)
                wordsSincePause = wordsSincePause || !fresh.isEmpty
                return fresh
            }
            if !fresh.isEmpty {
                onLive?(.words(fresh.joined(separator: " ")))
            }
            handler.handle(text: transcript.text, at: clock())
            return .transcribed(transcript.text)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func endOfSpeech() {
        let hadWords = lock.withLock { () -> Bool in
            defer { wordsSincePause = false }
            return wordsSincePause
        }
        if hadWords {
            onLive?(.pause)
        }
    }

    private func isPaused(at now: Date) -> Bool {
        lock.withLock { pausedUntil.map { now < $0 } ?? false }
    }
}

/// Live microphone soundboard: feeds the mic into a `SoundboardPipeline` and ticks it on a timer.
final class RealtimeSoundboard {
    private let handler: TranscriptHandler
    private let timing: SoundboardTiming
    private let showTranscript: Bool
    private let environment: CeeloEnvironment
    private let microphone: AudioInput
    private let lock = NSLock()
    private var pipeline: SoundboardPipeline?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(
        handler: TranscriptHandler,
        timing: SoundboardTiming,
        showTranscript: Bool,
        environment: CeeloEnvironment
    ) {
        self.handler = handler
        self.timing = timing
        self.showTranscript = showTranscript
        self.environment = environment
        self.microphone = environment.makeAudioInput()
    }

    func pauseRecording(for duration: TimeInterval) {
        lock.withLock { pipeline }?.pauseRecording(for: duration)
    }

    /// Loads the models in the background, then starts listening. Failures terminate the process.
    func start() {
        Task {
            do {
                let runtime = try await environment.loadRuntime()
                let pipeline = SoundboardPipeline(
                    handler: handler,
                    timing: timing,
                    transcriber: runtime.transcriber,
                    detector: runtime.detector,
                    onLive: showTranscript ? printLiveOutput : nil
                )
                guard lock.withLock({ () -> Bool in
                    self.pipeline = pipeline
                    return !stopped
                }) else { return }
                try microphone.start { samples in
                    pipeline.append(samples)
                }
                print("Listening. Press Ctrl-C to stop.")
                startTimer(pipeline)
            } catch {
                print("Failed to start soundboard: \(error)")
                environment.terminate(1)
            }
        }
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            stopped = true
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        microphone.stop()
    }

    private func startTimer(_ pipeline: SoundboardPipeline) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timing.liveUpdateSec, repeating: timing.liveUpdateSec)
        timer.setEventHandler {
            Task {
                _ = await pipeline.tick()
            }
        }
        timer.resume()
        let alreadyStopped = lock.withLock { () -> Bool in
            if !stopped { self.timer = timer }
            return stopped
        }
        if alreadyStopped {
            timer.cancel()
            microphone.stop()
        }
    }
}

/// Prints the live transcript: words on one line, a new line whenever speech pauses.
func printLiveOutput(_ output: LiveOutput) {
    switch output {
    case .words(let words):
        print(words, terminator: " ")
    case .pause:
        print("")
    }
    fflush(stdout)
}
