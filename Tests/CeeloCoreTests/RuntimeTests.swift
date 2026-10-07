import FluidAudio
import XCTest
@testable import CeeloCore

/// Runs the real Parakeet and Silero models. Skipped when they aren't downloaded (e.g. on CI) or when
/// CEELO_SKIP_MODEL_TESTS is set.
final class FluidRuntimeIntegrationTests: XCTestCase {
    private static var cached: SpeechRuntime?
    private var dir: TempSoundsDirectory!

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["CEELO_SKIP_MODEL_TESTS"] != nil {
            throw XCTSkip("CEELO_SKIP_MODEL_TESTS is set")
        }
        guard speechModelsAreDownloaded() else {
            throw XCTSkip("Speech models are not downloaded")
        }
        dir = try TempSoundsDirectory()
    }

    override func tearDown() {
        dir = nil
    }

    private func runtime() async throws -> SpeechRuntime {
        if let cached = Self.cached { return cached }
        let status = Recorder<String>()
        let runtime = try await loadFluidSpeechRuntime(status: { status.append($0) })
        XCTAssertTrue(status.values.contains { $0.contains("Loading speech models") })
        Self.cached = runtime
        return runtime
    }

    /// Speech from the system voice, written to the temp directory and deleted with it.
    private func speech(_ text: String) throws -> [Float] {
        let url = dir.url.appendingPathComponent("\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        try XCTSkipIf(say.terminationStatus != 0, "say is unavailable")
        return try AudioConverter().resampleAudioFile(url)
    }

    func testTranscribesSpeechWithWordTimingsIncludingClipsUnderASecond() async throws {
        let runtime = try await runtime()
        let sentence = try await runtime.transcriber.transcribe(try speech("please send the quarterly numbers"))
        XCTAssertTrue(normalizeText(sentence.text).contains("quarterly numbers"), sentence.text)
        XCTAssertEqual(sentence.words.map { normalizeText($0.text) }.joined(separator: " "), normalizeText(sentence.text))
        XCTAssertEqual(sentence.words.map(\.start), sentence.words.map(\.start).sorted())

        let short = try speech("yes")
        XCTAssertLessThan(short.count, asrMinimumSamples)
        let word = try await runtime.transcriber.transcribe(short)
        XCTAssertEqual(normalizeText(word.text), "yes")
    }

    func testDetectorSeparatesSpeechFromSilence() async throws {
        let runtime = try await runtime()
        let hasSpeech = try await runtime.detector.containsSpeech(try speech("heads up, new ticket"))
        let hasSilence = try await runtime.detector.containsSpeech([Float](repeating: 0, count: seconds(2)))
        XCTAssertTrue(hasSpeech)
        XCTAssertFalse(hasSilence)
    }
}
