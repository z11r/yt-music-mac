import Darwin
import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

private struct ExportFileFixture {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("StreamingExportFileTests-" + UUID().uuidString)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func prepare() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func url(_ name: String = "song.json") -> URL { directory.appendingPathComponent(name) }
    var metadata: PublicPlaybackMetadata {
        PublicPlaybackMetadata(track: Track(id: "abcDEF12_-3", title: "Song", artist: "Artist", origin: .catalog, contentKind: .song))!
    }
}

@Suite("Owned streaming metadata files")
struct StreamingExportFileTests {
    @Test func JSONContainsOnlyDisclosedTextAndExpiryAndClearsWithoutRemovingTheFile() async throws {
        let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
        let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
        let receipt = try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        let permit = gate.activate(target: receipt.id)
        let written = try await writer.write(StreamingMetadataDocument(metadata: fixture.metadata, now: fixture.date), receipt: receipt, gate: gate, permit: permit)
        let bytes = try Data(contentsOf: fixture.url())
        let value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(value.keys) == ["version", "state", "title", "artist", "updatedAt", "expiresAt"])
        #expect(value["title"] as? String == "Song" && value["artist"] as? String == "Artist")
        let formatter = ISO8601DateFormatter()
        let endText = try #require(value["expiresAt"] as? String)
        let end = try #require(formatter.date(from: endText))
        #expect(end.timeIntervalSince(fixture.date) == 15)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("abcDEF12_-3"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let cleared = try await writer.clear(receipt: written, now: fixture.date, gate: gate, through: gate.revoke())
        #expect(cleared.file == receipt.file && cleared.revision == 2)
        let stopped = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url())) as? [String: Any])
        #expect(stopped["state"] as? String == "stopped" && stopped["title"] == nil && stopped["artist"] == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.url().path))
    }

    @Test func TXTUsesOneLineAndGracefulClearLeavesAnEmptyOwnedFile() async throws {
        let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
        let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
        let receipt = try await writer.create(url: fixture.url("song.txt"), format: .text, now: fixture.date, gate: gate, revision: gate.revoke())
        let written = try await writer.write(StreamingMetadataDocument(metadata: fixture.metadata, now: fixture.date), receipt: receipt,
            gate: gate, permit: gate.activate(target: receipt.id))
        #expect(try String(contentsOf: fixture.url("song.txt"), encoding: .utf8) == "Song — Artist")
        _ = try await writer.clear(receipt: written, now: fixture.date, gate: gate, through: gate.revoke())
        #expect(try Data(contentsOf: fixture.url("song.txt")).isEmpty)
    }

    @Test func existingForeignFilesSymlinksAndDirectoriesCannotBeClaimed() async throws {
        let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
        let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
        let sentinel = Data("foreign file".utf8); try sentinel.write(to: fixture.url())
        await #expect(throws: StreamingExportError.invalidTarget) {
            try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        }
        try FileManager.default.createSymbolicLink(at: fixture.url("link.json"), withDestinationURL: fixture.url())
        await #expect(throws: StreamingExportError.invalidTarget) {
            try await writer.create(url: fixture.url("link.json"), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        }
        try FileManager.default.createDirectory(at: fixture.url("directory.json"), withIntermediateDirectories: false)
        await #expect(throws: StreamingExportError.invalidTarget) {
            try await writer.create(url: fixture.url("directory.json"), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        }
        #expect(try Data(contentsOf: fixture.url()) == sentinel)
    }

    @Test func foreignReplacementsManualEditsHardLinksAndPermissionsAreNeverOverwritten() async throws {
        for change in 0..<5 {
            let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
            let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
            let receipt = try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
            let bytes = Data("foreign content".utf8)
            switch change {
            case 0:
                try FileManager.default.moveItem(at: fixture.url(), to: fixture.url("old.json"))
                try bytes.write(to: fixture.url())
            case 1: try bytes.write(to: fixture.url())
            case 2: try FileManager.default.linkItem(at: fixture.url(), to: fixture.url("hard.json"))
            case 3: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url().path)
            default:
                try FileManager.default.moveItem(at: fixture.url(), to: fixture.url("old.json"))
                try bytes.write(to: fixture.url("foreign.json"))
                try FileManager.default.createSymbolicLink(at: fixture.url(), withDestinationURL: fixture.url("foreign.json"))
            }
            let before = try Data(contentsOf: fixture.url())
            await #expect(throws: StreamingExportError.changedTarget) {
                try await writer.write(StreamingMetadataDocument(metadata: fixture.metadata, now: fixture.date), receipt: receipt,
                    gate: gate, permit: gate.activate(target: receipt.id))
            }
            await #expect(throws: StreamingExportError.changedTarget) {
                try await writer.clear(receipt: receipt, now: fixture.date, gate: gate, through: gate.revoke())
            }
            #expect(try Data(contentsOf: fixture.url()) == before)
        }
    }

    @Test func stalePermissionsCannotCreateOrPublishAndOldClearsCannotEraseNewOutput() async throws {
        let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
        let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
        let old = gate.revoke(); _ = gate.revoke()
        await #expect(throws: StreamingExportError.revoked) {
            try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: old)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url().path))
        let receipt = try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        let permit = gate.activate(target: receipt.id); let revoked = gate.revoke()
        await #expect(throws: StreamingExportError.revoked) {
            try await writer.write(StreamingMetadataDocument(metadata: fixture.metadata, now: fixture.date), receipt: receipt, gate: gate, permit: permit)
        }
        let written = try await writer.write(StreamingMetadataDocument(metadata: fixture.metadata, now: fixture.date), receipt: receipt,
            gate: gate, permit: gate.activate(target: receipt.id))
        let before = try Data(contentsOf: fixture.url())
        await #expect(throws: StreamingExportError.revoked) {
            try await writer.clear(receipt: written, now: fixture.date, gate: gate, through: revoked)
        }
        #expect(try Data(contentsOf: fixture.url()) == before)
    }

    @Test func reopenedOwnedFilesRequireTheExactReceiptAndParentIdentity() async throws {
        let fixture = ExportFileFixture(); try fixture.prepare(); defer { fixture.remove() }
        let writer = StreamingExportFile(); let gate = PlaybackOutputGate()
        let receipt = try await writer.create(url: fixture.url(), format: .json, now: fixture.date, gate: gate, revision: gate.revoke())
        let reopened = StreamingExportFile()
        _ = try await reopened.clear(receipt: receipt, now: fixture.date, gate: gate, through: gate.revoke())
        let moved = fixture.directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
        let sentinel = Data("foreign parent".utf8); try sentinel.write(to: fixture.url())
        await #expect(throws: StreamingExportError.changedTarget) {
            try await reopened.clear(receipt: receipt, now: fixture.date, gate: gate, through: gate.revoke())
        }
        #expect(try Data(contentsOf: fixture.url()) == sentinel)
    }
}
