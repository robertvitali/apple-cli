import AppleKit
import ArgumentParser
import Foundation
import Testing
@testable import MessagesKit

@Suite("Messages event stream commands")
struct MessageEventStreamCommandTests {
    private let id = "aaaaaaaa-0123-4567-89ab-0123456789ab"

    @Test func explicitPreviewWinsAcrossNestedFlagPositions() throws {
        let orderings = [
            ["--dry-run", "event-streams", "retire", id, "--execute"],
            ["event-streams", "--dry-run", "retire", id, "--execute"],
            ["event-streams", "retire", id, "--dry-run", "--execute"]
        ]
        for arguments in orderings {
            let command = try #require(try MessagesCommand.parseAsRoot(arguments) as? MessagesEventStreams.Retire)
            guard case .preview(let target) = try command.retirementRequest() else {
                Issue.record("Dry run must win before accessing a stream")
                continue
            }
            #expect(target.uuidString.lowercased() == id)
        }
    }

    @Test func refusesNoncanonicalIDBeforeOpeningRegistry() throws {
        for invalid in [id.uppercased(), "../" + id, id + " ", ""] {
            let command = try MessagesEventStreams.Retire.parse([invalid])
            #expect(throws: AppleError.self) { try command.retirementRequest() }
        }
    }

    @Test func usesTheCurrentAccountForBothCommands() throws {
        let registry = try MessageEventWatchRegistry.currentUser()
        let storage = try MessageEventWatchStorage.currentUser()
        #expect(storage.registry.path == registry.path)
        #expect(registry.name == ".apple-cli-messages-events")
        #expect(storage.source == registry.parent + "/Library/Messages/chat.db")
    }
}
