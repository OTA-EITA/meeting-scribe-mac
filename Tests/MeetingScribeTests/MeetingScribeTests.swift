import XCTest
import Foundation
import WhisperKit
import SpeakerKit
@testable import MeetingScribe

final class TranscriptMessageTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let message = TranscriptMessage(
            type: "transcript",
            status: nil,
            confirmedText: "こんにちは",
            unconfirmedText: "今",
            message: nil,
            action: nil
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TranscriptMessage.self, from: data)
        XCTAssertEqual(decoded.type, "transcript")
        XCTAssertEqual(decoded.confirmedText, "こんにちは")
        XCTAssertEqual(decoded.unconfirmedText, "今")
    }

    func testOmitsAbsentOptionalFields() throws {
        let message = TranscriptMessage(type: "control", status: nil, confirmedText: nil, unconfirmedText: nil, message: nil, action: "start")
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("status"))
        XCTAssertFalse(json.contains("confirmedText"))
    }
}

final class ExportSettingsTests: XCTestCase {
    private let key = "exportFolderPath"
    private var previousValue: String?

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let previousValue {
            UserDefaults.standard.set(previousValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testFallsBackToDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ExportSettings.folderURL, ExportSettings.defaultFolderURL)
    }

    func testPersistsChosenFolder() {
        let customFolder = URL(fileURLWithPath: "/tmp/MeetingScribeTestFolder", isDirectory: true)
        ExportSettings.folderURL = customFolder
        XCTAssertEqual(ExportSettings.folderURL, customFolder)
    }
}

/// TranscriptionServer.whisperKit はテストでは常に nil (start() を呼んでいない
/// ため) なので、labelSegmentsHybrid は音源判定を試みられず、常に
/// 話者分離(latestDiarization)のみによるフォールバック経路を通る。
/// 音源による自分/相手の一次判定自体は MixedAudioProcessor が実機で
/// 提供する情報に依存するため、ここでは検証していない。
@MainActor
final class TranscriptionServerTextFormattingTests: XCTestCase {
    func testLabelSegmentsHybridHandlesEmptySegments() {
        let server = TranscriptionServer()
        XCTAssertTrue(server.labelSegmentsHybrid([]).isEmpty)
    }

    func testLabelSegmentsHybridFallsBackToDiarizationSpeakerLabels() {
        let server = TranscriptionServer()
        let segments = [
            TranscriptionSegment(start: 0.0, end: 1.0, text: "おはよう"),
            TranscriptionSegment(start: 1.0, end: 2.0, text: "です"),
            TranscriptionSegment(start: 2.0, end: 3.0, text: "こんにちは")
        ]
        server.latestDiarization = DiarizationResult(
            speakerCount: 2,
            totalFrames: 0,
            frameRate: 1,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0.0, endTime: 2.0, frameRate: 1),
                SpeakerSegment(speaker: .speakerId(1), startTime: 2.0, endTime: 3.0, frameRate: 1)
            ]
        )
        let result = server.labelSegmentsHybrid(segments)
        XCTAssertEqual(result, "[話者1] おはようです\n[話者2] こんにちは")
    }

    func testLabelSegmentsHybridFallsBackToUnknownWithoutDiarizationData() {
        let server = TranscriptionServer()
        let segments = [TranscriptionSegment(start: 10.0, end: 11.0, text: "テスト")]
        XCTAssertEqual(server.labelSegmentsHybrid(segments), "[不明] テスト")
    }
}
