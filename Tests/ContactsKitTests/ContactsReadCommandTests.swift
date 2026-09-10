import Foundation
import Testing
import Contacts
import ArgumentParser
@testable import ContactsKit
import AppleKit
import TestSupport

// Read commands driven end to end through the `run(storeFactory:)` seam: argv → validation →
// engine → JSON envelope. TCC-free (see ContactsFakeBackend.swift); stdout is captured, never
// written to the terminal.

/// Build the store the command under test will receive, and count how many times it was asked
/// for one — so "this path never touches the store" is an assertion, not a comment.
private final class StoreFactory {
    let backend: FakeContactsBackend
    private(set) var built = 0
    init(_ backend: FakeContactsBackend = FakeContactsBackend()) { self.backend = backend }
    func make() -> ContactsStore {
        built += 1
        return ContactsStore(backend: backend)
    }
}

@Suite("Contacts output final-leaf destinations")
struct ContactsOutFinalLeafTests {
    private let scratch = ScratchDirs("contacts-out-leaf")

    @Test func refusesNormalizedLinksBeforeStoreAccess() throws {
        for photo in [false, true] {
            for dangling in [false, true] {
                let root = try scratch.directory()
                let target = root.appendingPathComponent("sentinel")
                if !dangling { try Data("synthetic sentinel".utf8).write(to: target) }
                let link = root.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                let raw = root.path + "/absent/../link"
                let factory = StoreFactory()
                try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
                    if photo {
                        try PhotoGetCommand.parse(["c1", "--out", raw]).run(storeFactory: factory.make)
                    } else {
                        try VCardExportCommand.parse(["c1", "--out", raw]).run(storeFactory: factory.make)
                    }
                }
                #expect(factory.built == 0)
                if dangling {
                    #expect(!FileManager.default.fileExists(atPath: target.path))
                } else {
                    #expect(try Data(contentsOf: target) == Data("synthetic sentinel".utf8))
                }
            }
        }
    }

    @Test func rechecksRawAndCapturedLeavesAfterStoreAccess() throws {
        for photo in [false, true] {
            for plantCaptured in [false, true] {
                let root = try scratch.directory()
                let first = root.appendingPathComponent("first")
                let second = root.appendingPathComponent("second")
                try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
                let alias = root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
                let sentinel = root.appendingPathComponent("sentinel")
                let original = Data("synthetic sentinel".utf8)
                try original.write(to: sentinel)
                let captured = first.appendingPathComponent("leaf")
                try Data("synthetic existing output".utf8).write(to: captured)
                let planted = (plantCaptured ? first : second).appendingPathComponent("leaf")
                let raw = alias.path + "/leaf"
                let factory = StoreFactory()
                let contact = fakeContact(given: "Jane", family: "Doe")
                contact.imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
                factory.backend.contactsByIdentifier["c1"] = contact
                let make: () -> ContactsStore = {
                    do {
                        try FileManager.default.removeItem(at: alias)
                        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
                        if plantCaptured { try FileManager.default.removeItem(at: captured) }
                        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: sentinel)
                    } catch { Issue.record(error) }
                    return factory.make()
                }
                try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
                    if photo {
                        try PhotoGetCommand.parse(["c1", "--out", raw]).run(storeFactory: make)
                    } else {
                        try VCardExportCommand.parse(["c1", "--out", raw]).run(storeFactory: make)
                    }
                }
                #expect(factory.built == 1)
                #expect(try Data(contentsOf: sentinel) == original)
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: planted.path)) != nil)
            }
        }
    }

    @Test func acceptsNormalizedOrdinaryLeavesAndPhysicalParentTraversal() throws {
        for photo in [false, true] {
            for throughAlias in [false, true] {
                let root = try scratch.directory()
                let parent = root.appendingPathComponent("outer/inner")
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let alias = root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
                let sentinel = root.appendingPathComponent("sentinel")
                try Data("synthetic sentinel".utf8).write(to: sentinel)
                if throughAlias {
                    // A purely lexical guard would see this unrelated link and wrongly refuse.
                    try FileManager.default.createSymbolicLink(
                        at: root.appendingPathComponent("leaf"), withDestinationURL: sentinel)
                    // Full-path existence selects Foundation's physical traversal branch.
                    try Data("synthetic existing output".utf8).write(to: root.appendingPathComponent("outer/leaf"))
                }
                let raw = throughAlias ? alias.path + "/../leaf" : root.path + "/absent/../leaf"
                let destination = try confineWriteDestination(raw, action: "write", allowOutsideHome: true)
                let factory = StoreFactory()
                let contact = fakeContact(given: "Jane", family: "Doe")
                let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
                contact.imageData = bytes
                factory.backend.contactsByIdentifier["c1"] = contact
                let data = try runContacts {
                    if photo {
                        try PhotoGetCommand.parse(["c1", "--out", raw]).run(storeFactory: factory.make)
                    } else {
                        try VCardExportCommand.parse(["c1", "--out", raw]).run(storeFactory: factory.make)
                    }
                }
                #expect(data["written_to"] as? String == destination.path)
                #expect(try Data(contentsOf: sentinel) == Data("synthetic sentinel".utf8))
                if photo { #expect(try Data(contentsOf: destination) == bytes) }
                else { #expect(try String(contentsOf: destination, encoding: .utf8) == data["vcard"] as? String) }
            }
        }
    }
}

@Suite("contacts auth")
struct ContactsAuthCommandTests {
    @Test("an authorized status reports no remediation and never prompts")
    func authorized() throws {
        let factory = StoreFactory()
        factory.backend.statuses = [3]
        let data = try runContacts { try AuthCommand.parse([]).run(storeFactory: factory.make) }
        #expect(data["status"] as? String == "authorized")
        #expect(data.keys.contains("remediation") == false)
        #expect(factory.backend.accessRequests == 0)   // `auth` NEVER prompts
    }

    @Test("a denied status reports the remediation copy")
    func denied() throws {
        let factory = StoreFactory()
        factory.backend.statuses = [2]
        let data = try runContacts { try AuthCommand.parse([]).run(storeFactory: factory.make) }
        #expect(data["status"] as? String == "denied")
        #expect((data["remediation"] as? String)?.contains("System Settings") == true)
        #expect(factory.backend.accessRequests == 0)
    }

    @Test("--text renders without emitting JSON on stdout")
    func textOutput() throws {
        let factory = StoreFactory()
        // Pinned like every other command driver, so an ambient APPLE_DRY_RUN / APPLE_TEST_MODE
        // cannot reach this path either (see `pinnedGates`).
        let (streams, stdout) = contactsStreams()
        try pinnedGates {
            try Output.withStreams(streams) {
                try AuthCommand.parse(["--text"]).run(storeFactory: factory.make)
            }
        }
        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("authorized"))
        let asJSON = (try? JSONSerialization.jsonObject(with: stdout.data)) as? [String: Any]
        #expect(asJSON == nil, "--text must not emit the JSON envelope")
    }
}

@Suite("contacts list")
struct ContactsListCommandTests {
    @Test("emits paged summaries and echoes the resolved offset/limit")
    func success() throws {
        let factory = StoreFactory()
        factory.backend.contactRows = (0..<5).map { fakeContact(given: "Alice\($0)", family: "Doe") }
        let data = try runContacts {
            try ListCommand.parse(["--offset", "1", "--limit", "2"]).run(storeFactory: factory.make)
        }
        let contacts = try #require(data["contacts"] as? [[String: Any]])
        #expect(contacts.map { $0["given_name"] as? String } == ["Alice1", "Alice2"])
        #expect(data["count"] as? Int == 2)
        #expect(data["offset"] as? Int == 1)
        #expect(data["limit"] as? Int == 2)
        #expect(factory.built == 1)
    }

    @Test("a limit above the 200 cap is clamped, and the CLAMPED value is what's echoed")
    func cap() throws {
        let factory = StoreFactory()
        let data = try runContacts { try ListCommand.parse(["--limit", "5000"]).run(storeFactory: factory.make) }
        #expect(data["limit"] as? Int == 200)
    }

    @Test("a negative offset or a sub-1 limit is rejected BEFORE the store is built")
    func validation() throws {
        // `--offset=-1`, not `--offset -1`: a bare `-1` is parsed as a FLAG by ArgumentParser,
        // so the separated spelling never reaches the validator under test.
        for args in [["--offset=-1"], ["--limit", "0"]] {
            let factory = StoreFactory()
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try ListCommand.parse(args).run(storeFactory: factory.make)
            }
            #expect(factory.built == 0, "args \(args) must not reach the store")
        }
    }

    @Test("a denied authorization surfaces as authorization_denied at exit 77")
    func denied() throws {
        let factory = StoreFactory()
        factory.backend.statuses = [2]
        let payload = try expectContactsFailure(exit: AppleExit.permissionDenied,
                                                type: AppleErrorType.permissionDenied) {
            try ListCommand.parse([]).run(storeFactory: factory.make)
        }
        #expect(payload["status"] as? String == "denied")
        #expect(payload["remediation"] != nil)
    }
}

@Suite("contacts get")
struct ContactsGetCommandTests {
    @Test("emits the full record; --niche adds the four P3 families")
    func success() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] =
            fakeContact(given: "Jane", family: "Doe", organization: "Example Org",
                        phone: "+1-555-0102", email: "jane@example.com")

        let plain = try runContacts { try GetCommand.parse(["c1"]).run(storeFactory: factory.make) }
        let contact = try #require(plain["contact"] as? [String: Any])
        #expect(contact["given_name"] as? String == "Jane")
        #expect(contact["birthday"] is NSNull)               // key ALWAYS present
        #expect(contact.keys.contains("dates") == false)

        let rich = try runContacts { try GetCommand.parse(["c1", "--niche"]).run(storeFactory: factory.make) }
        let niche = try #require(rich["contact"] as? [String: Any])
        for key in ["dates", "social_profiles", "relations", "instant_messages"] {
            #expect(niche.keys.contains(key), "\(key) must be present with --niche")
        }

        // THE FETCH KEY SET IS PART OF THE CONTRACT, not an implementation detail: reading an
        // unfetched CN key TRAPS at runtime, so `--niche` must widen the request. Deleting
        // `keys += Self.nicheKeys` from ContactsStore.unifiedContact fails right here.
        let nicheKeys = [CNContactDatesKey, CNContactSocialProfilesKey,
                         CNContactRelationsKey, CNContactInstantMessageAddressesKey]
        #expect(factory.backend.unifiedContactKeys.count == 2)
        let plainKeys = try #require(factory.backend.unifiedContactKeys.first)
        #expect(plainKeys.contains(CNContactGivenNameKey))           // P1 keys always fetched
        #expect(plainKeys.contains(CNContactPhoneNumbersKey))
        for key in nicheKeys {
            #expect(plainKeys.contains(key) == false, "\(key) must NOT be fetched without --niche")
        }
        let richKeys = try #require(factory.backend.unifiedContactKeys.last)
        #expect(richKeys.contains(CNContactGivenNameKey))             // P1 keys still there
        for key in nicheKeys {
            #expect(richKeys.contains(key), "\(key) must be fetched under --niche")
        }
    }

    @Test("a blank identifier is a validation error before the store is built")
    func blankIdentifier() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try GetCommand.parse(["   "]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }

    @Test("an unresolvable identifier is not_found at exit 65")
    func notFound() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try GetCommand.parse(["missing"]).run(storeFactory: factory.make)
        }
    }
}

@Suite("contacts search")
struct ContactsSearchCommandTests {
    @Test("a single field searches that field and echoes the selection")
    func single() throws {
        let factory = StoreFactory()
        factory.backend.matchingContacts = [fakeContact(given: "Bob", family: "Roe")]
        let data = try runContacts {
            try SearchCommand.parse(["--email", " bob@example.com "]).run(storeFactory: factory.make)
        }
        #expect(data["search_field"] as? String == "email")
        #expect(data["search_value"] as? String == "bob@example.com")   // trimmed
        #expect(data["count"] as? Int == 1)
        #expect(data["limit"] as? Int == 200)
        #expect(data.keys.contains("deep") == false)                    // omitted in default mode
    }

    @Test("--deep issues ONE store query per field and unions overlapping rows, de-duped by id")
    func deep() throws {
        let factory = StoreFactory()
        // Deliberately OVERLAPPING rows across the four field searches. A fake that returned one
        // fixed list would make the de-dup assertion tautological — six rows go in across four
        // calls, three distinct contacts must come out, in first-seen order.
        let alice = fakeContact(given: "Alice", family: "Doe")
        let bob = fakeContact(given: "Bob", family: "Roe")
        let carol = fakeContact(given: "Carol", family: "Poe")
        factory.backend.matchingContactsSequence = [[alice, bob], [bob, carol], [alice], [carol]]

        let data = try runContacts {
            try SearchCommand.parse(["--name", "o", "--deep"]).run(storeFactory: factory.make)
        }
        #expect(data["deep"] as? Bool == true)
        #expect(data["search_field"] as? String == "name")
        // One query per field (name/phone/email/organization) — not one, and not five.
        #expect(factory.backend.unifiedContactsQueries.count == 4)
        let ids = try #require(data["contacts"] as? [[String: Any]]).map { $0["id"] as? String }
        #expect(ids == [alice.identifier, bob.identifier, carol.identifier])
        #expect(data["count"] as? Int == 3)
    }

    @Test("a single-field search issues exactly ONE store query")
    func singleFieldIssuesOneQuery() throws {
        let factory = StoreFactory()
        factory.backend.matchingContactsSequence = [[fakeContact(given: "Alice", family: "Doe"),
                                                     fakeContact(given: "Bob", family: "Roe")]]
        let data = try runContacts {
            try SearchCommand.parse(["--name", "o"]).run(storeFactory: factory.make)
        }
        #expect(factory.backend.unifiedContactsQueries.count == 1)
        #expect(data["count"] as? Int == 2)
    }

    @Test("--org is an alias for --organization")
    func orgAlias() throws {
        let factory = StoreFactory()
        let data = try runContacts {
            try SearchCommand.parse(["--org", "Example Org"]).run(storeFactory: factory.make)
        }
        #expect(data["search_field"] as? String == "organization")
    }

    @Test("zero or two selectors are validation errors before the store is built")
    func selection() throws {
        for args in [[], ["--name", "Bob", "--phone", "555-0103"]] {
            let factory = StoreFactory()
            try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
                try SearchCommand.parse(args).run(storeFactory: factory.make)
            }
            #expect(factory.built == 0)
        }
    }
}

@Suite("contacts groups + containers (read)")
struct ContactsGroupReadCommandTests {
    @Test("groups list emits every group with its cap")
    func groupsList() throws {
        let factory = StoreFactory()
        factory.backend.allGroups = [fakeGroup(name: "apple-cli-test group"), fakeGroup(name: "Friends")]
        let data = try runContacts { try GroupsListCommand.parse([]).run(storeFactory: factory.make) }
        let groups = try #require(data["groups"] as? [[String: Any]])
        #expect(groups.map { $0["name"] as? String } == ["apple-cli-test group", "Friends"])
        #expect(data["count"] as? Int == 2)
        #expect(data["limit"] as? Int == 200)
    }

    @Test("groups members distinguishes a missing group (404) from an empty one (0 rows)")
    func groupsMembers() throws {
        let missing = StoreFactory()
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try GroupsMembersCommand.parse(["g1"]).run(storeFactory: missing.make)
        }

        let empty = StoreFactory()
        empty.backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        let data = try runContacts { try GroupsMembersCommand.parse(["g1"]).run(storeFactory: empty.make) }
        #expect(data["group_identifier"] as? String == "g1")
        #expect(data["count"] as? Int == 0)

        let populated = StoreFactory()
        populated.backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        populated.backend.matchingContacts = [fakeContact(given: "Alice", family: "Doe")]
        let rows = try runContacts { try GroupsMembersCommand.parse(["g1"]).run(storeFactory: populated.make) }
        #expect(rows["count"] as? Int == 1)
    }

    @Test("groups members rejects a blank identifier before the store is built")
    func groupsMembersBlank() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try GroupsMembersCommand.parse([" "]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }

    @Test("containers list emits the rows, the count, and the 10-container cap")
    func containersList() throws {
        let empty = StoreFactory()
        let none = try runContacts { try ContainersListCommand.parse([]).run(storeFactory: empty.make) }
        #expect(none["count"] as? Int == 0)
        #expect(none["limit"] as? Int == 10)

        let factory = StoreFactory()
        factory.backend.allContainers = (0..<12).map { _ in CNContainer() }
        let data = try runContacts { try ContainersListCommand.parse([]).run(storeFactory: factory.make) }
        #expect((data["containers"] as? [[String: Any]])?.count == 10)   // capped
        #expect(data["count"] as? Int == 10)
        // list_containers is the LIST-EVERYTHING call: a nil predicate, exactly once.
        #expect(factory.backend.containerQueries.count == 1)
        #expect(factory.backend.containerQueries[0] == nil)
    }
}

@Suite("contacts vcard export")
struct ContactsVCardExportCommandTests {
    /// Held as a stored property: swift-testing builds a fresh suite instance per test, so its
    /// `deinit` reclaims exactly the directories this instance vended. `ScratchDirs` roots under
    /// `$TMPDIR` (outside `$HOME`), which is legitimate here because the Contacts `--out` extra
    /// passes `allowOutsideHome: true` — the guard under test is the credential blocklist.
    private let scratch = ScratchDirs("contacts-vcard-out")

    @Test("emits the vCard payload, the count, and the two parity notes")
    func success() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
        let data = try runContacts { try VCardExportCommand.parse(["c1"]).run(storeFactory: factory.make) }
        #expect((data["vcard"] as? String)?.contains("BEGIN:VCARD") == true)
        #expect(data["count"] as? Int == 1)
        #expect((data["notes"] as? [String])?.count == 2)
        #expect(data.keys.contains("written_to") == false)   // extra omitted when unused
    }

    @Test("an empty list or a blank element is a validation error")
    func validation() throws {
        let empty = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try VCardExportCommand.parse([]).run(storeFactory: empty.make)
        }
        let blank = StoreFactory()
        let payload = try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try VCardExportCommand.parse(["c1", " "]).run(storeFactory: blank.make)
        }
        #expect((payload["message"] as? String)?.contains("identifiers[1]") == true)
        #expect(blank.built == 0)
    }

    @Test("an unresolvable identifier is not_found")
    func notFound() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try VCardExportCommand.parse(["missing"]).run(storeFactory: factory.make)
        }
    }

    @Test("--out into a credential directory is refused BEFORE the store is touched")
    func confinesOutPath() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try VCardExportCommand.parse(["c1", "--out", "~/.ssh/apple-cli-test.vcf"]).run(storeFactory: factory.make)
        }
        // Bound before the store touch: the refusal must not depend on TCC being granted.
        #expect(factory.built == 0)
    }

    @Test("--out writes the vCard to disk and echoes the resolved destination")
    func writesOutFile() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact(given: "Jane", family: "Doe")
        let target = try scratch.directory().appendingPathComponent("apple-cli-test-export.vcf")

        let data = try runContacts {
            try VCardExportCommand.parse(["c1", "--out", target.path]).run(storeFactory: factory.make)
        }
        // `confineWriteDestination` resolves symlinks, so the echoed path is the RESOLVED one
        // (`/var/folders/...` becomes `/private/var/folders/...` on macOS).
        let resolved = target.resolvingSymlinksInPath().path
        #expect(data["written_to"] as? String == resolved)

        let onDisk = try String(contentsOfFile: resolved, encoding: .utf8)
        #expect(onDisk.contains("BEGIN:VCARD"))
        #expect(onDisk == data["vcard"] as? String)   // the file and the envelope agree
    }

    @Test("--out carrying a control character is refused")
    func rejectsControlCharacterOutPath() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try VCardExportCommand.parse(["c1", "--out", "apple-cli-test\u{1E}.vcf"]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }
}

@Suite("contacts note get")
struct ContactsNoteGetCommandTests {
    @Test("emits the identifier and the note text")
    func success() throws {
        let factory = StoreFactory()
        factory.backend.scriptResult = "a synthetic note"
        let data = try runContacts {
            try NoteGetCommand.parse(["c1:ABPerson"]).run(storeFactory: factory.make)
        }
        #expect(data["identifier"] as? String == "c1:ABPerson")
        #expect(data["note"] as? String == "a synthetic note")
    }

    @Test("a blank identifier is a validation error before the store is built")
    func blank() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try NoteGetCommand.parse([""]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }

    @Test("an AppleScript 'can't get' failure surfaces as not_found")
    func notFound() throws {
        let factory = StoreFactory()
        factory.backend.scriptError = AppleScriptRunner.RunError.scriptFailed(
            status: 1, stderr: "Contacts got an error: Can't get person 1")
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try NoteGetCommand.parse(["c1"]).run(storeFactory: factory.make)
        }
    }
}

@Suite("contacts photo get")
struct ContactsPhotoGetCommandTests {
    /// See the note on `ContactsVCardExportCommandTests.scratch`.
    private let scratch = ScratchDirs("contacts-photo-out")

    @Test("a contact with a photo emits base64 bytes, the sniffed format, and the size")
    func withPhoto() throws {
        let factory = StoreFactory()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let row = fakeContact(given: "Jane", family: "Doe")
        row.imageData = bytes
        factory.backend.contactsByIdentifier["c1"] = row

        let data = try runContacts { try PhotoGetCommand.parse(["c1"]).run(storeFactory: factory.make) }
        #expect(data["image_data"] as? String == bytes.base64EncodedString())
        #expect(data["format"] as? String == "jpeg")
        #expect(data["size_bytes"] as? Int == bytes.count)
        #expect(data.keys.contains("written_to") == false)
    }

    @Test("a contact WITHOUT a photo emits explicit nulls and size 0")
    func withoutPhoto() throws {
        let factory = StoreFactory()
        factory.backend.contactsByIdentifier["c1"] = fakeContact()
        let data = try runContacts { try PhotoGetCommand.parse(["c1"]).run(storeFactory: factory.make) }
        #expect(data["image_data"] is NSNull)
        #expect(data["format"] is NSNull)
        #expect(data["size_bytes"] as? Int == 0)
    }

    @Test("an unresolvable identifier is not_found; a blank one is a validation error")
    func failures() throws {
        let missing = StoreFactory()
        try expectContactsFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try PhotoGetCommand.parse(["missing"]).run(storeFactory: missing.make)
        }
        let blank = StoreFactory()
        try expectContactsFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try PhotoGetCommand.parse([" "]).run(storeFactory: blank.make)
        }
        #expect(blank.built == 0)
    }

    @Test("--out writes the RAW bytes to disk and echoes the resolved destination")
    func writesOutFile() throws {
        let factory = StoreFactory()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let row = fakeContact(given: "Jane", family: "Doe")
        row.imageData = bytes
        factory.backend.contactsByIdentifier["c1"] = row
        let target = try scratch.directory().appendingPathComponent("apple-cli-test-photo.png")

        let data = try runContacts {
            try PhotoGetCommand.parse(["c1", "--out", target.path]).run(storeFactory: factory.make)
        }
        let resolved = target.resolvingSymlinksInPath().path
        #expect(data["written_to"] as? String == resolved)
        // RAW bytes on disk, base64 in the envelope — the file is not the encoded form.
        #expect(try Data(contentsOf: URL(fileURLWithPath: resolved)) == bytes)
        #expect(data["image_data"] as? String == bytes.base64EncodedString())
        #expect(data["format"] as? String == "png")
    }

    @Test("--out into a credential directory is refused BEFORE the store is touched")
    func confinesOutPath() throws {
        let factory = StoreFactory()
        try expectContactsFailure(exit: AppleExit.permissionDenied, type: AppleErrorType.safetyViolation) {
            try PhotoGetCommand.parse(["c1", "--out", "~/.aws/credentials"]).run(storeFactory: factory.make)
        }
        #expect(factory.built == 0)
    }
}
