import Foundation
import Testing
@testable import Levistica

struct DownloadTests {
    @MainActor @Test func opaqueDownloadOriginsDoNotBecomeInvalidURLSchemes() {
        #expect(DownloadManager.displayOrigin(scheme: "", host: "", port: 0) == "不明な要求元")
        #expect(DownloadManager.displayOrigin(scheme: "not a scheme", host: "fixture.invalid", port: 0) == "不明な要求元")
        #expect(DownloadManager.displayOrigin(scheme: "file", host: "", port: 0) == "不明な要求元")
        #expect(DownloadManager.displayOrigin(scheme: "https", host: "fixture.invalid", port: 443) == "https://fixture.invalid:443")
    }

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
        #expect(DownloadManager.safeFilename("/") == "download")
        #expect(DownloadManager.safeFilename("////") == "download")
        #expect(DownloadManager.safeFilename("bad\nname.txt") == "badname.txt")
    }

    @MainActor
    @Test(arguments: ["家族👨\u{200D}👩\u{200D}👧\u{200D}👦.png", "研究👩🏽\u{200D}🔬.pdf", "می\u{200C}روم.txt"])
    func suggestedNamesPreserveTextJoiners(_ suggestion: String) {
        #expect(DownloadManager.safeFilename(suggestion) == suggestion)
    }

    @MainActor
    @Test(arguments: ["\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
                      "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"])
    func suggestedNamesStillRemoveDirectionControls(_ control: String) {
        #expect(DownloadManager.safeFilename("invoice" + control + "fdp.exe") == "invoicefdp.exe")
    }

    @MainActor
    @Test(arguments: ["\u{200C}", "\u{200D}", "\u{200C} \u{200D}", "\u{200D}.\u{200C}", "\u{200C}..\u{200D}"])
    func joinersCannotMakeAnEmptyOrDotOnlySuggestedName(_ suggestion: String) {
        #expect(DownloadManager.safeFilename(suggestion) == "download")
    }

    @MainActor @Test func joiningCharactersDoNotBypassControlRemovalOrByteLimit() {
        #expect(DownloadManager.safeFilename("写真👨\u{200D}👩\u{202E}\n.png") == "写真👨\u{200D}👩.png")
        let result = DownloadManager.safeFilename(String(repeating: "👩🏽\u{200D}🔬", count: 100))
        #expect(result.utf8.count <= 180)
        #expect(result.isEmpty == false)
        #expect(result.allSatisfy { $0 == "👩🏽\u{200D}🔬" })
    }

    @MainActor
    @Test(arguments: [(String(repeating: "a", count: 200) + ".pdf", ".pdf"),
                      (String(repeating: "論", count: 70) + ".pdf", ".pdf"),
                      (String(repeating: "👩🏽\u{200D}🔬", count: 20) + ".png", ".png"),
                      (String(repeating: "a", count: 200) + ".pdf.exe", ".exe")])
    func longSuggestedNamesKeepTheirFinalExtension(_ suggestion: String, _ suffix: String) {
        let result = DownloadManager.safeFilename(suggestion)
        #expect(result.hasSuffix(suffix))
        #expect(result.utf8.count <= 180)
    }

    @MainActor @Test func oversizedGraphemeStemKeepsItsShortExtensionWithAFallbackName() {
        let name = "a" + String(repeating: "\u{0301}", count: 180) + ".pdf"
        #expect(DownloadManager.safeFilename(name) == "download.pdf")
    }

    @MainActor @Test func excessiveExtensionLengthDoesNotBypassTheFilenameLimit() {
        let name = String(repeating: "a", count: 200) + "." + String(repeating: "x", count: 200)
        #expect(DownloadManager.safeFilename(name).utf8.count <= 180)
    }

    @MainActor @Test func suffixAtTheByteBoundaryLeavesRoomForTheFallbackStem() {
        let suffix = "." + String(repeating: "x", count: 171)
        let name = "a" + String(repeating: "\u{0301}", count: 180) + suffix
        let result = DownloadManager.safeFilename(name)
        #expect(result == "download" + suffix)
        #expect(result.utf8.count == 180)
    }
}
