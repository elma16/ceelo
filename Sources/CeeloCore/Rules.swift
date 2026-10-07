import Foundation

/// One sound and what has to be said to play it.
public struct SoundRule: Equatable {
    public enum Origin: Equatable {
        /// The n-th entry (from 1) of the rules file.
        case rulesFile(Int)
        /// No rule mentions the sound, so its file name is the phrase.
        case fileName
    }

    public let sound: URL
    /// Phrases that play the sound. Empty means the sound is switched off.
    let phrases: [Phrase]
    public let match: MatchMode
    /// Phrases that must have been said first (earlier in the same breath, or within `within` seconds).
    let after: [Phrase]
    public let within: TimeInterval
    public let origin: Origin

    public var name: String {
        sound.deletingPathExtension().lastPathComponent
    }

    public var isEnabled: Bool {
        !phrases.isEmpty
    }

    public init(
        sound: URL,
        say: [String],
        match: MatchMode = .words,
        after: [String] = [],
        within: TimeInterval = RuleDefaults.within,
        origin: Origin = .fileName
    ) {
        self.sound = sound
        self.phrases = say.map(Phrase.init)
        self.match = match
        self.after = after.map(Phrase.init)
        self.within = within
        self.origin = origin
    }

    /// One line for `--check-rules` and startup, e.g. `chime: "new ticket" after "heads up" (words)`.
    public var summary: String {
        guard isEnabled else { return "\(name): off" }
        var parts = [phrases.map { "\"\($0.text)\"" }.joined(separator: ", ")]
        if !after.isEmpty {
            parts.append("after " + after.map { "\"\($0.text)\"" }.joined(separator: ", ")
                + " within \(Self.format(within))s")
        }
        parts.append("(\(match.rawValue))")
        let source = origin == .fileName ? "  [file name]" : ""
        return "\(name): \(parts.joined(separator: " "))\(source)"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

public enum RuleDefaults {
    public static let within: TimeInterval = 8
}

public struct RulesError: Error, Equatable, CustomStringConvertible {
    public let problems: [String]

    public var description: String {
        let header = problems.count == 1 ? "1 problem" : "\(problems.count) problems"
        return "Rules have \(header):\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
    }
}

public let soundExtensions: Set<String> = ["mp3", "wav", "m4a", "aiff", "aac", "caf"]

public func listSoundFiles(in dir: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files
        .filter { soundExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
}

/// Builds the rules for a sounds directory: one per entry in the rules file, plus a file-name rule for every
/// sound the file doesn't mention. Every problem in the file is collected and reported together.
public func loadRules(soundsDir: URL, rulesFile: URL?) throws -> [SoundRule] {
    let files = listSoundFiles(in: soundsDir)
    guard !files.isEmpty else {
        throw RulesError(problems: ["No sounds (\(soundExtensions.sorted().joined(separator: ", "))) in \(soundsDir.path)"])
    }

    var rules: [SoundRule] = []
    if let rulesFile {
        rules = try parseRulesFile(rulesFile, soundsDir: soundsDir, soundFiles: files)
    }

    let mentioned = Set(rules.map { $0.sound.standardizedFileURL })
    for file in files where !mentioned.contains(file.standardizedFileURL) {
        let name = file.deletingPathExtension().lastPathComponent
        if !normalizeText(name).isEmpty {
            rules.append(SoundRule(sound: file, say: [name.replacingOccurrences(of: "_", with: " ")]))
        }
    }
    return rules
}

private let ruleKeys = ["sound", "say", "match", "after", "within"]
private let defaultKeys = ["match", "within"]

private func parseRulesFile(_ url: URL, soundsDir: URL, soundFiles: [URL]) throws -> [SoundRule] {
    let root: [String: Any]
    do {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw RulesError(problems: ["\(url.lastPathComponent): expected a JSON object with \"rules\""])
        }
        root = object
    } catch let error as RulesError {
        throw error
    } catch {
        throw RulesError(problems: ["\(url.lastPathComponent): \(error.localizedDescription)"])
    }

    var problems: [String] = []
    problems += unknownKeys(in: root, allowed: ["defaults", "rules"], at: "top level")

    let defaults = root["defaults"] as? [String: Any] ?? [:]
    if root["defaults"] != nil && root["defaults"] as? [String: Any] == nil {
        problems.append("\"defaults\" must be an object")
    }
    problems += unknownKeys(in: defaults, allowed: defaultKeys, at: "defaults")
    let defaultMatch = matchMode(defaults["match"], at: "defaults", problems: &problems) ?? .words
    let defaultWithin = seconds(defaults["within"], key: "within", at: "defaults", problems: &problems)
        ?? RuleDefaults.within

    guard let entries = root["rules"] as? [Any] else {
        throw RulesError(problems: problems + ["\"rules\" must be a list of rules"])
    }

    var byName: [String: URL] = [:]
    for file in soundFiles.reversed() {
        byName[file.lastPathComponent.lowercased()] = file
        byName[file.deletingPathExtension().lastPathComponent.lowercased()] = file
    }

    var rules: [SoundRule] = []
    for (offset, entry) in entries.enumerated() {
        let index = offset + 1
        guard let rule = entry as? [String: Any] else {
            problems.append("rule \(index): must be an object")
            continue
        }
        let label = "rule \(index)" + ((rule["sound"] as? String).map { " (\($0))" } ?? "")
        problems += unknownKeys(in: rule, allowed: ruleKeys, at: label)

        var sound: URL?
        if let name = rule["sound"] as? String {
            if name.contains("/") {
                let url = (name.hasPrefix("/") ? URL(fileURLWithPath: name) : soundsDir.appendingPathComponent(name))
                    .standardizedFileURL
                sound = FileManager.default.fileExists(atPath: url.path) ? url : nil
            } else {
                sound = byName[name.lowercased()]
            }
            if sound == nil {
                problems.append("\(label): no sound file \"\(name)\" in \(soundsDir.path)")
            }
        } else {
            problems.append("\(label): \"sound\" is required and must be a file name")
        }

        let say = phrases(rule["say"], key: "say", at: label, problems: &problems)
        if rule["say"] == nil {
            problems.append("\(label): \"say\" is required (use [] to switch the sound off)")
        }
        let after = phrases(rule["after"], key: "after", at: label, problems: &problems) ?? []
        let match = matchMode(rule["match"], at: label, problems: &problems) ?? defaultMatch
        let within = seconds(rule["within"], key: "within", at: label, problems: &problems) ?? defaultWithin

        if let sound, let say {
            rules.append(SoundRule(
                sound: sound, say: say, match: match, after: after, within: within, origin: .rulesFile(index)
            ))
        }
    }

    if !problems.isEmpty {
        throw RulesError(problems: problems.map { "\(url.lastPathComponent): \($0)" })
    }
    return rules
}

private func unknownKeys(in object: [String: Any], allowed: [String], at label: String) -> [String] {
    object.keys.sorted().filter { !allowed.contains($0) }.map { key in
        "\(label): unknown key \"\(key)\" (expected one of: \(allowed.joined(separator: ", ")))"
    }
}

private func phrases(_ value: Any?, key: String, at label: String, problems: inout [String]) -> [String]? {
    guard let value else { return nil }
    guard let list = value as? [String] else {
        problems.append("\(label): \"\(key)\" must be a list of phrases")
        return nil
    }
    for phrase in list where normalizeText(phrase).isEmpty {
        problems.append("\(label): \"\(key)\" phrase \"\(phrase)\" has no words")
    }
    return list.filter { !normalizeText($0).isEmpty }
}

private func matchMode(_ value: Any?, at label: String, problems: inout [String]) -> MatchMode? {
    guard let value else { return nil }
    guard let raw = value as? String, let mode = MatchMode(rawValue: raw) else {
        let options = MatchMode.allCases.map(\.rawValue).joined(separator: ", ")
        problems.append("\(label): \"match\" must be one of: \(options)")
        return nil
    }
    return mode
}

private func seconds(_ value: Any?, key: String, at label: String, problems: inout [String]) -> TimeInterval? {
    guard let value else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 else {
        problems.append("\(label): \"\(key)\" must be a number of seconds")
        return nil
    }
    return number.doubleValue
}

public protocol SoundPlaying: AnyObject {
    func play(url: URL)
}

/// Receives the transcript of each live window. Windows overlap, so the same spoken phrase shows up
/// in several consecutive transcripts; handlers must not fire for it more than once.
public protocol TranscriptHandler: AnyObject {
    func handle(text: String, at now: Date)
}

/// Plays the sound of every rule whose phrase was just said.
public final class RuleEngine: TranscriptHandler {
    private final class State {
        var lastFired: Date = .distantPast
        var lastSetup: Date?
    }

    public let rules: [SoundRule]
    private let states: [State]
    private let player: SoundPlaying
    private let refireGuardSec: TimeInterval
    private let onTrigger: ((SoundRule) -> Void)?
    private let lock = NSLock()

    /// - Parameter refireGuardSec: how long a phrase can stay visible in overlapping live windows after it
    ///   was first heard (`SoundboardTiming.refireGuardSec`). A rule never fires again sooner than this, so
    ///   one utterance plays its sound once.
    public init(
        rules: [SoundRule],
        player: SoundPlaying,
        refireGuardSec: TimeInterval = 0,
        onTrigger: ((SoundRule) -> Void)? = nil
    ) {
        self.rules = rules
        self.states = rules.map { _ in State() }
        self.player = player
        self.refireGuardSec = refireGuardSec
        self.onTrigger = onTrigger
    }

    public func handle(text: String, at now: Date) {
        let normalized = normalizeText(text)
        let spoken = tokenize(normalized)

        lock.lock()
        var hits: [SoundRule] = []
        for (rule, state) in zip(rules, states) where rule.isEnabled {
            let setupIndex = rule.after.compactMap { $0.firstMatch(in: spoken, normalized: normalized, mode: rule.match) }.min()
            if setupIndex != nil {
                state.lastSetup = now
            }
            guard let triggerIndex = rule.phrases.compactMap({
                $0.firstMatch(in: spoken, normalized: normalized, mode: rule.match)
            }).min() else { continue }

            if !rule.after.isEmpty {
                let setupOk: Bool
                if let setupIndex {
                    setupOk = setupIndex < triggerIndex
                } else if let lastSetup = state.lastSetup {
                    setupOk = now.timeIntervalSince(lastSetup) <= rule.within
                } else {
                    setupOk = false
                }
                if !setupOk { continue }
            }

            if now.timeIntervalSince(state.lastFired) < refireGuardSec {
                continue
            }
            state.lastFired = now
            hits.append(rule)
        }
        lock.unlock()

        for hit in hits {
            onTrigger?(hit)
            player.play(url: hit.sound)
        }
    }
}
