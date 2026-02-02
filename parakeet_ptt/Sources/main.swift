import Foundation
import AVFoundation
import AppKit
import Quartz
import FluidAudio

func runWavTranscription(_ wavPath: String) {
    let url = URL(fileURLWithPath: wavPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fputs("WAV not found: \(wavPath)\n", stderr)
        exit(1)
    }

    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let models = try await AsrModels.downloadAndLoad()
            let mgr = AsrManager(config: .default)
            try await mgr.initialize(models: models)
            let result = try await mgr.transcribe(url, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                print(text)
            }
        } catch {
            fputs("Transcription error: \(error)\n", stderr)
            exitCode = 1
        }
        sem.signal()
    }

    sem.wait()
    exit(exitCode)
}

struct KeywordSound {
    let keyword: String
    let url: URL
}

protocol TranscriptHandler: AnyObject {
    func handle(text: String)
    func suppress(for duration: TimeInterval)
}

struct SoundboardConfig: Decodable {
    struct Global: Decodable {
        let defaultCooldownSec: Double?
        let setupWithinSec: Double?
        let startWordMax: Int?
        let fuzzyMaxDistance: Int?

        enum CodingKeys: String, CodingKey {
            case defaultCooldownSec = "default_cooldown_sec"
            case setupWithinSec = "setup_within_sec"
            case startWordMax = "start_word_max"
            case fuzzyMaxDistance = "fuzzy_max_distance"
        }
    }

    struct Rule: Decodable {
        let sound: String
        let triggerAny: [String]?
        let triggerSubstringAny: [String]?
        let triggerFuzzyAny: [String]?
        let setupAny: [String]?
        let withinSec: Double?
        let cooldownSec: Double?
        let startWordMax: Int?
        let fuzzyMaxDistance: Int?

        enum CodingKeys: String, CodingKey {
            case sound
            case triggerAny = "trigger_any"
            case triggerSubstringAny = "trigger_substring_any"
            case triggerFuzzyAny = "trigger_fuzzy_any"
            case setupAny = "setup_any"
            case withinSec = "within_sec"
            case cooldownSec = "cooldown_sec"
            case startWordMax = "start_word_max"
            case fuzzyMaxDistance = "fuzzy_max_distance"
        }
    }

    let global: Global?
    let rules: [Rule]
}

struct Phrase {
    let raw: String
    let normalized: String
    let tokens: [String]

    init(_ raw: String) {
        self.raw = raw
        let normalized = normalizeText(raw)
        self.normalized = normalized
        self.tokens = tokenize(normalized)
    }
}

func normalizeText(_ text: String) -> String {
    let lower = text.lowercased()
    var out = ""
    out.reserveCapacity(lower.count)
    var lastWasSpace = true
    for scalar in lower.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
            lastWasSpace = false
        } else if !lastWasSpace {
            out.append(" ")
            lastWasSpace = true
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

func tokenize(_ normalized: String) -> [String] {
    guard !normalized.isEmpty else { return [] }
    return normalized.split(separator: " ").map { String($0) }
}

func findPhrasePositions(in tokens: [String], phraseTokens: [String]) -> [Int] {
    guard !phraseTokens.isEmpty, phraseTokens.count <= tokens.count else { return [] }
    let lastStart = tokens.count - phraseTokens.count
    if lastStart < 0 { return [] }
    var positions: [Int] = []
    if tokens.count == phraseTokens.count {
        if tokens == phraseTokens { return [0] }
        return []
    }
    for i in 0...lastStart {
        var matched = true
        for j in 0..<phraseTokens.count where tokens[i + j] != phraseTokens[j] {
            matched = false
            break
        }
        if matched { positions.append(i) }
    }
    return positions
}

func firstPhrasePosition(in tokens: [String], phraseTokens: [String]) -> Int? {
    return findPhrasePositions(in: tokens, phraseTokens: phraseTokens).first
}

func withinEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Bool {
    if maxDistance <= 0 { return a == b }
    if a == b { return true }
    let aChars = Array(a.utf16)
    let bChars = Array(b.utf16)
    let n = aChars.count
    let m = bChars.count
    if abs(n - m) > maxDistance { return false }
    if n == 0 { return m <= maxDistance }
    if m == 0 { return n <= maxDistance }

    var prev = Array(0...m)
    var curr = Array(repeating: 0, count: m + 1)

    for i in 1...n {
        curr[0] = i
        var rowMin = curr[0]
        let aCh = aChars[i - 1]
        for j in 1...m {
            let cost = aCh == bChars[j - 1] ? 0 : 1
            let deletion = prev[j] + 1
            let insertion = curr[j - 1] + 1
            let substitution = prev[j - 1] + cost
            let v = min(deletion, insertion, substitution)
            curr[j] = v
            if v < rowMin { rowMin = v }
        }
        if rowMin > maxDistance { return false }
        swap(&prev, &curr)
    }

    return prev[m] <= maxDistance
}

func firstFuzzyPhrasePosition(in tokens: [String], phraseTokens: [String], maxDistance: Int) -> Int? {
    guard maxDistance >= 0 else { return nil }
    guard !phraseTokens.isEmpty, phraseTokens.count <= tokens.count else { return nil }
    let lastStart = tokens.count - phraseTokens.count
    if lastStart < 0 { return nil }
    for i in 0...lastStart {
        var matched = true
        for j in 0..<phraseTokens.count {
            if !withinEditDistance(tokens[i + j], phraseTokens[j], maxDistance: maxDistance) {
                matched = false
                break
            }
        }
        if matched { return i }
    }
    return nil
}

func argumentValue(_ name: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func argumentDouble(_ name: String, in args: [String]) -> Double? {
    guard let raw = argumentValue(name, in: args) else { return nil }
    return Double(raw)
}

func printUsage() {
    let text = """
    Usage:
      parakeet_ptt [--soundboard] [--sounds-dir PATH]
      parakeet_ptt --push-to-talk
      parakeet_ptt --wav /path/to/audio.wav

    Modes:
      --soundboard   Realtime keyword soundboard (default)
      --push-to-talk Cmd+1 hold-to-talk dictation

    Options:
      --sounds-dir   Directory containing sound files (mp3, wav, m4a, aiff, aac, caf)
      --rules        JSON rules file for advanced matching
      --live-window  Seconds of audio used per transcription window (soundboard)
      --live-update  Seconds between transcriptions (soundboard)
      --min-audio    Minimum seconds of audio before transcribing (soundboard)
      --pause-during-playback  Drop mic audio while a sound is playing (soundboard)
      --help         Show this help
    """
    print(text)
}

func resolveSoundsDirectory(customPath: String?) -> URL? {
    let fm = FileManager.default
    var candidates: [URL] = []

    if let customPath {
        candidates.append(URL(fileURLWithPath: customPath))
    } else {
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("sounds"))
        candidates.append(cwd.appendingPathComponent("../sounds"))

        let exePath = URL(fileURLWithPath: CommandLine.arguments[0])
        let exeDir = exePath.deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("sounds"))
        candidates.append(exeDir.appendingPathComponent("../sounds"))
    }

    for url in candidates {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.standardizedFileURL
        }
    }

    return nil
}

func listSoundFiles(in dir: URL) -> [URL] {
    let allowed = Set(["mp3", "wav", "m4a", "aiff", "aac", "caf"])
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }

    return files.filter { url in
        let ext = url.pathExtension.lowercased()
        return allowed.contains(ext)
    }
}

func loadKeywordSounds(from dir: URL) -> [KeywordSound] {
    let files = listSoundFiles(in: dir)
    var sounds: [KeywordSound] = []
    for url in files {
        let keyword = url.deletingPathExtension().lastPathComponent.lowercased()
        guard !keyword.isEmpty else { continue }
        sounds.append(KeywordSound(keyword: keyword, url: url))
    }

    return sounds.sorted { $0.keyword < $1.keyword }
}

func resolveRulesFile(customPath: String?, soundsDir: URL?) -> URL? {
    let fm = FileManager.default
    if let customPath {
        let url = URL(fileURLWithPath: customPath)
        if fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    if let soundsDir {
        let candidates = ["rules.json", "soundboard.json", "soundboard_rules.json"]
        for name in candidates {
            let url = soundsDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
    }

    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let candidates = ["rules.json", "soundboard.json", "soundboard_rules.json"]
    for name in candidates {
        let url = cwd.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) {
            return url
        }
    }

    return nil
}

func loadSoundboardConfig(from url: URL) -> SoundboardConfig? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try JSONDecoder().decode(SoundboardConfig.self, from: data)
    } catch {
        fputs("Failed to parse rules: \(error)\n", stderr)
        return nil
    }
}

final class SoundPlayer: NSObject, AVAudioPlayerDelegate {
    private let queue = DispatchQueue(label: "sound-player")
    private var players: [AVAudioPlayer] = []
    var onPlay: ((TimeInterval) -> Void)?

    func play(url: URL) {
        queue.async {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                player.prepareToPlay()
                self.onPlay?(player.duration)
                player.play()
                self.players.append(player)
                let delayMs = Int(max(0.5, player.duration + 0.25) * 1000.0)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                    self.players.removeAll { $0 === player }
                }
            } catch {
                fputs("Sound playback error for \(url.path): \(error)\n", stderr)
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queue.async {
            self.players.removeAll { $0 === player }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        queue.async {
            self.players.removeAll { $0 === player }
        }
    }
}

final class TriggerMatcher: TranscriptHandler {
    private struct Trigger {
        let keyword: String
        let url: URL
        var lastMatchLocation: Int
    }

    private var triggers: [Trigger]
    private let maxKeywordLen: Int
    private var lastTextLength: Int = 0
    private let player: SoundPlayer
    private let onTrigger: ((KeywordSound) -> Void)?
    private let lock = NSLock()
    private var suppressedUntil: Date?
    private var lastTriggerTime: [String: Date] = [:]
    private let keywordCooldownSec: TimeInterval = 1.5

    init(sounds: [KeywordSound], player: SoundPlayer, onTrigger: ((KeywordSound) -> Void)? = nil) {
        self.triggers = sounds.map { Trigger(keyword: $0.keyword.lowercased(), url: $0.url, lastMatchLocation: -1) }
        self.maxKeywordLen = max(1, sounds.map { $0.keyword.utf16.count }.max() ?? 1)
        self.player = player
        self.onTrigger = onTrigger
    }

    func suppress(for duration: TimeInterval) {
        lock.lock()
        suppressedUntil = Date().addingTimeInterval(duration)
        lock.unlock()
    }

    func handle(text: String) {
        let lower = text.lowercased()
        let ns = lower as NSString
        let len = ns.length

        var matches: [Trigger] = []

        lock.lock()
        let now = Date()
        let suppressed = suppressedUntil.map { now < $0 } ?? false
        if len < lastTextLength {
            lastTextLength = 0
            for i in triggers.indices {
                triggers[i].lastMatchLocation = -1
            }
        }

        let scanStart = max(0, lastTextLength - maxKeywordLen + 1)
        if scanStart < len {
            for i in triggers.indices {
                var range = NSRange(location: scanStart, length: len - scanStart)
                while range.length > 0 {
                    let r = ns.range(of: triggers[i].keyword, options: [], range: range)
                    if r.location == NSNotFound { break }
                    if r.location > triggers[i].lastMatchLocation {
                        triggers[i].lastMatchLocation = r.location
                        if !suppressed {
                            let last = lastTriggerTime[triggers[i].keyword] ?? .distantPast
                            if now.timeIntervalSince(last) >= keywordCooldownSec {
                                lastTriggerTime[triggers[i].keyword] = now
                                matches.append(triggers[i])
                            }
                        }
                    }
                    let next = r.location + max(r.length, 1)
                    if next >= len { break }
                    range = NSRange(location: next, length: len - next)
                }
            }
        }

        lastTextLength = len
        lock.unlock()

        for match in matches {
            let sound = KeywordSound(keyword: match.keyword, url: match.url)
            onTrigger?(sound)
            player.play(url: match.url)
        }
    }
}

final class RuleEngine: TranscriptHandler {
    final class CompiledRule {
        let sound: KeywordSound
        let triggerAny: [Phrase]
        let triggerSubstringAny: [Phrase]
        let triggerFuzzyAny: [Phrase]
        let setupAny: [Phrase]
        let withinSec: TimeInterval
        let cooldownSec: TimeInterval
        let startWordMax: Int?
        let fuzzyMaxDistance: Int
        var lastTriggerTime: Date = .distantPast
        var lastSetupTime: Date?

        init(
            sound: KeywordSound,
            triggerAny: [Phrase],
            triggerSubstringAny: [Phrase],
            triggerFuzzyAny: [Phrase],
            setupAny: [Phrase],
            withinSec: TimeInterval,
            cooldownSec: TimeInterval,
            startWordMax: Int?,
            fuzzyMaxDistance: Int
        ) {
            self.sound = sound
            self.triggerAny = triggerAny
            self.triggerSubstringAny = triggerSubstringAny
            self.triggerFuzzyAny = triggerFuzzyAny
            self.setupAny = setupAny
            self.withinSec = withinSec
            self.cooldownSec = cooldownSec
            self.startWordMax = startWordMax
            self.fuzzyMaxDistance = fuzzyMaxDistance
        }
    }

    private let rules: [CompiledRule]
    private let player: SoundPlayer
    private let onTrigger: ((KeywordSound) -> Void)?
    private let lock = NSLock()
    private var suppressedUntil: Date?

    init?(
        config: SoundboardConfig,
        soundsDir: URL,
        player: SoundPlayer,
        onTrigger: ((KeywordSound) -> Void)? = nil
    ) {
        let files = listSoundFiles(in: soundsDir)
        var soundByFile: [String: URL] = [:]
        var soundByStem: [String: URL] = [:]
        for url in files {
            let fileName = url.lastPathComponent.lowercased()
            soundByFile[fileName] = url
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if soundByStem[stem] == nil {
                soundByStem[stem] = url
            }
        }

        let defaultCooldown = config.global?.defaultCooldownSec ?? 1.5
        let defaultWithin = config.global?.setupWithinSec ?? 8.0
        let defaultStartWordMax = config.global?.startWordMax
        let defaultFuzzyMaxDistance = config.global?.fuzzyMaxDistance ?? 1

        var compiled: [CompiledRule] = []

        for rule in config.rules {
            let soundName = rule.sound
            let resolvedUrl: URL?
            if soundName.contains("/") {
                let url = URL(fileURLWithPath: soundName, relativeTo: soundsDir).standardizedFileURL
                resolvedUrl = FileManager.default.fileExists(atPath: url.path) ? url : nil
            } else {
                let lower = soundName.lowercased()
                if let url = soundByFile[lower] {
                    resolvedUrl = url
                } else if let url = soundByStem[lower] {
                    resolvedUrl = url
                } else {
                    resolvedUrl = nil
                }
            }

            guard let soundUrl = resolvedUrl else {
                fputs("Rule sound not found: \(soundName)\n", stderr)
                continue
            }

            let triggerAny = (rule.triggerAny ?? []).map(Phrase.init).filter { !$0.tokens.isEmpty }
            let triggerSubstringAny = (rule.triggerSubstringAny ?? []).map(Phrase.init).filter { !$0.normalized.isEmpty }
            let triggerFuzzyAny = (rule.triggerFuzzyAny ?? []).map(Phrase.init).filter { !$0.tokens.isEmpty }
            let setupAny = (rule.setupAny ?? []).map(Phrase.init).filter { !$0.tokens.isEmpty }

            let hasTrigger = !triggerAny.isEmpty || !triggerSubstringAny.isEmpty || !triggerFuzzyAny.isEmpty
            if !hasTrigger {
                fputs("Rule for \(soundName) has no triggers; skipping.\n", stderr)
                continue
            }

            let fuzzyMaxDistance = max(0, rule.fuzzyMaxDistance ?? defaultFuzzyMaxDistance)
            let keyword = soundUrl.deletingPathExtension().lastPathComponent.lowercased()
            let sound = KeywordSound(keyword: keyword, url: soundUrl)
            let compiledRule = CompiledRule(
                sound: sound,
                triggerAny: triggerAny,
                triggerSubstringAny: triggerSubstringAny,
                triggerFuzzyAny: triggerFuzzyAny,
                setupAny: setupAny,
                withinSec: rule.withinSec ?? defaultWithin,
                cooldownSec: rule.cooldownSec ?? defaultCooldown,
                startWordMax: rule.startWordMax ?? defaultStartWordMax,
                fuzzyMaxDistance: fuzzyMaxDistance
            )
            compiled.append(compiledRule)
        }

        guard !compiled.isEmpty else { return nil }
        self.rules = compiled
        self.player = player
        self.onTrigger = onTrigger
    }

    func suppress(for duration: TimeInterval) {
        lock.lock()
        suppressedUntil = Date().addingTimeInterval(duration)
        lock.unlock()
    }

    func handle(text: String) {
        let normalized = normalizeText(text)
        let tokens = tokenize(normalized)
        let now = Date()

        lock.lock()
        let isSuppressed = suppressedUntil.map { now < $0 } ?? false
        if isSuppressed {
            lock.unlock()
            return
        }

        var hits: [KeywordSound] = []

        for rule in rules {
            let hasTrigger = !rule.triggerAny.isEmpty || !rule.triggerSubstringAny.isEmpty || !rule.triggerFuzzyAny.isEmpty

            var setupIndex: Int?
            if !rule.setupAny.isEmpty {
                var earliest: Int?
                for phrase in rule.setupAny {
                    if let pos = firstPhrasePosition(in: tokens, phraseTokens: phrase.tokens) {
                        if earliest == nil || pos < earliest! { earliest = pos }
                    }
                }
                setupIndex = earliest
                if setupIndex != nil {
                    rule.lastSetupTime = now
                }
            }

            var triggerMatch = false
            var triggerStartIndex: Int?

            if hasTrigger {
                var earliest: Int?
                for phrase in rule.triggerAny {
                    if let pos = firstPhrasePosition(in: tokens, phraseTokens: phrase.tokens) {
                        if earliest == nil || pos < earliest! { earliest = pos }
                    }
                }
                if let earliest {
                    triggerMatch = true
                    triggerStartIndex = earliest
                }

                if !triggerMatch {
                    for phrase in rule.triggerSubstringAny {
                        if phrase.normalized.isEmpty { continue }
                        if let range = normalized.range(of: phrase.normalized) {
                            triggerMatch = true
                            let prefix = normalized[..<range.lowerBound]
                            if !prefix.isEmpty {
                                triggerStartIndex = prefix.split(separator: " ").count
                            } else {
                                triggerStartIndex = 0
                            }
                            break
                        }
                    }
                }

                if !triggerMatch && !rule.triggerFuzzyAny.isEmpty {
                    let maxDistance = rule.fuzzyMaxDistance
                    var earliestFuzzy: Int?
                    for phrase in rule.triggerFuzzyAny {
                        if let pos = firstFuzzyPhrasePosition(in: tokens, phraseTokens: phrase.tokens, maxDistance: maxDistance) {
                            if earliestFuzzy == nil || pos < earliestFuzzy! { earliestFuzzy = pos }
                        }
                    }
                    if let earliestFuzzy {
                        triggerMatch = true
                        triggerStartIndex = earliestFuzzy
                    }
                }
            }

            if !triggerMatch {
                continue
            }

            if !rule.setupAny.isEmpty {
                var setupOk = false
                if let triggerStartIndex, let setupIndex {
                    setupOk = setupIndex < triggerStartIndex
                } else if let lastSetup = rule.lastSetupTime {
                    setupOk = now.timeIntervalSince(lastSetup) <= rule.withinSec
                }
                if !setupOk { continue }
            }

            if let maxStart = rule.startWordMax, let triggerStartIndex, triggerStartIndex > maxStart {
                continue
            }

            if now.timeIntervalSince(rule.lastTriggerTime) < rule.cooldownSec {
                continue
            }

            rule.lastTriggerTime = now
            hits.append(rule.sound)
        }

        lock.unlock()

        for hit in hits {
            onTrigger?(hit)
            player.play(url: hit.url)
        }
    }
}

final class RealtimeSoundboard {
    struct Timing {
        let liveWindowSec: Double
        let liveUpdateSec: Double
        let minAudioSec: Double
        let maxBufferSec: Double
    }

    private let sampleRate: Double = 16000
    private let liveWindowSec: Double
    private let liveUpdateSec: Double
    private let minAudioSec: Double
    private let maxBufferSec: Double

    private var engine: AVAudioEngine?
    private var audioAll: [Float] = []
    private let audioLock = NSLock()

    private var liveTimer: DispatchSourceTimer?
    private var lastLiveText = ""

    private var asr: AsrManager?
    private var asrReady = false

    private let handler: TranscriptHandler

    private let transcribeLock = NSLock()
    private var isTranscribing = false
    private let pauseLock = NSLock()
    private var pausedUntil: Date?

    init(handler: TranscriptHandler, timing: Timing) {
        self.handler = handler
        self.liveWindowSec = timing.liveWindowSec
        self.liveUpdateSec = timing.liveUpdateSec
        self.minAudioSec = timing.minAudioSec
        self.maxBufferSec = timing.maxBufferSec
    }

    func pauseRecording(for duration: TimeInterval) {
        pauseLock.lock()
        pausedUntil = Date().addingTimeInterval(duration)
        pauseLock.unlock()

        audioLock.lock()
        audioAll.removeAll(keepingCapacity: true)
        audioLock.unlock()
    }

    private func isRecordingPaused() -> Bool {
        pauseLock.lock()
        let paused = pausedUntil.map { Date() < $0 } ?? false
        pauseLock.unlock()
        return paused
    }

    func start() {
        Task {
            do {
                let models = try await AsrModels.downloadAndLoad()
                let mgr = AsrManager(config: .default)
                try await mgr.initialize(models: models)
                self.asr = mgr
                self.asrReady = true
                print("ASR ready. Listening for keywords...")
                self.startAudioEngine()
                self.startLiveTimer()
            } catch {
                print("Failed to initialize ASR: \(error)")
                exit(1)
            }
        }

        RunLoop.current.run()
    }

    private func startAudioEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("Failed to create target audio format.")
            exit(1)
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if converter == nil {
            print("Failed to create audio converter.")
            exit(1)
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else { return }
            if self.isRecordingPaused() { return }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if error != nil { return }

            guard let channel = outBuffer.floatChannelData?[0] else { return }
            let n = Int(outBuffer.frameLength)
            if n <= 0 { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: n))

            self.audioLock.lock()
            self.audioAll.append(contentsOf: chunk)
            let maxSamples = Int(self.maxBufferSec * self.sampleRate)
            if self.audioAll.count > maxSamples * 2 {
                let excess = self.audioAll.count - maxSamples
                self.audioAll.removeFirst(excess)
            }
            self.audioLock.unlock()
        }

        do {
            try engine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
            exit(1)
        }

        self.engine = engine
    }

    private func startLiveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + liveUpdateSec, repeating: liveUpdateSec)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.asrReady else { return }
            guard !self.isRecordingPaused() else { return }
            guard self.tryBeginTranscription() else { return }

            let window = self.snapshotLiveWindow()
            guard window.count >= Int(self.minAudioSec * self.sampleRate) else {
                self.endTranscription()
                return
            }

            Task {
                defer { self.endTranscription() }
                do {
                    guard let asr = self.asr else { return }
                    let result = try await asr.transcribe(window, source: .microphone)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { return }
                    let delta = self.deltaFromLast(text)
                    if !delta.isEmpty {
                        print(delta, terminator: " ")
                        fflush(stdout)
                    }
                    self.handler.handle(text: text)
                } catch {
                }
            }
        }
        timer.resume()
        liveTimer = timer
    }

    private func tryBeginTranscription() -> Bool {
        transcribeLock.lock()
        if isTranscribing {
            transcribeLock.unlock()
            return false
        }
        isTranscribing = true
        transcribeLock.unlock()
        return true
    }

    private func endTranscription() {
        transcribeLock.lock()
        isTranscribing = false
        transcribeLock.unlock()
    }

    private func snapshotLiveWindow() -> [Float] {
        audioLock.lock()
        let x = audioAll
        audioLock.unlock()

        let keep = Int(liveWindowSec * sampleRate)
        if x.count <= keep {
            return normalize(x)
        }
        return normalize(Array(x.suffix(keep)))
    }

    private func normalize(_ x: [Float]) -> [Float] {
        guard let m = x.map({ abs($0) }).max(), m > 1e-6 else { return x }
        return x.map { $0 / m }
    }

    private func deltaFromLast(_ newText: String) -> String {
        let a = Array(lastLiveText)
        let b = Array(newText)
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        lastLiveText = newText
        let suffix = String(b[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix
    }
}

final class KeyHoldDictation {
    private let holdKeyCode: CGKeyCode = 18 // 1
    private let holdRequiredModifiers: CGEventFlags = [.maskCommand]
    private let holdDisallowedModifiers: CGEventFlags = [
        .maskShift,
        .maskControl,
        .maskAlphaShift,
        .maskHelp,
        .maskSecondaryFn
    ]
    private let sampleRate: Double = 16000
    private let liveWindowSec: Double = 6.0
    private let liveUpdateSec: Double = 0.8
    private let minAudioSec: Double = 1.0

    private var engine: AVAudioEngine?
    private var tapInstalled = false

    private var isHolding = false
    private var audioAll: [Float] = []
    private let audioLock = NSLock()

    private var liveTimer: DispatchSourceTimer?
    private var lastLiveText = ""

    private var asr: AsrManager?
    private var asrReady = false

    func start() {
        Task {
            do {
                let models = try await AsrModels.downloadAndLoad()
                let mgr = AsrManager(config: .default)
                try await mgr.initialize(models: models)
                self.asr = mgr
                self.asrReady = true
                print("ASR ready. Hold Cmd+1 to dictate.")
            } catch {
                print("Failed to initialize ASR: \(error)")
                exit(1)
            }
        }

        installEventTap()
        RunLoop.current.run()
    }

    private func installEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                let me = Unmanaged<KeyHoldDictation>.fromOpaque(refcon!).takeUnretainedValue()
                me.handleKeyEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            print("Failed to create event tap. Enable Accessibility for this app/Terminal.")
            exit(1)
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Event tap installed. Hold Cmd+1 to record.")
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) {
        guard asrReady else { return }
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == holdKeyCode else { return }

        if type == .keyDown {
            let relevantFlags = holdRequiredModifiers.union(holdDisallowedModifiers)
            let normalizedFlags = event.flags.intersection(relevantFlags)
            guard normalizedFlags == holdRequiredModifiers else { return }
            if !isHolding {
                beginHold()
            }
        } else if type == .keyUp {
            if isHolding {
                endHold()
            }
        }
    }

    private func beginHold() {
        isHolding = true
        lastLiveText = ""
        audioLock.lock()
        audioAll.removeAll(keepingCapacity: true)
        audioLock.unlock()

        startAudioEngine()
        startLiveTimer()
        print("")
        print("[hold] recording...")
    }

    private func endHold() {
        isHolding = false
        stopLiveTimer()
        stopAudioEngine()

        let audio = snapshotAllAudio()
        guard audio.count >= Int(minAudioSec * sampleRate) else {
            print("[release] too little audio")
            return
        }

        Task {
            do {
                guard let asr else { return }
                let result = try await asr.transcribe(audio, source: .microphone)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    print("[final] empty")
                    return
                }
                print("")
                print("[final] \(text)")
                paste(text: text)
            } catch {
                print("Final transcription error: \(error)")
            }
        }
    }

    private func startAudioEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("Failed to create target audio format.")
            exit(1)
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if converter == nil {
            print("Failed to create audio converter.")
            exit(1)
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.isHolding else { return }
            guard let converter else { return }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if error != nil { return }

            guard let channel = outBuffer.floatChannelData?[0] else { return }
            let n = Int(outBuffer.frameLength)
            if n <= 0 { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: n))

            self.audioLock.lock()
            self.audioAll.append(contentsOf: chunk)
            self.audioLock.unlock()
        }

        do {
            try engine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
            exit(1)
        }

        self.engine = engine
    }

    private func stopAudioEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func startLiveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + liveUpdateSec, repeating: liveUpdateSec)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isHolding else { return }
            let window = self.snapshotLiveWindow()
            if window.count < Int(self.minAudioSec * self.sampleRate) { return }

            Task {
                do {
                    guard let asr = self.asr else { return }
                    let result = try await asr.transcribe(window, source: .microphone)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { return }
                    let delta = self.deltaFromLast(text)
                    if !delta.isEmpty {
                        print(delta, terminator: " ")
                        fflush(stdout)
                    }
                } catch {
                }
            }
        }
        timer.resume()
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.cancel()
        liveTimer = nil
    }

    private func snapshotAllAudio() -> [Float] {
        audioLock.lock()
        let x = audioAll
        audioLock.unlock()
        return normalize(x)
    }

    private func snapshotLiveWindow() -> [Float] {
        audioLock.lock()
        let x = audioAll
        audioLock.unlock()

        let keep = Int(liveWindowSec * sampleRate)
        if x.count <= keep {
            return normalize(x)
        }
        return normalize(Array(x.suffix(keep)))
    }

    private func normalize(_ x: [Float]) -> [Float] {
        guard let m = x.map({ abs($0) }).max(), m > 1e-6 else { return x }
        return x.map { $0 / m }
    }

    private func deltaFromLast(_ newText: String) -> String {
        let a = Array(lastLiveText)
        let b = Array(newText)
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        lastLiveText = newText
        let suffix = String(b[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix
    }

    private func paste(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let cmdDown = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)

        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}

let args = CommandLine.arguments

if args.contains("--help") {
    printUsage()
    exit(0)
}

if let idx = args.firstIndex(of: "--wav") {
    if idx + 1 >= args.count {
        fputs("Usage: parakeet_ptt --wav /path/to/audio.wav\n", stderr)
        exit(2)
    }
    runWavTranscription(args[idx + 1])
}

let usePushToTalk = args.contains("--push-to-talk")
let useSoundboard = args.contains("--soundboard") || !usePushToTalk

    if useSoundboard {
        guard let soundsDir = resolveSoundsDirectory(customPath: argumentValue("--sounds-dir", in: args)) else {
            fputs("Sounds directory not found. Use --sounds-dir or run from ceelo root.\n", stderr)
            exit(2)
        }

    let sounds = loadKeywordSounds(from: soundsDir)
    guard !sounds.isEmpty else {
        fputs("No sounds found in \(soundsDir.path)\n", stderr)
        exit(2)
    }

    print("Loaded \(sounds.count) sounds from \(soundsDir.path)")
    for sound in sounds {
        print(" - \(sound.keyword) -> \(sound.url.lastPathComponent)")
    }

    let player = SoundPlayer()
    let rulesPath = argumentValue("--rules", in: args)
    let rulesUrl = resolveRulesFile(customPath: rulesPath, soundsDir: soundsDir)

    let handler: TranscriptHandler
    if let rulesUrl, let config = loadSoundboardConfig(from: rulesUrl) {
        if let engine = RuleEngine(
            config: config,
            soundsDir: soundsDir,
            player: player,
            onTrigger: { sound in
                print("\n[hit] \(sound.keyword)")
                fflush(stdout)
            }
        ) {
            print("Loaded rules from \(rulesUrl.path)")
            handler = engine
        } else if rulesPath != nil {
            fputs("Rules file loaded but no valid rules found.\n", stderr)
            exit(2)
        } else {
            fputs("No valid rules found; falling back to keyword matching.\n", stderr)
            let matcher = TriggerMatcher(sounds: sounds, player: player) { sound in
                print("\n[hit] \(sound.keyword)")
                fflush(stdout)
            }
            handler = matcher
        }
    } else if rulesPath != nil {
        fputs("Rules file not found or invalid: \(rulesPath!)\n", stderr)
        exit(2)
    } else {
        let matcher = TriggerMatcher(sounds: sounds, player: player) { sound in
            print("\n[hit] \(sound.keyword)")
            fflush(stdout)
        }
        handler = matcher
    }

    let defaultTiming = RealtimeSoundboard.Timing(
        liveWindowSec: 2.0,
        liveUpdateSec: 0.35,
        minAudioSec: 0.4,
        maxBufferSec: 6.0
    )
    let timing = RealtimeSoundboard.Timing(
        liveWindowSec: argumentDouble("--live-window", in: args) ?? defaultTiming.liveWindowSec,
        liveUpdateSec: argumentDouble("--live-update", in: args) ?? defaultTiming.liveUpdateSec,
        minAudioSec: argumentDouble("--min-audio", in: args) ?? defaultTiming.minAudioSec,
        maxBufferSec: defaultTiming.maxBufferSec
    )

    let sanitizedTiming = RealtimeSoundboard.Timing(
        liveWindowSec: max(0.5, timing.liveWindowSec),
        liveUpdateSec: max(0.15, timing.liveUpdateSec),
        minAudioSec: min(max(0.2, timing.minAudioSec), max(0.2, timing.liveWindowSec)),
        maxBufferSec: max(timing.liveWindowSec * 3.0, timing.maxBufferSec)
    )

    let soundboard = RealtimeSoundboard(handler: handler, timing: sanitizedTiming)
    let pauseDuringPlayback = args.contains("--pause-during-playback")
    if pauseDuringPlayback {
        player.onPlay = { [weak handler, weak soundboard] duration in
            let suppressFor = duration + 0.4
            handler?.suppress(for: suppressFor)
            soundboard?.pauseRecording(for: suppressFor)
        }
    } else {
        player.onPlay = { [weak handler] duration in
            handler?.suppress(for: duration + 0.4)
        }
    }

    soundboard.start()
} else {
    KeyHoldDictation().start()
}
