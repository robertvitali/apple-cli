import Foundation
import Testing
import Contacts
@testable import ContactsKit
import AppleKit

// Logic-tier tests for the `ContactsStore` engine, driven through the injected
// `ContactsStoreBackend` seam. TCC-free: no `CNContactStore` is ever constructed here, so
// nothing prompts, reads authorization, or touches the operator's address book.
//
// What these pin that no other tier can: the CN-error → `AppleError` mapping (type + exit code)
// on every call, the authorization state machine including its prompt-then-recheck loop and its
// timeout branch, and the fetched-target label guards.

private func store(_ backend: FakeContactsBackend, timeout: TimeInterval = 10) -> ContactsStore {
    ContactsStore(backend: backend, requestTimeout: timeout)
}

/// Assert `body` throws an `AppleError` of the given contractual type.
private func expectAppleError(_ type: String,
                              sourceLocation: SourceLocation = #_sourceLocation,
                              _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected \(type) but nothing was thrown", sourceLocation: sourceLocation)
    } catch let e as AppleError {
        #expect(e.type == type, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected AppleError, got \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - Authorization

@Suite("ContactsStore authorization")
struct ContactsStoreAuthTests {
    @Test("every CNAuthorizationStatus raw value maps to the MCP's status string")
    func statusMapping() {
        let expected = [0: "notDetermined", 1: "restricted", 2: "denied",
                        3: "authorized", 4: "limited", 99: "notDetermined"]
        for (raw, name) in expected {
            let backend = FakeContactsBackend()
            backend.statuses = [raw]
            #expect(store(backend).authorizationStatus() == name, "raw \(raw)")
        }
    }

    @Test("remediation copy exists for every non-granted status and is nil otherwise")
    func remediation() {
        #expect(ContactsStore.remediation(for: "notDetermined")?.contains("has not been requested") == true)
        #expect(ContactsStore.remediation(for: "denied")?.contains("was denied") == true)
        #expect(ContactsStore.remediation(for: "restricted")?.contains("parental controls") == true)
        #expect(ContactsStore.remediation(for: "authorized") == nil)
        #expect(ContactsStore.remediation(for: "limited") == nil)
    }

    @Test("authorized and limited both pass the gate without prompting")
    func granted() throws {
        for raw in [3, 4] {
            let backend = FakeContactsBackend()
            backend.statuses = [raw]
            try store(backend).requireAuthorization()
            #expect(backend.accessRequests == 0, "raw \(raw) must not prompt")
        }
    }

    @Test("notDetermined prompts once, then re-reads the status and proceeds")
    func promptsThenRechecks() throws {
        let backend = FakeContactsBackend()
        backend.statuses = [0, 3]           // notDetermined → (prompt) → authorized
        try store(backend).requireAuthorization()
        #expect(backend.accessRequests == 1)
    }

    @Test("a denied status throws authorization_denied carrying status + remediation")
    func denied() {
        let backend = FakeContactsBackend()
        backend.statuses = [2]
        do {
            try store(backend).requireAuthorization()
            Issue.record("expected authorization_denied")
        } catch let e as AppleError {
            #expect(e.type == "authorization_denied")
            #expect(e.exitCode == AppleExit.permissionDenied)
            #expect(e.status == "denied")
            #expect(e.remediation?.contains("System Settings") == true)
            #expect(e.message.contains("status=denied"))
            // The oracle keeps these as three SEPARATE keys — the remediation is NOT appended.
            #expect(e.message.contains("was denied") == false)
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test("a restricted status is refused after the prompt path too")
    func restrictedAfterPrompt() {
        let backend = FakeContactsBackend()
        backend.statuses = [0, 1]           // notDetermined → (prompt) → restricted
        expectAppleError("authorization_denied") { try store(backend).requireAuthorization() }
        #expect(backend.accessRequests == 1)
    }

    @Test("an access-request ERROR surfaces as authorization_denied")
    func requestError() {
        let backend = FakeContactsBackend()
        backend.statuses = [0]
        backend.accessGrant = (false, FakeContactsFailure("prompt exploded"))
        expectAppleError("authorization_denied") { try store(backend).requireAuthorization() }
    }

    @Test("a prompt that never calls back times out with status=notDetermined and NO remediation")
    func requestTimeout() {
        let backend = FakeContactsBackend()
        backend.statuses = [0]
        backend.accessGrant = nil           // handler never fires
        do {
            try store(backend, timeout: 0.05).requireAuthorization()
            Issue.record("expected the timeout branch to throw")
        } catch let e as AppleError {
            #expect(e.type == "authorization_denied")
            #expect(e.status == "notDetermined")
            // The oracle's timeout branch deliberately carries NO remediation — the system
            // dialog is already on screen, so "open System Settings" would be wrong advice.
            #expect(e.remediation == nil)
            #expect(e.message.contains("awaiting your response"))
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test("the prompt is bridged correctly when Contacts answers on ANOTHER queue")
    func promptDeliveredOffThread() throws {
        // The realistic shape: Contacts invokes the completion on a queue of its own choosing, so
        // the handler's write and this thread's read genuinely cross. A synchronous re-entry never
        // exercises `ContactsStore.AccessResult`'s lock or the semaphore hand-off at all.
        let queue = DispatchQueue(label: "apple-cli-test.contacts.prompt", attributes: .concurrent)

        let granted = FakeContactsBackend()
        granted.statuses = [0, 3]                    // notDetermined → (prompt) → authorized
        granted.accessCompletionQueue = queue
        try store(granted).requireAuthorization()
        #expect(granted.accessRequests == 1)

        let denied = FakeContactsBackend()
        denied.statuses = [0, 2]
        denied.accessGrant = (false, nil)
        denied.accessCompletionQueue = queue
        expectAppleError("authorization_denied") { try store(denied).requireAuthorization() }
        #expect(denied.accessRequests == 1)

        let failed = FakeContactsBackend()
        failed.statuses = [0]
        failed.accessGrant = (false, FakeContactsFailure("prompt exploded"))
        failed.accessCompletionQueue = queue
        do {
            try store(failed).requireAuthorization()
            Issue.record("expected authorization_denied")
        } catch let e as AppleError {
            #expect(e.type == "authorization_denied")
            #expect(e.message.contains("Contacts authorization error"))
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test("an off-thread prompt that arrives AFTER the timeout cannot corrupt the refusal")
    func promptArrivesAfterTimeout() {
        // The timeout path returns while the handler is still in flight — the case the semaphore
        // alone does not order, and the reason `AccessResult` carries an explicit lock.
        let backend = FakeContactsBackend()
        backend.statuses = [0]
        backend.accessGrant = (true, nil)
        backend.accessCompletionQueue = DispatchQueue(label: "apple-cli-test.contacts.late")
        do {
            try store(backend, timeout: 0.001).requireAuthorization()
            Issue.record("expected the timeout branch to throw")
        } catch let e as AppleError {
            #expect(e.type == "authorization_denied")
            #expect(e.status == "notDetermined")
            #expect(e.message.contains("awaiting your response"))
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test("an empty status fixture degrades to notDetermined instead of trapping")
    func emptyStatusFixtureIsSafe() {
        let backend = FakeContactsBackend()
        backend.statuses = []
        #expect(store(backend).authorizationStatus() == "notDetermined")
    }

    @Test("a denied prompt (granted == false) still refuses")
    func promptDeclined() {
        let backend = FakeContactsBackend()
        backend.statuses = [0, 2]
        backend.accessGrant = (false, nil)
        expectAppleError("authorization_denied") { try store(backend).requireAuthorization() }
    }
}

// MARK: - Reads

@Suite("ContactsStore reads")
struct ContactsStoreReadTests {
    @Test("enumerateContacts applies offset and limit over the backend's rows")
    func paging() throws {
        let backend = FakeContactsBackend()
        backend.contactRows = (0..<10).map { fakeContact(given: "Alice\($0)", family: "Doe") }
        let s = store(backend)

        let firstPage = try s.enumerateContacts(offset: 0, limit: 3)
        #expect(firstPage.map(\.given_name) == ["Alice0", "Alice1", "Alice2"])

        let skipped = try s.enumerateContacts(offset: 4, limit: 2)
        #expect(skipped.map(\.given_name) == ["Alice4", "Alice5"])

        // A limit past the end simply returns what exists.
        #expect(try s.enumerateContacts(offset: 8, limit: 50).count == 2)
        // An offset past the end returns nothing.
        #expect(try s.enumerateContacts(offset: 99, limit: 5).isEmpty)
    }

    @Test("an enumeration failure maps to unknown")
    func enumerateFailure() {
        let backend = FakeContactsBackend()
        backend.enumerateError = FakeContactsFailure()
        expectAppleError("unknown") { _ = try store(backend).enumerateContacts(offset: 0, limit: 5) }
    }

    @Test("unifiedContact returns a serialized record, or nil when the id resolves to nothing")
    func unifiedContact() throws {
        let backend = FakeContactsBackend()
        let row = fakeContact(given: "Jane", family: "Doe", organization: "Example Org",
                              phone: "+1-555-0101", email: "jane@example.com")
        backend.contactsByIdentifier["c1"] = row
        let s = store(backend)

        let plain = try #require(s.unifiedContact("c1", includeNiche: false))
        #expect(plain.given_name == "Jane")
        #expect(plain.phones.first?.value == "+1-555-0101")
        #expect(plain.emails.first?.value == "jane@example.com")
        #expect(plain.dates == nil)                     // niche omitted

        let rich = try #require(s.unifiedContact("c1", includeNiche: true))
        #expect(rich.dates != nil)                      // niche key present
        #expect(s.unifiedContact("missing", includeNiche: false) == nil)
    }

    @Test("searchContacts accepts the four MCP fields and rejects anything else")
    func searchFields() throws {
        let backend = FakeContactsBackend()
        backend.matchingContacts = [fakeContact(given: "Bob", family: "Doe")]
        let s = store(backend)
        for field in ["name", "phone", "email", "organization"] {
            #expect(try s.searchContacts(field: field, value: "Bob", limit: 10).count == 1, "field \(field)")
        }
        expectAppleError("validation_error") {
            _ = try s.searchContacts(field: "nickname", value: "Bob", limit: 10)
        }
    }

    @Test("searchContacts truncates to the limit and maps fetch failures to unknown")
    func searchLimitAndFailure() throws {
        let backend = FakeContactsBackend()
        backend.matchingContacts = (0..<5).map { fakeContact(given: "Alice\($0)", family: "Doe") }
        #expect(try store(backend).searchContacts(field: "name", value: "Alice", limit: 2).count == 2)

        let failing = FakeContactsBackend()
        failing.matchingContactsError = FakeContactsFailure()
        expectAppleError("unknown") {
            _ = try store(failing).searchContacts(field: "email", value: "a@example.com", limit: 5)
        }
    }

    @Test("readPhoto distinguishes not-found, no-photo, and bytes-present")
    func readPhoto() throws {
        let backend = FakeContactsBackend()
        let bare = fakeContact()
        let withPhoto = fakeContact(given: "Alice")
        // A 1x1 GIF header is enough for the availability flag and the format sniffer.
        withPhoto.imageData = Data(Array("GIF89a".utf8) + [0x00, 0x01])
        backend.contactsByIdentifier = ["bare": bare, "photo": withPhoto]
        let s = store(backend)

        #expect(s.readPhoto("missing") == nil)
        let none = try #require(s.readPhoto("bare"))
        #expect(none.available == false)
        #expect(none.bytes.isEmpty)
        let some = try #require(s.readPhoto("photo"))
        #expect(some.available == true)
        #expect(detectImageFormat(some.bytes) == "gif")
    }
}

// MARK: - Groups, containers, vCard export

@Suite("ContactsStore groups + containers")
struct ContactsStoreGroupTests {
    @Test("listGroups maps every group; an unmatched container resolves to \"\" rather than failing")
    func listGroups() throws {
        let backend = FakeContactsBackend()
        backend.allGroups = [fakeGroup(name: "apple-cli-test group"), fakeGroup(name: "Friends")]
        let groups = try store(backend).listGroups()
        #expect(groups.map(\.name) == ["apple-cli-test group", "Friends"])
        // No container matched the group predicate, so the id resolves to "" (not a crash).
        #expect(groups.allSatisfy { $0.container_id.isEmpty })
        #expect(groups.allSatisfy { !$0.id.isEmpty })
    }

    @Test("a group whose container DOES resolve carries that container's id")
    func listGroupsWithContainer() throws {
        let backend = FakeContactsBackend()
        let container = CNContainer()
        backend.allGroups = [fakeGroup(name: "apple-cli-test group")]
        backend.containerLookup = [container]
        let groups = try store(backend).listGroups()
        #expect(groups.first?.container_id == container.identifier)
    }

    @Test("a group-fetch failure maps to unknown on both list and lookup")
    func groupFailures() {
        let backend = FakeContactsBackend()
        backend.groupsError = FakeContactsFailure()
        expectAppleError("unknown") { _ = try store(backend).listGroups() }
        expectAppleError("unknown") { _ = try store(backend).fetchGroup("g1") }
    }

    @Test("fetchGroup returns the matched group, or nil when the lookup is empty")
    func fetchGroup() throws {
        let backend = FakeContactsBackend()
        backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        #expect(try store(backend).fetchGroup("g1")?.name == "apple-cli-test group")

        let empty = FakeContactsBackend()
        #expect(try store(empty).fetchGroup("g1") == nil)
        // The lookup is identifier-scoped: production asks with a predicate, not with nil.
        #expect(empty.groupQueries.count == 1)
        #expect(empty.groupQueries[0] != nil)
    }

    @Test("contactsInGroup truncates to the limit; a failure maps to unknown")
    func contactsInGroup() throws {
        let backend = FakeContactsBackend()
        backend.matchingContacts = (0..<4).map { fakeContact(given: "Alice\($0)", family: "Doe") }
        #expect(try store(backend).contactsInGroup("g1", limit: 2).count == 2)

        let failing = FakeContactsBackend()
        failing.matchingContactsError = FakeContactsFailure()
        expectAppleError("unknown") { _ = try store(failing).contactsInGroup("g1", limit: 5) }
    }

    @Test("listContainers maps every container and flags the default one")
    func listContainers() throws {
        #expect(try store(FakeContactsBackend()).listContainers().isEmpty)

        // `CNContainer` has no initializer that sets name or type, so the type STRING is pinned
        // separately by `containerTypeStrings` below; what this pins is the mapping and the
        // is_default comparison against `defaultContainerIdentifier()`.
        let backend = FakeContactsBackend()
        let first = CNContainer(), second = CNContainer()
        backend.allContainers = [first, second]
        backend.defaultContainer = second.identifier
        let containers = try store(backend).listContainers()
        #expect(containers.map(\.id) == [first.identifier, second.identifier])
        #expect(containers.map(\.is_default) == [false, true])
        #expect(containers.allSatisfy { $0.type == "unknown(0)" })

        let failing = FakeContactsBackend()
        failing.containersError = FakeContactsFailure()
        expectAppleError("unknown") { _ = try store(failing).listContainers() }
    }

    @Test("container type strings match the MCP's vocabulary, unknown included")
    func containerTypeStrings() {
        #expect(ContactsStore.containerType(.local) == "local")
        #expect(ContactsStore.containerType(.exchange) == "exchange")
        #expect(ContactsStore.containerType(.cardDAV) == "cardDAV")
        #expect(ContactsStore.containerType(.unassigned) == "unknown(0)")
    }

    @Test("exportVCard serializes every requested contact and 404s on the first miss")
    func exportVCard() throws {
        let backend = FakeContactsBackend()
        backend.contactsByIdentifier = [
            "c1": fakeContact(given: "Jane", family: "Doe"),
            "c2": fakeContact(given: "Alice", family: "Roe"),
        ]
        let text = try store(backend).exportVCard(["c1", "c2"])
        #expect(text.contains("BEGIN:VCARD"))
        #expect(text.contains("VERSION:3.0"))
        #expect(text.contains("Jane"))
        #expect(text.contains("Alice"))

        expectAppleError("not_found") { _ = try store(backend).exportVCard(["c1", "missing"]) }
    }

    @Test("a payload that PARSES but yields no cards is its own validation error")
    func vcardParsesToZeroCards() {
        // A well-formed but contact-less card: CN parses it successfully and returns an EMPTY
        // array, which is a different failure from a parse error and gets its own message.
        //
        // WHICH BRANCH MALFORMED INPUT ACTUALLY TAKES. `CNContactVCardSerialization.contacts(
        // with:)` is far more tolerant than its throwing signature suggests — probed on macOS 26
        // against `BEGIN:VCARD` alone, `END:VCARD` alone, a bad VERSION, an un-decodable PHOTO,
        // a truncated UTF-16 BOM, raw binary, and plain prose, it threw for NONE of them and
        // returned an empty array every time. So the `catch` arm that maps to "vCard parse
        // failed" is unreachable by any text this CLI can be handed, and EVERY malformed payload
        // — including the "not a vcard at all" case the sibling suite asserts on — lands here.
        // Pinning the message keeps that distinction visible instead of implied.
        let emptyCard = ["BEGIN:VCARD", "VERSION:3.0", "END:VCARD", ""].joined(separator: "\r\n")
        do {
            _ = try ContactsStore.validateVCard(text: emptyCard)
            Issue.record("expected validation_error for a card-less payload")
        } catch let e as AppleError {
            #expect(e.type == "validation_error")
            #expect(e.message.contains("No vCards found in input"))
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test("vcardPrimaryNames reads the label-bearing name of every card without a store")
    func vcardPrimaryNames() throws {
        let payload = fakeVCard(given: "apple-cli-test Jane", family: "Doe")
            + fakeVCard(given: "Bob", family: "Roe")
        #expect(try ContactsStore.vcardPrimaryNames(text: payload)
            == ["apple-cli-test Jane", "Bob"])
    }
}

// MARK: - Fetched-target write guards

@Suite("ContactsStore fetched-target guards")
struct ContactsStoreTargetGuardTests {
    // The CANONICAL constant, never the env-backed `TestMode.sandboxPrefix`: every literal below
    // is an "apple-cli-test…" name, and MailKitTests setenv()s APPLE_TEST_SANDBOX in parallel.
    let prefix = TestMode.canonicalSandboxPrefix

    @Test("a labeled contact passes; an unlabeled one is a safety_violation; a missing one 404s")
    func contactTarget() throws {
        let backend = FakeContactsBackend()
        backend.contactsByIdentifier = [
            "ok": fakeContact(given: "apple-cli-test Jane", family: "Doe"),
            "real": fakeContact(given: "Jane", family: "Doe"),
        ]
        let s = store(backend)
        try s.requireLabeledContactTarget("ok", prefix: prefix)

        do {
            try s.requireLabeledContactTarget("real", prefix: prefix)
            Issue.record("expected a safety_violation for an unlabeled contact")
        } catch let e as AppleError {
            #expect(e.type == "safety_violation")
            #expect(e.exitCode == AppleExit.permissionDenied)
            #expect(e.sandbox == true)
        }
        expectAppleError("not_found") { try s.requireLabeledContactTarget("missing", prefix: prefix) }
    }

    @Test("the group guard mirrors the contact guard exactly")
    func groupTarget() throws {
        let labeled = FakeContactsBackend()
        labeled.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        try store(labeled).requireLabeledGroupTarget("g1", prefix: prefix)

        let real = FakeContactsBackend()
        real.groupLookup = [fakeGroup(name: "Friends")]
        expectAppleError("safety_violation") { try store(real).requireLabeledGroupTarget("g1", prefix: prefix) }

        let missing = FakeContactsBackend()
        expectAppleError("not_found") { try store(missing).requireLabeledGroupTarget("g1", prefix: prefix) }
    }
}

// MARK: - Writes

@Suite("ContactsStore writes")
struct ContactsStoreWriteTests {
    private func labeledFields() -> ContactFields {
        var f = ContactFields()
        f.given_name = "apple-cli-test Jane"
        f.family_name = "Doe"
        return f
    }

    @Test("createContact saves and returns the new identifier")
    func createContact() throws {
        let backend = FakeContactsBackend()
        let id = try store(backend).createContact(fields: labeledFields(), groupIdentifier: nil,
                                                  containerIdentifier: nil)
        #expect(!id.isEmpty)
        #expect(backend.executed.count == 1)
    }

    @Test("createContact adds to a group when one is named, and 404s on a missing group")
    func createContactInGroup() throws {
        let backend = FakeContactsBackend()
        backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        _ = try store(backend).createContact(fields: labeledFields(), groupIdentifier: "g1",
                                             containerIdentifier: "container-1")
        #expect(backend.executed.count == 1)

        let missing = FakeContactsBackend()
        expectAppleError("not_found") {
            _ = try store(missing).createContact(fields: self.labeledFields(), groupIdentifier: "g1",
                                                 containerIdentifier: nil)
        }
    }

    @Test("a failed save maps to unknown on every write")
    func executeFailures() {
        func failing() -> FakeContactsBackend {
            let b = FakeContactsBackend()
            b.executeError = FakeContactsFailure()
            b.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
            b.groupLookup = [fakeGroup(name: "apple-cli-test group")]
            return b
        }
        expectAppleError("unknown") {
            _ = try store(failing()).createContact(fields: self.labeledFields(), groupIdentifier: nil,
                                                   containerIdentifier: nil)
        }
        expectAppleError("unknown") {
            _ = try store(failing()).updateContact(identifier: "c1", fields: self.labeledFields())
        }
        expectAppleError("unknown") { _ = try store(failing()).deleteContact(identifier: "c1") }
        expectAppleError("unknown") { _ = try store(failing()).writePhoto(identifier: "c1", imageData: nil) }
        expectAppleError("unknown") {
            _ = try store(failing()).createGroup(name: "apple-cli-test group", containerIdentifier: nil)
        }
        expectAppleError("unknown") {
            _ = try store(failing()).renameGroup(identifier: "g1", newName: "apple-cli-test renamed")
        }
        expectAppleError("unknown") { _ = try store(failing()).deleteGroup(identifier: "g1") }
        expectAppleError("unknown") {
            try store(failing()).addContactToGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        }
        expectAppleError("unknown") {
            _ = try store(failing()).importVCard(text: fakeVCard(given: "apple-cli-test Jane", family: "Doe"),
                                                 groupIdentifier: nil)
        }
    }

    @Test("id-addressed writes 404 when the contact does not resolve")
    func missingContact() {
        let backend = FakeContactsBackend()
        expectAppleError("not_found") {
            _ = try store(backend).updateContact(identifier: "c1", fields: self.labeledFields())
        }
        expectAppleError("not_found") { _ = try store(backend).deleteContact(identifier: "c1") }
        expectAppleError("not_found") { _ = try store(backend).writePhoto(identifier: "c1", imageData: Data()) }
        expectAppleError("not_found") {
            try store(backend).addContactToGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        }
    }

    @Test("updateContact applies the fields and echoes the identifier back")
    func updateContact() throws {
        let backend = FakeContactsBackend()
        backend.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
        var f = ContactFields()
        f.family_name = "Roe"
        #expect(try store(backend).updateContact(identifier: "c1", fields: f) == "c1")
        #expect(backend.executed.count == 1)
    }

    @Test("deleteContact and writePhoto echo the identifier back")
    func deleteAndPhoto() throws {
        let backend = FakeContactsBackend()
        backend.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
        let s = store(backend)
        #expect(try s.writePhoto(identifier: "c1", imageData: Data([0xFF, 0xD8, 0xFF])) == "c1")
        #expect(try s.writePhoto(identifier: "c1", imageData: nil) == "c1")   // clear
        #expect(try s.deleteContact(identifier: "c1") == "c1")
        #expect(backend.executed.count == 3)
    }

    @Test("group create / rename / delete round-trip through one save each")
    func groupWrites() throws {
        let create = FakeContactsBackend()
        let created = try store(create).createGroup(name: "apple-cli-test group", containerIdentifier: "container-1")
        #expect(created.name == "apple-cli-test group")
        #expect(!created.id.isEmpty)
        #expect(create.executed.count == 1)

        let rename = FakeContactsBackend()
        rename.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        let renamed = try store(rename).renameGroup(identifier: "g1", newName: "apple-cli-test renamed")
        #expect(renamed.name == "apple-cli-test renamed")
        #expect(renamed.id == "g1")

        let del = FakeContactsBackend()
        del.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        #expect(try store(del).deleteGroup(identifier: "g1") == "g1")

        let missing = FakeContactsBackend()
        expectAppleError("not_found") {
            _ = try store(missing).renameGroup(identifier: "g1", newName: "apple-cli-test renamed")
        }
        expectAppleError("not_found") { _ = try store(missing).deleteGroup(identifier: "g1") }
    }

    @Test("addContactToGroup 404s distinctly for a missing contact and a missing group")
    func membership() throws {
        let ok = FakeContactsBackend()
        ok.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
        ok.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        try store(ok).addContactToGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        #expect(ok.executed.count == 1)

        let noGroup = FakeContactsBackend()
        noGroup.contactsByIdentifier["c1"] = fakeContact()
        do {
            try store(noGroup).addContactToGroup(contactIdentifier: "c1", groupIdentifier: "g1")
            Issue.record("expected not_found")
        } catch let e as AppleError {
            #expect(e.type == "not_found")
            #expect(e.message.contains("Group not found"))
        }
    }

    @Test("importVCard parses, saves once, and returns one identifier per card")
    func importVCard() throws {
        let backend = FakeContactsBackend()
        backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        let payload = fakeVCard(given: "apple-cli-test Jane", family: "Doe")
            + fakeVCard(given: "apple-cli-test Alice", family: "Roe")
        let ids = try store(backend).importVCard(text: payload, groupIdentifier: "g1")
        #expect(ids.count == 2)
        #expect(backend.executed.count == 1)        // atomic: ONE save request

        expectAppleError("validation_error") {
            _ = try store(backend).importVCard(text: "not a vcard", groupIdentifier: nil)
        }
        let missingGroup = FakeContactsBackend()
        expectAppleError("not_found") {
            _ = try store(missingGroup).importVCard(
                text: fakeVCard(given: "apple-cli-test Jane", family: "Doe"), groupIdentifier: "g1")
        }
    }
}

// MARK: - AppleScript fallbacks (notes + group remove-member)

@Suite("ContactsStore AppleScript fallbacks")
struct ContactsStoreScriptTests {
    @Test("readNote returns the script's stdout and binds the id as ARGV, never in the source")
    func readNote() throws {
        let backend = FakeContactsBackend()
        backend.scriptResult = "a synthetic note"
        let id = "ABCD-1234:ABPerson"
        #expect(try store(backend).readNote(id) == "a synthetic note")
        let call = try #require(backend.scriptCalls.first)
        #expect(call.arguments == [id])
        // SECURITY: the identifier must reach osascript as argv only.
        #expect(call.script.contains(id) == false)
        #expect(call.script.contains("on run argv"))
    }

    @Test("writeNote passes id + text as ARGV, never interpolated into the script")
    func writeNote() throws {
        let backend = FakeContactsBackend()
        let note = "note text with \" quote and \\ backslash"
        try store(backend).writeNote("c1", note: note)
        let call = try #require(backend.scriptCalls.first)
        #expect(call.arguments == ["c1", note])
        #expect(call.script.contains(note) == false)
    }

    @Test("an AppleScript 'can't get' failure maps to not_found on every script path")
    func scriptNotFound() {
        for stderr in ["execution error: Invalid index. (-1719)",
                       "Contacts got an error: Can't get person 1",
                       "Contacts got an error: Can\u{2019}t get person 1"] {
            let backend = FakeContactsBackend()
            backend.contactsByIdentifier["c1"] = fakeContact()
            backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
            backend.scriptError = AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: stderr)
            let s = store(backend)
            expectAppleError("not_found") { _ = try s.readNote("c1") }
            expectAppleError("not_found") { try s.writeNote("c1", note: "x") }
            expectAppleError("not_found") {
                try s.removeContactFromGroup(contactIdentifier: "c1", groupIdentifier: "g1")
            }
        }
    }

    @Test("any other AppleScript failure maps to unknown WITHOUT leaking raw osascript stderr")
    func scriptGenericFailure() throws {
        let secret = "some-unstable-locale-specific-stderr"
        let backend = FakeContactsBackend()
        backend.contactsByIdentifier["c1"] = fakeContact()
        backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        backend.scriptError = AppleScriptRunner.RunError.scriptFailed(status: 2, stderr: secret)
        let s = store(backend)
        do {
            _ = try s.readNote("c1")
            Issue.record("expected unknown")
        } catch let e as AppleError {
            #expect(e.type == "unknown")
            #expect(e.message.contains(secret) == false)
            #expect(e.message.contains("read_note failed"))
            #expect(e.message.contains("Automation"))
        }
        expectAppleError("unknown") { try s.writeNote("c1", note: "x") }
        expectAppleError("unknown") {
            try s.removeContactFromGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        }
    }

    @Test("removeContactFromGroup preflights both sides before running the script")
    func removeMemberPreflight() throws {
        let ok = FakeContactsBackend()
        ok.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
        ok.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        try store(ok).removeContactFromGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        let call = try #require(ok.scriptCalls.first)
        #expect(call.arguments == ["c1", "g1"])

        // A missing contact must 404 from the PREFLIGHT — the script never runs.
        let noContact = FakeContactsBackend()
        noContact.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        expectAppleError("not_found") {
            try store(noContact).removeContactFromGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        }
        #expect(noContact.scriptCalls.isEmpty)
    }
}

// MARK: - Save wiring (what feeds each CNSaveRequest)

/// What every write path asks the store for BEFORE it saves, and how many saves it issues.
///
/// SCOPE — READ THIS BEFORE STRENGTHENING. `CNSaveRequest` exposes no public read API: there is
/// no supported way to ask a request which contacts or groups were added, updated, deleted, or
/// re-grouped. (Private ivars exist; reaching into them from a test would couple this suite to
/// Apple internals that can change in a point release, which is worse than the gap.) So these
/// tests pin the observable surface that FEEDS each save — the identifier looked up, the exact
/// key set requested, whether the group/container lookup was identifier-scoped or list-everything,
/// and the number of saves issued — plus the identifier each write returns. Together those catch a
/// regressed lookup, a narrowed key set, a missing preflight, a duplicated save, and a save that
/// stopped happening. They do NOT catch a save that carries the wrong OPERATION (an `update` where
/// a `delete` belongs); that residue is covered at the live tier, where the store's real state is
/// the oracle.
@Suite("ContactsStore save wiring")
struct ContactsSaveWiringTests {
    private func loaded() -> FakeContactsBackend {
        let b = FakeContactsBackend()
        b.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
        b.groupLookup = [fakeGroup(name: "apple-cli-test group")]
        return b
    }

    private func labeledFields() -> ContactFields {
        var f = ContactFields()
        f.given_name = "apple-cli-test Jane"
        return f
    }

    @Test("create: no identifier lookup, one save, and a group named ⇒ one scoped group query")
    func createWiring() throws {
        let plain = FakeContactsBackend()
        _ = try store(plain).createContact(fields: labeledFields(), groupIdentifier: nil,
                                           containerIdentifier: nil)
        #expect(plain.unifiedContactRequests.isEmpty)   // built fresh, never fetched
        #expect(plain.executed.count == 1)
        #expect(plain.groupQueries.isEmpty)             // no --group ⇒ no group resolution

        let grouped = loaded()
        _ = try store(grouped).createContact(fields: labeledFields(), groupIdentifier: "g1",
                                             containerIdentifier: nil)
        #expect(grouped.executed.count == 1)
        #expect(grouped.groupQueries.count == 1)
        #expect(grouped.groupQueries[0] != nil)         // identifier-scoped, not list-everything
    }

    @Test("update: fetches c1 with the P1 + niche key set, then saves once")
    func updateWiring() throws {
        let backend = loaded()
        _ = try store(backend).updateContact(identifier: "c1", fields: labeledFields())
        #expect(backend.unifiedContactRequests == ["c1"])
        let keys = try #require(backend.unifiedContactKeys.first)
        // Update must read the WHOLE record — it round-trips fields it does not change.
        #expect(keys.contains(CNContactGivenNameKey))
        #expect(keys.contains(CNContactPhoneNumbersKey))
        #expect(keys.contains(CNContactDatesKey))        // niche included on update
        #expect(backend.executed.count == 1)
    }

    @Test("delete: fetches c1 with the IDENTIFIER key alone, then saves once")
    func deleteWiring() throws {
        let backend = loaded()
        _ = try store(backend).deleteContact(identifier: "c1")
        #expect(backend.unifiedContactRequests == ["c1"])
        // A delete needs no field data; fetching more would be wasted I/O on a real store.
        #expect(backend.unifiedContactKeys == [[CNContactIdentifierKey]])
        #expect(backend.executed.count == 1)
    }

    @Test("write photo: fetches only the image key, then saves once")
    func writePhotoWiring() throws {
        let backend = loaded()
        _ = try store(backend).writePhoto(identifier: "c1", imageData: Data([0xFF, 0xD8, 0xFF]))
        #expect(backend.unifiedContactKeys == [[CNContactImageDataKey]])
        #expect(backend.executed.count == 1)
    }

    @Test("read photo: fetches the image key AND the availability flag")
    func readPhotoWiring() throws {
        let backend = loaded()
        _ = store(backend).readPhoto("c1")
        let keys = try #require(backend.unifiedContactKeys.first)
        #expect(keys.contains(CNContactImageDataKey))
        #expect(keys.contains(CNContactImageDataAvailableKey))
        #expect(backend.executed.isEmpty)                // a read never saves
    }

    @Test("add member: preflights BOTH sides, then saves once")
    func addMemberWiring() throws {
        let backend = loaded()
        try store(backend).addContactToGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        #expect(backend.unifiedContactRequests == ["c1"])
        #expect(backend.unifiedContactKeys == [[CNContactIdentifierKey]])
        #expect(backend.groupQueries.count == 1)
        #expect(backend.executed.count == 1)
    }

    @Test("remove member: preflights both sides, saves NOTHING, and runs one script")
    func removeMemberWiring() throws {
        let backend = loaded()
        try store(backend).removeContactFromGroup(contactIdentifier: "c1", groupIdentifier: "g1")
        #expect(backend.unifiedContactRequests == ["c1"])
        #expect(backend.groupQueries.count == 1)
        // CNSaveRequest.removeMember silently no-ops, which is WHY this path is AppleScript.
        #expect(backend.executed.isEmpty)
        #expect(backend.scriptCalls.count == 1)
    }

    @Test("group create / rename / delete: one save each, and the container is resolved after")
    func groupWriteWiring() throws {
        let create = FakeContactsBackend()
        _ = try store(create).createGroup(name: "apple-cli-test group", containerIdentifier: nil)
        #expect(create.executed.count == 1)
        // The new group's container is resolved by an identifier-scoped container query.
        #expect(create.containerQueries.count == 1)
        #expect(create.containerQueries[0] != nil)

        let rename = loaded()
        _ = try store(rename).renameGroup(identifier: "g1", newName: "apple-cli-test renamed")
        #expect(rename.executed.count == 1)
        #expect(rename.groupQueries.contains { $0 != nil })

        let delete = loaded()
        _ = try store(delete).deleteGroup(identifier: "g1")
        #expect(delete.executed.count == 1)
        #expect(delete.containerQueries.isEmpty)         // a delete resolves no container
    }

    @Test("import vCard: no identifier lookups and exactly ONE save for N cards (atomic)")
    func importWiring() throws {
        let backend = loaded()
        let payload = fakeVCard(given: "apple-cli-test Jane", family: "Doe")
            + fakeVCard(given: "apple-cli-test Alice", family: "Roe")
        let ids = try store(backend).importVCard(text: payload, groupIdentifier: "g1")
        #expect(ids.count == 2)
        #expect(backend.unifiedContactRequests.isEmpty)  // parsed from text, never fetched
        #expect(backend.executed.count == 1)             // ONE request for both cards
        #expect(backend.groupQueries.count == 1)
    }

    @Test("notes: the AppleScript paths save nothing through CN at all")
    func noteWiring() throws {
        let read = loaded()
        read.scriptResult = "a synthetic note"
        _ = try store(read).readNote("c1")
        #expect(read.executed.isEmpty)
        #expect(read.scriptCalls.count == 1)

        let write = loaded()
        try store(write).writeNote("c1", note: "hello")
        #expect(write.executed.isEmpty)
        #expect(write.scriptCalls.count == 1)
    }

    @Test("the fetched-target guards read the P1 key set, never the identifier alone")
    func targetGuardWiring() throws {
        let backend = loaded()
        try store(backend).requireLabeledContactTarget("c1", prefix: TestMode.canonicalSandboxPrefix)
        let keys = try #require(backend.unifiedContactKeys.first)
        // The guard reads the NAME, so an identifier-only fetch would trap on access.
        #expect(keys.contains(CNContactGivenNameKey))
        #expect(keys.contains(CNContactFamilyNameKey))
        #expect(keys.contains(CNContactOrganizationNameKey))
        #expect(backend.executed.isEmpty)                // a guard never writes
    }
}
