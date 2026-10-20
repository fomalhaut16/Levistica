import Foundation
import Testing
@testable import Levistica

struct DownloadTests {
    @Test func externallyChangedOriginalIsNotReplaced() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.txt")
        try Data("original".utf8).write(to: url)
        let target = try DownloadDestination(url: url)
        defer { target.cleanup() }
        try Data("incoming".utf8).write(to: target.stagingURL)
        try Data("changed by another writer".utf8).write(to: url)
        #expect(throws: (any Error).self) { try target.finish() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed by another writer")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func completedFileReplacesOldDataAndKeepsQuarantine() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.txt")
        try Data("old".utf8).write(to: url)
        let target = try DownloadDestination(url: url)
        defer { target.cleanup() }
        try Data("new".utf8).write(to: target.stagingURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "old")
        try target.finish()
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        #expect(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
    }

    @Test func cancelledOrIncompleteReplacementDoesNotEraseTheOriginal() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.txt")
        try Data("keep".utf8).write(to: url)
        let target = try DownloadDestination(url: url)
        defer { target.cleanup() }
        #expect(throws: (any Error).self) { try target.finish() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
        try Data("partial".utf8).write(to: target.stagingURL)
        target.cleanup()
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
    }

    @Test func aFileCreatedAfterTheSaveDialogIsNotOverwritten() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.txt")
        let target = try DownloadDestination(url: url)
        defer { target.cleanup() }
        try Data("incoming".utf8).write(to: target.stagingURL)
        try Data("another writer".utf8).write(to: url)
        #expect(throws: (any Error).self) { try target.finish() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "another writer")
    }

    @Test func symbolicLinkDestinationIsRejected() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real.txt")
        let link = folder.appendingPathComponent("link.txt")
        try Data("keep".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) { _ = try DownloadDestination(url: link) }
        #expect(try String(contentsOf: real, encoding: .utf8) == "keep")
    }

    @MainActor
    @Test func suggestedNamesCannotSelectAnotherDirectory() {
        #expect(DownloadManager.safeFilename("../../outside.txt") == "outside.txt")
        #expect(DownloadManager.safeFilename("..") == "download")
        #expect(DownloadManager.safeFilename("bad\nname.txt") == "badname.txt")
    }
}
