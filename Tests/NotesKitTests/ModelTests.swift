import Testing
import Foundation
@testable import NotesKit
@testable import AppleKit

@Suite("Notes payload encoding")
struct ModelTests {

    func jsonObject<T: Encodable>(_ data: T) throws -> [String: Any] {
        let encoded = try Output.encodeSuccess(tool: "notes", data: data)
        let obj = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return try #require(obj["data"] as? [String: Any])
    }

    @Test("NotesMetadata omits nil fields (schema-drift / absent columns)")
    func metadataOmitsNil() throws {
        var md = NotesMetadata()
        md.set("pinned", bool: true)
        md.set("snippet", text: "hello")
        let data = try jsonObject(md)
        #expect(data["pinned"] as? Bool == true)
        #expect(data["snippet"] as? String == "hello")
        #expect(data["password_hint"] == nil) // never set → omitted
        #expect(data["has_checklist"] == nil)
        #expect(data.keys.count == 2)
    }

    @Test("empty NotesMetadata encodes to an empty object")
    func metadataEmpty() throws {
        let data = try jsonObject(NotesMetadata())
        #expect(data.isEmpty)
    }

    @Test("NotesSyncStatus carries the sync fields; nil seconds omitted")
    func syncStatus() throws {
        var status = NotesSyncStatus()
        status.sync_detected = false
        status.pending_upload = 0
        status.seconds_since_last_change = 945
        status.recent_activity = false
        let data = try jsonObject(status)
        #expect(data["sync_detected"] as? Bool == false)
        #expect(data["pending_upload"] as? Int == 0)
        #expect(data["seconds_since_last_change"] as? Int == 945)
        #expect(data["warning"] == nil)
        #expect(data["error"] == nil)
    }

    @Test("ChecklistState carries items + counts")
    func checklistState() throws {
        let state = ChecklistState(items: [
            .init(text: "a", done: true), .init(text: "b", done: false),
        ], checked: 1, total: 2)
        let data = try jsonObject(state)
        #expect(data["checked"] as? Int == 1)
        #expect(data["total"] as? Int == 2)
        let items = try #require(data["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items[0]["text"] as? String == "a")
        #expect(items[0]["done"] as? Bool == true)
    }

    @Test("dates encode as ISO-8601 strings")
    func isoDates() throws {
        let note = NoteMetaByLookup(id: "id", title: "t", created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0), shared: false, password_protected: false, account: nil)
        let data = try jsonObject(note)
        let created = try #require(data["created"] as? String)
        #expect(created.hasPrefix("1970-01-01"))
        #expect(data["account"] == nil) // nil optional omitted
    }

    @Test("CreatedNote keeps ok/id/title, omits nil folder/account")
    func createdNote() throws {
        let data = try jsonObject(CreatedNote(ok: true, id: "x", title: "t", folder: nil, account: nil,
                                              warning: nil))
        #expect(data["ok"] as? Bool == true)
        #expect(data["id"] as? String == "x")
        #expect(data["folder"] == nil)
    }
}
