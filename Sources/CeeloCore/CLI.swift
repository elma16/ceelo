import Foundation

enum CLIError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case invalidNumber(option: String, value: String)
    case conflictingCommands

    var description: String {
        switch self {
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .invalidNumber(let option, let value):
            return "Invalid number for \(option): \(value)"
        case .conflictingCommands:
            return "Use only one of --check-rules and --test"
        }
    }
}

struct CeeloOptions: Equatable {
    enum Command: Equatable {
        case listen
        case checkRules
        case test(String)
    }

    var command = Command.listen
    var soundsDir = "sounds"
    var rulesPath: String?
    var liveWindow: Double?
    var liveUpdate: Double?
    var quiet = false
    var showHelp = false

    /// Parses arguments, excluding the executable name.
    static func parse(_ arguments: [String]) throws -> CeeloOptions {
        var options = CeeloOptions()
        var commands = 0
        var remaining = arguments[...]

        func value(for option: String) throws -> String {
            guard let next = remaining.popFirst(), !next.hasPrefix("--") else {
                throw CLIError.missingValue(option)
            }
            return next
        }

        func number(for option: String) throws -> Double {
            let raw = try value(for: option)
            guard let parsed = Double(raw), parsed.isFinite else {
                throw CLIError.invalidNumber(option: option, value: raw)
            }
            return parsed
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--sounds-dir":
                options.soundsDir = try value(for: argument)
            case "--rules":
                options.rulesPath = try value(for: argument)
            case "--live-window":
                options.liveWindow = try number(for: argument)
            case "--live-update":
                options.liveUpdate = try number(for: argument)
            case "--quiet", "-q":
                options.quiet = true
            case "--check-rules":
                options.command = .checkRules
                commands += 1
            case "--test":
                options.command = .test(try value(for: argument))
                commands += 1
            default:
                throw CLIError.unknownOption(argument)
            }
        }

        if commands > 1 {
            throw CLIError.conflictingCommands
        }
        return options
    }

    var soundboardTiming: SoundboardTiming {
        let defaults = SoundboardTiming.default
        return SoundboardTiming(
            liveWindowSec: liveWindow ?? defaults.liveWindowSec,
            liveUpdateSec: liveUpdate ?? defaults.liveUpdateSec,
            minAudioSec: defaults.minAudioSec,
            maxBufferSec: defaults.maxBufferSec
        ).sanitized()
    }
}

let usageText = """
Usage:
  ceelo [--sounds-dir DIR] [--rules FILE] [--live-window SEC] [--live-update SEC] [-q]
  ceelo --check-rules [--sounds-dir DIR] [--rules FILE]
  ceelo --test TEXT [--sounds-dir DIR] [--rules FILE]

Plays a sound when you say its phrase. The microphone is ignored while a sound plays.

  --sounds-dir DIR   Sound files (default: ./sounds)
  --rules FILE       Rules file (default: rules.json in the sounds directory, if present)
  --live-window SEC  Seconds of audio per transcription (default 2.0)
  --live-update SEC  Seconds between transcriptions (default 0.15)
  -q, --quiet        Don't print the live transcript
  --check-rules      Check the rules, list what each sound responds to, and exit
  --test TEXT        Show which sounds TEXT would play, and exit
  -h, --help         Show this help

See README.md for the rules file format.
"""

/// Everything ceelo needs from the outside world. Tests swap these for fakes.
struct CeeloEnvironment {
    var loadRuntime: () async throws -> SpeechRuntime
    var makeAudioInput: () -> AudioInput
    var makeSoundPlayer: () -> SoundPlayer
    /// Ends the process after a failure while listening.
    var terminate: (Int32) -> Void

    static let live = CeeloEnvironment(
        loadRuntime: { try await loadFluidSpeechRuntime() },
        makeAudioInput: { MicrophoneCapture() },
        makeSoundPlayer: { SoundPlayer() },
        terminate: { exit($0) }
    )
}

enum LaunchResult {
    /// Finished (or failed to start) with this exit code.
    case finished(Int32)
    /// Listening on the main run loop; call `stop` to shut down.
    case running(stop: () -> Void)
}

public enum CeeloRunner {
    /// - Parameter arguments: the full command line, including the executable name.
    public static func run(with arguments: [String]) -> Never {
        switch launch(Array(arguments.dropFirst()), environment: .live) {
        case .finished(let code):
            exit(code)
        case .running(let stop):
            // `stop` owns the soundboard; without it the soundboard would be deallocated.
            withExtendedLifetime(stop) {
                RunLoop.main.run()
            }
            exit(0)
        }
    }

    /// - Parameter arguments: the arguments, excluding the executable name.
    static func launch(_ arguments: [String], environment: CeeloEnvironment) -> LaunchResult {
        let options: CeeloOptions
        do {
            options = try CeeloOptions.parse(arguments)
        } catch {
            fputs("\(error)\n\n\(usageText)\n", stderr)
            return .finished(2)
        }
        if options.showHelp {
            print(usageText)
            return .finished(0)
        }

        let soundsDir = URL(fileURLWithPath: options.soundsDir).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: soundsDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fputs("Sounds directory not found: \(soundsDir.path) (use --sounds-dir)\n", stderr)
            return .finished(2)
        }

        let rulesFile: URL?
        if let rulesPath = options.rulesPath {
            rulesFile = URL(fileURLWithPath: rulesPath)
            guard FileManager.default.fileExists(atPath: rulesPath) else {
                fputs("Rules file not found: \(rulesPath)\n", stderr)
                return .finished(2)
            }
        } else {
            let candidate = soundsDir.appendingPathComponent("rules.json")
            rulesFile = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }

        let rules: [SoundRule]
        do {
            rules = try loadRules(soundsDir: soundsDir, rulesFile: rulesFile)
        } catch {
            fputs("\(error)\n", stderr)
            return .finished(2)
        }

        switch options.command {
        case .checkRules:
            printSummary(rules, soundsDir: soundsDir, rulesFile: rulesFile)
            print("Rules OK.")
            return .finished(0)
        case .test(let text):
            print("Heard as: \"\(normalizeText(text))\"")
            var played: [SoundRule] = []
            RuleEngine(rules: rules, player: SilentPlayer(), onTrigger: { played.append($0) }).handle(text: text, at: Date())
            print(played.isEmpty ? "No sound would play." : "Would play: " + played.map(\.name).joined(separator: ", "))
            return .finished(0)
        case .listen:
            printSummary(rules, soundsDir: soundsDir, rulesFile: rulesFile)
            return listen(rules: rules, options: options, environment: environment)
        }
    }

    private static func printSummary(_ rules: [SoundRule], soundsDir: URL, rulesFile: URL?) {
        print("Sounds: \(soundsDir.path)")
        print("Rules:  \(rulesFile?.path ?? "none (each file name is its phrase)")")
        for rule in rules {
            print("  \(rule.summary)")
        }
    }

    private static func listen(rules: [SoundRule], options: CeeloOptions, environment: CeeloEnvironment) -> LaunchResult {
        let timing = options.soundboardTiming
        let player = environment.makeSoundPlayer()
        let engine = RuleEngine(rules: rules, player: player, refireGuardSec: timing.refireGuardSec) { rule in
            print("\n[hit] \(rule.name)")
            fflush(stdout)
        }
        player.preload(rules.filter(\.isEnabled).map(\.sound))
        player.warmUp()

        let soundboard = RealtimeSoundboard(
            handler: engine,
            timing: timing,
            showTranscript: !options.quiet,
            environment: environment
        )

        // Ignore the microphone while a sound plays (plus its echo) so it can't trigger itself or others.
        let previousOnPlay = player.onPlay
        player.onPlay = { [weak soundboard] duration in
            previousOnPlay?(duration)
            soundboard?.pauseRecording(for: duration + 0.4)
        }

        soundboard.start()
        return .running(stop: soundboard.stop)
    }
}

/// Collects what would play without playing it, for `--test`.
private final class SilentPlayer: SoundPlaying {
    func play(url: URL) {}
}
