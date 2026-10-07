import AVFoundation
import XCTest
@testable import CeeloCore

final class SoundPlayerTests: XCTestCase {
    private var dir: TempSoundsDirectory!
    private var tone: URL!

    override func setUpWithError() throws {
        dir = try TempSoundsDirectory()
        tone = try dir.writeTone("tone.caf")
    }

    override func tearDown() {
        dir = nil
    }

    func testPlayReportsDurationForPreloadedAndUnloadedSounds() {
        let player = SoundPlayer()
        player.volume = 0
        var durations: [TimeInterval] = []
        player.onPlay = { durations.append($0) }

        player.play(url: tone)
        player.preload([tone])
        player.warmUp()
        player.play(url: tone)
        player.play(url: tone)

        XCTAssertEqual(durations.count, 3)
        for duration in durations {
            XCTAssertEqual(duration, 0.25, accuracy: 0.02)
        }
    }

    func testFinishedPlayersAreRecycled() async throws {
        let player = SoundPlayer()
        player.volume = 0
        player.preload([tone])
        player.play(url: tone)
        player.play(url: tone)
        // Both the preloaded and the overlapping player finish, and either can be reused afterwards.
        try await pause(0.6)
        var played = 0
        player.onPlay = { _ in played += 1 }
        player.play(url: tone)
        XCTAssertEqual(played, 1)
    }

    func testDelegateCallbacksHandleUnknownPlayers() throws {
        let player = SoundPlayer()
        let stray = try AVAudioPlayer(contentsOf: tone)
        player.audioPlayerDidFinishPlaying(stray, successfully: true)
        player.audioPlayerDecodeErrorDidOccur(stray, error: nil)
    }

    func testWarmUpWithNothingPreloadedIsANoOp() {
        SoundPlayer().warmUp()
    }

    func testUnreadableSoundIsSkipped() throws {
        let player = SoundPlayer()
        var played = false
        player.onPlay = { _ in played = true }
        player.play(url: dir.url.appendingPathComponent("missing.wav"))
        try dir.write("broken.wav", contents: "not audio")
        player.preload([dir.url.appendingPathComponent("broken.wav")])
        XCTAssertFalse(played)
    }
}
