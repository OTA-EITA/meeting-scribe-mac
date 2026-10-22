import Testing
import Foundation
import WhisperKit
import SpeakerKit
@testable import MeetingScribe

struct TranscriptMessageTests {
    @Test func roundTripsThroughJSON() throws {
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
        #expect(decoded.type == "transcript")
        #expect(decoded.confirmedText == "こんにちは")
        #expect(decoded.unconfirmedText == "今")
    }

    @Test func omitsAbsentOptionalFields() throws {
        let message = TranscriptMessage(type: "control", status: nil, confirmedText: nil, unconfirmedText: nil, message: nil, action: "start")
        let data = try JSONEncoder().encode(message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("status"))
        #expect(!json.contains("confirmedText"))
    }
}

/// UserDefaults.standard を書き換えるため、他のテストと並行させない。
@Suite(.serialized)
struct ExportSettingsTests {
    private let key = "exportFolderPath"

    private func withRestoredDefaults(_ body: () -> Void) {
        let previousValue = UserDefaults.standard.string(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func fallsBackToDefaultWhenUnset() {
        withRestoredDefaults {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(ExportSettings.folderURL == ExportSettings.defaultFolderURL)
        }
    }

    @Test func persistsChosenFolder() {
        withRestoredDefaults {
            let customFolder = URL(fileURLWithPath: "/tmp/MeetingScribeTestFolder", isDirectory: true)
            ExportSettings.folderURL = customFolder
            #expect(ExportSettings.folderURL == customFolder)
        }
    }
}

/// TranscriptionServer.whisperKit はテストでは常に nil (start() を呼んでいない
/// ため) なので、labelSegmentsHybrid は音源判定を試みられず、常に
/// 話者分離(latestDiarization)のみによるフォールバック経路を通る。
/// 音源による自分/相手の一次判定自体は MixedAudioProcessor が実機で
/// 提供する情報に依存するため、ここでは検証していない。
@MainActor
struct TranscriptionServerTextFormattingTests {
    @Test func labelSegmentsHybridHandlesEmptySegments() {
        let server = TranscriptionServer()
        #expect(server.labelSegmentsHybrid([]).isEmpty)
    }

    @Test func labelSegmentsHybridFallsBackToDiarizationSpeakerLabels() {
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
        #expect(result == "[話者1] おはようです\n[話者2] こんにちは")
    }

    @Test func labelSegmentsHybridFallsBackToUnknownWithoutDiarizationData() {
        let server = TranscriptionServer()
        let segments = [TranscriptionSegment(start: 10.0, end: 11.0, text: "テスト")]
        #expect(server.labelSegmentsHybrid(segments) == "[不明] テスト")
    }
}

struct HallucinationFilterTests {
    @Test(arguments: [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございました。",
        "(音楽)",
        "（拍手）",
        "[音楽]",
        "♪～",
        "チャンネル登録よろしくお願いします",
        "  "
    ])
    func dropsKnownHallucinations(_ text: String) {
        #expect(HallucinationFilter.clean(text).isEmpty)
    }

    @Test func removesBracketedNoiseButKeepsSpeech() {
        #expect(HallucinationFilter.clean("(音楽)それでは始めます") == "それでは始めます")
    }

    @Test func keepsOrdinarySpeech() {
        #expect(HallucinationFilter.clean("ありがとうございました") == "ありがとうございました")
    }

    @Test func dropsSegmentsThatBecomeEmpty() {
        let segments = [
            TranscriptionSegment(start: 0, end: 1, text: "(音楽)"),
            TranscriptionSegment(start: 1, end: 2, text: "本題に入ります")
        ]
        let result = HallucinationFilter.filter(segments)
        #expect(result.map(\.text) == ["本題に入ります"])
    }
}

@MainActor
struct TranscriptionServerHallucinationTests {
    @Test func labelSegmentsHybridSkipsHallucinatedSegments() {
        let server = TranscriptionServer()
        let segments = [
            TranscriptionSegment(start: 0, end: 1, text: "ご視聴ありがとうございました"),
            TranscriptionSegment(start: 1, end: 2, text: "テスト")
        ]
        #expect(server.labelSegmentsHybrid(segments) == "[不明] テスト")
    }
}
