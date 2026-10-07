import AVFoundation
import XCTest
@testable import CeeloCore

/// The real system-facing components, exercised only in ways that are safe on a developer machine or CI:
/// nothing here opens the microphone.
final class LiveComponentTests: XCTestCase {
    func testLiveEnvironmentBuildsTheRealComponents() {
        let live = CeeloEnvironment.live
        XCTAssertTrue(live.makeAudioInput() is MicrophoneCapture)
        XCTAssertEqual(live.makeSoundPlayer().volume, 1)
    }

    func testMicrophoneStopWithoutStartIsSafe() {
        MicrophoneCapture().stop()
    }

    func testMicrophoneErrorMessagesSayWhatToFix() {
        XCTAssertTrue(MicrophoneError.accessDenied.description.contains("Privacy & Security > Microphone"))
        XCTAssertTrue(MicrophoneError.noInputDevice.description.contains("Sound"))
        XCTAssertTrue(MicrophoneError.unsupportedFormat("2 ch").description.contains("2 ch"))
        XCTAssertTrue(MicrophoneError.engine(MicrophoneFailure()).description.contains("MicrophoneFailure"))
    }

    func testMicrophoneAccessCheck() {
        XCTAssertNoThrow(try MicrophoneCapture.checkAccess(status: .authorized, requestAccess: { XCTFail(); return false }))
        XCTAssertNoThrow(try MicrophoneCapture.checkAccess(status: .notDetermined, requestAccess: { true }))
        for status: AVAuthorizationStatus in [.denied, .restricted] {
            XCTAssertThrowsError(try MicrophoneCapture.checkAccess(status: status, requestAccess: { true })) {
                XCTAssertEqual("\($0)", MicrophoneError.accessDenied.description)
            }
        }
        XCTAssertThrowsError(try MicrophoneCapture.checkAccess(status: .notDetermined, requestAccess: { false }))
    }

    func testDeviceFormatCheckRejectsTheZeroHertzFormatReportedWithoutAccess() throws {
        XCTAssertThrowsError(try MicrophoneCapture.validate(deviceFormat: AVAudioFormat())) {
            XCTAssertEqual("\($0)", MicrophoneError.noInputDevice.description)
        }
        let real = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        XCTAssertNoThrow(try MicrophoneCapture.validate(deviceFormat: real))
    }
}
