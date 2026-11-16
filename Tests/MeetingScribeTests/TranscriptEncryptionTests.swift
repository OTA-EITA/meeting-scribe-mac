import Testing
import Foundation
import CryptoKit
@testable import MeetingScribe

struct TranscriptCryptoTests {
    private let key = SymmetricKey(size: .bits256)

    @Test func roundTripsJapaneseText() throws {
        let sealed = try TranscriptCrypto.seal("[00:00:01] [田中] こんにちは", using: key)
        #expect(TranscriptCrypto.isSealed(sealed))
        #expect(try TranscriptCrypto.open(sealed, using: key) == "[00:00:01] [田中] こんにちは")
    }

    @Test func doesNotLeakPlainText() throws {
        let sealed = try TranscriptCrypto.seal("社外秘の売上の話", using: key)
        #expect(sealed.range(of: Data("社外秘".utf8)) == nil)
    }

    @Test func rejectsAnotherKey() throws {
        let sealed = try TranscriptCrypto.seal("こんにちは", using: key)
        #expect(throws: (any Error).self) {
            try TranscriptCrypto.open(sealed, using: SymmetricKey(size: .bits256))
        }
    }

    @Test func rejectsTamperedData() throws {
        var sealed = try TranscriptCrypto.seal("こんにちは", using: key)
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            try TranscriptCrypto.open(sealed, using: key)
        }
    }

    @Test func doesNotTreatPlainTextAsSealed() {
        #expect(!TranscriptCrypto.isSealed(Data("[00:00:01] [自分] こんにちは".utf8)))
    }
}

struct TranscriptFilesEncryptionTests {
    private let key = SymmetricKey(size: .bits256)

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func writesOnlyTheSealedFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("議事録_test.txt")

        let written = try TranscriptFiles.write("[相手1] どうも", to: textURL, encrypt: true, markdown: true, key: { key })

        #expect(written.lastPathComponent == "議事録_test.txt.enc")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["議事録_test.txt.enc"])
        #expect(try TranscriptFiles.read(written, key: { key }) == "[相手1] どうも")
    }

    @Test func rewritesSealedFilesSealed() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try TranscriptFiles.write("[相手1] どうも", to: folder.appendingPathComponent("議事録_test.txt"),
                                                encrypt: true, key: { key })

        try TranscriptFiles.rewrite("[田中] どうも", at: written, markdown: true, key: { key })

        #expect(TranscriptCrypto.isSealed(try Data(contentsOf: written)))
        #expect(try TranscriptFiles.read(written, key: { key }) == "[田中] どうも")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["議事録_test.txt.enc"])
    }

    @Test func readsPlainTextWithoutTheKey() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let textURL = folder.appendingPathComponent("議事録_test.txt")
        try "[自分] 平文".write(to: textURL, atomically: true, encoding: .utf8)

        let text = try TranscriptFiles.read(textURL, key: { throw TranscriptKeyStore.Failure.keychain(errSecItemNotFound) })
        #expect(text == "[自分] 平文")
    }

    @Test func acceptsSealedFilesInTheExportFolder() {
        let folder = URL(fileURLWithPath: "/tmp/MeetingScribeExportFolder", isDirectory: true)
        #expect(TranscriptFiles.isExportedTranscript(folder.appendingPathComponent("議事録_1.txt.enc"), in: folder))
        #expect(!TranscriptFiles.isExportedTranscript(folder.appendingPathComponent("議事録_1.sh.enc"), in: folder))
    }

    @Test func titleDropsBothExtensions() {
        #expect(TranscriptFiles.title(for: URL(fileURLWithPath: "/tmp/議事録_1.txt.enc")) == "議事録_1")
        #expect(TranscriptFiles.title(for: URL(fileURLWithPath: "/tmp/議事録_1.txt")) == "議事録_1")
    }
}
