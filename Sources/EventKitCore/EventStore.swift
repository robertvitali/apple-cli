import Foundation
import EventKit
import AppleKit

/// A small box that carries a completion-handler result across the semaphore bridge used to
/// make EventKit's async APIs synchronous for a single-threaded CLI. `@unchecked Sendable`
/// is sound here: exactly one writer (the handler) then one reader (after `wait()`), never
/// concurrent.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

/// The EventKit surface `EventStore` actually touches, extracted so logic tests can bind a
/// pure in-memory stand-in. `LiveEventKitStoreBackend` below is the ONLY production
/// implementation and is `private` to this file, so no flag, env var, or public initializer can
/// swap it — `EventStore()` always talks to the real `EKEventStore`.
///
/// Every completion handler here is `@escaping @Sendable`: each one is bridged to a synchronous
/// call through a `DispatchSemaphore`, and EventKit is free to invoke it on an arbitrary queue,
/// so the callback must be safe to run off the calling thread. `EKEventStore`'s own parameters
/// are not `@Sendable`, which is fine — a `@Sendable` closure converts to a plain one, so the
/// live backend still forwards each handler unchanged.
protocol EventKitStoreBackend {
    var store: EKEventStore { get }
    var sources: [EKSource] { get }
    var defaultCalendarForNewEvents: EKCalendar? { get }

    func authorizationStatus(for entity: EventStore.Entity) -> EventStore.AuthStatus
    func requestFullAccessToEvents(completion: @escaping @Sendable (Bool, Error?) -> Void)
    func requestFullAccessToReminders(completion: @escaping @Sendable (Bool, Error?) -> Void)
    func calendars(for entity: EventStore.Entity) -> [EKCalendar]
    func calendar(withIdentifier id: String) -> EKCalendar?
    func defaultCalendarForNewReminders() -> EKCalendar?
    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate
    func events(matching predicate: NSPredicate) -> [EKEvent]
    func event(withIdentifier id: String) -> EKEvent?
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func calendarItem(withIdentifier id: String) -> EKCalendarItem?
    func fetchReminders(matching predicate: NSPredicate, completion: @escaping @Sendable ([EKReminder]?) -> Void)
    func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate
    func save(_ reminder: EKReminder, commit: Bool) throws
    func remove(_ reminder: EKReminder, commit: Bool) throws
    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws
    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws
    func commit() throws
}

private final class LiveEventKitStoreBackend: EventKitStoreBackend {
    let store = EKEventStore()

    var sources: [EKSource] { store.sources }
    var defaultCalendarForNewEvents: EKCalendar? { store.defaultCalendarForNewEvents }

    func authorizationStatus(for entity: EventStore.Entity) -> EventStore.AuthStatus {
        EventStore.authorizationStatus(for: entity)
    }

    func requestFullAccessToEvents(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        store.requestFullAccessToEvents(completion: completion)
    }

    func requestFullAccessToReminders(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        store.requestFullAccessToReminders(completion: completion)
    }

    func calendars(for entity: EventStore.Entity) -> [EKCalendar] {
        store.calendars(for: entity.ekType)
    }

    func calendar(withIdentifier id: String) -> EKCalendar? {
        store.calendar(withIdentifier: id)
    }

    func defaultCalendarForNewReminders() -> EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    }

    func events(matching predicate: NSPredicate) -> [EKEvent] {
        store.events(matching: predicate)
    }

    func event(withIdentifier id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        try store.save(event, span: span, commit: commit)
    }

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        try store.remove(event, span: span, commit: commit)
    }

    func calendarItem(withIdentifier id: String) -> EKCalendarItem? {
        store.calendarItem(withIdentifier: id)
    }

    func fetchReminders(matching predicate: NSPredicate, completion: @escaping @Sendable ([EKReminder]?) -> Void) {
        store.fetchReminders(matching: predicate, completion: completion)
    }

    func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate {
        store.predicateForReminders(in: lists)
    }

    func save(_ reminder: EKReminder, commit: Bool) throws {
        try store.save(reminder, commit: commit)
    }

    func remove(_ reminder: EKReminder, commit: Bool) throws {
        try store.remove(reminder, commit: commit)
    }

    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        try store.saveCalendar(calendar, commit: commit)
    }

    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        try store.removeCalendar(calendar, commit: commit)
    }

    func commit() throws {
        try store.commit()
    }
}

/// The shared EventKit engine for Calendar + Reminders. Every EventKit call goes through an
/// `EventKitStoreBackend` — in production always the file-private `LiveEventKitStoreBackend`,
/// which owns the one `EKEventStore` this type exposes as `store` for object construction
/// (`EKEvent(eventStore:)` and friends). It bridges EventKit's async access/fetch APIs to
/// synchronous CLI calls and centralizes auth + error mapping so both domains behave
/// identically. RemindersKit imports this UNCHANGED — keep the public API stable.
public final class EventStore {
    public let store: EKEventStore
    private let backend: any EventKitStoreBackend

    public init() {
        let backend = LiveEventKitStoreBackend()
        self.store = backend.store
        self.backend = backend
    }

    /// Test-only seam. Internal (and the protocol is internal), so no other module — and no
    /// flag or env var — can reach it; `EventStore()` is the only production path.
    init(backend: any EventKitStoreBackend) {
        self.store = backend.store
        self.backend = backend
    }

    // MARK: Entities + auth

    public enum Entity: Sendable {
        case event, reminder
        var ekType: EKEntityType { self == .event ? .event : .reminder }
    }

    public enum AccessMode: Sendable { case read, write }

    /// Normalized authorization state (string-friendly for `doctor` output).
    public enum AuthStatus: String, Sendable {
        case notDetermined = "not_determined"
        case restricted
        case denied
        case fullAccess = "full_access"
        case writeOnly = "write_only"
        case authorized
        case unknown
    }

    /// Non-prompting status probe (safe to call anywhere, including `doctor`).
    public static func authorizationStatus(for entity: Entity) -> AuthStatus {
        switch EKEventStore.authorizationStatus(for: entity.ekType) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .authorized: return .authorized     // deprecated alias (rawValue shares .fullAccess)
        @unknown default: return .unknown
        }
    }

    /// Ensure the process has sufficient EventKit access for `entity` in `mode`, prompting on
    /// first run (`.notDetermined`). Throws `AppleError.permissionDenied` (exit 77) if denied.
    ///
    /// OPERATOR NOTE: on a machine where the TCC prompt has never been answered, the first live
    /// call BLOCKS on the system permission dialog until the user responds. This is expected and
    /// unavoidable for EventKit; pure logic tests never reach this path.
    public func requestAccess(to entity: Entity, mode: AccessMode = .read) throws {
        let status = backend.authorizationStatus(for: entity)
        if Self.satisfies(status, mode: mode, entity: entity) { return }

        switch status {
        case .denied, .restricted:
            throw AppleError.permissionDenied(deniedMessage(entity))
        case .notDetermined:
            let granted = try requestFullAccess(to: entity)
            let after = backend.authorizationStatus(for: entity)
            if granted && Self.satisfies(after, mode: mode, entity: entity) { return }
            throw AppleError.permissionDenied(deniedMessage(entity))
        default:
            // e.g. .writeOnly when a read is needed → insufficient
            throw AppleError.permissionDenied(deniedMessage(entity))
        }
    }

    private static func satisfies(_ status: AuthStatus, mode: AccessMode, entity: Entity) -> Bool {
        switch status {
        case .fullAccess, .authorized: return true
        case .writeOnly: return mode == .write && entity == .event
        default: return false
        }
    }

    private func deniedMessage(_ entity: Entity) -> String {
        let name = entity == .event ? "Calendars" : "Reminders"
        return "EventKit access to \(name) is not granted — enable it in "
            + "System Settings › Privacy & Security › \(name)."
    }

    /// Always requests FULL access, not the events-only write-only tier. Rationale: (1) it
    /// matches the parity oracle — the reference EventKitCLI @1.4.0 always requests full access
    /// for both entities; (2) create/update commands echo the written item back (a read), which
    /// write-only access cannot satisfy. `satisfies(_:mode:entity:)` still ACCEPTS a pre-existing
    /// `.writeOnly` grant for an event write, so a user who granted only write-only is not forced
    /// to re-grant — we just never request the narrower tier ourselves.
    private func requestFullAccess(to entity: Entity) throws -> Bool {
        let box = Box<(Bool, Error?)>((false, nil))
        let sem = DispatchSemaphore(value: 0)
        let handler: @Sendable (Bool, Error?) -> Void = { granted, err in
            box.value = (granted, err)
            sem.signal()
        }
        switch entity {
        case .event: backend.requestFullAccessToEvents(completion: handler)
        case .reminder: backend.requestFullAccessToReminders(completion: handler)
        }
        sem.wait()
        let (granted, err) = box.value
        if let err { throw AppleError.permissionDenied("EventKit access request failed: \(err.localizedDescription)") }
        return granted
    }

    // MARK: Calendars / lists

    public func calendars(for entity: Entity) -> [EKCalendar] {
        backend.calendars(for: entity)
    }

    public func calendar(withIdentifier id: String) -> EKCalendar? {
        backend.calendar(withIdentifier: id)
    }

    /// Resolve a calendar by identifier first, then by case-insensitive title, within an entity.
    /// Event-calendar and reminder-list identifiers share a namespace, so an id that resolves to
    /// the WRONG entity type is rejected (returns nil) rather than silently returning a
    /// mismatched calendar that would fail later at `save` with a murkier error.
    public func calendar(matching nameOrId: String, entity: Entity) -> EKCalendar? {
        if let byId = backend.calendar(withIdentifier: nameOrId),
           byId.allowedEntityTypes.contains(entity == .event ? .event : .reminder) {
            return byId
        }
        let lowered = nameOrId.lowercased()
        return calendars(for: entity).first { $0.title.lowercased() == lowered }
    }

    public var defaultCalendarForEvents: EKCalendar? { backend.defaultCalendarForNewEvents }
    public var defaultCalendarForReminders: EKCalendar? { backend.defaultCalendarForNewReminders() }

    /// EKSource resolution for creating a new calendar/list (prefers a writable local/cloud source).
    public func preferredSource(for entity: Entity) -> EKSource? {
        if entity == .event, let s = backend.defaultCalendarForNewEvents?.source { return s }
        if entity == .reminder, let s = backend.defaultCalendarForNewReminders()?.source { return s }
        // Fall back to a local source, else any source.
        return backend.sources.first { $0.sourceType == .local } ?? backend.sources.first
    }

    // MARK: Events

    /// Construct a new event bound to this store (the domain fills fields, then calls `save`).
    public func newEvent() -> EKEvent { EKEvent(eventStore: store) }

    public func event(withIdentifier id: String) -> EKEvent? {
        backend.event(withIdentifier: id)
    }

    public func events(start: Date, end: Date, calendars: [EKCalendar]?) -> [EKEvent] {
        let predicate = backend.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return backend.events(matching: predicate).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    // WRITE-GUARD CONTRACT (applies to every mutator below — save/remove/saveCalendar/
    // removeCalendar/commit): this engine does NOT self-gate, and deliberately holds no gate of
    // its own — the gates live entirely in the two command layers (`CalendarWriteGuard` in
    // CalendarKit, `ReminderWriteGuard` in RemindersKit), which is what lets Calendar and
    // Reminders be flipped as independent edits without contending on this shared file.
    //
    // Under write-model v2 (docs/write-model-v2.md) the CALLER must:
    //   1. resolve the write posture ONCE at the top of `run()` via its domain
    //      `…WriteGuard.resolve(global)` and branch on `gate.willExecute` — note that v2 EXECUTES
    //      BY DEFAULT (mirroring the oracle), so the old "dry-run unless --execute" reading of
    //      this contract no longer holds; `--dry-run` is what opts out; and
    //   2. apply the label check ONLY when `gate.sandboxActive` — the sandbox is opt-in, and
    //      outside it the CLI mutates real data on call exactly as the MCP does.
    //
    // `remove(_:span:.futureEvents)` and `removeCalendar` are DANGEROUS ACTIONS (irreversible on
    // the user's live store — a whole recurring series / an entire calendar). They are reachable
    // by default now, so the caller's `willExecute` branch is the ONLY thing standing between a
    // flagless invocation and the deletion; never wire a new command path to them without it.

    public func save(_ event: EKEvent, span: EKSpan, commit: Bool = true) throws {
        do { try backend.save(event, span: span, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    /// DANGEROUS with `span: .futureEvents` — deletes the whole recurring series. See the
    /// write-guard contract above; the caller must have branched on `gate.willExecute` and, when
    /// `gate.sandboxActive`, checked the label.
    public func remove(_ event: EKEvent, span: EKSpan, commit: Bool = true) throws {
        do { try backend.remove(event, span: span, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    // MARK: Reminders

    /// Construct a new reminder in a list (the domain fills fields, then calls `save`).
    public func newReminder(in list: EKCalendar) -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.calendar = list
        return r
    }

    /// Look up a single reminder by identifier (via the generic calendar-item lookup).
    public func reminder(withIdentifier id: String) -> EKReminder? {
        backend.calendarItem(withIdentifier: id) as? EKReminder
    }

    /// Fetch reminders matching a predicate, bridging EventKit's async fetch to a sync call.
    /// Bounded at 30s: unlike the interactive access prompt (which legitimately waits on the
    /// user), a fetch that never calls back is a stall, so it throws `.upstream` rather than
    /// hanging the CLI forever.
    ///
    /// EventKit may invoke the handler on any queue, so it is `@Sendable` and communicates back
    /// only through the `Box` + semaphore pair (one write, then one read after `wait()`).
    public func reminders(matching predicate: NSPredicate) throws -> [EKReminder] {
        let box = Box<[EKReminder]>([])
        let sem = DispatchSemaphore(value: 0)
        let handler: @Sendable ([EKReminder]?) -> Void = { reminders in
            box.value = reminders ?? []
            sem.signal()
        }
        backend.fetchReminders(matching: predicate, completion: handler)
        if sem.wait(timeout: .now() + 30) == .timedOut {
            throw AppleError.upstream("EventKit reminder fetch timed out after 30s")
        }
        return box.value
    }

    public func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate {
        backend.predicateForReminders(in: lists)
    }

    public func save(_ reminder: EKReminder, commit: Bool = true) throws {
        do { try backend.save(reminder, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    public func remove(_ reminder: EKReminder, commit: Bool = true) throws {
        do { try backend.remove(reminder, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    // MARK: Calendar (list/collection) mutation

    /// Construct a new calendar/list for an entity, sourced from a writable EKSource.
    /// Returns nil if no source is available (the domain surfaces a clearer error).
    public func newCalendar(for entity: Entity) -> EKCalendar? {
        let cal = EKCalendar(for: entity.ekType, eventStore: store)
        guard let source = preferredSource(for: entity) else { return nil }
        cal.source = source
        return cal
    }

    public func saveCalendar(_ calendar: EKCalendar, commit: Bool = true) throws {
        do { try backend.saveCalendar(calendar, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    /// DANGEROUS — deletes an entire calendar/list AND every item in it, irreversibly. See the
    /// write-guard contract above; the caller must have branched on `gate.willExecute` and, when
    /// `gate.sandboxActive`, checked the label.
    public func removeCalendar(_ calendar: EKCalendar, commit: Bool = true) throws {
        do { try backend.removeCalendar(calendar, commit: commit) }
        catch { throw Self.mapError(error) }
    }

    public func commit() throws {
        do { try backend.commit() }
        catch { throw Self.mapError(error) }
    }

    // MARK: Error mapping

    /// Map an EventKit error to the shared `AppleError` (contractual type + exit code). Bad-input
    /// EKErrors become `.validation` (64); everything else is `.upstream` (69).
    public static func mapError(_ error: Error) -> AppleError {
        if let apple = error as? AppleError { return apple } // mappers throw AppleError.validation
        if let ek = error as? EKError {
            switch ek.code {
            case .eventStoreNotAuthorized:
                return .permissionDenied("EventKit: \(ek.localizedDescription)")
            case .eventNotMutable, .noCalendar, .noStartDate, .noEndDate, .datesInverted,
                 .calendarReadOnly, .durationGreaterThanRecurrence, .alarmGreaterThanRecurrence,
                 .startDateTooFarInFuture, .startDateCollidesWithOtherOccurrence,
                 .objectBelongsToDifferentStore, .invitesCannotBeMoved, .invalidSpan,
                 .calendarSourceCannotBeModified, .calendarIsImmutable,
                 .sourceDoesNotAllowCalendarAddDelete, .recurringReminderRequiresDueDate,
                 .structuredLocationsNotSupported, .reminderLocationsNotSupported,
                 .alarmProximityNotSupported, .calendarDoesNotAllowEvents,
                 .calendarDoesNotAllowReminders, .sourceDoesNotAllowReminders,
                 .sourceDoesNotAllowEvents, .priorityIsInvalid, .invalidEntityType,
                 .procedureAlarmsNotMutable:
                return .validation("EventKit: \(ek.localizedDescription)")
            default:
                return .upstream("EventKit error: \(ek.localizedDescription)")
            }
        }
        return .upstream("EventKit error: \(error.localizedDescription)")
    }
}

public protocol CalendarEventStore {
    func requestAccess(to entity: EventStore.Entity, mode: EventStore.AccessMode) throws
    func calendars(for entity: EventStore.Entity) -> [EKCalendar]
    func calendar(matching nameOrId: String, entity: EventStore.Entity) -> EKCalendar?
    var defaultCalendarForEvents: EKCalendar? { get }
    func event(withIdentifier id: String) -> EKEvent?
    func events(start: Date, end: Date, calendars: [EKCalendar]?) -> [EKEvent]
    func newEvent() -> EKEvent
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws
}

public protocol ReminderStore {
    func requestAccess(to entity: EventStore.Entity, mode: EventStore.AccessMode) throws
    func calendars(for entity: EventStore.Entity) -> [EKCalendar]
    func calendar(matching nameOrId: String, entity: EventStore.Entity) -> EKCalendar?
    var defaultCalendarForReminders: EKCalendar? { get }
    func reminder(withIdentifier id: String) -> EKReminder?
    func reminders(matching predicate: NSPredicate) throws -> [EKReminder]
    func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate
    func newReminder(in list: EKCalendar) -> EKReminder
    func newCalendar(for entity: EventStore.Entity) -> EKCalendar?
    func save(_ reminder: EKReminder, commit: Bool) throws
    func remove(_ reminder: EKReminder, commit: Bool) throws
    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws
    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws
}

extension EventStore: CalendarEventStore, ReminderStore {}
