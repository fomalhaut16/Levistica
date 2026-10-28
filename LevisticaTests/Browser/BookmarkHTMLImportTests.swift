import Foundation
import Testing
@testable import Levistica

struct BookmarkHTMLImportTests {
    private func html(_ body: String) -> Data {
        Data(("<!DOCTYPE NETSCAPE-Bookmark-file-1><META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\"><TITLE>Bookmarks</TITLE><DL><p>" + body + "</DL><p>").utf8)
    }

    @Test func chromeFoldersEntitiesAndSameURLInDifferentFoldersArePreserved() throws {
        let preview = try BookmarkHTMLImport.parse(html("""
        <DT><H3>Research &amp; Docs</H3><DL><p>
        <DT><A HREF="https://example.com/a?x=1&amp;y=2">A &amp; B</A>
        <DT><H3>日本語</H3><DL><p><DT><A HREF="https://example.com/same">論文</A></DL><p>
        </DL><p><DT><A HREF="https://example.com/same">Root</A>
        """))
        #expect(preview.entries.count == 3)
        #expect(preview.entries[0].title == "A & B")
        #expect(preview.entries[0].url.absoluteString == "https://example.com/a?x=1&y=2")
        #expect(preview.entries[0].folders == ["Research & Docs"])
        #expect(preview.entries[1].folders == ["Research & Docs", "日本語"])
        #expect(preview.entries[2].folders.isEmpty)
    }

    @Test func unsupportedLinksDuplicatesAndEmptyFoldersAreCountedWithoutExecutingHTML() throws {
        let preview = try BookmarkHTMLImport.parse(html("""
        <SCRIPT>document.write('<a href="https://example.com/script">hidden</a>')</SCRIPT>
        <DT><H3>Empty</H3><DL><p></DL><p>
        <DT><A HREF="javascript:alert(1)">Script</A>
        <DT><A HREF="file:///tmp/private">Local</A>
        <DT><A HREF="https://u:p@example.com/">Credentials</A>
        <DT><A HREF="https://example.com/a">First</A><DT><A HREF="https://example.com/a">Duplicate</A>
        """))
        #expect(preview.entries.map(\.title) == ["First"])
        #expect(preview.rejectedCount == 3)
        #expect(preview.repeatedCount == 1)
        #expect(preview.emptyFolderCount == 1)
    }

    @Test func invalidTitleDoesNotHideLaterValidEntryAndEmptyTitleUsesHost() throws {
        let preview = try BookmarkHTMLImport.parse(html("<DT><A HREF=\"https://example.com/a\">" + String(repeating: "x", count: 513)
            + "</A><DT><A HREF=\"https://example.com/a\">Valid</A><DT><A HREF=\"https://example.org/\"></A>"))
        #expect(preview.entries.map(\.title) == ["Valid", "example.org"])
        #expect(preview.rejectedCount == 1)
    }

    @Test(arguments: ["<html><a href='https://example.com/'>Not an export</a></html>",
                      "<!DOCTYPE NETSCAPE-Bookmark-file-1><!ENTITY local SYSTEM 'file:///tmp/never-read'><DL><A HREF='https://example.com/'>&local;</A></DL>"])
    func wrongFormatsAndEntityDeclarationsAreRejected(_ input: String) throws {
        #expect(throws: BookmarkHTMLImport.Failure.self) { try BookmarkHTMLImport.parse(Data(input.utf8)) }
    }

    @Test func aFolderWithoutItsListDoesNotSilentlyMoveLinksToTheRoot() throws {
        #expect(throws: BookmarkHTMLImport.Failure.self) {
            try BookmarkHTMLImport.parse(html("<DT><H3>Folder</H3><DT><A HREF='https://example.com/'>Wrong location</A>"))
        }
    }

    @Test func identicalSiblingFolderNamesAreRejectedInsteadOfMergingTheirContents() throws {
        #expect(throws: BookmarkHTMLImport.Failure.self) {
            try BookmarkHTMLImport.parse(html("<DT><H3>Same</H3><DL><p><DT><A HREF='https://example.com/a'>A</A></DL><p><DT><H3>Same</H3><DL><p><DT><A HREF='https://example.com/b'>B</A></DL><p>"))
        }
    }

    @Test func fileReadingIncludesTheTailAndRejectsSymbolicLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("bookmarks.html")
        try html("<!--" + String(repeating: "x", count: 200_000) + "--><DT><A HREF='https://example.com/tail'>Tail</A>").write(to: file)
        #expect(try BookmarkHTMLImport.read(file).entries.map(\.title) == ["Tail"])
        let link = folder.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try BookmarkHTMLImport.read(link) }
    }

    @Test func sizeCountAndDepthLimitsRejectTheWholeImport() throws {
        #expect(throws: BookmarkHTMLImport.Failure.self) { try BookmarkHTMLImport.parse(Data(repeating: 65, count: BookmarkHTMLImport.maximumBytes + 1)) }
        let many = (0..<1001).map { "<DT><A HREF=\"https://example.com/\($0)\">Entry</A>" }.joined()
        #expect(throws: BookmarkHTMLImport.Failure.self) { try BookmarkHTMLImport.parse(html(many)) }
        let deep = String(repeating: "<DT><H3>Nested</H3><DL><p>", count: 33) + "<DT><A HREF=\"https://example.com/\">Entry</A>" + String(repeating: "</DL><p>", count: 33)
        #expect(throws: BookmarkHTMLImport.Failure.self) { try BookmarkHTMLImport.parse(html(deep)) }
    }
}
