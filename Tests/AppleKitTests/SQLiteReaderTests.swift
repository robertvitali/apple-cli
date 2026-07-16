import Testing
import Foundation
@testable import AppleKit

// The direct-open path (copyToTemp:false) reads a LIVE Apple store another app holds open, so it
// opens with `immutable=1` to skip locking + WAL bookkeeping. These lock the URI construction:
// it must survive SQLite's URI parser for real store paths (spaces, `~`-expanded absolutes).

@Suite("SQLiteReader immutable URI")
struct SQLiteReaderURITests {

    @Test("absolute path becomes a file: URI with immutable=1")
    func absolutePath() {
        #expect(SQLiteReader.immutableURI(forPath: "/Users/x/Library/Messages/chat.db")
                == "file:/Users/x/Library/Messages/chat.db?immutable=1")
    }

    @Test("spaces in the path are percent-encoded (e.g. Application Support, Envelope Index)")
    func spacesEncoded() {
        let uri = SQLiteReader.immutableURI(forPath: "/Users/x/Library/Application Support/AddressBook/AddressBook-v22.abcddb")
        #expect(uri == "file:/Users/x/Library/Application%20Support/AddressBook/AddressBook-v22.abcddb?immutable=1")
        // No raw space survives — a raw space would break SQLite's URI parse.
        #expect(!uri.contains(" "))
    }

    @Test("path separators are preserved, immutable flag appended once")
    func separatorsPreserved() {
        let uri = SQLiteReader.immutableURI(forPath: "/a/b/c.sqlite")
        #expect(uri.hasPrefix("file:/a/b/c.sqlite"))
        #expect(uri.hasSuffix("?immutable=1"))
    }

    @Test("a non-absolute path is returned unchanged (no malformed URI)")
    func relativePassthrough() {
        // Falls back to a plain filename open rather than emitting a bad file: URI.
        #expect(SQLiteReader.immutableURI(forPath: "relative/thing.db") == "relative/thing.db")
        #expect(SQLiteReader.immutableURI(forPath: ":memory:") == ":memory:")
    }

    @Test("URI query-parameter injection is prevented — a path can't smuggle mode=rwc / immutable=0 / vfs")
    func noQueryParamInjection() {
        // The strongest security property: `?`, `&`, `=` in a path must be percent-encoded so a
        // crafted path can't flip immutable off, make the open writable, or select a VFS.
        let uri = SQLiteReader.immutableURI(forPath: "/a/b?immutable=0&mode=rwc&vfs=unix/c.db")
        #expect(uri.contains("%3F"))   // ?
        #expect(uri.contains("%3D"))   // =
        #expect(uri.contains("%26"))   // &
        // Exactly one real query separator — the one WE append — and it's immutable=1.
        #expect(uri.hasSuffix("?immutable=1"))
        #expect(uri.filter { $0 == "?" }.count == 1)
    }
}
