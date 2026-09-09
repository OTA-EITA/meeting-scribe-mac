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

@MainActor
final class TranscriptionServerTextFormattingTests: XCTestCase {
    func testJoinWithPauseBreaksInsertsNewlineAfterLongSilence() {
        let server = TranscriptionServer()
        let segments = [
            TranscriptionSegment(start: 0.0, end: 1.0, text: "こんにちは"),
            TranscriptionSegment(start: 1.2, end: 2.0, text: "元気ですか"), // 0.2s gap: same line
            TranscriptionSegment(start: 5.0, end: 6.0, text: "また今度")   // 3s gap: new line
        ]
        let result = server.joinWithPauseBreaks(segments)
        XCTAssertEqual(result, "こんにちは元気ですか\nまた今度")
    }

    func testJoinWithPauseBreaksHandlesEmptySegments() {
        let server = TranscriptionServer()
        XCTAssertTrue(server.joinWithPauseBreaks([]).isEmpty)
    }

    func testLabelSegmentsGroupsBySpeakerAndInsertsLabelOnChange() {
        let server = TranscriptionServer()
        let segments = [
            TranscriptionSegment(start: 0.0, end: 1.0, text: "おはよう"),
            TranscriptionSegment(start: 1.0, end: 2.0, text: "です"),
            TranscriptionSegment(start: 2.0, end: 3.0, text: "こんにちは")
        ]
        let diarization = DiarizationResult(
            speakerCount: 2,
            totalFrames: 0,
            frameRate: 1,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0.0, endTime: 2.0, frameRate: 1),
                SpeakerSegment(speaker: .speakerId(1), startTime: 2.0, endTime: 3.0, frameRate: 1)
            ]
        )
        let result = server.labelSegments(segments, with: diarization)
        XCTAssertEqual(result, "[話者1] おはようです\n[話者2] こんにちは")
    }

    func testLabelSegmentsFallsBackToUnknownSpeakerWithoutOverlap() {
        let server = TranscriptionServer()
        let segments = [TranscriptionSegment(start: 10.0, end: 11.0, text: "テスト")]
        let diarization = DiarizationResult(speakerCount: 0, totalFrames: 0, frameRate: 1, segments: [])
        let result = server.labelSegments(segments, with: diarization)
        XCTAssertEqual(result, "[話者不明] テスト")
    }
}
