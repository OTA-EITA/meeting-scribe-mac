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

/// UserDefaults.standard を書き換えるため、他のテストと並行させない。
@Suite(.serialized)
struct ModelSettingsTests {
    private func withRestoredDefaults(_ body: () -> Void) {
        let previousValue = UserDefaults.standard.string(forKey: "whisperModel")
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: "whisperModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "whisperModel")
            }
        }
        body()
    }

    @Test func defaultsToSmall() {
        withRestoredDefaults {
            UserDefaults.standard.removeObject(forKey: "whisperModel")
            #expect(ModelSettings.current == .small)
        }
    }

    @Test func persistsChosenModel() {
        withRestoredDefaults {
            ModelSettings.current = .medium
            #expect(ModelSettings.current == .medium)
        }
    }

    @Test func ignoresUnknownStoredValue() {
        withRestoredDefaults {
            UserDefaults.standard.set("no-such-model", forKey: "whisperModel")
            #expect(ModelSettings.current == .small)
        }
    }
}

struct TranscriptFormatterTests {
    @Test(arguments: [
        (Float(0), "00:00:00"),
        (Float(5.9), "00:00:05"),
        (Float(754), "00:12:34"),
        (Float(3661), "01:01:01")
    ])
    func formatsElapsedTime(_ seconds: Float, _ expected: String) {
        #expect(TranscriptFormatter.elapsed(seconds) == expected)
    }

    @Test func convertsTimestampedTextToMarkdown() {
        let text = """
        [00:00:01] [自分] おはようございます
        [00:00:09] 本題に入ります
        [00:00:15] [相手1] よろしくお願いします
        """
        let markdown = TranscriptFormatter.markdown(from: text, title: "議事録_2026-10-22")
        #expect(markdown == """
        # 議事録_2026-10-22

        - **00:00:01 自分**: おはようございます
        - **00:00:09 自分**: 本題に入ります
        - **00:00:15 相手1**: よろしくお願いします

        """)
    }

    @Test func findsOtherSpeakerLabelsInOrder() {
        let text = "[00:00:01] [相手2] a\n[00:00:02] [自分] b\n[00:00:03] [相手1] c\n[00:00:04] [相手2] d"
        #expect(TranscriptFormatter.otherSpeakerLabels(in: text) == ["相手2", "相手1"])
    }

    @Test func renamesSpeakersWithoutTouchingSimilarLabels() {
        let text = "[相手1] a\n[相手10] b\n相手1さんの件"
        let renamed = TranscriptFormatter.renameSpeakers(in: text, mapping: ["相手1": "田中", "相手10": ""])
        #expect(renamed == "[田中] a\n[相手10] b\n相手1さんの件")
    }
}

@MainActor
struct TranscriptionServerTimestampTests {
    @Test func prefixesEachLineWithElapsedTime() {
        let server = TranscriptionServer()
        let segments = [
            TranscriptionSegment(start: 1, end: 2, text: "一つ目"),
            TranscriptionSegment(start: 2, end: 3, text: "続き"),
            TranscriptionSegment(start: 9, end: 10, text: "間が空いた")
        ]
        #expect(server.labelSegmentsHybrid(segments, timestamps: true) == "[00:00:01] [不明] 一つ目続き\n[00:00:09] 間が空いた")
    }
}

struct TranscriptFilesTests {
    @Test func writesTextAndMarkdownSideBySide() throws {
        let previous = UserDefaults.standard.object(forKey: "exportMarkdown")
        defer { UserDefaults.standard.set(previous, forKey: "exportMarkdown") }
        ExportSettings.saveMarkdown = true

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let textURL = folder.appendingPathComponent("議事録_test.txt")
        try TranscriptFiles.write("[00:00:01] [自分] こんにちは", to: textURL)

        #expect(try String(contentsOf: textURL, encoding: .utf8) == "[00:00:01] [自分] こんにちは")
        let markdown = try String(contentsOf: TranscriptFiles.markdownURL(for: textURL), encoding: .utf8)
        #expect(markdown == "# 議事録_test\n\n- **00:00:01 自分**: こんにちは\n")
    }
}

@MainActor
struct TranscriptClientRenameTests {
    @Test func renamesOnScreenTextAndSavedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("議事録_test.txt")
        try "[00:00:01] [相手1] どうも".write(to: textURL, atomically: true, encoding: .utf8)

        let client = TranscriptClient()
        client.transcript = "[00:00:01] [相手1] どうも"
        client.lastExportURL = textURL
        client.renameSpeakers(["相手1": "田中"], exportFolder: folder)

        #expect(client.transcript == "[00:00:01] [田中] どうも")
        #expect(try String(contentsOf: textURL, encoding: .utf8) == "[00:00:01] [田中] どうも")
    }
}

struct OriginPolicyTests {
    @Test func allowsNativeClientsWithoutOrigin() {
        #expect(OriginPolicy.isAllowed(origin: nil))
    }

    @Test func allowsTheBundledChromeExtension() {
        #expect(OriginPolicy.isAllowed(origin: "chrome-extension://pjkgdgbmgcoooolfkjjgkinidnccojhj"))
    }

    @Test(arguments: [
        "https://evil.example",
        "http://localhost:3000",
        "null",
        "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "chrome-extension://pjkgdgbmgcoooolfkjjgkinidnccojhj.evil.example"
    ])
    func rejectsOtherBrowserOrigins(_ origin: String) {
        #expect(!OriginPolicy.isAllowed(origin: origin))
    }

    @Test func readsOriginHeaderCaseInsensitively() {
        let headers = [(name: "Host", value: "127.0.0.1:8765"), (name: "origin", value: "https://evil.example")]
        #expect(OriginPolicy.origin(in: headers) == "https://evil.example")
    }
}

struct TranscriptFilesLocationTests {
    private let folder = URL(fileURLWithPath: "/tmp/MeetingScribeExportFolder", isDirectory: true)

    @Test func acceptsTextFilesInTheExportFolder() {
        #expect(TranscriptFiles.isExportedTranscript(folder.appendingPathComponent("議事録_1.txt"), in: folder))
    }

    @Test(arguments: [
        "/etc/hosts",
        "/tmp/MeetingScribeExportFolder/../secret.txt",
        "/tmp/MeetingScribeExportFolderEvil/議事録_1.txt",
        "/tmp/MeetingScribeExportFolder/sub/議事録_1.txt",
        "/tmp/MeetingScribeExportFolder/議事録_1.sh"
    ])
    func rejectsOtherLocations(_ path: String) {
        #expect(!TranscriptFiles.isExportedTranscript(URL(fileURLWithPath: path), in: folder))
    }
}

@MainActor
struct TranscriptClientRenameGuardTests {
    @Test func doesNotRewriteFilesOutsideTheExportFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.appendingPathComponent("outside.txt")
        try "[相手1] そのまま".write(to: outside, atomically: true, encoding: .utf8)

        let client = TranscriptClient()
        client.transcript = "[相手1] そのまま"
        client.lastExportURL = outside
        client.renameSpeakers(["相手1": "田中"], exportFolder: folder.appendingPathComponent("exports", isDirectory: true))

        #expect(client.transcript == "[田中] そのまま")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "[相手1] そのまま")
    }
}
