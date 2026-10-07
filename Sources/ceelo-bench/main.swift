import AVFoundation
import CeeloCore
import FluidAudio
import Foundation

// Benchmarks for the ceelo pipeline. Speech is generated with `say` into a temporary directory that is
// deleted on exit, so no audio files are needed or written to the repo.
// Run with: swift run -c release ceelo-bench [--iterations N] [--load-only]

let iterations = argumentInt("--iterations") ?? 15
let warmup = 3

enum BenchError: Error {
    case say(String)
    case audio(String)
}

func argumentInt(_ name: String) -> Int? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let value = try await work()
    return (value, milliseconds(ContinuousClock.now - start))
}

struct Stats {
    let median: Double
    let p95: Double
    let min: Double

    init(_ samples: [Double]) {
        let s = samples.sorted()
        median = s[s.count / 2]
        p95 = s[Swift.min(s.count - 1, Int(Double(s.count) * 0.95))]
        min = s[0]
    }

    var summary: String {
        String(format: "median %7.1f ms   p95 %7.1f ms   min %7.1f ms", median, p95, min)
    }
}

func samples(seconds: Double) -> Int {
    Int(seconds * Double(asrSampleRate))
}

func synthesize(_ text: String, in dir: URL, name: String) throws -> [Float] {
    let url = dir.appendingPathComponent("\(name).wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-o", url.path, "--data-format=LEF32@\(asrSampleRate)", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BenchError.say(text) }

    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == Double(asrSampleRate),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw BenchError.audio("unexpected format for \(url.path)") }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// Deterministic low-level gaussian noise, roughly a quiet room through a laptop mic.
func roomNoise(seconds: Double, amplitude: Float = 0.002, seed: UInt64) -> [Float] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
    return (0..<samples(seconds: seconds)).map { _ in
        let u1 = max(next(), 1e-7)
        let u2 = next()
        return amplitude * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

final class CountingPlayer: SoundPlaying {
    var hits = 0

    func play(url: URL) {
        hits += 1
    }
}

final class SimulatedClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

// MARK: - Setup

let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ceelo-bench-\(getpid())")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

let paragraphText = """
    The quarterly report is due on Friday, so please send your numbers to the finance team before Thursday \
    afternoon. After that we will review the budget, discuss the hiring plan for next year, and decide \
    whether the new office should open in the spring or wait until the autumn.
    """
let paragraph = try synthesize(paragraphText, in: workDir, name: "paragraph")
// `say` pads clips with trailing silence; trim it so the keyword end marker is accurate.
let keywordLead = Array(
    try synthesize("Okay everyone, heads up, new ticket", in: workDir, name: "lead")
        .reversed().drop { abs($0) < 0.01 }.reversed()
)
let keywordTail = try synthesize("just came in from the support queue.", in: workDir, name: "tail")
try? FileManager.default.removeItem(at: workDir)
print(String(format: "Synthesised %.1fs paragraph and %.1fs keyword clip. Iterations per case: %d",
             Double(paragraph.count) / Double(asrSampleRate),
             Double(keywordLead.count + keywordTail.count) / Double(asrSampleRate), iterations))

// MARK: - 1. Model load

section("1. Runtime load (models already on disk)")
let (runtime, loadMs) = try await timed {
    try await loadFluidSpeechRuntime(status: { _ in })
}
let transcriber = runtime.transcriber
let detector = runtime.detector
let (_, firstAsrMs) = try await timed { try await transcriber.transcribe(Array(paragraph.prefix(samples(seconds: 2)))) }
print(String(format: "load: %.0f ms, then first transcription: %.0f ms", loadMs, firstAsrMs))
if CommandLine.arguments.contains("--load-only") { exit(0) }

// MARK: - 2. ASR latency vs window length

section("2. ASR latency vs window length (speech)")
var longSpeech = paragraph
while longSpeech.count < samples(seconds: 20) { longSpeech += paragraph }
for seconds in [0.5, 1.0, 2.0, 4.0, 6.0, 10.0, 15.0, 20.0] {
    let window = Array(longSpeech.prefix(samples(seconds: seconds)))
    var times: [Double] = []
    for i in 0..<(warmup + iterations) {
        let (_, ms) = try await timed { try await transcriber.transcribe(window) }
        if i >= warmup { times.append(ms) }
    }
    print(String(format: "%5.1fs window: %@", seconds, Stats(times).summary))
}

// MARK: - 3. VAD gate

section("3. VAD gate: cost and accuracy on 2s windows")
var vadTimes: [Double] = []
let vadWindow = Array(paragraph.prefix(samples(seconds: 2)))
for i in 0..<(warmup + iterations) {
    let (_, ms) = try await timed { try await detector.containsSpeech(vadWindow) }
    if i >= warmup { vadTimes.append(ms) }
}
print("cost: \(Stats(vadTimes).summary)")

let speechWindows = stride(from: 0, to: paragraph.count - samples(seconds: 2), by: samples(seconds: 0.5)).map {
    Array(paragraph[$0..<($0 + samples(seconds: 2))])
}
for gain: Float in [1, 0.05, 0.01] {
    var detected = 0
    for window in speechWindows {
        let quiet = zip(window, roomNoise(seconds: 2, seed: 7)).map { $0 * gain + $1 }
        if try await detector.containsSpeech(quiet) { detected += 1 }
    }
    print(String(format: "speech at gain %.2f + room noise: %d/%d windows detected", gain, detected, speechWindows.count))
}
var falseAlarms = 0
for seed in 0..<20 where try await detector.containsSpeech(roomNoise(seconds: 2, seed: UInt64(seed + 1))) {
    falseAlarms += 1
}
print("room noise only: \(falseAlarms)/20 windows flagged as speech")

// MARK: - 4. Silence hallucinations

section("4. Transcripts produced from 2s of room noise (no speech, no VAD)")
var hallucinations: [String] = []
for seed in 0..<10 {
    let text = try await transcriber.transcribe(roomNoise(seconds: 2, seed: UInt64(seed + 1))).text
    if !text.isEmpty { hallucinations.append(text) }
}
print("\(hallucinations.count)/10 windows produced text \(hallucinations.prefix(3))")

// MARK: - 5. End-to-end soundboard simulation

section("5. Soundboard simulation: \"new ticket\" spoken once, then 6s of silence")

struct SimulationResult {
    var latencies: [Double] = []
    var missed = 0
    var doubleFires = 0
    var computeMs = 0.0
    var audioSec = 0.0
    var asrCalls = 0
    var ticks = 0
}

/// Replays a stream through the real SoundboardPipeline + RuleEngine on a simulated clock, ticking
/// every `update` seconds and skipping ticks while a transcription is in flight, as the live timer does.
/// Every scenario sees the same keyword offsets, spread evenly over the slowest update interval (0.35s),
/// so differences come from the settings rather than from where the ticks happened to land.
@MainActor
func simulate(timing: SoundboardTiming, vad: Bool, refireGuard: Bool, phases: Int = 21) async throws -> SimulationResult {
    var result = SimulationResult()
    for phase in 0..<phases {
        let lead = roomNoise(seconds: 3 + 0.35 * Double(phase) / Double(phases), seed: 99)
        let stream = lead + keywordLead + keywordTail + roomNoise(seconds: 6, seed: 100)
        let keywordEnd = Double(lead.count + keywordLead.count) / Double(asrSampleRate)

        let clock = SimulatedClock()
        let player = CountingPlayer()
        let matcher = RuleEngine(
            rules: [SoundRule(sound: URL(fileURLWithPath: "/dev/null"), say: ["new ticket"])],
            player: player,
            refireGuardSec: refireGuard ? timing.refireGuardSec : 0
        )
        let pipeline = SoundboardPipeline(
            handler: matcher,
            timing: timing,
            transcriber: transcriber,
            detector: vad ? detector : nil,
            clock: { clock.now }
        )

        var fed = 0
        var now = timing.liveUpdateSec
        var latency: Double?
        let end = Double(stream.count) / Double(asrSampleRate)
        while now <= end {
            let target = min(stream.count, samples(seconds: now))
            pipeline.append(Array(stream[fed..<target]))
            fed = target
            clock.now = Date(timeIntervalSinceReferenceDate: now)

            let hitsBefore = player.hits
            let (outcome, ms) = await timed { await pipeline.tick() }
            result.ticks += 1
            result.computeMs += ms
            if case .transcribed = outcome { result.asrCalls += 1 }
            if latency == nil, player.hits > hitsBefore {
                latency = now + ms / 1000 - keywordEnd
            }
            now += timing.liveUpdateSec * max(1, (ms / 1000 / timing.liveUpdateSec).rounded(.up))
        }

        result.audioSec += end
        if let latency { result.latencies.append(latency * 1000) } else { result.missed += 1 }
        if player.hits > 1 { result.doubleFires += 1 }
    }
    return result
}

print("latency is relative to the end of \"ticket\" (negative = fired before the word fully ended)")
print("busy = compute time / audio time; ASR calls are per run")
let scenarios: [(String, SoundboardTiming, Bool, Bool)] = [
    ("previous defaults (0.35s, 1s min, no VAD/guard)",
     SoundboardTiming(liveWindowSec: 2.0, liveUpdateSec: 0.35, minAudioSec: 1.0, maxBufferSec: 6.0), false, false),
    ("update 0.20s, no VAD", SoundboardTiming(liveWindowSec: 2.0, liveUpdateSec: 0.2, minAudioSec: 0.4, maxBufferSec: 6.0), false, true),
    ("update 0.20s + VAD", SoundboardTiming(liveWindowSec: 2.0, liveUpdateSec: 0.2, minAudioSec: 0.4, maxBufferSec: 6.0), true, true),
    ("update 0.15s + VAD (default)", SoundboardTiming.default, true, true),
    ("update 0.10s + VAD", SoundboardTiming(liveWindowSec: 2.0, liveUpdateSec: 0.1, minAudioSec: 0.4, maxBufferSec: 6.0), true, true),
]
for (name, timing, vad, refireGuard) in scenarios {
    let r = try await simulate(timing: timing.sanitized(), vad: vad, refireGuard: refireGuard)
    let mean = r.latencies.isEmpty ? Double.nan : r.latencies.reduce(0, +) / Double(r.latencies.count)
    let runs = r.latencies.count + r.missed
    print(String(
        format: "%@ mean %5.0f ms  worst %5.0f ms  missed %d/%d  double-fires %d  busy %4.1f%%  ASR calls %3d",
        name.padding(toLength: 50, withPad: " ", startingAt: 0), mean, r.latencies.max() ?? .nan, r.missed, runs, r.doubleFires,
        100 * r.computeMs / 1000 / r.audioSec, r.asrCalls / max(1, runs)
    ))
}

// MARK: - 6. Non-ASR overhead per tick

section("6. Non-ASR overhead per tick")
let buffer12s = Array(longSpeech.prefix(samples(seconds: 12)))
let (_, snapshotMs) = await timed { () -> Int in
    var total = 0
    for _ in 0..<100 { total += paddedForAsr(peakNormalized(Array(buffer12s.suffix(samples(seconds: 2))))).count }
    return total
}
print(String(format: "window snapshot + normalise + pad: %.3f ms/tick", snapshotMs / 100))

let matchPlayer = CountingPlayer()
let matcher = RuleEngine(
    rules: ["new ticket", "airhorn", "soft bell", "boom", "wow"].map {
        SoundRule(sound: URL(fileURLWithPath: "/dev/null"), say: [$0])
    },
    player: matchPlayer
)
let transcript = "okay everyone heads up new ticket just came in from the support queue so please take a look"
let (_, matchMs) = await timed {
    for i in 0..<10_000 {
        matcher.handle(text: transcript, at: Date(timeIntervalSinceReferenceDate: Double(i)))
    }
}
print(String(format: "keyword matching (5 sounds): %.4f ms/transcript", matchMs / 10_000))

// MARK: - 8 (optional). Long run

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : .nan
}

/// Continuous speech through the real pipeline, ticking back to back (harsher than live use, where the
/// Neural Engine idles ~80% of the time). Reports whether tick time or memory drift as the run goes on.
@MainActor
func longRun(minutes: Int) async throws {
    section("8. Long run: \(minutes) min of continuous speech, ticks back to back")
    var stream: [Float] = []
    var seed: UInt64 = 1
    while stream.count < samples(seconds: Double(minutes) * 60) {
        stream += paragraph + roomNoise(seconds: 0.5, seed: seed)
        seed += 1
    }

    let clock = SimulatedClock()
    let player = CountingPlayer()
    let matcher = RuleEngine(
        rules: [SoundRule(sound: URL(fileURLWithPath: "/dev/null"), say: ["budget"])],
        player: player,
        refireGuardSec: SoundboardTiming.default.refireGuardSec
    )
    var printedWords = 0
    var printedLines = 0
    var sample: [String] = []
    let pipeline = SoundboardPipeline(
        handler: matcher,
        timing: .default,
        transcriber: transcriber,
        detector: detector,
        clock: { clock.now },
        onLive: { output in
            switch output {
            case .words(let words):
                printedWords += words.split(separator: " ").count
                if sample.count < 100 { sample.append(words) }
            case .pause: printedLines += 1
            }
        }
    )

    let update = SoundboardTiming.default.liveUpdateSec
    var fed = 0
    var now = update
    var minute = 0
    var tickTimes: [Double] = []
    print("minute   ticks   median tick   p95 tick   resident memory   triggers")
    while fed < stream.count {
        let target = min(stream.count, samples(seconds: now))
        pipeline.append(Array(stream[fed..<target]))
        fed = target
        clock.now = Date(timeIntervalSinceReferenceDate: now)
        let (_, ms) = await timed { await pipeline.tick() }
        tickTimes.append(ms)
        now += update

        if Int(now / 60) > minute || fed == stream.count {
            minute += 1
            let stats = Stats(tickTimes)
            print(String(format: "%6d   %5d   %8.1f ms   %6.1f ms   %10.0f MB   %8d",
                         minute, tickTimes.count, stats.median, stats.p95, residentMB(), player.hits))
            tickTimes = []
        }
    }
    let paragraphs = stream.count / (paragraph.count + samples(seconds: 0.5))
    let spokenWords = paragraphs * paragraphText.split(separator: " ").count
    print("live transcript: printed \(printedWords) words in \(printedLines) lines for \(spokenWords) spoken; "
        + "\(player.hits) triggers for \(paragraphs) spoken \"budget\"")
    print("first words printed: \(sample.joined(separator: " ").split(separator: " ").prefix(100).joined(separator: " "))")
    print("spoken (repeating):  \(paragraphText)")
}

if let minutes = argumentInt("--long-run") {
    try await longRun(minutes: minutes)
    exit(0)
}

// MARK: - 7. Sound playback

section("7. Time for play() to return, per sound (muted)")
let soundsDir = URL(fileURLWithPath: "sounds")
if FileManager.default.fileExists(atPath: soundsDir.path) {
    let urls = listSoundFiles(in: soundsDir)
    if urls.isEmpty {
        print("no playable sounds in \(soundsDir.path)")
    } else {
        let cold = SoundPlayer()
        cold.volume = 0
        var coldTimes: [Double] = []
        for url in urls {
            let (_, ms) = await timed { cold.play(url: url) }
            coldTimes.append(ms)
        }

        let preloaded = SoundPlayer()
        preloaded.volume = 0
        let (_, preloadMs) = await timed {
            preloaded.preload(urls)
            preloaded.warmUp()
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        var warmTimes: [Double] = []
        for url in urls {
            let (_, ms) = await timed { preloaded.play(url: url) }
            warmTimes.append(ms)
        }
        print("decode on hit (previous): \(Stats(coldTimes).summary)")
        print("preloaded + warmed (new): \(Stats(warmTimes).summary)")
        print(String(format: "one-off preload of %d sounds at startup: %.0f ms", urls.count, preloadMs))
    }
} else {
    print("no sounds directory found; skipping")
}
