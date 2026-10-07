import XCTest
@testable import CeeloCore

final class SoundboardPipelineTests: XCTestCase {
    private let timing = SoundboardTiming(liveWindowSec: 2.0, liveUpdateSec: 0.2, minAudioSec: 0.4, maxBufferSec: 6.0)

    private func makePipeline(
        transcriber: SpeechTranscriber,
        detector: SpeechDetector? = nil,
        handler: RecordingHandler = RecordingHandler(),
        clock: TestClock = TestClock(),
        onLive: ((LiveOutput) -> Void)? = nil
    ) -> SoundboardPipeline {
        SoundboardPipeline(
            handler: handler,
            timing: timing,
            transcriber: transcriber,
            detector: detector,
            clock: { clock.now },
            onLive: onLive
        )
    }

    func testWaitsForMinimumAudio() async {
        let transcriber = ScriptedTranscriber(["hello"])
        let pipeline = makePipeline(transcriber: transcriber)
        pipeline.append([Float](repeating: 0.1, count: seconds(0.3)))
        let outcome = await pipeline.tick()
        XCTAssertEqual(outcome, .tooShort)
        XCTAssertTrue(transcriber.calls.isEmpty)
    }

    func testTranscribesOnlyTheLatestWindowAndPassesTextToHandler() async {
        let transcriber = ScriptedTranscriber(["new ticket"])
        let handler = RecordingHandler()
        let clock = TestClock()
        let pipeline = makePipeline(transcriber: transcriber, handler: handler, clock: clock)
        let old = [Float](repeating: 0.5, count: seconds(1))
        let recent = [Float](repeating: 0.25, count: seconds(2))
        pipeline.append(old + recent)
        clock.advance(3)

        let outcome = await pipeline.tick()
        XCTAssertEqual(outcome, .transcribed("new ticket"))
        XCTAssertEqual(transcriber.calls, [recent])
        XCTAssertEqual(handler.texts, ["new ticket"])
        XCTAssertEqual(handler.times, [t0.addingTimeInterval(3)])
    }

    func testSilentWindowsSkipAsr() async {
        let transcriber = ScriptedTranscriber(["hello"])
        let detector = FixedDetector(speech: false)
        let handler = RecordingHandler()
        let pipeline = makePipeline(transcriber: transcriber, detector: detector, handler: handler)
        pipeline.append([Float](repeating: 0, count: seconds(1)))

        let silent = await pipeline.tick()
        XCTAssertEqual(silent, .silent)
        XCTAssertTrue(transcriber.calls.isEmpty)
        XCTAssertTrue(handler.texts.isEmpty)

        detector.speech = true
        let spoken = await pipeline.tick()
        XCTAssertEqual(spoken, .transcribed("hello"))
        XCTAssertEqual(detector.calls, 2)
    }

    func testPauseDropsBufferedAudioAndIgnoresMicUntilItExpires() async {
        let transcriber = ScriptedTranscriber(["after"])
        let clock = TestClock()
        let pipeline = makePipeline(transcriber: transcriber, clock: clock)
        pipeline.append([Float](repeating: 0.1, count: seconds(1)))

        pipeline.pauseRecording(for: 1.0)
        pipeline.append([Float](repeating: 0.1, count: seconds(1)))
        let paused = await pipeline.tick()
        XCTAssertEqual(paused, .paused)

        clock.advance(1.1)
        let empty = await pipeline.tick()
        XCTAssertEqual(empty, .tooShort, "audio from before and during the pause is gone")

        pipeline.append([Float](repeating: 0.1, count: seconds(0.5)))
        let resumed = await pipeline.tick()
        XCTAssertEqual(resumed, .transcribed("after"))
    }

    func testAShorterPauseDoesNotCutALongerOneShort() async {
        let clock = TestClock()
        let pipeline = makePipeline(transcriber: ScriptedTranscriber([]), clock: clock)
        pipeline.pauseRecording(for: 1.0)
        pipeline.pauseRecording(for: 0.1)
        clock.advance(0.5)
        let outcome = await pipeline.tick()
        XCTAssertEqual(outcome, .paused)
    }

    func testOverlappingTicksAreDropped() async throws {
        let transcriber = GatedTranscriber()
        let pipeline = makePipeline(transcriber: transcriber)
        pipeline.append([Float](repeating: 0.1, count: seconds(1)))

        let first = Task { await pipeline.tick() }
        try await waitUntil { transcriber.isWaiting }
        let second = await pipeline.tick()
        XCTAssertEqual(second, .busy)

        transcriber.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .transcribed("gated"))
    }

    func testFailureDoesNotWedgeThePipeline() async {
        let transcriber = ScriptedTranscriber(results: [.failure(TranscriberFailure()), .success("ok")])
        let pipeline = makePipeline(transcriber: transcriber)
        pipeline.append([Float](repeating: 0.1, count: seconds(1)))

        guard case .failed = await pipeline.tick() else {
            return XCTFail("expected failure")
        }
        let recovered = await pipeline.tick()
        XCTAssertEqual(recovered, .transcribed("ok"))
    }

    func testLiveOutputShowsEachWordOnceAndBreaksAtPauses() async {
        // Three overlapping windows over "hello big world"; timings are relative to each window's start.
        func words(_ list: [(String, Double, Double)]) -> [TimedWord] {
            list.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
        }
        let transcriber = ScriptedTranscriber(transcripts: [
            Transcript(text: "hello big", words: words([("hello", 0.1, 0.4), ("big", 0.5, 0.8)])),
            Transcript(text: "hello big world", words: words([("hello", 0.1, 0.4), ("big", 0.5, 0.8), ("world", 0.9, 1.2)])),
            Transcript(text: "big world", words: words([("big", 0.0, 0.3), ("world", 0.4, 0.7)]))
        ])
        let detector = FixedDetector(speech: true)
        let outputs = Recorder<LiveOutput>()
        let pipeline = makePipeline(transcriber: transcriber, detector: detector, onLive: { outputs.append($0) })

        pipeline.append([Float](repeating: 0.1, count: seconds(1.2)))
        _ = await pipeline.tick()
        pipeline.append([Float](repeating: 0.1, count: seconds(0.4)))
        _ = await pipeline.tick()
        pipeline.append([Float](repeating: 0.1, count: seconds(0.5)))
        _ = await pipeline.tick()
        detector.speech = false
        _ = await pipeline.tick()
        _ = await pipeline.tick()

        XCTAssertEqual(outputs.values, [.words("hello big"), .words("world"), .pause])
    }
}
