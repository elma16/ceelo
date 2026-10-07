import XCTest
@testable import CeeloCore

final class CLIOptionsTests: XCTestCase {
    func testDefaults() throws {
        let options = try CeeloOptions.parse([])
        XCTAssertEqual(options.command, .listen)
        XCTAssertEqual(options.soundsDir, "sounds")
        XCTAssertNil(options.rulesPath)
        XCTAssertFalse(options.quiet)
        XCTAssertFalse(options.showHelp)
        XCTAssertEqual(options.soundboardTiming, SoundboardTiming.default.sanitized())
    }

    func testOptions() throws {
        let options = try CeeloOptions.parse([
            "--sounds-dir", "s", "--rules", "r.json", "--live-window", "1.6", "--live-update", "0.25",
            "-q"
        ])
        XCTAssertEqual(options.soundsDir, "s")
        XCTAssertEqual(options.rulesPath, "r.json")
        XCTAssertTrue(options.quiet)
        XCTAssertEqual(
            options.soundboardTiming,
            SoundboardTiming(liveWindowSec: 1.6, liveUpdateSec: 0.25, minAudioSec: 0.4, maxBufferSec: 6.0)
        )
    }

    func testCommands() throws {
        XCTAssertEqual(try CeeloOptions.parse(["--check-rules"]).command, .checkRules)
        XCTAssertEqual(try CeeloOptions.parse(["--test", "hello there"]).command, .test("hello there"))
        XCTAssertTrue(try CeeloOptions.parse(["--help"]).showHelp)
        XCTAssertTrue(try CeeloOptions.parse(["-h"]).showHelp)
    }

    func testErrors() {
        XCTAssertThrowsError(try CeeloOptions.parse(["--push-to-talk"])) {
            XCTAssertEqual($0 as? CLIError, .unknownOption("--push-to-talk"))
        }
        XCTAssertThrowsError(try CeeloOptions.parse(["--test"])) {
            XCTAssertEqual($0 as? CLIError, .missingValue("--test"))
        }
        XCTAssertThrowsError(try CeeloOptions.parse(["--rules", "--quiet"])) {
            XCTAssertEqual($0 as? CLIError, .missingValue("--rules"))
        }
        XCTAssertThrowsError(try CeeloOptions.parse(["--live-window", "abc"])) {
            XCTAssertEqual($0 as? CLIError, .invalidNumber(option: "--live-window", value: "abc"))
        }
        XCTAssertThrowsError(try CeeloOptions.parse(["--live-update", "nan"]))
        XCTAssertThrowsError(try CeeloOptions.parse(["--check-rules", "--test", "x"])) {
            XCTAssertEqual($0 as? CLIError, .conflictingCommands)
        }
    }

    func testErrorMessages() {
        XCTAssertEqual("\(CLIError.unknownOption("--x"))", "Unknown option: --x")
        XCTAssertEqual("\(CLIError.missingValue("--rules"))", "Missing value for --rules")
        XCTAssertEqual("\(CLIError.invalidNumber(option: "--live-update", value: "q"))", "Invalid number for --live-update: q")
        XCTAssertEqual("\(CLIError.conflictingCommands)", "Use only one of --check-rules and --test")
    }

    func testTiming() {
        let timing = SoundboardTiming(liveWindowSec: 0.1, liveUpdateSec: 0.01, minAudioSec: 5, maxBufferSec: 0).sanitized()
        XCTAssertEqual(timing, SoundboardTiming(liveWindowSec: 0.5, liveUpdateSec: 0.1, minAudioSec: 0.5, maxBufferSec: 1.5))
        XCTAssertEqual(SoundboardTiming(liveWindowSec: 2, liveUpdateSec: 0.2, minAudioSec: 0, maxBufferSec: 6).sanitized().minAudioSec, 0.2)
        XCTAssertEqual(SoundboardTiming.default.refireGuardSec, SoundboardTiming.default.liveWindowSec + 1)
    }
}
