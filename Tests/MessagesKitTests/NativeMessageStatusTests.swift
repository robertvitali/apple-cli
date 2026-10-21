import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeMessageStatusTests {
    private let columns = ["error", "is_delivered", "is_read", "date_delivered", "date_read"]

    private func fixture(columns present: [String]) throws -> ChatFixture {
        let fixture = try ChatFixture()
        try fixture.exec("ALTER TABLE message DROP COLUMN error")
        for column in present {
            try fixture.exec("ALTER TABLE message ADD COLUMN \(column)")
        }
        return fixture
    }

    private func read(_ fixture: ChatFixture) throws -> ChatDB.ExactMessage {
        var db = try ChatDB(path: fixture.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                            homeDirectoryForTilde: fixture.homePath)
        return try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func absentAndIndividuallyPresentColumnsHaveExplicitNulls() throws {
        for present in [[]] + columns.map({ [$0] }) {
            let status = try json(read(fixture(columns: present)).native_status)
            #expect(Set(status.keys) == Set(columns))
            for column in columns {
                let field = try #require(status[column] as? [String: Any])
                #expect(field["status"] as? String == (present.contains(column) ? "null" : "missing-schema"))
                #expect(field["raw"] is NSNull)
                let keys = column == "error" ? ["status", "raw", "is_error"]
                    : column.hasPrefix("date_") ? ["status", "raw", "normalized_seconds", "normalized_nanoseconds", "date", "date_local"]
                    : ["status", "raw", "value"]
                #expect(Set(field.keys) == Set(keys))
                for key in keys where key != "status" { #expect(field[key] is NSNull) }
            }
        }
    }

    @Test(arguments: ["'not an integer'", "1.5", "X''", "X'ff'", "CAST(X'ff' AS TEXT)"])
    func wrongStorageTypesNeverDecodePayloads(_ sql: String) throws {
        let fixture = try fixture(columns: columns)
        try fixture.exec("UPDATE message SET " + columns.map { "\($0)=\(sql)" }.joined(separator: ",") + " WHERE ROWID=1")
        let status = try json(read(fixture).native_status)
        for column in columns {
            let field = try #require(status[column] as? [String: Any])
            #expect(field["status"] as? String == "wrong-type")
            #expect(field["raw"] is NSNull)
        }
    }

    @Test(arguments: [Int64.min, -1, 0, 1, 2, Int64.max])
    func flagsAndErrorsPreserveStrictIntegers(_ raw: Int64) throws {
        let fixture = try fixture(columns: columns)
        try fixture.exec("UPDATE message SET error=\(raw),is_delivered=\(raw),is_read=\(raw) WHERE ROWID=1")
        let status = try read(fixture).native_status
        #expect(status.error.status == "available")
        #expect(status.error.raw == raw)
        #expect(status.error.is_error == (raw != 0))
        for flag in [status.is_delivered, status.is_read] {
            #expect(flag.raw == raw)
            #expect(flag.status == (raw == 0 || raw == 1 ? "available" : "invalid-boolean"))
            #expect(flag.value == (raw == 0 ? false : raw == 1 ? true : nil))
        }
    }

    @Test(arguments: [Int64.min, -1, 0, 1, 9_999_999_999, 10_000_000_000, 800_000_000_999_999_999, Int64.max])
    func timestampBoundaryNormalizationDoesNotRound(_ raw: Int64) throws {
        let fixture = try fixture(columns: columns)
        try fixture.exec("UPDATE message SET date_delivered=\(raw),date_read=\(raw) WHERE ROWID=1")
        let status = try read(fixture).native_status
        for stamp in [status.date_delivered, status.date_read] {
            #expect(stamp.raw == raw)
            if raw <= 0 {
                #expect(stamp.status == (raw == 0 ? "zero-sentinel" : "negative"))
                #expect(stamp.normalized_seconds == nil)
                #expect(stamp.normalized_nanoseconds == nil)
                #expect(stamp.date == nil)
                #expect(stamp.date_local == nil)
            } else {
                #expect(stamp.status == "available")
                #expect(stamp.normalized_seconds == (raw <= 9_999_999_999 ? raw : raw / 1_000_000_000))
                #expect(stamp.normalized_nanoseconds == (raw <= 9_999_999_999 ? 0 : raw % 1_000_000_000))
            }
        }
    }

    @Test func timezoneAndFailedFormattingAreExplicit() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 3600))
        let stamp = NativeMessageStatusDecoder.timestamp(raw: 10_999_999_999, timeZone: zone)
        #expect(stamp.date == "2001-01-01T00:00:10Z")
        #expect(stamp.date_local == "2001-01-01 01:00:10")
        #expect(stamp.normalized_nanoseconds == 999_999_999)
        let failed = NativeMessageStatusDecoder.timestamp(raw: 1, timeZone: zone,
                                                          format: { _, _ in ("invalid", "invalid") })
        #expect(failed.status == "invalid-timestamp")
        #expect(failed.raw == 1)
        let fields = try json(failed)
        for key in ["normalized_seconds", "normalized_nanoseconds", "date", "date_local"] {
            #expect(fields[key] is NSNull)
        }
    }

    @Test func paginatedHistoryMatchesGetWithoutInferringFlagsFromDates() throws {
        let fixture = try fixture(columns: columns)
        try fixture.exec("UPDATE message SET error=0,is_delivered=0,is_read=1,date_delivered=10000000000,date_read=0 WHERE ROWID=1")
        var db = try ChatDB(path: fixture.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                            homeDirectoryForTilde: fixture.homePath)
        let exact = try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
        var cursor: String?
        var found: ChatDB.ExactMessage?
        repeat {
            let page = try db.exactHistory(chat: .rowid(3), limit: 1, order: .asc, cursor: cursor)
            if let row = page.items.first, row.rowid == 1 { found = row }
            cursor = page.nextCursor
        } while cursor != nil
        #expect(try #require(found).native_status == exact.native_status)
        #expect(exact.native_status.is_delivered.value == false)
        #expect(exact.native_status.date_delivered.status == "available")
        #expect(exact.native_status.is_read.value == true)
        #expect(exact.native_status.date_read.status == "zero-sentinel")
        #expect(exact.message_guid == "g1")
        #expect(exact.body == "hello from friend")
        #expect(exact.thread_originator.reason == "missing-schema")
        #expect(exact.native_parts_reason == "absent-blob")
    }
}
