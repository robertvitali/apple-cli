import Testing
import Foundation
import EventKit
import AppleKit
@testable import EventKitCore

// Logic-tier tests for the shared EventKit engine. These are TCC-free, not EventKit-free: the
// honest invariant is that an `EKEventStore` is constructed ONLY as an inert object factory for
// `EKEvent` / `EKReminder` / `EKCalendar` (see `FakeEventKitBackend.store` below), and that
// access/fetch/save/remove/commit is NEVER called on it — every such call routes through a fake.
// Construction alone neither prompts nor reads TCC. EKRecurrenceRule, EKAlarm, and
// EKStructuredLocation are plain value objects, so the EK⇄model round-trips need no permission.
//
//     PATH="$HOME/.swiftly/bin:$PATH" swift test

// MARK: - Date parsing + all-day inference

@Suite("DateParsing")
struct DateParsingTests {
    @Test("bare yyyy-MM-dd is recognized as date-only")
    func bareDate() {
        #expect(DateParsing.isBareDate("2026-07-15"))
        #expect(!DateParsing.isBareDate("2026-07-15 10:00:00"))
        #expect(!DateParsing.isBareDate("2026-7-5"))
        #expect(!DateParsing.isBareDate("2026-07-15T10:00"))
        #expect(!DateParsing.isBareDate(""))
    }

    @Test("parse infers all-day for a bare date, timed for the rest")
    func parseInference() throws {
        #expect(try DateParsing.parse("2026-07-15").isDateOnly)
        #expect(try !DateParsing.parse("2026-07-15 09:30:00").isDateOnly)
        #expect(try !DateParsing.parse("2026-07-15T09:30:00").isDateOnly)
        #expect(try !DateParsing.parse("2026-07-15T09:30:00Z").isDateOnly)
    }

    @Test("ISO-8601 with Z parses to the correct instant")
    func isoInstant() throws {
        let parsed = try DateParsing.parse("2026-07-15T12:00:00Z")
        let expected = Date(timeIntervalSince1970: 1_784_116_800)
        #expect(abs(parsed.date.timeIntervalSince1970 - expected.timeIntervalSince1970) < 1.0)
    }

    /// CAL-02: the oracle anchors a bare `yyyy-MM-dd` at MIDNIGHT in the parse zone (its
    /// `DateFormatter` default); we used to lift to noon, a 12-hour divergence on every bare
    /// create/update date and recurrence end. Pinned as an exact instant in UTC so a re-anchor
    /// (noon, end-of-day, anything) goes red.
    @Test("bare date anchors at midnight in the parse zone, matching the oracle")
    func bareDateAnchorsAtMidnight() throws {
        let utc = TimeZone(identifier: "UTC")!
        let parsed = try DateParsing.parse("2026-07-15", timeZone: utc)
        #expect(parsed.date == Date(timeIntervalSince1970: 1_784_073_600),  // 2026-07-15T00:00:00Z
                "bare date must resolve to midnight, got \(parsed.date)")
        // And in a non-UTC zone the instant shifts by exactly the zone offset (still local 00:00).
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!   // UTC+9, no DST
        let jst = try DateParsing.parse("2026-07-15", timeZone: tokyo)
        #expect(jst.date == Date(timeIntervalSince1970: 1_784_073_600 - 9 * 3600))
    }

    @Test("unrecognized input throws")
    func unrecognized() {
        #expect(throws: DateParsing.ParseError.self) { _ = try DateParsing.parse("not-a-date") }
    }

    /// PARTIAL REVERSAL, recorded and MEASURED (not reasoned): the old test assumed the oracle
    /// rejects every impossible date. Executing the oracle's own formatters showed the split —
    /// a month out of 1…12 IS rejected ("2026-13-45" fails both engines), but a day past the
    /// month's end ROLLS OVER (Feb 30 → Mar 2), because a non-lenient DateFormatter
    /// bounds-checks the month yet rolls the day. Strict superset + this repo's doctrine
    /// (reject only where the MCP also rejects) means we match both halves, typo risk and all.
    @Test("impossible dates: month 13 rejects, Feb 30 rolls to Mar 2 — the oracle's exact split")
    func impossibleDatesOracleSplit() throws {
        let utc = TimeZone(identifier: "UTC")!
        #expect(throws: DateParsing.ParseError.self) { _ = try DateParsing.parse("2026-13-45") }
        let rolled = try DateParsing.parse("2026-02-30 10:00:00", timeZone: utc)
        #expect(DateParsing.bareDateString(rolled.date, timeZone: utc) == "2026-03-02")
        // Genuine garbage still throws (our documented stricter divergence — the oracle would
        // silently null the date instead).
        #expect(throws: DateParsing.ParseError.self) { _ = try DateParsing.parse("garbage") }
    }

    @Test("bareDateString round-trips a parsed bare date in UTC")
    func bareRoundTrip() throws {
        let utc = TimeZone(identifier: "UTC")!
        let parsed = try DateParsing.parse("2026-07-15", timeZone: utc)
        #expect(DateParsing.bareDateString(parsed.date, timeZone: utc) == "2026-07-15")
    }

}

/// Carries a non-Sendable EventKit payload into the background queue the asynchronous fetch
/// fake calls back on. Exactly one writer (construction) then one reader — never concurrent.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class FakeEventKitBackend: EventKitStoreBackend {
    /// INERT OBJECT FACTORY ONLY. `EKEvent(eventStore:)` / `EKReminder(eventStore:)` /
    /// `EKCalendar(for:eventStore:)` all require a store instance and there is no in-memory
    /// substitute, so one is constructed here — but no access/fetch/save/remove/commit is ever
    /// issued against it. Construction neither prompts nor reads TCC.
    let store = EKEventStore()
    /// nil → call the fetch completion synchronously on the caller's thread (the default).
    /// Non-nil → complete asynchronously on that queue, like the real EventKit fetch.
    var fetchCompletionQueue: DispatchQueue?
    /// Same knob for the ACCESS-request bridge. That bridge's `sem.wait()` is deliberately
    /// unbounded (it waits on the system dialog), so a signalling-order mistake there deadlocks
    /// the CLI rather than timing out — it is the bridge that most needs cross-thread coverage.
    var promptCompletionQueue: DispatchQueue?
    var status: EventStore.AuthStatus = .fullAccess
    var statusAfterPrompt: EventStore.AuthStatus?
    var promptResult: (Bool, Error?) = (true, nil)
    var promptEntities: [EventStore.Entity] = []
    var calendarsByEntity: [EventStore.Entity: [EKCalendar]] = [:]
    var calendarsById: [String: EKCalendar] = [:]
    var sources: [EKSource] = []
    var defaultCalendarForNewEvents: EKCalendar?
    var defaultReminderList: EKCalendar?
    var eventRows: [EKEvent] = []
    var eventsById: [String: EKEvent] = [:]
    var remindersById: [String: EKReminder] = [:]
    var reminderRows: [EKReminder]? = []
    var savedEvents: [(EKEvent, EKSpan, Bool)] = []
    var removedEvents: [(EKEvent, EKSpan, Bool)] = []
    var savedReminders: [(EKReminder, Bool)] = []
    var removedReminders: [(EKReminder, Bool)] = []
    var savedCalendars: [(EKCalendar, Bool)] = []
    var removedCalendars: [(EKCalendar, Bool)] = []
    var committed = false
    var thrownError: Error?

    func authorizationStatus(for entity: EventStore.Entity) -> EventStore.AuthStatus {
        if let statusAfterPrompt, promptEntities.contains(entity) { return statusAfterPrompt }
        return status
    }

    func requestFullAccessToEvents(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        promptEntities.append(.event)
        deliverPrompt(completion)
    }

    func requestFullAccessToReminders(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        promptEntities.append(.reminder)
        deliverPrompt(completion)
    }

    /// Real EventKit answers the access prompt on its own queue, well after the call returns.
    /// With `promptCompletionQueue` set this reproduces that, so `EventStore.requestFullAccess`'s
    /// `Box` + semaphore pair is genuinely crossed rather than re-entered synchronously.
    private func deliverPrompt(_ completion: @escaping @Sendable (Bool, Error?) -> Void) {
        let result = UncheckedBox(promptResult)
        guard let queue = promptCompletionQueue else {
            completion(result.value.0, result.value.1)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
            completion(result.value.0, result.value.1)
        }
    }

    func calendars(for entity: EventStore.Entity) -> [EKCalendar] {
        calendarsByEntity[entity] ?? []
    }

    func calendar(withIdentifier id: String) -> EKCalendar? {
        calendarsById[id]
    }

    func defaultCalendarForNewReminders() -> EKCalendar? {
        defaultReminderList
    }

    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate {
        NSPredicate(value: true)
    }

    func events(matching predicate: NSPredicate) -> [EKEvent] {
        eventRows
    }

    func event(withIdentifier id: String) -> EKEvent? {
        eventsById[id]
    }

    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        if let thrownError { throw thrownError }
        savedEvents.append((event, span, commit))
    }

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        if let thrownError { throw thrownError }
        removedEvents.append((event, span, commit))
    }

    func calendarItem(withIdentifier id: String) -> EKCalendarItem? {
        remindersById[id]
    }

    func fetchReminders(matching predicate: NSPredicate, completion: @escaping @Sendable ([EKReminder]?) -> Void) {
        let rows = UncheckedBox(reminderRows)
        guard let queue = fetchCompletionQueue else {
            completion(rows.value)
            return
        }
        // EventKit is free to call back on its own queue; this reproduces that so the
        // `Box` + semaphore bridge in `EventStore.reminders(matching:)` is exercised
        // across threads rather than re-entered synchronously.
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { completion(rows.value) }
    }

    /// Identity-checkable: the wrapper must hand back THIS instance, and record the lists it was
    /// asked about, so delegation is proved by identity rather than by the fake's own constant.
    let reminderPredicate = NSPredicate(format: "SELF == nil")
    var reminderPredicateLists: [[EKCalendar]?] = []

    func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate {
        reminderPredicateLists.append(lists)
        return reminderPredicate
    }

    func save(_ reminder: EKReminder, commit: Bool) throws {
        if let thrownError { throw thrownError }
        savedReminders.append((reminder, commit))
    }

    func remove(_ reminder: EKReminder, commit: Bool) throws {
        if let thrownError { throw thrownError }
        removedReminders.append((reminder, commit))
    }

    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        if let thrownError { throw thrownError }
        savedCalendars.append((calendar, commit))
    }

    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        if let thrownError { throw thrownError }
        removedCalendars.append((calendar, commit))
    }

    func commit() throws {
        if let thrownError { throw thrownError }
        committed = true
    }
}

@Suite("EventStore backend seam")
struct EventStoreBackendTests {
    func calendar(_ title: String, entity: EKEntityType, store: EKEventStore) -> EKCalendar {
        let calendar = EKCalendar(for: entity, eventStore: store)
        calendar.title = title
        return calendar
    }

    func event(_ title: String, start: TimeInterval, store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSince1970: start)
        event.endDate = Date(timeIntervalSince1970: start + 3_600)
        return event
    }

    func reminder(_ title: String, store: EKEventStore) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        return reminder
    }

    @Test("requestAccess accepts existing full and event write-only grants")
    func requestAccessExistingGrant() throws {
        let full = FakeEventKitBackend()
        try EventStore(backend: full).requestAccess(to: .reminder, mode: .read)
        #expect(full.promptEntities.isEmpty)

        let writeOnly = FakeEventKitBackend()
        writeOnly.status = .writeOnly
        try EventStore(backend: writeOnly).requestAccess(to: .event, mode: .write)
        #expect(writeOnly.promptEntities.isEmpty)
        #expect(throws: AppleError.self) {
            try EventStore(backend: writeOnly).requestAccess(to: .event, mode: .read)
        }
    }

    @Test("requestAccess prompts notDetermined and maps denial or prompt errors")
    func requestAccessPromptOutcomes() throws {
        let granted = FakeEventKitBackend()
        granted.status = .notDetermined
        granted.statusAfterPrompt = .fullAccess
        try EventStore(backend: granted).requestAccess(to: .event, mode: .read)
        #expect(granted.promptEntities == [.event])

        let deniedAfterPrompt = FakeEventKitBackend()
        deniedAfterPrompt.status = .notDetermined
        deniedAfterPrompt.statusAfterPrompt = .denied
        #expect(throws: AppleError.self) {
            try EventStore(backend: deniedAfterPrompt).requestAccess(to: .reminder, mode: .read)
        }

        let promptError = FakeEventKitBackend()
        promptError.status = .notDetermined
        promptError.promptResult = (false, NSError(domain: "synthetic", code: 1))
        #expect(throws: AppleError.self) {
            try EventStore(backend: promptError).requestAccess(to: .event, mode: .read)
        }

        let denied = FakeEventKitBackend()
        denied.status = .denied
        #expect(throws: AppleError.self) {
            try EventStore(backend: denied).requestAccess(to: .event, mode: .read)
        }

        let restricted = FakeEventKitBackend()
        restricted.status = .restricted
        #expect(throws: AppleError.self) {
            try EventStore(backend: restricted).requestAccess(to: .reminder, mode: .read)
        }
    }

    @Test("calendar lookup rejects wrong entity ids and falls back to case-insensitive title")
    func calendarMatching() throws {
        let fake = FakeEventKitBackend()
        let events = calendar("apple-cli-test Events", entity: .event, store: fake.store)
        let reminders = calendar("apple-cli-test Reminders", entity: .reminder, store: fake.store)
        fake.calendarsByEntity = [.event: [events], .reminder: [reminders]]
        fake.calendarsById = ["event-id": events, "reminder-id": reminders]
        let store = EventStore(backend: fake)

        #expect(store.calendar(matching: "APPLE-CLI-TEST EVENTS", entity: .event) === events)
        #expect(store.calendar(matching: "reminder-id", entity: .event) == nil)
    }

    @Test("events are fetched through the backend and sorted by start date")
    func eventsSorted() {
        let fake = FakeEventKitBackend()
        fake.eventRows = [
            event("apple-cli-test later", start: 200, store: fake.store),
            event("apple-cli-test earlier", start: 100, store: fake.store),
        ]

        let rows = EventStore(backend: fake).events(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 300),
            calendars: nil)

        #expect(rows.map(\.title) == ["apple-cli-test earlier", "apple-cli-test later"])
    }

    /// The other half of that sort: its key coalesces a missing `startDate` to `.distantPast`.
    /// EventKit really can hand back an event with no start date, and `eventsSorted` above never
    /// supplies one — so the `?? .distantPast` branch was unexecuted, and changing it (to
    /// `.distantFuture`, or to a force-unwrap) stayed green. This pins that such a row sorts
    /// FIRST and, more importantly, that the comparator survives it at all.
    @Test("an event with no start date sorts first through the distantPast coalescing")
    func eventsSortedWithMissingStartDate() {
        let fake = FakeEventKitBackend()
        let undated = EKEvent(eventStore: fake.store)
        undated.title = "apple-cli-test undated"
        // Precondition: a freshly-constructed EKEvent really does report a nil start date, so a
        // failure below is the comparator and not a fixture that quietly acquired one.
        #expect(undated.startDate == nil)

        fake.eventRows = [
            event("apple-cli-test later", start: 200, store: fake.store),
            undated,
            event("apple-cli-test earlier", start: 100, store: fake.store),
        ]

        let rows = EventStore(backend: fake).events(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 300),
            calendars: nil)

        #expect(rows.map(\.title) == ["apple-cli-test undated",
                                      "apple-cli-test earlier",
                                      "apple-cli-test later"])
    }

    @Test("reminder fetch bridges nil callback rows to an empty array")
    func remindersNilCallbackIsEmpty() throws {
        let fake = FakeEventKitBackend()
        fake.reminderRows = nil
        let rows = try EventStore(backend: fake).reminders(matching: NSPredicate(value: true))
        #expect(rows.isEmpty)
    }

    @Test("mutators delegate commit flags and map backend errors")
    func mutatorsDelegateAndMapErrors() throws {
        let fake = FakeEventKitBackend()
        let store = EventStore(backend: fake)
        let event = event("apple-cli-test event", start: 100, store: fake.store)
        let reminder = reminder("apple-cli-test reminder", store: fake.store)
        let list = calendar("apple-cli-test list", entity: .reminder, store: fake.store)

        try store.save(event, span: .futureEvents, commit: false)
        try store.remove(event, span: .thisEvent, commit: false)
        try store.save(reminder, commit: false)
        try store.remove(reminder, commit: false)
        try store.saveCalendar(list, commit: false)
        try store.removeCalendar(list, commit: false)
        try store.commit()

        #expect(fake.savedEvents.first?.1 == .futureEvents)
        #expect(fake.savedEvents.first?.2 == false)
        #expect(fake.removedEvents.first?.2 == false)
        #expect(fake.savedReminders.first?.1 == false)
        #expect(fake.removedReminders.first?.1 == false)
        #expect(fake.savedCalendars.first?.1 == false)
        #expect(fake.removedCalendars.first?.1 == false)
        #expect(fake.committed)

        fake.thrownError = NSError(domain: "synthetic", code: 2)
        #expect(throws: AppleError.self) {
            try store.save(event, span: .thisEvent, commit: true)
        }
    }

    /// EVERY `catch { throw Self.mapError(error) }` arm on the wrapper, one case per arm, each
    /// asserting the MAPPED type + exit code rather than merely that something was thrown.
    ///
    /// `mutatorsDelegateAndMapErrors` above covers exactly one of the seven, and only with
    /// `#expect(throws: AppleError.self)` — which cannot distinguish a mapped error from a raw
    /// rethrow, and says nothing about the other six. Deleting any single `catch` line hands the
    /// bare `NSError`/`EKError` to `runGuarded`, which has no contractual type or exit code for
    /// it; that is the defect this pins, per arm.
    ///
    /// Three error kinds per arm, deliberately: a bad-input `EKError` (→ validation / 64), an
    /// `EKError` the mapper treats as an authorization failure (→ authorization_denied / 77), and
    /// an unrelated `NSError` (→ upstream / 69). Any one alone would still pass an arm that threw a
    /// hardcoded error; the SET is what proves the backend's value actually flows through
    /// `mapError` — and the 77 case is the one an operator acts on differently from the other two
    /// (grant TCC, not fix the input), so an arm that flattened it would misroute a real user.
    /// `MapErrorTests` covers the classification itself — this covers the wiring.
    @Test("every mutator arm maps a backend error through mapError rather than rethrowing it raw",
          arguments: ["save event", "remove event", "save reminder", "remove reminder",
                      "saveCalendar", "removeCalendar", "commit"])
    func mutatorArmsMapBackendErrors(arm: String) throws {
        let cases: [(Error, String, Int32)] = [
            (EKError(_nsError: NSError(domain: EKErrorDomain,
                                       code: EKError.Code.eventNotMutable.rawValue)),
             AppleErrorType.validation, AppleExit.usage),
            (EKError(_nsError: NSError(domain: EKErrorDomain,
                                       code: EKError.Code.eventStoreNotAuthorized.rawValue)),
             AppleErrorType.permissionDenied, AppleExit.permissionDenied),
            (NSError(domain: "apple-cli-test.synthetic", code: 7),
             AppleErrorType.upstream, AppleExit.upstream),
        ]

        for (backendError, expectedType, expectedExit) in cases {
            let fake = FakeEventKitBackend()
            fake.thrownError = backendError
            let store = EventStore(backend: fake)
            let event = event("apple-cli-test event", start: 100, store: fake.store)
            let reminder = reminder("apple-cli-test reminder", store: fake.store)
            let list = calendar("apple-cli-test list", entity: .reminder, store: fake.store)

            let call: () throws -> Void
            switch arm {
            case "save event":      call = { try store.save(event, span: .thisEvent, commit: true) }
            case "remove event":    call = { try store.remove(event, span: .thisEvent, commit: true) }
            case "save reminder":   call = { try store.save(reminder, commit: true) }
            case "remove reminder": call = { try store.remove(reminder, commit: true) }
            case "saveCalendar":    call = { try store.saveCalendar(list, commit: true) }
            case "removeCalendar":  call = { try store.removeCalendar(list, commit: true) }
            case "commit":          call = { try store.commit() }
            default:
                // A `default:` that ran `commit()` silently re-tested the commit arm for any
                // typo'd or newly-added argument, so an arm could be renamed in the `arguments:`
                // list above and still report seven green cases while its real call site went
                // untested. Fail loudly instead.
                Issue.record("unhandled arm '\(arm)' — add it to the switch or fix the arguments list")
                return
            }

            var thrown: Error?
            do { try call() } catch { thrown = error }
            let mapped = try #require(
                thrown as? AppleError,
                "\(arm): expected a mapped AppleError, got \(String(describing: thrown))")
            #expect(mapped.type == expectedType, "\(arm) (\(expectedType))")
            #expect(mapped.exitCode == expectedExit, "\(arm) (\(expectedExit))")
        }
    }

    @Test("event, reminder, and calendar constructors remain bound to the live EK store")
    func constructorsAndLookups() throws {
        let fake = FakeEventKitBackend()
        let events = calendar("apple-cli-test events", entity: .event, store: fake.store)
        let reminders = calendar("apple-cli-test reminders", entity: .reminder, store: fake.store)
        let reminder = reminder("apple-cli-test reminder", store: fake.store)
        fake.defaultCalendarForNewEvents = events
        fake.defaultReminderList = reminders
        fake.eventsById = ["event-1": event("apple-cli-test event", start: 100, store: fake.store)]
        fake.remindersById = ["reminder-1": reminder]
        let store = EventStore(backend: fake)

        #expect(store.defaultCalendarForEvents === events)
        #expect(store.defaultCalendarForReminders === reminders)
        #expect(store.event(withIdentifier: "event-1")?.title == "apple-cli-test event")
        #expect(store.reminder(withIdentifier: "reminder-1") === reminder)
        #expect(store.newEvent().title == "")
        #expect(store.newReminder(in: reminders).calendar === reminders)
        #expect(store.newCalendar(for: .event) == nil)
    }

    @Test("direct wrapper lookups delegate to the backend")
    func directWrapperLookups() throws {
        let fake = FakeEventKitBackend()
        let events = calendar("apple-cli-test events", entity: .event, store: fake.store)
        let reminders = calendar("apple-cli-test reminders", entity: .reminder, store: fake.store)
        let reminder = reminder("apple-cli-test reminder", store: fake.store)
        fake.calendarsByEntity = [.event: [events], .reminder: [reminders]]
        fake.calendarsById = ["calendar-1": events]
        fake.reminderRows = [reminder]

        let store = EventStore(backend: fake)
        #expect(store.calendars(for: .event).first === events)
        #expect(store.calendar(withIdentifier: "calendar-1") === events)
        #expect(store.preferredSource(for: .event) == nil)
        // Identity, not the fake's own constant: the wrapper must hand back the backend's
        // predicate object and forward the list argument verbatim.
        #expect(store.predicateForReminders(in: [reminders]) === fake.reminderPredicate)
        #expect(fake.reminderPredicateLists.count == 1)
        #expect(fake.reminderPredicateLists.first??.first === reminders)
        #expect(try store.reminders(matching: NSPredicate(value: true)).first === reminder)
    }

    @Test("calendar lookup returns the identifier hit when the entity type matches")
    func calendarMatchingByIdentifier() {
        let fake = FakeEventKitBackend()
        let events = calendar("apple-cli-test events", entity: .event, store: fake.store)
        let reminders = calendar("apple-cli-test reminders", entity: .reminder, store: fake.store)
        fake.calendarsById = ["event-id": events, "reminder-id": reminders]
        // Deliberately EMPTY, so a title fallback cannot rescue the lookup: only the
        // identifier branch can return a calendar here.
        fake.calendarsByEntity = [:]
        let store = EventStore(backend: fake)

        #expect(store.calendar(matching: "event-id", entity: .event) === events)
        #expect(store.calendar(matching: "reminder-id", entity: .reminder) === reminders)
        // Right id, wrong entity — rejected rather than silently returned.
        #expect(store.calendar(matching: "reminder-id", entity: .event) == nil)
        #expect(store.calendar(matching: "event-id", entity: .reminder) == nil)
    }

    @Test("newCalendar binds a writable source, and returns nil when none exists")
    func newCalendarSourceResolution() {
        let sourceless = FakeEventKitBackend()
        #expect(EventStore(backend: sourceless).newCalendar(for: .reminder) == nil)

        let withSource = FakeEventKitBackend()
        let source = EKSource()
        withSource.sources = [source]
        let created = EventStore(backend: withSource).newCalendar(for: .reminder)
        #expect(created != nil)
        #expect(created?.source === source)
        #expect(created?.allowedEntityTypes.contains(.reminder) == true)
    }

    @Test("an EKError code outside the validation set maps to upstream, not validation")
    func unmappedEKErrorIsUpstream() {
        // `internalFailure` is deliberately absent from `mapError`'s bad-input list, so it must
        // fall through to `.upstream` (exit 69) rather than `.validation` (exit 64).
        let internalFailure = EKError(_nsError: NSError(domain: EKErrorDomain,
                                                        code: EKError.Code.internalFailure.rawValue))
        let mapped = EventStore.mapError(internalFailure)
        #expect(mapped.type == AppleErrorType.upstream)
        #expect(mapped.exitCode == AppleExit.upstream)

        // A code that IS in the list stays validation — the two branches must not collapse.
        let notMutable = EKError(_nsError: NSError(domain: EKErrorDomain,
                                                   code: EKError.Code.eventNotMutable.rawValue))
        #expect(EventStore.mapError(notMutable).type == AppleErrorType.validation)
        #expect(EventStore.mapError(notMutable).exitCode == AppleExit.usage)

        // Authorization failures keep their own type + exit 77.
        let unauthorized = EKError(_nsError: NSError(domain: EKErrorDomain,
                                                     code: EKError.Code.eventStoreNotAuthorized.rawValue))
        #expect(EventStore.mapError(unauthorized).type == AppleErrorType.permissionDenied)
        #expect(EventStore.mapError(unauthorized).exitCode == AppleExit.permissionDenied)

        // An AppleError thrown by a mapper passes through untouched.
        #expect(EventStore.mapError(AppleError.validation("synthetic")).type == AppleErrorType.validation)
    }

    @Test("the access-request bridge returns grant, denial, and prompt errors delivered off-thread")
    func asyncAuthorizationCrossesTheSemaphoreBridge() throws {
        let queue = DispatchQueue(label: "apple-cli-test.prompt")

        // Grant: notDetermined → prompt answered on another thread → fullAccess.
        let granted = FakeEventKitBackend()
        granted.status = .notDetermined
        granted.statusAfterPrompt = .fullAccess
        granted.promptCompletionQueue = queue
        try EventStore(backend: granted).requestAccess(to: .event, mode: .read)
        #expect(granted.promptEntities == [.event])

        // Denial: the prompt completes (off-thread) with granted == false.
        let denied = FakeEventKitBackend()
        denied.status = .notDetermined
        denied.statusAfterPrompt = .denied
        denied.promptResult = (false, nil)
        denied.promptCompletionQueue = queue
        #expect(throws: AppleError.self) {
            try EventStore(backend: denied).requestAccess(to: .reminder, mode: .read)
        }
        #expect(denied.promptEntities == [.reminder])

        // Prompt error: the handler carries an Error across the bridge, which must surface as
        // permissionDenied (exit 77) rather than being lost with the crossing.
        let failed = FakeEventKitBackend()
        failed.status = .notDetermined
        failed.promptResult = (false, NSError(domain: "synthetic", code: 1))
        failed.promptCompletionQueue = queue
        var thrown: AppleError?
        #expect(throws: AppleError.self) {
            do { try EventStore(backend: failed).requestAccess(to: .event, mode: .write) }
            catch let error as AppleError { thrown = error; throw error }
        }
        #expect(thrown?.exitCode == AppleExit.permissionDenied)
        #expect(thrown?.message.contains("EventKit access request failed") == true)
    }

    @Test("the reminder fetch bridge returns rows delivered on another thread")
    func asyncFetchCrossesTheSemaphoreBridge() throws {
        // `EventKitCore.makeStore()` / `EventStore()` are deliberately NOT exercised here: they
        // construct the live backend, which belongs to the live tier, not the logic tier.
        let fake = FakeEventKitBackend()
        let rows = [reminder("apple-cli-test one", store: fake.store),
                    reminder("apple-cli-test two", store: fake.store)]
        fake.reminderRows = rows
        fake.fetchCompletionQueue = DispatchQueue(label: "apple-cli-test.fetch")

        let store = EventStore(backend: fake)
        let fetched = try store.reminders(matching: NSPredicate(value: true))

        #expect(fetched.count == 2)
        #expect(fetched.map { $0.title } == ["apple-cli-test one", "apple-cli-test two"])
    }

    @Test("a nil reminder fetch result becomes an empty array")
    func asyncFetchNilBecomesEmpty() throws {
        let fake = FakeEventKitBackend()
        fake.reminderRows = nil
        fake.fetchCompletionQueue = DispatchQueue(label: "apple-cli-test.fetch-nil")

        let store = EventStore(backend: fake)
        #expect(try store.reminders(matching: NSPredicate(value: true)).isEmpty)
    }
}

// MARK: - Recurrence round-trips + validation

@Suite("RecurrenceMapping")
struct RecurrenceMappingTests {
    @Test("recurrence end_date encodes as the oracle's bare local yyyy-MM-dd (Q12 [13])")
    func recurrenceEndDateEncodesBareLocalDate() throws {
        // Noon UTC avoids date flips in any plausible test-runner zone.
        let end = Date(timeIntervalSince1970: 1_756_728_000)   // 2025-09-01T12:00:00Z
        let rule = RecurrenceRule(frequency: "daily", interval: 1, end_date: end)
        let json = try String(data: JSONEncoder().encode(rule), encoding: .utf8)!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        #expect(json.contains("\"end_date\":\"\(f.string(from: end))\""))
        // Non-tautological half (review L5): a POSIX-locale Gregorian literal — on any
        // machine whose default calendar is Gregorian these agree; the mirrored oracle
        // quirk (non-Gregorian device calendars render differently) is documented at the
        // formatter, not silently depended on here.
        // On a Gregorian device this instant is 2025-09-01 in every US-continental zone and
        // 2025-09-02 only east of UTC+12 — pin the LITERAL date (no formatter reuse) so a
        // local-vs-UTC or era regression is actually caught, guarding the common case.
        if Calendar.current.identifier == .gregorian,
           TimeZone.current.secondsFromGMT() > -12 * 3600, TimeZone.current.secondsFromGMT() < 12 * 3600 {
            #expect(json.contains("\"end_date\":\"2025-09-01\""))
        }
        #expect(!json.contains("T12:00"))          // never the ISO-UTC instant form
        // nil end_date omits the key entirely.
        let open = RecurrenceRule(frequency: "daily", interval: 1)
        let openJSON = try String(data: JSONEncoder().encode(open), encoding: .utf8)!
        #expect(!openJSON.contains("end_date"))
    }

    @Test("structured_location omits radius when <= 0, like the oracle (Q12 [14])")
    func structuredLocationOmitsNonPositiveRadius() throws {
        let zero = StructuredLocation(title: "HQ", latitude: 1, longitude: 2, radius: nil)
        let j0 = try String(data: JSONEncoder().encode(zero), encoding: .utf8)!
        #expect(!j0.contains("radius"))
        let pos = StructuredLocation(title: "HQ", latitude: 1, longitude: 2, radius: 50)
        let j1 = try String(data: JSONEncoder().encode(pos), encoding: .utf8)!
        #expect(j1.contains("\"radius\":50"))
    }

    @Test("weekly by-day rule round-trips model → EK → model")
    func weeklyByDay() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let model = RecurrenceRule(frequency: "weekly", interval: 2, end_date: end, days_of_week: [2, 4, 6])
        let ek = try RecurrenceMapping.ekRule(from: model)
        #expect(ek.frequency == .weekly)
        #expect(ek.interval == 2)
        #expect(Set(ek.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } ?? []) == [2, 4, 6])

        let back = RecurrenceMapping.rule(from: ek)
        #expect(back.frequency == "weekly")
        #expect(Set(back.days_of_week ?? []) == [2, 4, 6])
        #expect(back.end_date != nil)
        #expect(back.occurrence_count == nil)
    }

    @Test("occurrence count survives when it is the only end")
    func occurrenceCount() throws {
        let ek = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "monthly", interval: 1, occurrence_count: 5))
        let back = RecurrenceMapping.rule(from: ek)
        #expect(back.occurrence_count == 5)
        #expect(back.end_date == nil)
    }

    /// REM-06: the oracle checks endDate FIRST (`if let endDateStr … else if let count`,
    /// EventKitCLI.swift:283); the old mapper let occurrence_count win, silently inverting a
    /// spec that carried both.
    @Test("end_date wins over occurrence_count when a rule carries both")
    func endDatePrecedence() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let ek = try RecurrenceMapping.ekRule(from: RecurrenceRule(
            frequency: "daily", interval: 1, end_date: end, occurrence_count: 5))
        let back = RecurrenceMapping.rule(from: ek)
        #expect(back.end_date != nil, "end_date must win")
        #expect(back.occurrence_count == nil)
    }

    @Test("simple daily rule uses the plain initializer")
    func simpleDaily() throws {
        let ek = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "daily", interval: 3))
        #expect(ek.frequency == .daily)
        #expect(ek.interval == 3)
        #expect(RecurrenceMapping.rule(from: ek).days_of_week == nil)
    }

    @Test("days_of_month round-trips including negative-from-end")
    func daysOfMonth() throws {
        let model = RecurrenceRule(frequency: "monthly", interval: 1, days_of_month: [1, 15, -1])
        let ek = try RecurrenceMapping.ekRule(from: model)
        #expect(Set(ek.daysOfTheMonth?.map { $0.intValue } ?? []) == [1, 15, -1])
        #expect(Set(RecurrenceMapping.rule(from: ek).days_of_month ?? []) == [1, 15, -1])
    }

    @Test("set_positions round-trips (e.g. last weekday of month)")
    func setPositions() throws {
        let model = RecurrenceRule(frequency: "monthly", interval: 1, days_of_week: [2], set_positions: [-1])
        let ek = try RecurrenceMapping.ekRule(from: model)
        #expect(ek.setPositions?.map { $0.intValue } == [-1])
        #expect(RecurrenceMapping.rule(from: ek).set_positions == [-1])
    }

    @Test("yearly with months-of-year round-trips")
    func yearlyMonths() throws {
        let ek = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "yearly", interval: 1, months_of_year: [1, 6, 12]))
        #expect(Set(RecurrenceMapping.rule(from: ek).months_of_year ?? []) == [1, 6, 12])
    }

    @Test("unknown frequency throws a validation AppleError (exit 64)")
    func badFrequency() {
        #expect(throws: AppleError.self) {
            _ = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "hourly", interval: 1))
        }
    }

    @Test("out-of-range by-part values are REJECTED, not silently dropped")
    func rangeValidation() {
        // weekday 8 (valid 1-7) — the silent-corruption case the review flagged
        #expect(throws: AppleError.self) {
            _ = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "weekly", interval: 1, days_of_week: [8]))
        }
        #expect(throws: AppleError.self) {
            _ = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "monthly", interval: 1, days_of_month: [32]))
        }
        #expect(throws: AppleError.self) {
            _ = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "yearly", interval: 1, months_of_year: [13]))
        }
    }

    @Test("interval below 1 is rejected (not silently clamped)")
    func intervalRejected() {
        #expect(throws: AppleError.self) {
            _ = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "daily", interval: 0))
        }
    }
}

// MARK: - Alarm mapping

@Suite("AlarmMapping")
struct AlarmMappingTests {
    @Test("relative offset alarm round-trips")
    func relative() throws {
        let ek = try AlarmMapping.ekAlarm(from: Alarm(relative_offset: -1800))
        #expect(ek.relativeOffset == -1800)
        let back = AlarmMapping.alarm(from: ek, preferredTimeZone: .current)
        #expect(back.relative_offset == -1800)
        #expect(back.absolute_date == nil)
        #expect(back.location_trigger == nil)
    }

    /// The alarm's `absolute_date` is the SIXTH event-payload date site: the oracle renders it
    /// through the same `formatEventDate` as the event dates, in the ITEM's zone, always timed.
    /// Pinned as an exact string so a regression to UTC instants goes red.
    @Test("absolute date alarm round-trips and renders in the item's zone")
    func absolute() throws {
        let instant = Date(timeIntervalSince1970: 1_784_073_600)   // 2026-07-15T00:00:00Z
        let ek = try AlarmMapping.ekAlarm(from: Alarm(absoluteDateValue: instant))
        #expect(ek.absoluteDate == instant)
        let ny = TimeZone(identifier: "America/New_York")!
        let back = AlarmMapping.alarm(from: ek, preferredTimeZone: ny)
        #expect(back.absolute_date == "2026-07-14T20:00:00-04:00")
        #expect(back.relative_offset == nil)
    }

    @Test("geofence alarm maps title/coords/radius/proximity both ways")
    func geofence() throws {
        let trigger = LocationTrigger(title: "Office", latitude: 37.3349, longitude: -122.009, radius: 150, proximity: "enter")
        let ek = try AlarmMapping.ekAlarm(from: Alarm(location_trigger: trigger))
        #expect(ek.structuredLocation != nil)
        #expect(ek.proximity == .enter)

        let lt = try #require(AlarmMapping.alarm(from: ek, preferredTimeZone: .current).location_trigger)
        #expect(lt.title == "Office")
        #expect(lt.proximity == "enter")
        #expect(lt.radius == 150)
        #expect(abs((lt.latitude ?? 0) - 37.3349) < 1e-6)
        #expect(abs((lt.longitude ?? 0) + 122.009) < 1e-6)
    }

    /// Oracle `locationTriggerToJSON`: `title ?? "Location"` and `radius > 0 ? radius : 100` —
    /// note the 100 default here, DIFFERENT from the structured-location site's omit-when-0.
    @Test("titleless / radiusless alarm geofence gets the oracle's fallbacks")
    func geofenceFallbacks() throws {
        let ek = EKAlarm()
        let loc = EKStructuredLocation()
        loc.title = nil
        loc.geoLocation = CLLocation(latitude: 1, longitude: 2)
        loc.radius = 0
        ek.structuredLocation = loc
        let lt = try #require(AlarmMapping.alarm(from: ek, preferredTimeZone: .current).location_trigger)
        #expect(lt.title == "Location")
        #expect(lt.radius == 100)
    }

    @Test("an alarm with no trigger kind throws a validation AppleError")
    func emptyThrows() {
        #expect(throws: AppleError.self) { _ = try AlarmMapping.ekAlarm(from: Alarm()) }
    }
}

// MARK: - Enum + write-mapper helpers

@Suite("EKEnum")
struct EKEnumTests {
    @Test("availability round-trips through strings")
    func availability() {
        for s in ["busy", "free", "tentative", "unavailable"] {
            let ek = try! #require(EKEnum.availability(from: s))
            #expect(EKEnum.availabilityString(ek) == s)
        }
        #expect(EKEnum.availability(from: "bogus") == nil)
    }

    @Test("proximity matches the MCP write default (unknown → enter)")
    func proximity() {
        #expect(EKEnum.proximity(from: "enter") == .enter)
        #expect(EKEnum.proximity(from: "leave") == .leave)
        #expect(EKEnum.proximity(from: "depart") == .leave)   // MCP alias
        #expect(EKEnum.proximity(from: "exit") == .leave)     // MCP alias
        #expect(EKEnum.proximity(from: "whatever") == .enter) // MCP default
        #expect(EKEnum.proximityString(EKAlarmProximity.none) == "none")
    }

    @Test("frequency parses the four valid values and rejects others")
    func frequency() {
        for s in ["daily", "weekly", "monthly", "yearly"] {
            let f = try! #require(EKEnum.frequency(from: s))
            #expect(EKEnum.frequencyString(f) == s)
        }
        #expect(EKEnum.frequency(from: "fortnightly") == nil)
    }

    @Test("span maps the MCP strings")
    func span() {
        #expect(EKEnum.span(from: "this-event") == .thisEvent)
        #expect(EKEnum.span(from: "future-events") == .futureEvents)
        #expect(EKEnum.span(from: "all") == nil) // command-layer superset, not an EKSpan
    }

    @Test("priority word ↔ int follows the 0/1/5/9 convention")
    func priority() {
        #expect(EKEnum.priorityInt(from: "none") == 0)
        #expect(EKEnum.priorityInt(from: "high") == 1)
        #expect(EKEnum.priorityInt(from: "medium") == 5)
        #expect(EKEnum.priorityInt(from: "low") == 9)
        #expect(EKEnum.priorityInt(from: "7") == 7)
        #expect(EKEnum.priorityWord(from: 5) == "medium")
        #expect(EKEnum.priorityWord(from: 2) == "high")
        #expect(EKEnum.priorityWord(from: 0) == "none")
    }

    @Test("read-only participant, calendar, and source enums map every public case")
    func readOnlyEnumStrings() {
        #expect(EKEnum.participantStatusString(.unknown) == "unknown")
        #expect(EKEnum.participantStatusString(.pending) == "pending")
        #expect(EKEnum.participantStatusString(.accepted) == "accepted")
        #expect(EKEnum.participantStatusString(.declined) == "declined")
        #expect(EKEnum.participantStatusString(.tentative) == "tentative")
        #expect(EKEnum.participantStatusString(.delegated) == "delegated")
        #expect(EKEnum.participantStatusString(.completed) == "completed")
        #expect(EKEnum.participantStatusString(.inProcess) == "in-process")

        #expect(EKEnum.participantRoleString(.unknown) == "unknown")
        #expect(EKEnum.participantRoleString(.required) == "required")
        #expect(EKEnum.participantRoleString(.optional) == "optional")
        #expect(EKEnum.participantRoleString(.chair) == "chair")
        #expect(EKEnum.participantRoleString(.nonParticipant) == "non-participant")

        #expect(EKEnum.participantTypeString(.unknown) == "unknown")
        #expect(EKEnum.participantTypeString(.person) == "person")
        #expect(EKEnum.participantTypeString(.room) == "room")
        #expect(EKEnum.participantTypeString(.resource) == "resource")
        #expect(EKEnum.participantTypeString(.group) == "group")

        #expect(EKEnum.calendarTypeString(.local) == "local")
        #expect(EKEnum.calendarTypeString(.calDAV) == "caldav")
        #expect(EKEnum.calendarTypeString(.exchange) == "exchange")
        #expect(EKEnum.calendarTypeString(.subscription) == "subscription")
        #expect(EKEnum.calendarTypeString(.birthday) == "birthday")

        #expect(EKEnum.sourceTypeString(.local) == "local")
        #expect(EKEnum.sourceTypeString(.exchange) == "exchange")
        #expect(EKEnum.sourceTypeString(.calDAV) == "caldav")
        #expect(EKEnum.sourceTypeString(.mobileMe) == "mobileme")
        #expect(EKEnum.sourceTypeString(.subscribed) == "subscribed")
        #expect(EKEnum.sourceTypeString(.birthdays) == "birthdays")
    }
}

@Suite("Color + finite helpers")
struct ColorHelperTests {
    @Test("hex → CGColor → hex round-trips")
    func colorRoundTrip() throws {
        let cg = try #require(ReadMapping.cgColor(fromHex: "#FF8800"))
        #expect(ReadMapping.hexColor(from: cg) == "#FF8800")
        #expect(ReadMapping.cgColor(fromHex: "3399FF") != nil) // leading # optional
    }

    @Test("malformed hex returns nil")
    func badHex() {
        #expect(ReadMapping.cgColor(fromHex: "#FFF") == nil)   // must be 6 digits
        #expect(ReadMapping.cgColor(fromHex: "nothex") == nil)
        #expect(ReadMapping.cgColor(fromHex: "#GG0000") == nil)
    }

    @Test("grayscale CGColor maps through the two-component path")
    func grayscaleHex() {
        let gray = CGColor(gray: 0.5, alpha: 1)
        #expect(ReadMapping.hexColor(from: gray) == "#929292")
        #expect(ReadMapping.hexColor(from: nil) == nil)
    }

    @Test("non-finite doubles are coerced so encoding stays total")
    func nonFinite() {
        #expect(finite(Double.nan) == nil)
        #expect(finite(Double.infinity) == nil)
        #expect(finite(1.5) == 1.5)
    }
}

// MARK: - Error mapping classification (exit-code contract)

@Suite("EventStore.mapError")
struct MapErrorTests {
    @Test("an AppleError passes through unchanged")
    func passthrough() {
        #expect(EventStore.mapError(AppleError.notFound("x")).exitCode == AppleExit.notFound)
    }

    @Test("a bad-input EKError classifies as validation (exit 64)")
    func ekValidation() {
        let ek = NSError(domain: EKErrorDomain, code: EKError.Code.eventNotMutable.rawValue)
        #expect(EventStore.mapError(ek).exitCode == AppleExit.usage)
    }

    @Test("an auth EKError classifies as permission-denied (exit 77)")
    func ekAuth() {
        let ek = NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue)
        #expect(EventStore.mapError(ek).exitCode == AppleExit.permissionDenied)
    }

    @Test("an unrelated error classifies as upstream (exit 69)")
    func generic() {
        #expect(EventStore.mapError(NSError(domain: "z", code: 1)).exitCode == AppleExit.upstream)
    }
}

// MARK: - Oracle date pipeline goldens (REM-02/03/04)

/// Every row was produced by EXECUTING the oracle's own functions (copied verbatim into
/// `fixtures/oracle-dates/gen-goldens.swift.txt`, with only `TimeZone.current` replaced by a
/// fixed America/New_York so the goldens are machine-independent). The port must agree on
/// parse success, granularity (hour set), the pinned zone identifier, the resolved instant,
/// and both due-date renderings — for all 39 rows, including the 9 formats REM-03 named, the
/// detector's bare-date false-positive-then-fallthrough, DST edges, and the rollover rows.
@Suite("oracle date-pipeline goldens")
struct OracleDatesGoldenTests {
    struct Row: Codable {
        let input: String
        let parses: Bool
        let hour_set: Bool?
        let tz_identifier: String?
        let epoch: Double?
        let due_render: String?
        let due_render_hinted: String?
    }

    static var goldensURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/oracle-dates/goldens.json")
    }

    @Test("the port agrees with the oracle on every golden row")
    func goldens() throws {
        let fixed = TimeZone(identifier: "America/New_York")!
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: Self.goldensURL))
        #expect(rows.count == 39, "goldens should have 39 rows, found \(rows.count)")
        for row in rows {
            let comps = OracleDates.parseComponents(from: row.input, localZone: fixed)
            #expect((comps != nil) == row.parses, "\(row.input.debugDescription): parse mismatch")
            guard let comps, row.parses else { continue }
            #expect((comps.hour != nil) == row.hour_set, "\(row.input.debugDescription): granularity")
            #expect(comps.timeZone?.identifier == row.tz_identifier, "\(row.input.debugDescription): zone")
            let date = OracleDates.parseDate(from: row.input, localZone: fixed)
            #expect(date?.timeIntervalSince1970 == row.epoch, "\(row.input.debugDescription): instant")
            #expect(OracleDates.dueDateString(from: comps, timeZoneHint: nil, localZone: fixed)
                    == row.due_render, "\(row.input.debugDescription): due render")
            var stripped = comps
            stripped.timeZone = nil
            stripped.calendar = nil
            #expect(OracleDates.dueDateString(from: stripped,
                                              timeZoneHint: TimeZone(identifier: "Asia/Tokyo")!,
                                              localZone: fixed)
                    == row.due_render_hinted, "\(row.input.debugDescription): hinted render")
        }
    }
}

// MARK: - Geofence spec (shared Calendar/Reminders parser — CAL-04 / REM-05)

@Suite("GeofenceSpec")
struct GeofenceSpecTests {

    /// CAL-04's headline case: a street address IS a comma-bearing title, and the old parser
    /// kept only its LAST fragment.
    @Test("a comma-bearing title survives verbatim, spacing intact")
    func commaTitle() throws {
        let g = try GeofenceSpec.parse("40.0,-74.0,100,enter,742 Evergreen Terrace, Exampleton, ZZ 00000")
        #expect(g.radius == 100)
        #expect(g.proximity == "enter")
        #expect(g.title == "742 Evergreen Terrace, Exampleton, ZZ 00000")
    }

    @Test("radius and proximity are order-independent, each at most once")
    func orderIndependent() throws {
        let a = try GeofenceSpec.parse("37.3,-122.0,enter,250,Home")
        #expect(a.radius == 250 && a.proximity == "enter" && a.title == "Home")
        let b = try GeofenceSpec.parse("37.3,-122.0,150,leave,Home")
        #expect(b.radius == 150 && b.proximity == "leave" && b.title == "Home")
    }

    /// The old Reminders copy let ANY later numeric overwrite the radius, so "500" could never
    /// be a title; now a second numeric fragment starts the title.
    @Test("a numeric title is expressible after an explicit radius")
    func numericTitle() throws {
        let g = try GeofenceSpec.parse("40.0,-74.0,100,enter,500")
        #expect(g.radius == 100)
        #expect(g.title == "500")
    }

    @Test("defaults: radius 100, proximity enter, title nil; bare keyword/title slots work")
    func defaults() throws {
        let bare = try GeofenceSpec.parse("37.33,-122.03")
        #expect(bare.radius == 100 && bare.proximity == "enter" && bare.title == nil)
        #expect(try GeofenceSpec.parse("37.3,-122.0,leave").proximity == "leave")
        #expect(try GeofenceSpec.parse("1.0,2.0,Office").title == "Office")
        // trailing empty fragment is not a title
        #expect(try GeofenceSpec.parse("1.0,2.0,100,").title == nil)
        // empty fragments BEFORE the title are skipped (old-parser behavior kept)
        #expect(try GeofenceSpec.parse("1.0,2.0,,Home").title == "Home")
        #expect(try GeofenceSpec.parse("1.0,2.0,100,,Home").title == "Home")
    }

    /// Documented consequence of comma-bearing titles: once the title starts, a later keyword
    /// is part of it.
    @Test("a keyword after the title has started belongs to the title")
    func keywordInTitle() throws {
        let g = try GeofenceSpec.parse("40.0,-74.0,Home,leave")
        #expect(g.proximity == "enter")
        #expect(g.title == "Home,leave")
    }

    @Test("validation: lat/lon required + in range, radius finite and non-negative")
    func validation() {
        #expect(throws: GeofenceSpec.SpecError.self) { _ = try GeofenceSpec.parse("notanumber") }
        #expect(throws: GeofenceSpec.SpecError.self) { _ = try GeofenceSpec.parse("91,0") }
        #expect(throws: GeofenceSpec.SpecError.self) { _ = try GeofenceSpec.parse("0,181") }
        #expect(throws: GeofenceSpec.SpecError.self) { _ = try GeofenceSpec.parse("1,2,-5") }
        #expect(throws: GeofenceSpec.SpecError.self) { _ = try GeofenceSpec.parse("1,2,inf") }
    }
}

// MARK: - Structured-location read mapping (CAL-09)

@Suite("structured-location read mapping")
struct StructuredLocationMappingTests {
    /// CAL-09: the oracle GUARANTEES the `title` key (`structuredLocation.title ?? "Location"`
    /// onto a non-optional field); omitting it on a titleless location broke `if "title" in`.
    @Test("a titleless EKStructuredLocation maps with the oracle's \"Location\" fallback")
    func titleFallback() {
        let loc = EKStructuredLocation()
        loc.title = nil
        #expect(ReadMapping.structuredLocation(from: loc).title == "Location")
        let named = EKStructuredLocation(title: "HQ")
        #expect(ReadMapping.structuredLocation(from: named).title == "HQ")
    }

    /// Review H4: the radius omit-when-<=0 defect lived HERE (ReadMapping.structuredLocation),
    /// not in the DTO — the earlier pin built the DTO directly and could not catch a mapping
    /// revert (Double promotes to Double? implicitly, so `radius: finiteOrZero(...)` would
    /// re-compile and re-emit the spurious 0 with a green suite). Pin the mapping + the wire.
    @Test("read mapping omits radius when <= 0, matching the oracle (radius > 0 ? r : nil)")
    func mappingRadiusOmission() throws {
        let zero = EKStructuredLocation(title: "HQ")   // radius defaults to 0
        #expect(ReadMapping.structuredLocation(from: zero).radius == nil)
        let neg = EKStructuredLocation(title: "HQ"); neg.radius = -5
        #expect(ReadMapping.structuredLocation(from: neg).radius == nil)
        let pos = EKStructuredLocation(title: "HQ"); pos.radius = 42
        #expect(ReadMapping.structuredLocation(from: pos).radius == 42)
        let json = try String(data: JSONEncoder().encode(ReadMapping.structuredLocation(from: zero)), encoding: .utf8)!
        #expect(!json.contains("radius"))
    }

    /// The WRITE half of the same mapping (`events create/update --geo-*` builds its
    /// `EKStructuredLocation` through this). It was reachable only from the live-store path
    /// before the injected-store tests, so nothing pinned the nil-absorption: a nil title must
    /// become `""` (not crash the non-optional initializer), a coordinate pair must be set only
    /// when BOTH halves are present, and a nil radius must land as EventKit's own 0 sentinel —
    /// which `structuredLocation(from:)` then omits again on the way out.
    @Test("write mapping absorbs nil title/coords/radius into EventKit's own sentinels")
    func writeMappingAbsorbsNils() throws {
        let full = ReadMapping.ekStructuredLocation(from: StructuredLocation(
            title: "Office", latitude: 12.5, longitude: -34.25, radius: 150))
        #expect(full.title == "Office")
        #expect(full.radius == 150)
        let coordinate = try #require(full.geoLocation?.coordinate)
        #expect(abs(coordinate.latitude - 12.5) < 1e-9)
        #expect(abs(coordinate.longitude + 34.25) < 1e-9)

        let bare = ReadMapping.ekStructuredLocation(from: StructuredLocation(
            title: nil, latitude: nil, longitude: nil, radius: nil))
        #expect(bare.title == "")
        #expect(bare.geoLocation == nil)
        #expect(bare.radius == 0)
        // Round-trip: a radius-less write reads back with the key omitted (Q12 [14]).
        #expect(ReadMapping.structuredLocation(from: bare).radius == nil)

        // A half-supplied coordinate pair is NOT a location — latitude alone must not invent one.
        let halfCoord = ReadMapping.ekStructuredLocation(from: StructuredLocation(
            title: "Half", latitude: 1, longitude: nil, radius: 10))
        #expect(halfCoord.geoLocation == nil)
        #expect(halfCoord.radius == 10)
    }
}

// MARK: - Zone-pinned calendar helper

@Suite("Calendar.currentWithZone")
struct CalendarZoneHelperTests {
    /// DISCLOSURE: `Calendar.currentWithZone(_:)` has NO production caller today (grep over
    /// `Sources/` finds only its definition) — it is a helper kept alongside `DateParsing` for
    /// zone-pinned arithmetic. It is pinned here so its contract (Gregorian, the given zone, and
    /// no mutation of `Calendar.current`) is stated rather than assumed if a caller appears.
    @Test("returns a Gregorian calendar pinned to the given zone without touching Calendar.current")
    func pinsZoneWithoutMutatingCurrent() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let before = Calendar.current.timeZone
        let pinned = Calendar.currentWithZone(tokyo)
        #expect(pinned.identifier == .gregorian)
        #expect(pinned.timeZone == tokyo)
        #expect(Calendar.current.timeZone == before)

        // Zone-pinned arithmetic actually differs from a UTC-pinned one for the same instant.
        let utc = try #require(TimeZone(identifier: "UTC"))
        let instant = Date(timeIntervalSince1970: 1_784_116_800)   // 2026-07-15T12:00:00Z
        #expect(Calendar.currentWithZone(tokyo).component(.hour, from: instant) == 21)
        #expect(Calendar.currentWithZone(utc).component(.hour, from: instant) == 12)
    }
}

// MARK: - Encoding (envelope + wire-key shape)

@Suite("EventKitCore encoding")
struct EncodingTests {
    func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try Output.encodeSuccess(tool: "calendar", data: value)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(obj["data"] as? [String: Any])
    }

    @Test("CalendarEvent omits nil optionals and carries oracle-format date strings")
    func eventNilOmission() throws {
        let start = Date(timeIntervalSince1970: 1_784_116_800)   // 2026-07-15T12:00:00Z
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let event = CalendarEvent(
            id: "EVT-1", title: "apple-cli-test standup", location: "HQ",
            start_date: EventDateFormat.string(start, timeZone: la, includeTime: true),
            end_date: EventDateFormat.string(start.addingTimeInterval(1800), timeZone: la, includeTime: true),
            is_all_day: false,
            availability: "busy", status: "confirmed", calendar: "Work", calendar_id: "CAL-1",
            account: "iCloud", time_zone: "America/Los_Angeles", is_detached: false, has_recurrence: false
        )
        let data = try object(event)
        #expect(data["is_all_day"] as? Bool == false)
        #expect(data["calendar_id"] as? String == "CAL-1")
        // CAL-03: the wire value is the EVENT-zone rendering, not a UTC instant.
        #expect(data["start_date"] as? String == "2026-07-15T05:00:00-07:00")
        #expect(data["notes"] == nil)      // nil optionals omitted, not null
        #expect(data["organizer"] == nil)
        #expect(data["url"] == nil)
    }

    /// CAL-03: port of the oracle's `formatEventDate` — every event date renders in the event's
    /// zone; all-day start/end are date-only WITH the offset. Pinned as exact strings so a
    /// regression to UTC instants (or to timed all-day forms) goes red.
    @Test("EventDateFormat matches the oracle's rendering")
    func eventDateFormat() throws {
        let instant = Date(timeIntervalSince1970: 1_784_073_600)   // 2026-07-15T00:00:00Z
        let ny = TimeZone(identifier: "America/New_York")!
        #expect(EventDateFormat.string(instant, timeZone: ny, includeTime: true)
                == "2026-07-14T20:00:00-04:00")
        // All-day: date + offset, NO time — and the date is the EVENT-LOCAL day (July 14 in NY).
        #expect(EventDateFormat.string(instant, timeZone: ny, includeTime: false)
                == "2026-07-14-04:00")
        // GMT renders as the formatter's `Z` suffix — same DateFormatter behavior as the oracle.
        let utc = TimeZone(identifier: "UTC")!
        #expect(EventDateFormat.string(instant, timeZone: utc, includeTime: false) == "2026-07-15Z")
        #expect(EventDateFormat.string(instant, timeZone: utc, includeTime: true) == "2026-07-15T00:00:00Z")
    }

    /// CAL-03's SELECTION, pinned (review: pinning only the formatter left `includeTime =
    /// !isAllDay` and the `timeZone ?? .current` fallback mutable with every test green).
    @Test("eventDates: all-day drops the time on start/end ONLY; nil zone falls back to current")
    func eventDatesSelection() throws {
        let instant = Date(timeIntervalSince1970: 1_784_073_600)   // 2026-07-15T00:00:00Z
        let ny = TimeZone(identifier: "America/New_York")!
        let allDay = EventDateFormat.eventDates(start: instant, end: instant, occurrence: instant,
                                                created: instant, modified: instant,
                                                isAllDay: true, timeZone: ny)
        #expect(allDay.start == "2026-07-14-04:00")                // date-only
        #expect(allDay.end == "2026-07-14-04:00")
        #expect(allDay.occurrence == "2026-07-14T20:00:00-04:00")  // ALWAYS timed
        #expect(allDay.created == "2026-07-14T20:00:00-04:00")
        #expect(allDay.modified == "2026-07-14T20:00:00-04:00")

        let timed = EventDateFormat.eventDates(start: instant, end: nil, occurrence: nil,
                                               created: nil, modified: nil,
                                               isAllDay: false, timeZone: ny)
        #expect(timed.start == "2026-07-14T20:00:00-04:00")
        #expect(timed.end == nil)

        // nil zone → the CURRENT zone, whatever it is (pin by recomputing with .current).
        let fallback = EventDateFormat.eventDates(start: instant, end: nil, occurrence: nil,
                                                  created: nil, modified: nil,
                                                  isAllDay: false, timeZone: nil)
        #expect(fallback.start == EventDateFormat.string(instant, timeZone: .current, includeTime: true))
    }

    /// Golden lock on the rich nested wire keys — a rename/retype of any of these is a MAJOR
    /// schema break and MUST fail CI here.
    @Test("fully-populated CalendarEvent locks the rich nested keys")
    func eventGolden() throws {
        let start = Date(timeIntervalSince1970: 1_784_116_800)
        let utc = TimeZone(identifier: "UTC")!
        let event = CalendarEvent(
            id: "EVT-2", title: "apple-cli-test review", notes: "n", location: "HQ",
            url: "https://example.com",
            start_date: EventDateFormat.string(start, timeZone: utc, includeTime: true),
            end_date: EventDateFormat.string(start.addingTimeInterval(3600), timeZone: utc, includeTime: true),
            is_all_day: false, availability: "busy", status: "confirmed", calendar: "Work",
            calendar_id: "CAL-1", account: "iCloud", time_zone: "UTC", is_detached: true,
            has_recurrence: true,
            occurrence_date: EventDateFormat.string(start, timeZone: utc, includeTime: true),
            external_id: "EXT-9",
            organizer: Participant(name: "Org", email: "org@x.com", url: "mailto:org@x.com",
                                   status: "accepted", role: "chair", type: "person", is_current_user: true),
            attendees: [Participant(name: "A", email: "a@x.com", url: "mailto:a@x.com",
                                    status: "declined", role: "required", type: "person", is_current_user: false)],
            recurrence_rules: [RecurrenceRule(frequency: "weekly", interval: 1, days_of_week: [2, 4])],
            alarms: [Alarm(relative_offset: -900, type: "display")],
            structured_location: StructuredLocation(title: "HQ", latitude: 37.0, longitude: -122.0, radius: 50)
        )
        let data = try object(event)
        #expect(data["external_id"] as? String == "EXT-9")
        #expect(data["is_detached"] as? Bool == true)
        #expect(data["occurrence_date"] != nil)

        let rules = try #require(data["recurrence_rules"] as? [[String: Any]])
        #expect(rules[0]["frequency"] as? String == "weekly")
        #expect((rules[0]["days_of_week"] as? [Int]) == [2, 4])

        let alarms = try #require(data["alarms"] as? [[String: Any]])
        #expect(alarms[0]["relative_offset"] as? Double == -900)
        #expect(alarms[0]["type"] as? String == "display")

        let attendees = try #require(data["attendees"] as? [[String: Any]])
        #expect(attendees[0]["status"] as? String == "declined")
        #expect(attendees[0]["is_current_user"] as? Bool == false)

        let org = try #require(data["organizer"] as? [String: Any])
        #expect(org["role"] as? String == "chair")

        let loc = try #require(data["structured_location"] as? [String: Any])
        #expect(loc["title"] as? String == "HQ")
        #expect(loc["radius"] as? Double == 50)
    }

    @Test("fully-populated Reminder locks tags/parent_id/location_trigger and priority")
    func reminderGolden() throws {
        let r = Reminder(
            id: "REM-1", title: "apple-cli-test buy milk", notes: "n", url: "https://x.com",
            location: "Store", list: "Groceries", list_id: "LIST-1", account: "iCloud",
            time_zone: "UTC", external_id: "REXT-1", completed: false,
            due_date: "2026-07-15T12:00:00Z", priority: 5, has_recurrence: true,
            recurrence_rules: [RecurrenceRule(frequency: "daily", interval: 1)],
            alarms: [Alarm(relative_offset: -600, type: "display")],
            location_trigger: LocationTrigger(title: "Store", latitude: 1.0, longitude: 2.0, radius: 100, proximity: "enter"),
            tags: ["errand", "home"], parent_id: "REM-PARENT"
        )
        let data = try object(r)
        #expect(data["priority"] as? Int == 5)
        #expect(data["completed"] as? Bool == false)
        #expect(data["external_id"] as? String == "REXT-1")
        #expect(data["time_zone"] as? String == "UTC")
        #expect((data["tags"] as? [String]) == ["errand", "home"])
        #expect(data["parent_id"] as? String == "REM-PARENT")

        let lt = try #require(data["location_trigger"] as? [String: Any])
        #expect(lt["proximity"] as? String == "enter")
        #expect(lt["radius"] as? Double == 100)

        let rules = try #require(data["recurrence_rules"] as? [[String: Any]])
        #expect(rules[0]["frequency"] as? String == "daily")
    }
}
