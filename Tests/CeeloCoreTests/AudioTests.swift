import AVFoundation
import XCTest
@testable import CeeloCore

final class AudioTests: XCTestCase {
    func testShortWindowsArePaddedToTheAsrMinimum() {
        let padded = paddedForAsr([0.5, -0.5])
        XCTAssertEqual(padded.count, asrMinimumSamples)
        XCTAssertEqual(Array(padded.prefix(2)), [0.5, -0.5])
        XCTAssertTrue(padded.dropFirst(2).allSatisfy { $0 == 0 })

        let long = [Float](repeating: 0.1, count: asrMinimumSamples + 5)
        XCTAssertEqual(paddedForAsr(long), long)
    }

    func testPeakNormalization() {
        XCTAssertEqual(peakNormalized([0.25, -0.5, 0.1]), [0.5, -1.0, 0.2])
        XCTAssertEqual(peakNormalized([0, 1e-7]), [0, 1e-7], "near-silence is left alone")
        XCTAssertEqual(peakNormalized([]), [])
    }

    func testRollingBufferKeepsRecentSamplesWithinCapacity() {
        let buffer = RollingAudioBuffer(capacity: 10)
        buffer.append((0..<15).map(Float.init))
        XCTAssertEqual(buffer.count, 15, "trimming happens in batches past twice the capacity")
        buffer.append((15..<25).map(Float.init))
        XCTAssertEqual(buffer.all(), (15..<25).map(Float.init))
        XCTAssertEqual(buffer.latest(3), [22, 23, 24])
        XCTAssertEqual(buffer.latest(100).count, 10)
        buffer.removeAll()
        XCTAssertEqual(buffer.count, 0)
    }

    func testSampleRateConverterDoesNotRepeatAudio() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let converter = try XCTUnwrap(SampleRateConverter(from: inputFormat))

        // A rising ramp: repeated input would show up as the output jumping backwards.
        let frames = 2048
        let buffers = 48
        var output: [Float] = []
        for b in 0..<buffers {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                buffer.floatChannelData![0][i] = Float(b * frames + i) / 48_000
            }
            output += converter.convert(buffer)
        }

        let expected = buffers * frames / 3
        XCTAssertEqual(Double(output.count), Double(expected), accuracy: 64)
        let settled = output.dropFirst(64)
        let backwardsJumps = zip(settled, settled.dropFirst()).filter { $1 < $0 - 0.001 }.count
        XCTAssertEqual(backwardsJumps, 0)
        XCTAssertEqual(Double(output.last!), Double(buffers * frames) / 48_000, accuracy: 0.01)
    }
}
