import Foundation
import Darwin

@main
struct RestoreFixturePreparation {
    static func main() {
        do { try generate() }
        catch {
            FileHandle.standardError.write(Data("Fixture preparation rejected.\n".utf8))
            exit(2)
        }
    }

    private static func generate() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let count = Int(arguments[2]), [50, 100].contains(count),
              let base = URLComponents(string: arguments[3]), base.scheme == "http", base.host == "127.0.0.1",
              let port = base.port, (1024...65535).contains(port), base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.path.isEmpty, let baseURL = base.url else {
            throw SessionStore.Failure.invalidData
        }
        let file = URL(fileURLWithPath: arguments[1])
        let parent = file.deletingLastPathComponent()
        let executableDirectory = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory,
              parent.path == parent.resolvingSymlinksInPath().path,
              parent.deletingLastPathComponent() == executableDirectory,
              executableDirectory.lastPathComponent.hasPrefix("tests."),
              executableDirectory.deletingLastPathComponent().lastPathComponent == "artifacts",
              executableDirectory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".local",
              file.path == file.resolvingSymlinksInPath().path,
              file.lastPathComponent == "session.sqlite3",
              parent.lastPathComponent.hasPrefix("restore-fixture-"),
              try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty else {
            throw SessionStore.Failure.invalidData
        }
        let tabs = (1...count).map { index in
            SavedTab(id: UUID(), title: String(format: "Restore fixture %03d", index),
                     url: baseURL.appendingPathComponent("restore-\(index)"), mayReload: true)
        }
        let selected = tabs[count / 2].id
        let expected = SavedSession(tabs: tabs, selectedID: selected, wasRunning: false)
        do {
            let store = try SessionStore(fileURL: file)
            try store.save(expected)
            guard try store.load() == expected else { throw SessionStore.Failure.invalidData }
        }
        // A second reader verifies persisted data after the writer is released.
        let reopened = try SessionStore(fileURL: file)
        guard try reopened.load() == expected else { throw SessionStore.Failure.invalidData }
        let manifest: [String: Any] = ["kind": "GeneratedRestoreSessionV1", "count": count,
            "selectedID": selected.uuidString, "selectedIndex": count / 2, "wasRunning": false,
            "tabs": tabs.map { ["id": $0.id.uuidString, "title": $0.title, "url": $0.url!.absoluteString] },
            "normalDataUsed": false, "applicationLaunchVerified": false]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
