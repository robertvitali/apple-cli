import Foundation
import Darwin
import Testing
import Contacts
import ArgumentParser
@testable import ContactsKit
import AppleKit
import TestSupport

// Shared logic-tier fixtures for the Contacts lane: an in-memory `ContactsStoreBackend`, the
// synthetic CN objects the suites feed it, and the stdout-capturing command drivers.
//
// TCC-FREE BY CONSTRUCTION. Nothing here constructs a `CNContactStore`, and no test in this
// target calls `requestAccess` / `unifiedContacts` / `enumerateContacts` / `execute` /
// `authorizationStatus` on a real store, or `Permissions.preflight()`. `CNMutableContact` and
// `CNMutableGroup` need no store to exist, so the fake vends those directly; every framework
// call production makes is intercepted by `FakeContactsBackend` and answered from memory.
//
// NO PERSONAL DATA: every fixture uses reserved placeholders (Jane Doe / Alice / Bob,
// example.com, 555-01xx, 1 Main St) per AGENTS.md.

// MARK: - Errors the fake raises

/// Carries a non-Sendable payload into a `@Sendable` completion closure. Sound here: written
/// once before the closure is formed, then read once inside it, with no concurrent mutation.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Stands in for the `CNError` a real `CNContactStore` throws when an identifier resolves to
/// nothing. Production wraps that call in `try?`, so only the fact that it threw matters.
struct FakeContactsNotFound: Error {}

/// Stands in for an arbitrary framework failure (a failed `execute`, a failed fetch), so the
/// `catch` arms that map to `unknown` can be reached without a live store.
struct FakeContactsFailure: Error, LocalizedError {
    let reason: String
    init(_ reason: String = "synthetic backend failure") { self.reason = reason }
    var errorDescription: String? { reason }
}

// MARK: - The in-memory backend

/// An in-memory `ContactsStoreBackend`.
///
/// It deliberately does NOT emulate `NSPredicate` matching: `CNGroup.predicateForGroups(
/// withIdentifiers:)` and `CNContact.predicateForContacts(matchingName:)` are opaque Contacts
/// predicates, and a hand-rolled re-implementation could only drift from the real semantics —
/// a test that passes because the FAKE filtered proves nothing about production. What the fake
/// pins instead is the shape of the call production makes: it records every predicate, and
/// answers `nil`-predicate queries (the "list everything" calls) from a different slot than
/// identifier-scoped ones (the "look this up" calls), which is exactly the distinction the
/// production code draws.
final class FakeContactsBackend: ContactsStoreBackend {
    // Authorization
    /// Raw `CNAuthorizationStatus` values returned by successive `authorizationStatus()` reads;
    /// the last entry repeats. A two-entry sequence drives the notDetermined → prompt → recheck
    /// loop end to end. Default `[3]` is `authorized`.
    var statuses: [Int] = [3]
    private var statusReads = 0
    var authorizationStatusRawValue: Int {
        // An empty `statuses` would make `statuses.count - 1` negative and trap on subscript, so
        // it degrades to notDetermined (0) instead — a fixture mistake should surface as a failed
        // expectation, not as a crash that takes the whole test process down with it.
        guard !statuses.isEmpty else { return 0 }
        let value = statuses[min(statusReads, statuses.count - 1)]
        statusReads += 1
        return value
    }
    /// `nil` ⇒ the handler is never invoked, which drives the request-timeout branch.
    var accessGrant: (Bool, Error?)? = (true, nil)
    var accessRequests = 0
    /// A prestarted test thread delivers callbacks independently of Dispatch's shared worker
    /// pool. The test owns readiness, release, completion, and bounded thread shutdown.
    var accessCompletionWorker: ContactsCompletionWorker?

    // Enumeration (list_contacts)
    var contactRows: [CNContact] = []
    var enumerateError: Error?

    // Identifier lookups (get / update / delete / photo / vcard export / target guards)
    var contactsByIdentifier: [String: CNContact] = [:]
    var unifiedContactRequests: [String] = []
    /// The key set production asked for on each identifier lookup, as raw key strings. Recorded
    /// so a test can assert WHICH keys were fetched — an unfetched CN key traps on access, so the
    /// key set is part of the contract, not an implementation detail.
    var unifiedContactKeys: [[String]] = []

    // Predicate lookups (search / group membership)
    var matchingContacts: [CNContact] = []
    /// Per-CALL results, consumed in order (the last entry repeats once exhausted). Set this when
    /// a test needs successive calls to return DIFFERENT, overlapping rows — the only way to make
    /// `search --deep`'s union/de-dup observable rather than tautological.
    var matchingContactsSequence: [[CNContact]]?
    private var matchingContactsCalls = 0
    var matchingContactsError: Error?
    /// Every predicate handed to `unifiedContacts(matching:)`, in order. The count IS the
    /// assertion for `--deep` (four field searches) vs. a single-field search (one).
    var unifiedContactsQueries: [NSPredicate] = []

    // Groups: nil predicate ⇒ list_groups; non-nil ⇒ fetchGroup by identifier.
    var allGroups: [CNGroup] = []
    var groupLookup: [CNGroup] = []
    var groupsError: Error?
    var groupQueries: [NSPredicate?] = []

    // Containers: nil predicate ⇒ list_containers; non-nil ⇒ container-of-group resolution.
    var allContainers: [CNContainer] = []
    var containerLookup: [CNContainer] = []
    var containersError: Error?
    var defaultContainer = ""
    /// Every predicate handed to `containers(matching:)`, in order — `nil` for the list-everything
    /// call, non-nil for a container-of-group resolution. Recorded so a test can prove which of
    /// the two production actually issued.
    var containerQueries: [NSPredicate?] = []

    // Writes
    var executed: [CNSaveRequest] = []
    var executeError: Error?

    // AppleScript fallback
    var scriptCalls: [(script: String, arguments: [String])] = []
    var scriptResult = ""
    var scriptError: Error?

    func requestAccess(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        accessRequests += 1
        guard let accessGrant else { return }   // never calls back → timeout branch
        let boxed = UncheckedSendableBox(accessGrant)
        guard let accessCompletionWorker else {
            completion(boxed.value.0, boxed.value.1)
            return
        }
        accessCompletionWorker.submit {
            completion(boxed.value.0, boxed.value.1)
        }
    }

    func enumerateContacts(with request: CNContactFetchRequest,
                           usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        if let enumerateError { throw enumerateError }
        var stop = ObjCBool(false)
        for row in contactRows {
            block(row, &stop)
            if stop.boolValue { break }
        }
    }

    func unifiedContact(withIdentifier identifier: String, keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        unifiedContactRequests.append(identifier)
        unifiedContactKeys.append(keys.compactMap { $0 as? String })
        guard let hit = contactsByIdentifier[identifier] else { throw FakeContactsNotFound() }
        return hit
    }

    func unifiedContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        unifiedContactsQueries.append(predicate)
        if let matchingContactsError { throw matchingContactsError }
        guard let matchingContactsSequence, !matchingContactsSequence.isEmpty else {
            return matchingContacts
        }
        let index = min(matchingContactsCalls, matchingContactsSequence.count - 1)
        matchingContactsCalls += 1
        return matchingContactsSequence[index]
    }

    func groups(matching predicate: NSPredicate?) throws -> [CNGroup] {
        groupQueries.append(predicate)
        if let groupsError { throw groupsError }
        return predicate == nil ? allGroups : groupLookup
    }

    func containers(matching predicate: NSPredicate?) throws -> [CNContainer] {
        containerQueries.append(predicate)
        if let containersError { throw containersError }
        return predicate == nil ? allContainers : containerLookup
    }

    func defaultContainerIdentifier() -> String { defaultContainer }

    /// NOTE ON SAVE-REQUEST CONTENTS. `CNSaveRequest` exposes NO public read API — there is no
    /// supported way to ask it which contacts/groups were added, updated, deleted, or re-grouped
    /// (only private ivars, which tests must not reach into). So the fake records the requests
    /// themselves and the suites assert the observable surface instead: exactly how many saves a
    /// path issues, the identifier each write returns, and — recorded above — the identifier, key
    /// set and predicate of every lookup that FEEDS the save. See the header comment on
    /// `ContactsSaveWiringTests` for what that does and does not prove.
    func execute(_ request: CNSaveRequest) throws {
        if let executeError { throw executeError }
        executed.append(request)
    }

    func runScript(_ script: String, arguments: [String]) throws -> String {
        scriptCalls.append((script, arguments))
        if let scriptError { throw scriptError }
        return scriptResult
    }
}

// MARK: - Synthetic CN objects

/// A synthetic contact. All values are reserved placeholders (AGENTS.md).
func fakeContact(given: String = "Jane", family: String = "Doe", organization: String = "",
                 phone: String? = nil, email: String? = nil) -> CNMutableContact {
    let c = CNMutableContact()
    c.givenName = given
    c.familyName = family
    c.organizationName = organization
    if let phone {
        c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
    }
    if let email {
        c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
    }
    return c
}

func fakeGroup(name: String) -> CNMutableGroup {
    let g = CNMutableGroup()
    g.name = name
    return g
}

/// A minimal, well-formed vCard 3.0 payload for the given name.
func fakeVCard(given: String, family: String) -> String {
    ["BEGIN:VCARD", "VERSION:3.0", "N:\(family);\(given);;;", "FN:\(given) \(family)", "END:VCARD", ""]
        .joined(separator: "\r\n")
}

// MARK: - Command drivers (stdout captured, never written to the terminal)

/// Pin every process-global the contacts WRITE GATE reads, for the duration of `body`.
///
/// WHY THIS WRAPS THE RUNNERS RATHER THAN EACH TEST. `resolveWrite` consults `APPLE_DRY_RUN`
/// (the preview default) and `APPLE_TEST_MODE` (the sandbox) straight from the process
/// environment, and `TestMode.sandboxPrefix` reads `APPLE_TEST_SANDBOX`. So a test asserting
/// "this write EXECUTES" is simply WRONG under an ambient `APPLE_DRY_RUN=1` — the operator's
/// shell, CI, or a concurrent suite's open window silently turns it into a preview, and the
/// resulting failure reads as a product regression rather than as environment bleed.
///
/// Putting the pin in the three shared runners below — which every command test in this target
/// goes through — makes it impossible to forget when a new test is added, which per-test
/// wrapping is not. Every write-posture variable is pinned ABSENT under the test process's single
/// recursive lock, so a test that wants one SET nests its own `TestEnvironment.with` window
/// (the delete-grant tests do exactly that, with a test-owned variable name).
///
/// The set is `TestEnvironment.writeModeVariables`, named ONCE in TestSupport — not re-spelled
/// here. This pin used to compose `withoutSandboxOverrides` with its own `APPLE_DRY_RUN` entry,
/// which pinned all four correctly on the day it was written and would have silently
/// under-pinned the day a fifth write-posture variable was added to the shared list.
@discardableResult
func pinnedGates<T>(_ body: () throws -> T) rethrows -> T {
    try TestEnvironment.withoutWriteModeOverrides(body)
}

func contactsStreams() -> (CLIStreams, MemoryOutputSink) {
    let stdout = MemoryOutputSink()
    return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
}

func contactsPayload(_ stdout: MemoryOutputSink) throws -> [String: Any] {
    let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
    return try #require(root["data"] as? [String: Any])
}

func contactsEnvelope(_ stdout: MemoryOutputSink) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
}

func contactsErrorPayload(_ stdout: MemoryOutputSink) throws -> [String: Any] {
    let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
    return try #require(root["error"] as? [String: Any])
}

/// Run a command that must SUCCEED and return the emitted `data` object.
func runContacts(_ body: () throws -> Void) throws -> [String: Any] {
    try pinnedGates {
        let (streams, stdout) = contactsStreams()
        try Output.withStreams(streams) { try body() }
        return try contactsPayload(stdout)
    }
}

/// Run a command that must SUCCEED and return the whole envelope (for `sandbox` / `ok` keys).
func runContactsEnvelope(_ body: () throws -> Void) throws -> [String: Any] {
    try pinnedGates {
        let (streams, stdout) = contactsStreams()
        try Output.withStreams(streams) { try body() }
        return try contactsEnvelope(stdout)
    }
}

/// Run a command that must FAIL, and pin BOTH halves of the contract `runGuarded` binds
/// atomically: the exact process exit value AND the emitted `error.type`. `#expect(throws:
/// ExitCode.self)` alone passes for any failure whatsoever, so a branch that started throwing
/// `.notFound` where it owes `.validation` (65 vs 64 — a discriminator agents branch on) would
/// stay green. Asserting the pair is the exit-code matrix.
@discardableResult
func expectContactsFailure(exit: Int32, type: String,
                           sourceLocation: SourceLocation = SourceLocation(
                            fileID: #fileID, filePath: #filePath, line: #line, column: #column),
                           _ body: () throws -> Void) throws -> [String: Any] {
    let (streams, stdout) = contactsStreams()
    var thrown: Error?
    pinnedGates {
        do { try Output.withStreams(streams) { try body() } } catch { thrown = error }
    }
    #expect((thrown as? ExitCode)?.rawValue == exit,
            "expected exit \(exit), got \(String(describing: thrown))",
            sourceLocation: sourceLocation)
    let payload = try contactsErrorPayload(stdout)
    #expect(payload["type"] as? String == type, sourceLocation: sourceLocation)
    return payload
}

/// One finite callback thread, already waiting for work before the authorization deadline starts.
/// No timer or dispatch-pool capacity determines when the callback may run. A held worker is
/// released explicitly by the late-completion test after the real authorization call times out.
final class ContactsCompletionWorker {
    struct Snapshot {
        let submissions: Int
        let completions: Int
        let callerThread: UInt64
        let callbackThread: UInt64
        let failure: String?
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var ready = false
        var released: Bool
        var cancelled = false
        var finished = false
        var job: (@Sendable () -> Void)?
        var submissions = 0
        var completions = 0
        var callerThread: UInt64 = 0
        var callbackThread: UInt64 = 0
        var failure: String?

        init(held: Bool) { released = !held }

        static func threadID() -> UInt64 {
            var value: UInt64 = 0
            guard pthread_threadid_np(nil, &value) == 0 else { return 0 }
            return value
        }

        func run() {
            condition.lock()
            ready = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(10)
            while !cancelled && (job == nil || !released) {
                if !condition.wait(until: deadline) {
                    failure = "callback job was not released before the fixture deadline"
                    cancelled = true
                }
            }
            guard !cancelled, let callback = job else {
                job = nil
                finished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            job = nil
            callbackThread = Self.threadID()
            condition.unlock()
            callback()
            condition.lock()
            completions += 1
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func wait(until predicate: () -> Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                if finished { return false }
                if !condition.wait(until: deadline) { return predicate() }
            }
            return true
        }
    }

    private let state: State
    private let thread: Thread

    init(held: Bool = false) {
        let state = State(held: held)
        self.state = state
        thread = Thread { state.run() }
        thread.name = "apple-cli-test.contacts.completion"
        thread.start()
    }

    func waitUntilReady() -> Bool { state.wait { state.ready } }
    func waitUntilCompleted() -> Bool { state.wait { state.completions == 1 } }

    func submit(_ callback: @escaping @Sendable () -> Void) {
        state.condition.lock()
        defer { state.condition.unlock() }
        state.submissions += 1
        guard state.submissions == 1, !state.cancelled, !state.finished else {
            state.failure = "completion worker received an unexpected request"
            return
        }
        state.callerThread = State.threadID()
        state.job = callback
        state.condition.broadcast()
    }

    func release() {
        state.condition.lock()
        state.released = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    var snapshot: Snapshot {
        state.condition.lock()
        defer { state.condition.unlock() }
        return Snapshot(submissions: state.submissions, completions: state.completions,
                        callerThread: state.callerThread, callbackThread: state.callbackThread,
                        failure: state.failure)
    }

    /// Cancel an unsubmitted/held job and observe actual Thread completion. Call from test defer,
    /// including failed readiness/assertion paths; no callback worker is intentionally abandoned.
    func finish() -> Bool {
        state.condition.lock()
        state.cancelled = true
        state.condition.broadcast()
        state.condition.unlock()
        let deadline = Date().addingTimeInterval(10)
        while !thread.isFinished && Date() < deadline { usleep(1_000) }
        return thread.isFinished
    }
}
