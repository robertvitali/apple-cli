import AppleKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

@Suite("Conversation creation raw contact evidence")
struct MessagesConversationRawContactsTests {
    private let scratch = ScratchDirs("conversation-raw-contacts")

    private func fixture(_ sql: String = "") throws -> String {
        let path = try scratch.directory().appendingPathComponent("contacts.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME, ZLASTNAME, ZNICKNAME);
            CREATE TABLE ZABCDPHONENUMBER (ZOWNER, ZFULLNUMBER);
            CREATE TABLE ZABCDEMAILADDRESS (ZOWNER, ZADDRESS);
            INSERT INTO ZABCDRECORD VALUES(1,'Alice','Example','Al');
            INSERT INTO ZABCDPHONENUMBER VALUES(1,'+1 (212) 555-0100 ext 42');
            INSERT INTO ZABCDEMAILADDRESS VALUES(1,'Alice@EXAMPLE.COM');
            """
        try #require(sqlite3_exec(db, schema + sql, nil, nil, nil) == SQLITE_OK)
        return path
    }

    @Test func preservesOriginalAddressesAndNames() throws {
        let path = try fixture()
        let records = try MessagesConversationRawContacts.read(paths: [path],
            deadline: .millisecondsFromNow(5000))
        #expect(records.count == 2)
        #expect(Set(records.map(\.rawAddress)) == ["+1 (212) 555-0100 ext 42", "Alice@EXAMPLE.COM"])
        #expect(records.allSatisfy { $0.fullName == "Alice Example" && $0.nickname == "Al" })
        let malformed = try #require(records.first { $0.rawAddress.contains("ext 42") })
        #expect(throws: MessagesConversationAddress.ParseError.unsupportedAddress) {
            try MessagesConversationAddress.parse(malformed.rawAddress)
        }
    }

    @Test func unreadableSourceInvalidatesCompleteCapture() throws {
        let path = try fixture()
        #expect(throws: (any Error).self) {
            try MessagesConversationRawContacts.read(paths: [path, path + ".missing"],
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test(arguments: [
        "DROP TABLE ZABCDEMAILADDRESS;",
        "UPDATE ZABCDRECORD SET ZFIRSTNAME = 7;",
        "UPDATE ZABCDPHONENUMBER SET ZFULLNUMBER = 7;",
        "UPDATE ZABCDEMAILADDRESS SET ZADDRESS = X'616263';",
        "UPDATE ZABCDRECORD SET ZNICKNAME = zeroblob(1000);",
        "UPDATE ZABCDPHONENUMBER SET ZFULLNUMBER = CAST(X'ff' AS TEXT);",
    ])
    func refusesIncompleteOrMalformedEvidence(_ sql: String) throws {
        let path = try fixture(sql)
        #expect(throws: (any Error).self) {
            try MessagesConversationRawContacts.read(paths: [path], deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func retainsEmptyAndMalformedAddressesForResolution() throws {
        let path = try fixture("INSERT INTO ZABCDPHONENUMBER VALUES(1,'');")
        let records = try MessagesConversationRawContacts.read(paths: [path],
            deadline: .millisecondsFromNow(5000))
        #expect(records.count == 3)
        #expect(records.contains { $0.rawAddress.isEmpty })
    }

    @Test func absentNameComponentsFollowLegacyDisplayConstruction() throws {
        let path = try fixture("UPDATE ZABCDRECORD SET ZFIRSTNAME=NULL, ZNICKNAME=NULL;")
        let records = try MessagesConversationRawContacts.read(paths: [path],
            deadline: .millisecondsFromNow(5000))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.fullName == "Example" && $0.nickname.isEmpty })
    }

    @Test func sourcesAreNotSilentlyDeduplicated() throws {
        let path = try fixture()
        #expect(throws: MessagesConversationRawContacts.Failure.invalidSources) {
            try MessagesConversationRawContacts.read(paths: [path, path], deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func enforcesMergedRowBudget() throws {
        let path = try fixture("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5000)
            INSERT INTO ZABCDPHONENUMBER SELECT 1,'+12125550101' FROM n;
            """)
        let other = try fixture("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5000)
            INSERT INTO ZABCDPHONENUMBER SELECT 1,'+12125550101' FROM n;
            """)
        #expect(throws: MessagesConversationRawContacts.Failure.limitExceeded) {
            try MessagesConversationRawContacts.read(paths: [path, other], deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func cancellationPreventsReading() throws {
        let path = try fixture()
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationRawContacts.read(paths: [path], deadline: .millisecondsFromNow(5000),
                isCancelled: { true })
        }
    }

    @Test func refusesOversizedRawField() throws {
        let path = try fixture("UPDATE ZABCDPHONENUMBER SET ZFULLNUMBER = printf('%0513d',1);")
        #expect(throws: MessagesConversationRawContacts.Failure.limitExceeded) {
            try MessagesConversationRawContacts.read(paths: [path], deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func refusesInvalidSourceSetsBeforeOpening() {
        let cases: [[String]] = [[], Array(repeating: "/synthetic", count: 65),
                                ["relative.db"], ["/synthetic\0.db"],
                                ["/" + String(repeating: "a", count: 4096)]]
        for paths in cases {
            #expect(throws: MessagesConversationRawContacts.Failure.invalidSources) {
                try MessagesConversationRawContacts.read(paths: paths, deadline: .millisecondsFromNow(5000))
            }
        }
    }

    @Test func expiryPreventsReading() {
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationRawContacts.read(paths: ["/synthetic"], deadline: .millisecondsFromNow(0))
        }
    }

    @Test func enforcesMergedByteBudget() throws {
        let sql = """
            UPDATE ZABCDRECORD SET ZFIRSTNAME=printf('%0512d',1),
                ZLASTNAME=printf('%0512d',1), ZNICKNAME=printf('%0512d',1);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4000)
            INSERT INTO ZABCDPHONENUMBER SELECT 1,printf('%0512d',1) FROM n;
            """
        let a = try fixture(sql), b = try fixture(sql)
        #expect(throws: MessagesConversationRawContacts.Failure.limitExceeded) {
            try MessagesConversationRawContacts.read(paths: [a, b], deadline: .millisecondsFromNow(5000))
        }
    }
}
