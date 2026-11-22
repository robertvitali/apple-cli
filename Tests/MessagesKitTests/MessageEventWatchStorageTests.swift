import Foundation
import TestSupport
import Testing
@testable import MessagesKit

@Suite struct MessageEventWatchStorageTests {
    private let scratch = ScratchDirs("watch-storage")

    @Test(arguments: ["", "relative", "/", "/a//b", "/a/", "/a/./b", "/a/../b", "/a\0b"])
    func refusesAmbiguousParent(_ parent: String) {
        #expect(throws: MessageEventWatchRegistry.Failure.self) {
            try MessageEventWatchRegistry(parent: parent, name: "streams")
        }
    }

    @Test(arguments: ["", ".", "..", "two/components", "bad\0name", String(repeating: "x", count: 256)])
    func refusesInvalidRegistryComponent(_ name: String) {
        #expect(throws: MessageEventWatchRegistry.Failure.self) {
            try MessageEventWatchRegistry(parent: "/private/tmp", name: name)
        }
    }

    @Test func independentLocationsAreRechecked() throws {
        let fm = FileManager.default
        let parent = try scratch.directory()
        let registry = try MessageEventWatchRegistry(parent: parent.path, name: "streams")
        let source = parent.appendingPathComponent("chat.sqlite").path
        var checks = 0
        let storage = try MessageEventWatchStorage(source: source, registry: registry) { value in
            #expect(value == source)
            checks += 1
        }
        #expect(!fm.fileExists(atPath: registry.path))
        try fm.createDirectory(atPath: registry.path, withIntermediateDirectories: false)
        try storage.checkSource()
        #expect(checks == 2)
        let missing = parent.appendingPathComponent("absent/source.sqlite").path
        let unavailable = try MessageEventWatchStorage(source: missing, registry: registry)
        #expect(throws: ContinuityFailure.sourceReset) { try SourceAnchor(unavailable) }
        let id = try MessageEventStreamID("00000000-0000-4000-8000-000000000001")
        #expect(storage.registry.journal(id) == registry.path + "/" + id.rawValue + "/state.sqlite")
        #expect(throws: MessageEventWatchRegistry.Failure.self) {
            try MessageEventWatchStorage(source: registry.path + "/chat.sqlite", registry: registry)
        }
    }
}
