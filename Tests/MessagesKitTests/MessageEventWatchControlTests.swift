import AppleKit
import Foundation
import Testing
@testable import MessagesKit

struct MessageEventWatchControlTests {
    private func cursor(_ sequence: Int64) throws -> MessageEventCursor {
        try MessageEventCursor(
            stream: MessageEventStreamID("00000000-0000-4000-8000-000000000012"),
            filter: MessageEventFilter(conversations: ["private-synthetic-chat"]).digest,
            sequence: sequence
        )
    }

    private func fields(_ control: MessageEventWatchControl) throws -> [String: Any] {
        let bytes = try Output.encodeCompactSuccess(tool: "messages", data: control)
        #expect(!bytes.contains(10))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("private-synthetic-chat"))
        let envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(envelope["schema_version"] as? Int == 1)
        #expect(envelope["tool"] as? String == "messages")
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["data"] as? [String: Any])
    }

    @Test func startedHasAnExplicitEmptyWindow() throws {
        let initial = try cursor(0)
        let result = try fields(.started(initial))
        #expect(result["record_type"] as? String == "stream_started")
        #expect(result["stream_id"] as? String == initial.stream.rawValue)
        #expect(result["last_committed_cursor"] as? String == initial.rawValue)
        #expect(result["head_sequence"] as? String == "0")
        #expect(result["oldest_retained_sequence"] is NSNull)
        #expect(result["observation_limitations"] as? [String] == ["snapshot_polling", "intermediate_changes_may_be_unobserved"])
        #expect(result["resume_after_cursor"] == nil)
        #expect(throws: MessageEventCursorFailure.invalidCursor) { try fields(.started(cursor(1))) }
    }

    @Test func resumeDistinguishesDeliveryPositionFromCommittedHead() throws {
        let after = try cursor(Int64.max - 1)
        let result = try fields(.resumed(after: after, head: .max, oldest: .max))
        #expect(result["record_type"] as? String == "stream_resumed")
        #expect(result["resume_after_cursor"] as? String == after.rawValue)
        let committed = try cursor(.max)
        #expect(result["last_committed_cursor"] as? String == committed.rawValue)
        #expect(result["head_sequence"] as? String == "9223372036854775807")
        #expect(result["oldest_retained_sequence"] as? String == "9223372036854775807")
        let empty = try fields(.resumed(after: committed, head: .max, oldest: nil))
        #expect(empty["oldest_retained_sequence"] is NSNull)
    }

    @Test func resumeRejectsUnusablePositions() throws {
        #expect(throws: MessageEventCursorFailure.invalidRetentionBounds) { try fields(.resumed(after: cursor(0), head: 1, oldest: 2)) }
        #expect(throws: MessageEventCursorFailure.expired) { try fields(.resumed(after: cursor(1), head: 2, oldest: nil)) }
        #expect(throws: MessageEventCursorFailure.aheadOfHead) { try fields(.resumed(after: cursor(3), head: 2, oldest: 1)) }
    }

    @Test(arguments: MessageEventCaptureLimit.allCases)
    func capacityControlNamesOnlyTheObservedLimit(_ limit: MessageEventCaptureLimit) throws {
        let position = try cursor(19)
        let result = try fields(.capacityExceeded(position, limit: limit))
        #expect(Set(result.keys) == ["record_type", "stream_id", "last_committed_cursor", "limit"])
        #expect(result["record_type"] as? String == "capacity_exceeded")
        #expect(result["last_committed_cursor"] as? String == position.rawValue)
        #expect(result["limit"] as? String == limit.rawValue)
    }

    @Test func observationControlsCarryOnlyCommittedIdentity() throws {
        let position = try cursor(19)
        let controls: [(MessageEventWatchControl, String)] = [
            (.gap(position), "observation_gap"), (.restored(position), "observation_restored"),
            (.schemaChanged(position), "schema_changed"), (.capacityExceeded(position), "capacity_exceeded")
        ]
        for (control, name) in controls {
            let result = try fields(control)
            #expect(Set(result.keys) == ["record_type", "stream_id", "last_committed_cursor"])
            #expect(result["record_type"] as? String == name)
            #expect(result["stream_id"] as? String == position.stream.rawValue)
            #expect(result["last_committed_cursor"] as? String == position.rawValue)
        }
    }
}
