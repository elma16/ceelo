import XCTest
@testable import CeeloCore

final class RunnerTests: XCTestCase {
    private func exitCode(_ result: LaunchResult, file: StaticString = #filePath, line: UInt = #line) -> Int32? {
        guard case .finished(let code) = result else {
            XCTFail("expected ceelo to finish", file: file, line: line)
            return nil
        }
        return code
    }

    func testHelpAndArgumentErrors() {
        let env = TestEnvironment()
        XCTAssertEqual(exitCode(CeeloRunner.launch(["--help"], environment: env.environment)), 0)
        XCTAssertEqual(exitCode(CeeloRunner.launch(["--wav", "x.wav"], environment: env.environment)), 2)
    }

    func testSoundsAndRulesProblemsExitTwo() throws {
        let env = TestEnvironment()
        let dir = try TempSoundsDirectory(files: ["boom.mp3"])
        let missingDir = dir.url.appendingPathComponent("nope").path
        XCTAssertEqual(exitCode(CeeloRunner.launch(["--sounds-dir", missingDir], environment: env.environment)), 2)

        let missingRules = dir.url.appendingPathComponent("missing.json").path
        XCTAssertEqual(exitCode(CeeloRunner.launch(
            ["--sounds-dir", dir.url.path, "--rules", missingRules], environment: env.environment
        )), 2)

        try dir.write("rules.json", contents: #"{"rules": [{"sound": "boom", "trigger_any": ["x"]}]}"#)
        XCTAssertEqual(exitCode(CeeloRunner.launch(
            ["--sounds-dir", dir.url.path, "--check-rules"], environment: env.environment
        )), 2, "rules.json in the sounds directory is picked up and checked")

        let empty = try TempSoundsDirectory()
        XCTAssertEqual(exitCode(CeeloRunner.launch(["--sounds-dir", empty.url.path], environment: env.environment)), 2)
    }

    func testCheckRulesAndTestCommands() throws {
        let dir = try TempSoundsDirectory(files: ["boom.mp3", "chime.wav"])
        try dir.write("party.json", contents: #"{"rules": [{"sound": "chime", "say": ["new ticket"]}]}"#)
        let rules = dir.url.appendingPathComponent("party.json").path
        let env = TestEnvironment()
        let base = ["--sounds-dir", dir.url.path, "--rules", rules]

        XCTAssertEqual(exitCode(CeeloRunner.launch(base + ["--check-rules"], environment: env.environment)), 0)
        XCTAssertEqual(exitCode(CeeloRunner.launch(base + ["--test", "a new ticket, boom"], environment: env.environment)), 0)
        XCTAssertEqual(exitCode(CeeloRunner.launch(base + ["--test", "nothing"], environment: env.environment)), 0)
    }

    func testListeningPlaysTheSoundForASpokenPhrase() async throws {
        let dir = try TempSoundsDirectory()
        try dir.writeTone("boom.caf")
        let env = TestEnvironment(transcriber: ScriptedTranscriber([], fallback: "and then boom"))
        let plays = Recorder<TimeInterval>()
        env.player.onPlay = { plays.append($0) }

        guard case .running(let stop) = CeeloRunner.launch(
            ["--sounds-dir", dir.url.path, "--live-update", "0.1", "--quiet"], environment: env.environment
        ) else { return XCTFail("expected ceelo to listen") }

        try await waitUntil { env.audioInput.isRunning }
        env.audioInput.feed([Float](repeating: 0.1, count: seconds(1)))
        try await waitUntil { !plays.values.isEmpty }
        XCTAssertEqual(plays.values.first ?? 0, 0.25, accuracy: 0.02)

        stop()
        XCTAssertFalse(env.audioInput.isRunning)
        XCTAssertEqual(env.terminated.values, [])
    }

    func testListeningWithARulesFileIgnoresTheMicWhileTheSoundPlays() async throws {
        let dir = try TempSoundsDirectory()
        try dir.writeTone("chime.caf")
        try dir.write("rules.json", contents: #"{"rules": [{"sound": "chime", "say": ["new ticket"]}]}"#)
        let env = TestEnvironment(transcriber: ScriptedTranscriber([], fallback: "a new ticket"))
        let plays = Recorder<TimeInterval>()
        env.player.onPlay = { plays.append($0) }

        guard case .running(let stop) = CeeloRunner.launch(
            ["--sounds-dir", dir.url.path, "--live-update", "0.1"],
            environment: env.environment
        ) else { return XCTFail("expected ceelo to listen") }

        try await waitUntil { env.audioInput.isRunning }
        env.audioInput.feed([Float](repeating: 0.1, count: seconds(1)))
        try await waitUntil { !plays.values.isEmpty }
        // The transcriber keeps saying "new ticket", but audio during the 0.25s sound (+0.4s) is dropped
        // and the phrase can't repeat within the window, so nothing else plays.
        env.audioInput.feed([Float](repeating: 0.1, count: seconds(1)))
        try await pause(0.4)
        XCTAssertEqual(plays.values.count, 1)
        stop()
    }

    func testTerminatesWhenTheModelsOrMicrophoneFail() async throws {
        let dir = try TempSoundsDirectory()
        try dir.writeTone("boom.caf")

        let noModels = TestEnvironment()
        noModels.loadRuntime = { throw TranscriberFailure() }
        guard case .running(let stop) = CeeloRunner.launch(["--sounds-dir", dir.url.path], environment: noModels.environment)
        else { return XCTFail("expected ceelo to listen") }
        try await waitUntil { noModels.terminated.values == [1] }
        stop()

        let noMic = TestEnvironment()
        noMic.audioInput.failToStart = true
        guard case .running(let stopNoMic) = CeeloRunner.launch(["--sounds-dir", dir.url.path], environment: noMic.environment)
        else { return XCTFail("expected ceelo to listen") }
        try await waitUntil { noMic.terminated.values == [1] }
        stopNoMic()
    }

    func testStoppingBeforeTheModelsLoadNeverStartsListening() async throws {
        let dir = try TempSoundsDirectory()
        try dir.writeTone("boom.caf")
        let env = TestEnvironment()
        let gate = GatedTranscriber()
        let runtime = SpeechRuntime(transcriber: ScriptedTranscriber([]), detector: FixedDetector(speech: true))
        env.loadRuntime = {
            _ = try await gate.transcribe([])
            return runtime
        }

        guard case .running(let stop) = CeeloRunner.launch(["--sounds-dir", dir.url.path], environment: env.environment)
        else { return XCTFail("expected ceelo to listen") }
        try await waitUntil { gate.isWaiting }
        stop()
        gate.release()
        try await pause(0.1)
        XCTAssertEqual(env.audioInput.startCount, 0)
    }
}
