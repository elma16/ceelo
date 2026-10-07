import FluidAudio
import XCTest
@testable import CeeloCore

final class LiveWordTrackerTests: XCTestCase {
    /// A window ending at `end` seconds, `length` long, with words at absolute times.
    private func step(
        _ tracker: inout LiveWordTracker,
        end: Double,
        length: Double = 2,
        cut: Bool = true,
        _ words: [(String, Double, Double)]
    ) -> [String] {
        let start = end - length
        let window = RollingAudioBuffer.Window(
            samples: [Float](repeating: 0, count: seconds(length)),
            endPosition: seconds(end),
            isCutOnTheLeft: cut
        )
        let transcript = Transcript(
            text: words.map(\.0).joined(separator: " "),
            words: words.map { TimedWord(text: $0.0, start: $0.1 - start, end: $0.2 - start) }
        )
        return tracker.newWords(in: transcript, window: window)
    }

    func testWordsWhoseTimestampsDriftArePrintedOnce() {
        // Taken from a real trace: "on" moved from 1.28s to 1.48s, "Friday" stretched as context arrived.
        var tracker = LiveWordTracker()
        XCTAssertEqual(step(&tracker, end: 1.8, cut: false, [("due", 1.04, 1.28), ("on", 1.28, 1.44), ("Friday.", 1.44, 1.76)]),
                       ["due", "on"])
        XCTAssertEqual(step(&tracker, end: 2.2, [("due", 1.16, 1.48), ("on", 1.48, 1.72), ("Friday", 1.72, 1.96)]), [])
        XCTAssertEqual(step(&tracker, end: 2.4, [("due", 1.20, 1.52), ("on", 1.52, 1.68), ("Friday", 1.68, 2.08)]),
                       ["Friday"])
        XCTAssertEqual(step(&tracker, end: 2.9, [("on", 1.52, 1.76), ("Friday,", 1.76, 2.32), ("so", 2.32, 2.48)]),
                       ["so"])
    }

    func testFragmentsAtTheLeftEdgeAndUnfinishedWordsAtTheRightAreSkipped() {
        var tracker = LiveWordTracker()
        XCTAssertEqual(step(&tracker, end: 3.0, [("uneral", 1.0, 1.2), ("was", 1.3, 1.5), ("sad", 2.6, 2.9)]), ["was"])
        XCTAssertEqual(step(&tracker, end: 3.4, [("was", 1.4, 1.6), ("sad", 2.6, 2.9)]), ["sad"])
    }

    func testLateRevisionsOfThePastAreNotPrinted() {
        var tracker = LiveWordTracker()
        XCTAssertEqual(step(&tracker, end: 3.0, [("the", 1.5, 1.6), ("final", 1.6, 2.0)]), ["the", "final"])
        // The model now hears "finance" where "final" was printed: a revision, too similar to be new.
        XCTAssertEqual(step(&tracker, end: 3.4, [("the", 1.5, 1.6), ("finance", 1.65, 2.1), ("team", 2.2, 2.5)]),
                       ["team"])
        // A different word squeezed in before what's printed is dropped rather than printed out of order.
        XCTAssertEqual(step(&tracker, end: 3.6, [("to", 1.4, 1.5), ("team", 2.2, 2.5)]), [])
    }

    func testRepeatsFarEnoughApartAreRealWords() {
        var tracker = LiveWordTracker()
        XCTAssertEqual(step(&tracker, end: 3.0, cut: false, [("no", 1.0, 1.2), ("no", 1.8, 2.0)]), ["no", "no"])
    }

    func testOldWordsAreForgotten() {
        var tracker = LiveWordTracker()
        XCTAssertEqual(step(&tracker, end: 2.0, cut: false, [("yes", 0.5, 0.8)]), ["yes"])
        XCTAssertEqual(step(&tracker, end: 10.0, [("yes", 8.5, 8.8)]), ["yes"])
    }

    func testTokensAreJoinedIntoWords() {
        func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
            TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
        }
        let joined = words(from: [
            token("er", 0.0, 0.1),
            token(" fun", 0.1, 0.2), token("er", 0.2, 0.3), token("al", 0.3, 0.4),
            token("▁Hi", 0.5, 0.6), token(" ", 0.6, 0.6), token(".", 0.6, 0.7)
        ])
        XCTAssertEqual(joined, [
            TimedWord(text: "er", start: 0.0, end: 0.1),
            TimedWord(text: "funeral", start: 0.1, end: 0.4),
            TimedWord(text: "Hi.", start: 0.5, end: 0.7)
        ])
    }

    func testBufferWindowsKnowTheirPosition() {
        let buffer = RollingAudioBuffer(capacity: 4)
        buffer.append([1, 2, 3, 4, 5, 6])
        let window = buffer.window(3)
        XCTAssertEqual(window.samples, [4, 5, 6])
        XCTAssertEqual(window.endPosition, 6)
        XCTAssertTrue(window.isCutOnTheLeft)
        XCTAssertFalse(buffer.window(10).isCutOnTheLeft)

        buffer.append([7, 8, 9])
        XCTAssertEqual(buffer.window(2).endPosition, 9, "positions survive trimming")
        buffer.removeAll()
        buffer.append([10])
        let afterClear = buffer.window(5)
        XCTAssertEqual(afterClear.samples, [10])
        XCTAssertEqual(afterClear.endPosition, 10, "positions keep counting after a clear")
        XCTAssertFalse(afterClear.isCutOnTheLeft)
    }

    func testPrintingLiveOutput() {
        printLiveOutput(.words("[LiveWordTrackerTests]"))
        printLiveOutput(.pause)
    }
}
