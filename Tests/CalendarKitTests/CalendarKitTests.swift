import Testing
import Foundation
import ArgumentParser
import EventKit
import AppleKit
import EventKitCore
@testable import CalendarKit

// Logic-tier tests for the Calendar command surface — flag/spec parsers, the read-window
// default, the write guard, and the commands driven through an injected store. These are
// TCC-free, not EventKit-free: `FakeCalendarEventStore` constructs an `EKEventStore` solely as
// an inert object factory for `EKEvent` / `EKCalendar` (there is no in-memory substitute for
// `EKEvent(eventStore:)`), and never issues access/fetch/save/remove/commit against it — every
// such call routes through the fake. Construction alone neither prompts nor reads TCC.
//
//     PATH="$HOME/.swiftly/bin:$PATH" swift test

// MARK: - Alarm spec parsing

@Suite("AlarmSpec")
struct AlarmSpecTests {
    @Test("unsigned relative is BEFORE start (negative)")
    func relativeBefore() throws {
        #expect(try AlarmSpec.parse("15m").relative_offset == -900)
        #expect(try AlarmSpec.parse("2h").relative_offset == -7200)
        #expect(try AlarmSpec.parse("1d").relative_offset == -86_400)
        #expect(try AlarmSpec.parse("30s").relative_offset == -30)
    }

    @Test("explicit sign is honored; bare number is raw-signed (MCP relativeOffset)")
    func signed() throws {
        #expect(try AlarmSpec.parse("+30m").relative_offset == 1800)
        #expect(try AlarmSpec.parse("-15m").relative_offset == -900)
        #expect(try AlarmSpec.parse("-900").relative_offset == -900)
        #expect(try AlarmSpec.parse("900").relative_offset == 900)  // bare unsigned = raw (+), matches MCP
    }

    @Test("geofence spec parses coords/radius/proximity/title")
    func geofence() throws {
        let a = try AlarmSpec.parse("geo:37.33,-122.03,150,leave,Office")
        let lt = try #require(a.location_trigger)
        #expect(abs((lt.latitude ?? 0) - 37.33) < 1e-9)
        #expect(abs((lt.longitude ?? 0) + 122.03) < 1e-9)
        #expect(lt.radius == 150)
        #expect(lt.proximity == "leave")
        #expect(lt.title == "Office")
    }

    @Test("geofence with an OMITTED radius still reads proximity/title (regression)")
    func geofenceOmitRadius() throws {
        let lt1 = try #require(try AlarmSpec.parse("geo:37.33,-122.03,leave").location_trigger)
        #expect(lt1.proximity == "leave")   // not silently dropped
        #expect(lt1.radius == 100)          // default

        let lt2 = try #require(try AlarmSpec.parse("geo:1.0,2.0,Office").location_trigger)
        #expect(lt2.title == "Office")      // not silently dropped
        #expect(lt2.radius == 100)
    }

    @Test("geofence defaults radius 100 / proximity enter when omitted")
    func geofenceDefaults() throws {
        let lt = try #require(try AlarmSpec.parse("geo:1.0,2.0").location_trigger)
        #expect(lt.radius == 100)
        #expect(lt.proximity == "enter")
    }

    @Test("out-of-range geofence coordinates are rejected")
    func geofenceRange() {
        #expect(throws: AppleError.self) { _ = try AlarmSpec.parse("geo:200,10") }
        #expect(throws: AppleError.self) { _ = try AlarmSpec.parse("geo:nan,10") }
    }

    @Test("a date string parses as an absolute alarm")
    func absolute() throws {
        let a = try AlarmSpec.parse("2026-07-15T09:00:00")
        #expect(a.absolute_date != nil)
        #expect(a.relative_offset == nil)
    }

    @Test("garbage throws")
    func bad() {
        #expect(throws: AppleError.self) { _ = try AlarmSpec.parse("banana") }
        #expect(throws: AppleError.self) { _ = try AlarmSpec.parse("geo:only-one") }
    }
}

// MARK: - Recurrence spec parsing

@Suite("RecurrenceSpec")
struct RecurrenceSpecTests {
    @Test("full weekly spec parses every field")
    func weekly() throws {
        let r = try RecurrenceSpec.parse("freq=weekly;interval=2;byday=2,4;count=6")
        #expect(r.frequency == "weekly")
        #expect(r.interval == 2)
        #expect(r.occurrence_count == 6)
        #expect(r.days_of_week == [2, 4])
    }

    @Test("monthly by-set-position and negative month-day")
    func monthly() throws {
        let r = try RecurrenceSpec.parse("freq=monthly;bymonthday=1,-1;bysetpos=-1;bymonth=6")
        #expect(r.days_of_month == [1, -1])
        #expect(r.set_positions == [-1])
        #expect(r.months_of_year == [6])
    }

    @Test("until= sets an end date")
    func until() throws {
        let r = try RecurrenceSpec.parse("freq=daily;until=2026-12-31")
        #expect(r.end_date != nil)
        #expect(r.interval == 1) // default
    }

    @Test("missing freq or malformed segment throws")
    func bad() {
        #expect(throws: AppleError.self) { _ = try RecurrenceSpec.parse("interval=2") }
        #expect(throws: AppleError.self) { _ = try RecurrenceSpec.parse("freq=weekly;interval=x") }
        #expect(throws: AppleError.self) { _ = try RecurrenceSpec.parse("freqweekly") }
    }

    @Test("parsed spec feeds EventKitCore validation (out-of-range rejected)")
    func feedsValidation() throws {
        let r = try RecurrenceSpec.parse("freq=weekly;byday=8")
        #expect(throws: AppleError.self) { _ = try RecurrenceMapping.ekRule(from: r) }
    }

    @Test("count + until together → until wins (MCP precedence)")
    func countUntilPrecedence() throws {
        let r = try RecurrenceSpec.parse("freq=daily;count=10;until=2026-12-31")
        #expect(r.end_date != nil)
        #expect(r.occurrence_count == nil) // dropped so endDate wins, matching the MCP
    }
}

// MARK: - Read window default (parity with the MCP's resolveReadDateRange)

@Suite("ReadWindow")
struct ReadWindowTests {
    let cal = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_784_116_800) // 2026-07-15T12:00:00Z

    @Test("neither bound → [startOfToday, +14d]")
    func neither() {
        let w = ReadWindow.resolve(start: nil, end: nil, now: now, calendar: cal)
        #expect(w.start == cal.startOfDay(for: now))
        #expect(abs(w.end.timeIntervalSince(w.start) - 14 * 86_400) < 1)
    }

    @Test("start only → end = start + 14d")
    func startOnly() {
        let s = now
        let w = ReadWindow.resolve(start: s, end: nil, now: now, calendar: cal)
        #expect(w.start == s)
        #expect(abs(w.end.timeIntervalSince(s) - 14 * 86_400) < 1)
    }

    @Test("end only → start = end - 14d")
    func endOnly() {
        let e = now
        let w = ReadWindow.resolve(start: nil, end: e, now: now, calendar: cal)
        #expect(w.end == e)
        #expect(abs(e.timeIntervalSince(w.start) - 14 * 86_400) < 1)
    }

    @Test("both bounds pass through unchanged")
    func both() {
        let s = now, e = now.addingTimeInterval(3600)
        let w = ReadWindow.resolve(start: s, end: e, now: now, calendar: cal)
        #expect(w.start == s && w.end == e)
    }
}

// MARK: - Write guard

/// Pins the write-model v2 DECISION `CalendarWriteGuard.resolve` makes, which nothing else can
/// catch: the bats tier cannot assert "a flagless `calendar events create` executes" without
/// actually writing to the operator's calendar, and the AppleKit core tier only proves the
/// precedence chain, not that THIS domain opted into it. A silent revert to dry-run-by-default (or
/// a re-tightening of the lifted label gate) fails here and only here.
///
/// These read the real process environment and assume `APPLE_TEST_MODE` / `APPLE_DRY_RUN` are
/// unset — asserted below so a polluted env fails legibly instead of mysteriously.
@Suite("Calendar write-model v2 posture")
struct CalendarWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
        #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
    }

    @Test("DEFAULT PIN: a flagless calendar write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        let gate = try CalendarWriteGuard.resolve(opts([]))
        #expect(gate.willExecute == true)
        #expect(gate.sandboxActive == false)
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        #expect(try CalendarWriteGuard.resolve(opts(["--dry-run"])).willExecute == false)
        #expect(try CalendarWriteGuard.resolve(opts(["--execute"])).willExecute == true)
        #expect(try CalendarWriteGuard.resolve(opts(["--dry-run", "--execute"])).willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        let gate = try CalendarWriteGuard.resolve(opts(["--test-mode"]))
        #expect(gate.sandboxActive == true)
        #expect(gate.willExecute == true)
    }

    /// Pinned via the `prefix:` seam — `TestMode.sandboxPrefix` is env-backed and MailKitTests
    /// setenv()s `APPLE_TEST_SANDBOX=qa-fixture` in parallel, which flaked the Contacts and Notes
    /// posture suites 1-in-6 before the seam existed.
    @Test("LIFT PIN: the label gate applies ONLY inside the sandbox")
    func labelGateIsSandboxOnly() throws {
        let p = TestMode.canonicalSandboxPrefix
        // Unsandboxed, an unlabeled title is allowed — that IS the v2 flip (the oracle creates and
        // deletes real events on call). A throw here means the gate was re-tightened.
        #expect(throws: Never.self) {
            try CalendarWriteGuard.requireLabeled("Real Meeting", sandboxActive: false, prefix: p)
        }
        #expect(throws: Never.self) {
            try CalendarWriteGuard.requireLabeled("", sandboxActive: false, prefix: p)
        }
        // Sandboxed, the same names are refused...
        #expect(throws: AppleError.self) {
            try CalendarWriteGuard.requireLabeled("Real Meeting", sandboxActive: true, prefix: p)
        }
        #expect(throws: AppleError.self) {
            try CalendarWriteGuard.requireLabeled("", sandboxActive: true, prefix: p)
        }
        // ...a near-miss is refused (prefix, not substring)...
        #expect(throws: AppleError.self) {
            try CalendarWriteGuard.requireLabeled("almost-\(p) thing", sandboxActive: true, prefix: p)
        }
        // ...and a labeled one passes.
        #expect(throws: Never.self) {
            try CalendarWriteGuard.requireLabeled("\(p) standup", sandboxActive: true, prefix: p)
        }
    }
}

// MARK: - Dry-run preview encoding

@Suite("EventWritePreview encoding")
struct PreviewTests {
    @Test("preview carries dry_run true and the parsed intent")
    func preview() throws {
        let p = EventWritePreview(action: "create", title: "apple-cli-test x",
                                  alarms: [Alarm(relative_offset: -900)])
        let data = try Output.encodeSuccess(tool: "calendar", data: p)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let d = try #require(obj["data"] as? [String: Any])
        #expect(d["dry_run"] as? Bool == true)
        #expect(d["action"] as? String == "create")
        let alarms = try #require(d["alarms"] as? [[String: Any]])
        #expect(alarms[0]["relative_offset"] as? Double == -900)
    }
}

// MARK: - Structured location (title-only allowed; coords range-checked)

@Suite("StructuredLocationArg")
struct StructuredLocationArgTests {
    @Test("title-only structured location is allowed (MCP parity)")
    func titleOnly() throws {
        let loc = try #require(try StructuredLocationArg.parse(lat: nil, lon: nil, radius: nil, title: "Conference Room B"))
        #expect(loc.title == "Conference Room B")
        #expect(loc.latitude == nil && loc.longitude == nil)
    }

    @Test("both coordinates together are accepted and range-checked")
    func coords() throws {
        let loc = try #require(try StructuredLocationArg.parse(lat: 40.0, lon: -105.0, radius: 50, title: "HQ"))
        #expect(loc.latitude == 40.0 && loc.longitude == -105.0 && loc.radius == 50)
    }

    @Test("one coordinate without the other is rejected")
    func lonely() {
        #expect(throws: AppleError.self) { _ = try StructuredLocationArg.parse(lat: 40.0, lon: nil, radius: nil, title: "x") }
    }

    @Test("out-of-range / non-finite coordinates are rejected")
    func range() {
        #expect(throws: AppleError.self) { _ = try StructuredLocationArg.parse(lat: 200, lon: 10, radius: nil, title: nil) }
        #expect(throws: AppleError.self) { _ = try StructuredLocationArg.parse(lat: .nan, lon: 10, radius: nil, title: nil) }
    }

    @Test("no geo flag at all → nil")
    func none() throws {
        #expect(try StructuredLocationArg.parse(lat: nil, lon: nil, radius: nil, title: nil) == nil)
    }

    /// Review HIGH (Q12-A): the preview builds its structured_location from THIS parse, so a
    /// nil/zero radius must be nil (key omitted) here too — the read mapping already omits it,
    /// and a preview emitting `radius: 0` while --execute omits the key broke the
    /// preview↔execute byte-agreement invariant. Encoded both ways to pin the WIRE.
    @Test("radius omitted when absent or zero — preview agrees with the read mapping")
    func radiusOmission() throws {
        let none = try #require(try StructuredLocationArg.parse(lat: 1, lon: 2, radius: nil, title: "HQ"))
        #expect(none.radius == nil)
        let zero = try #require(try StructuredLocationArg.parse(lat: 1, lon: 2, radius: 0, title: "HQ"))
        #expect(zero.radius == nil)
        let json = try String(data: JSONEncoder().encode(zero), encoding: .utf8)!
        #expect(!json.contains("radius"))
        let pos = try #require(try StructuredLocationArg.parse(lat: 1, lon: 2, radius: 75, title: "HQ"))
        #expect(pos.radius == 75)
    }
}

// MARK: - Window-bound flooring (bare date → start-of-day)

/// CAL-06: the oracle's update-path timezone rules, pinned on the pure resolver.
@Suite("EventTZUpdate")
struct EventTZUpdateTests {

    @Test("a provided start always re-derives the zone — offset, Z, local, and bare dates")
    func startDerives() throws {
        #expect(try EventTZUpdate.resolve(start: "2026-07-15T09:00:00+02:00", end: nil,
                                          existing: nil)?.identifier == "GMT+0200")
        #expect(try EventTZUpdate.resolve(start: "2026-07-15T09:00:00Z", end: nil,
                                          existing: TimeZone(identifier: "Asia/Tokyo"))?.identifier == "GMT")
        // no offset → the LOCAL zone; bare dates included (the old code skipped date-only)
        #expect(try EventTZUpdate.resolve(start: "2026-07-15 09:00:00", end: nil,
                                          existing: nil) == TimeZone.current)
        #expect(try EventTZUpdate.resolve(start: "2026-07-15", end: nil,
                                          existing: nil) == TimeZone.current)
    }

    @Test("a provided end derives the zone ONLY when the event has none")
    func endDerivesWhenUnset() throws {
        #expect(try EventTZUpdate.resolve(start: nil, end: "2026-07-15T17:00:00+02:00",
                                          existing: nil)?.identifier == "GMT+0200")
        // existing zone + end-only update: zone untouched, no conflict error
        #expect(try EventTZUpdate.resolve(start: nil, end: "2026-07-15T17:00:00+02:00",
                                          existing: TimeZone(identifier: "Asia/Tokyo")) == nil)
    }

    @Test("start and end with different zones in ONE update is a validation rejection")
    func conflictRejected() {
        #expect(throws: AppleError.self) {
            _ = try EventTZUpdate.resolve(start: "2026-07-15T09:00:00+02:00",
                                          end: "2026-07-15T17:00:00-05:00", existing: nil)
        }
        // same zone on both sides is fine
        #expect(throws: Never.self) {
            _ = try EventTZUpdate.resolve(start: "2026-07-15T09:00:00+02:00",
                                          end: "2026-07-15T17:00:00+02:00", existing: nil)
        }
        // Local start + offset end ALSO conflicts (oracle quirk preserved): the local side is a
        // NAMED zone ("America/…"), the offset side a fixed "GMT±…" zone — the identifiers can
        // never be equal, so the oracle rejects. Deterministic on any machine, since
        // TimeZone.current is always a named zone.
        #expect(throws: AppleError.self) {
            _ = try EventTZUpdate.resolve(start: "2026-07-15 09:00:00",
                                          end: "2026-07-15T17:00:00+02:00", existing: nil)
        }
    }
}

/// The oracle uses `parseDate`'s instant DIRECTLY as the window bound — no flooring. The old
/// floor was an artifact of the noon-anchor era, and after the Q10 parser widening it actively
/// SHIFTED offset-bearing date-only bounds by the zone gap (review measured −18h/−20h vs the
/// oracle on `+0200`/`Z` forms — these exact-instant pins are the regression guard).
@Suite("DateArg.windowBound")
struct WindowBoundTests {
    @Test("a bare LOCAL date is midnight in the local zone")
    func bareIsLocalMidnight() throws {
        let bound = try DateArg.windowBound("2026-07-15")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute, .second], from: bound)
        #expect(comps.hour == 0 && comps.minute == 0 && comps.second == 0)
    }

    @Test("offset-bearing date-only bounds are midnight in THEIR zone, not floored locally")
    func offsetDateOnlyExactInstants() throws {
        #expect(try DateArg.windowBound("2026-09-01+02:00")
                == Date(timeIntervalSince1970: 1_788_213_600))   // 2026-08-31T22:00:00Z
        #expect(try DateArg.windowBound("2026-09-01Z")
                == Date(timeIntervalSince1970: 1_788_220_800))   // 2026-09-01T00:00:00Z
    }

    @Test("a timed value passes through unchanged")
    func timedUnchanged() throws {
        let bound = try DateArg.windowBound("2026-07-15T09:30:00Z")
        #expect(bound == Date(timeIntervalSince1970: 1_784_107_800)) // 2026-07-15T09:30:00Z
    }
}

// MARK: - Timezone detection (parity: preserve input offset)

@Suite("TZDetect")
struct TZDetectTests {
    @Test("Z and explicit offsets are detected")
    func offsets() {
        #expect(TZDetect.from("2026-07-15T09:00:00Z")?.secondsFromGMT() == 0)
        #expect(TZDetect.from("2026-07-15T09:00:00+09:00")?.secondsFromGMT() == 9 * 3600)
        #expect(TZDetect.from("2026-07-15T09:00:00-05:00")?.secondsFromGMT() == -5 * 3600)
    }

    @Test("a bare date's trailing -DD is NOT read as an offset")
    func bareDateNotOffset() {
        #expect(TZDetect.from("2026-07-15") == nil)   // no time component
        #expect(TZDetect.from("2026-07-15 09:30:00") == nil) // timed but no offset → local
    }
}

// MARK: - URL validation

@Suite("URLArg")
struct URLArgTests {
    @Test("a URL with a scheme is accepted; garbage is rejected")
    func validate() throws {
        #expect(try URLArg.require("https://example.com").scheme == "https")
        #expect(throws: AppleError.self) { _ = try URLArg.require("not a url") }
        #expect(throws: AppleError.self) { _ = try URLArg.require("example.com") } // no scheme
    }
}

// MARK: - Command execution with injected EventStore

final class FakeCalendarEventStore: CalendarEventStore {
    /// INERT OBJECT FACTORY ONLY — see the file header. No access/fetch/save/remove/commit is
    /// ever issued against this instance.
    let ekStore = EKEventStore()
    var requestedAccess: [(EventStore.Entity, EventStore.AccessMode)] = []
    var collections: [EKCalendar]
    var defaultCalendar: EKCalendar?
    var eventsById: [String: EKEvent] = [:]
    var eventRows: [EKEvent] = []
    /// Every `events(start:end:calendars:)` call, so the RESOLVED window + calendar set that
    /// production hands EventKit can be asserted rather than emulated.
    var eventsQueries: [(start: Date, end: Date, calendars: [EKCalendar]?)] = []
    var saved: [(EKEvent, EKSpan, Bool)] = []
    var removed: [(EKEvent, EKSpan, Bool)] = []

    init() {
        let cal = EKCalendar(for: .event, eventStore: ekStore)
        cal.title = "apple-cli-test calendar"
        self.collections = [cal]
        self.defaultCalendar = cal
    }

    func requestAccess(to entity: EventStore.Entity, mode: EventStore.AccessMode) throws {
        requestedAccess.append((entity, mode))
    }

    func calendars(for entity: EventStore.Entity) -> [EKCalendar] {
        entity == .event ? collections : []
    }

    func calendar(matching nameOrId: String, entity: EventStore.Entity) -> EKCalendar? {
        guard entity == .event else { return nil }
        return collections.first {
            $0.calendarIdentifier == nameOrId || $0.title.lowercased() == nameOrId.lowercased()
        }
    }

    var defaultCalendarForEvents: EKCalendar? { defaultCalendar }

    func event(withIdentifier id: String) -> EKEvent? { eventsById[id] }

    /// Rows are returned VERBATIM, matching `FakeEventKitBackend.events(...)`. The fake
    /// deliberately does not re-implement window/calendar matching: that is EventKit's
    /// `NSPredicate` semantics, which a hand-rolled emulation can only drift from, and a test
    /// that passes because the FAKE filtered proves nothing about production. What production
    /// actually owes us here is that it forwards the resolved window and calendar set — recorded
    /// in `eventsQueries` and asserted directly — and then applies its own in-process
    /// `--search` / `--availability` filters to whatever comes back.
    func events(start: Date, end: Date, calendars: [EKCalendar]?) -> [EKEvent] {
        eventsQueries.append((start, end, calendars))
        return eventRows
    }

    func newEvent() -> EKEvent { EKEvent(eventStore: ekStore) }

    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        saved.append((event, span, commit))
    }

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        removed.append((event, span, commit))
    }
}

@Suite("Calendar command execution with injected store")
struct CalendarCommandExecutionTests {
    func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
    }

    func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        return try #require(root["data"] as? [String: Any])
    }

    func errorPayload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        return try #require(root["error"] as? [String: Any])
    }

    /// Run a command that must FAIL, and pin BOTH halves of the contract `runGuarded` binds
    /// atomically: the exact process exit value AND the emitted `error.type`. `#expect(throws:
    /// ExitCode.self)` on its own passes for any failure whatsoever, so a branch that started
    /// throwing `.notFound` where it owes `.validation` (exit 65 vs 64 — a discriminator agents
    /// actually branch on) would stay green. Asserting the pair is the exit-code matrix.
    func expectFailure(exit: Int32, type: String,
                       sourceLocation: SourceLocation = SourceLocation(
                        fileID: #fileID, filePath: #filePath, line: #line, column: #column),
                       _ body: (CLIStreams) throws -> Void) throws {
        let (cliStreams, stdout) = streams()
        var thrown: Error?
        do { try Output.withStreams(cliStreams) { try body(cliStreams) } } catch { thrown = error }
        #expect((thrown as? ExitCode)?.rawValue == exit,
                "expected exit \(exit), got \(String(describing: thrown))",
                sourceLocation: sourceLocation)
        #expect((try errorPayload(from: stdout))["type"] as? String == type,
                sourceLocation: sourceLocation)
    }

    func event(id: String = "event-1", title: String = "apple-cli-test standup",
               calendar: EKCalendar, store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = "synthetic notes"
        event.location = "Conference Room"
        event.startDate = Date(timeIntervalSince1970: 1_784_116_800)
        event.endDate = Date(timeIntervalSince1970: 1_784_120_400)
        // No `availability` assignment: an unsaved EKCalendar reports no supported
        // availabilities, so EventKit silently discards the write and the row always reads back
        // `.notSupported`. `eventsReadAvailabilityFilter` asserts against that real value
        // instead of a setting that never sticks.
        event.timeZone = TimeZone(identifier: "UTC")
        return event
    }

    @Test("calendars list emits injected collections")
    func calendarsList() throws {
        let fake = FakeCalendarEventStore()
        let command = try CalendarsList.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        let data = try payload(from: stdout)
        let calendars = try #require(data["calendars"] as? [[String: Any]])
        #expect(calendars.map { $0["title"] as? String } == ["apple-cli-test calendar"])
        #expect(fake.requestedAccess.count == 1)
    }

    @Test("events read by id emits the mapped event")
    func eventsReadById() throws {
        let fake = FakeCalendarEventStore()
        let row = event(calendar: fake.collections[0], store: fake.ekStore)
        fake.eventsById["event-1"] = row
        let command = try EventsRead.parse(["--id", "event-1"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        let data = try payload(from: stdout)
        #expect(data["title"] as? String == "apple-cli-test standup")
        #expect(fake.requestedAccess.first?.1 == .read)
    }

    @Test("events read selects on --search alone, over title, notes, and location")
    func eventsReadSearchFilter() throws {
        // ONLY `--search` is passed, and the two rows differ ONLY in the searched text, so
        // nothing else can discriminate. (`--calendar` is covered separately by
        // `eventsReadForwardsResolvedWindowAndCalendars`: its filtering is EventKit's, not
        // ours, so at this tier the honest assertion is that the resolved set is forwarded.)
        let fake = FakeCalendarEventStore()
        let keep = event(id: "event-1", title: "apple-cli-test planning",
                         calendar: fake.collections[0], store: fake.ekStore)
        let drop = event(id: "event-2", title: "apple-cli-test other",
                         calendar: fake.collections[0], store: fake.ekStore)
        fake.eventRows = [drop, keep]
        let command = try EventsRead.parse([
            "--start", "2026-07-15T00:00:00Z",
            "--end", "2026-07-16T00:00:00Z",
            "--search", "plan",
        ])
        let (searchStreams, stdout) = streams()

        try Output.withStreams(searchStreams) {
            try command.run(storeFactory: { fake })
        }

        let data = try payload(from: stdout)
        let events = try #require(data["events"] as? [[String: Any]])
        #expect(events.count == 1)
        let first = try #require(events.first)
        #expect(first["title"] as? String == "apple-cli-test planning")

        // The other two searched fields, each on its own: the helper gives every row
        // `notes == "synthetic notes"` and `location == "Conference Room"`, so a term found
        // only there must still match, and an absent term must drop everything.
        for (term, expected) in [("synthetic", 2), ("conference", 2), ("absent-term", 0)] {
            let byField = try EventsRead.parse([
                "--start", "2026-07-15T00:00:00Z",
                "--end", "2026-07-16T00:00:00Z",
                "--search", term,
            ])
            let (fieldStreams, fieldOut) = streams()
            try Output.withStreams(fieldStreams) {
                try byField.run(storeFactory: { fake })
            }
            #expect((try payload(from: fieldOut)["events"] as? [[String: Any]])?.count == expected,
                    "--search '\(term)' should have matched \(expected) row(s)")
        }
    }

    @Test("events read forwards the resolved window and calendar set to the store")
    func eventsReadForwardsResolvedWindowAndCalendars() throws {
        // Window/calendar narrowing is EventKit's predicate, not ours — so what production owes
        // us is that it RESOLVES `--calendar` and hands the right window + set down. Explicit
        // instants (not bare dates) keep the expected bounds independent of the runner's zone:
        // a bare date floors to LOCAL midnight, which is what made two earlier window tests fail
        // at UTC+13/+14.
        let fake = FakeCalendarEventStore()
        let command = try EventsRead.parse([
            "--start", "2026-07-15T00:00:00Z",
            "--end", "2026-07-16T00:00:00Z",
            "--calendar", "apple-cli-test calendar",
        ])
        let (windowStreams, _) = streams()
        try Output.withStreams(windowStreams) {
            try command.run(storeFactory: { fake })
        }

        #expect(fake.eventsQueries.count == 1)
        let query = try #require(fake.eventsQueries.first)
        #expect(query.start == Date(timeIntervalSince1970: 1_784_073_600))   // 2026-07-15T00:00:00Z
        #expect(query.end == Date(timeIntervalSince1970: 1_784_160_000))     // 2026-07-16T00:00:00Z
        #expect(query.calendars?.count == 1)
        #expect(query.calendars?.first === fake.collections[0])

        // CAL-07: `--calendar ""` resolves to the DEFAULT calendar rather than 404ing.
        let empty = try EventsRead.parse(["--calendar", ""])
        let (emptyStreams, _) = streams()
        try Output.withStreams(emptyStreams) {
            try empty.run(storeFactory: { fake })
        }
        #expect(fake.eventsQueries.count == 2)
        #expect(fake.eventsQueries.last?.calendars?.first === fake.defaultCalendar)
    }

    @Test("events read selects on availability alone")
    func eventsReadAvailabilityFilter() throws {
        // Both rows carry the SAME availability (`.notSupported` — see the `event(…)` helper),
        // so nothing but the availability filter can discriminate: the matching value must keep
        // both rows and a non-matching value must drop both. `--search` is deliberately absent.
        //
        // KNOWN LIMITATION (review L2): the value that discriminates here is `not-supported`,
        // which `EKEnum.availability(from:)` accepts but the flag's own help text and error
        // message advertise as invalid. It is the only value REACHABLE at this tier — an
        // unsaved `EKCalendar` supports no availabilities, so EventKit silently discards any
        // `busy`/`free`/`tentative`/`unavailable` write and the row always reads back
        // `.notSupported`. The four user-facing values are therefore covered on the filter's
        // reject path (below, `busy` matches nothing) but not on its accept path; a saved
        // calendar with real `supportedEventAvailabilities` is a live-tier fixture.
        let fake = FakeCalendarEventStore()
        fake.eventRows = [
            event(id: "event-1", title: "apple-cli-test planning",
                  calendar: fake.collections[0], store: fake.ekStore),
            event(id: "event-2", title: "apple-cli-test other",
                  calendar: fake.collections[0], store: fake.ekStore),
        ]
        #expect(fake.eventRows.allSatisfy { $0.availability == .notSupported })

        let matching = try EventsRead.parse([
            "--start", "2026-07-15T00:00:00Z", "--end", "2026-07-16T00:00:00Z",
            "--availability", "not-supported",
        ])
        let (matchStreams, matchOut) = streams()
        try Output.withStreams(matchStreams) {
            try matching.run(storeFactory: { fake })
        }
        let matched = try #require(try payload(from: matchOut)["events"] as? [[String: Any]])
        #expect(matched.count == 2)
        #expect(matched.allSatisfy { $0["availability"] as? String == "not-supported" })

        let nonMatching = try EventsRead.parse([
            "--start", "2026-07-15T00:00:00Z", "--end", "2026-07-16T00:00:00Z",
            "--availability", "busy",
        ])
        let (busyStreams, busyOut) = streams()
        try Output.withStreams(busyStreams) {
            try nonMatching.run(storeFactory: { fake })
        }
        #expect((try payload(from: busyOut)["events"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("events create executes through the injected store")
    func eventsCreateExecute() throws {
        let fake = FakeCalendarEventStore()
        let command = try EventsCreate.parse([
            "--title", "apple-cli-test launch",
            "--start", "2026-07-15T09:00:00Z",
            "--end", "2026-07-15T10:00:00Z",
            "--target-calendar", "apple-cli-test calendar",
            "--availability", "free",
            "--note", "synthetic",
            "--location", "Room A",
            "--url", "https://example.com/event",
            "--alarm", "15m",
            "--recurrence", "freq=daily;count=2",
            "--geo-lat", "12.5",
            "--geo-lon=-34.25",   // `=` form: a bare "-34.25" would parse as a flag
            "--geo-radius", "150",
            "--geo-title", "Office",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        #expect(fake.saved.count == 1)
        #expect(fake.saved[0].0.title == "apple-cli-test launch")
        #expect(fake.saved[0].0.alarms?.count == 1)
        #expect(fake.saved[0].0.recurrenceRules?.count == 1)
        // The whole point of `commit:` being explicit at every call site: a create that does not
        // commit does not persist, and the fake records the flag, so assert it.
        #expect(fake.saved[0].2 == true)
        #expect(fake.saved[0].1 == .thisEvent)
        #expect(fake.saved[0].0.calendar === fake.collections[0])
        #expect(fake.saved[0].0.notes == "synthetic")
        #expect(fake.saved[0].0.url?.absoluteString == "https://example.com/event")
        // MEASURED, not assumed: EventKit couples the two location surfaces — assigning
        // `structuredLocation` (done after `location` in `EventsCreate.run`) overwrites the
        // plain `location` with the structured title, so `--location "Room A"` combined with
        // `--geo-title Office` persists "Office". Pre-existing behavior inherited from
        // EventKit itself, pinned here so a reordering of those two assignments is visible.
        #expect(fake.saved[0].0.location == "Office")
        // `--geo-*` reaches EventKit through `ReadMapping.ekStructuredLocation` — previously
        // only ever exercised on the live path.
        let structured = try #require(fake.saved[0].0.structuredLocation)
        #expect(structured.title == "Office")
        #expect(structured.radius == 150)
        #expect(abs((structured.geoLocation?.coordinate.latitude ?? 0) - 12.5) < 1e-9)
        // `--availability free` is passed but NOT asserted on the saved object: an unsaved
        // EKCalendar reports no supported availabilities, so EventKit discards the write (same
        // fixture constraint documented on `eventsReadAvailabilityFilter`). What IS assertable
        // here is that the value was accepted rather than rejected — the command reached `save`.
        let data = try payload(from: stdout)
        #expect(data["dry_run"] as? Bool == false)
    }

    /// PRE-EXISTING PRODUCT BEHAVIOR, documented — NOT introduced by this coverage lane and
    /// NOT changed by it. `EKEnum.availability(from:)` (`Sources/EventKitCore/Mapping.swift:32`)
    /// accepts `not-supported` / `notsupported`, and `events create` / `events update` validate
    /// through that same shared parser (`EventsCommand.swift:146,186,249,315`) even though both
    /// flags' help text and rejection message advertise only `busy|free|tentative|unavailable`.
    /// `EKEventAvailability.notSupported` is a READ-only state, so a write path should not take
    /// it. Verified present verbatim at `git show HEAD:Sources/EventKitCore/Mapping.swift` and
    /// `HEAD:Sources/CalendarKit/EventsCommand.swift`, so tightening it is a parity/contract
    /// change (a value that exits 0 today would start exiting 64) and belongs to a behavior
    /// change with its own release note — NOT to a coverage lane. KNOWN PARITY FOLLOW-UP: decide
    /// whether the write paths should use a write-specific parser that rejects `not-supported`.
    @Test("KNOWN FOLLOW-UP: write paths still accept the read-only 'not-supported' availability")
    func availabilityWritePathsAcceptNotSupported() throws {
        let fake = FakeCalendarEventStore()
        let create = try EventsCreate.parse([
            "--title", "apple-cli-test availability",
            "--start", "2026-07-15T09:00:00Z",
            "--end", "2026-07-15T10:00:00Z",
            "--availability", "not-supported",
        ])
        let (createStreams, _) = streams()
        try Output.withStreams(createStreams) {
            try create.run(storeFactory: { fake })
        }
        #expect(fake.saved.count == 1, "create currently ACCEPTS not-supported (documented, not endorsed)")

        let row = event(calendar: fake.collections[0], store: fake.ekStore)
        fake.eventsById["event-1"] = row
        let update = try EventsUpdate.parse(["--id", "event-1", "--availability", "notsupported"])
        let (updateStreams, _) = streams()
        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { fake })
        }
        #expect(fake.saved.count == 2, "update currently ACCEPTS notsupported (documented, not endorsed)")

        // The contrast that makes this a documented quirk rather than a blanket hole: a value
        // outside the parser's set really is rejected, with the advertised exit code and type.
        let rejected = try EventsCreate.parse([
            "--title", "apple-cli-test availability",
            "--start", "2026-07-15T09:00:00Z",
            "--end", "2026-07-15T10:00:00Z",
            "--availability", "away",
        ])
        let (rejectedStreams, rejectedOut) = streams()
        #expect(throws: ExitCode(AppleExit.usage)) {
            try Output.withStreams(rejectedStreams) {
                try rejected.run(storeFactory: { fake })
            }
        }
        #expect((try errorPayload(from: rejectedOut))["type"] as? String == AppleErrorType.validation)
    }

    @Test("events update executes mutations and span through the injected store")
    func eventsUpdateExecute() throws {
        let fake = FakeCalendarEventStore()
        let row = event(calendar: fake.collections[0], store: fake.ekStore)
        fake.eventsById["event-1"] = row
        let command = try EventsUpdate.parse([
            "--id", "event-1",
            "--title", "apple-cli-test renamed",
            "--start", "2026-07-15T11:00:00Z",
            "--end", "2026-07-15T12:00:00Z",
            "--clear-alarms",
            "--clear-recurrence",
            "--span", "future-events",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        #expect(row.title == "apple-cli-test renamed")
        #expect(fake.saved.first?.1 == .futureEvents)
        #expect(fake.saved.first?.2 == true)
        #expect((try payload(from: stdout))["dry_run"] as? Bool == false)
    }

    @Test("events delete executes through the injected store")
    func eventsDeleteExecute() throws {
        let fake = FakeCalendarEventStore()
        let row = event(calendar: fake.collections[0], store: fake.ekStore)
        fake.eventsById["event-1"] = row
        let command = try EventsDelete.parse(["--id", "event-1", "--span", "all"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        #expect(fake.removed.count == 1)
        #expect(fake.removed[0].1 == .futureEvents)
        #expect(fake.removed[0].2 == true)
        let deleteData = try payload(from: stdout)
        #expect(deleteData["deleted"] as? Bool == true)
        // `all` and `future` resolve to the SAME EKSpan, so the emitted label is the only thing
        // that distinguishes them — and it is part of the JSON contract.
        #expect(deleteData["span"] as? String == "all")
    }

    @Test("events create dry-run emits preview without opening the store")
    func eventsCreateDryRun() throws {
        let fake = FakeCalendarEventStore()
        let command = try EventsCreate.parse([
            "--dry-run",
            "--title", "apple-cli-test preview",
            "--start", "2026-07-15",
            "--end", "2026-07-16",
            "--all-day",
            "--target-calendar", "apple-cli-test calendar",
            "--geo-title", "Office",
            "--alarm", "15m",
            "--recurrence", "freq=daily;count=2",
        ])
        let (streams, stdout) = streams()

        // The factory is what OPENS the store, and in production it is `{ EventStore() }` — so
        // "the dry run never touched the store" is only actually proved by the factory never
        // being CALLED. Inspecting the fake's method arrays cannot show that: the fake exists
        // before the run either way.
        var factoryCalls = 0
        try Output.withStreams(streams) {
            try command.run(storeFactory: { factoryCalls += 1; return fake })
        }

        let data = try payload(from: stdout)
        #expect(data["action"] as? String == "create")
        #expect(data["dry_run"] as? Bool == true)
        #expect(factoryCalls == 0)
        #expect(fake.requestedAccess.isEmpty)
        #expect(fake.saved.isEmpty)
    }

    @Test("events update and delete dry-run emit sandbox target deferral")
    func eventsMutatingDryRuns() throws {
        let fake = FakeCalendarEventStore()
        let update = try EventsUpdate.parse([
            "--dry-run",
            "--test-mode",
            "--id", "event-1",
            "--title", "apple-cli-test preview rename",
            "--clear-structured-location",
            "--clear-alarms",
            "--clear-recurrence",
            "--span", "this-event",
        ])
        let (updateStreams, updateOut) = streams()

        var factoryCalls = 0
        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { factoryCalls += 1; return fake })
        }

        let updateData = try payload(from: updateOut)
        #expect(updateData["action"] as? String == "update")
        #expect(updateData["dry_run"] as? Bool == true)
        #expect(updateData["sandbox_target_unchecked"] as? Bool == true)
        #expect(factoryCalls == 0)

        let delete = try EventsDelete.parse(["--dry-run", "--test-mode", "--id", "event-1", "--span", "future"])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { factoryCalls += 1; return fake })
        }

        let deleteData = try payload(from: deleteOut)
        #expect(deleteData["action"] as? String == "delete")
        #expect(deleteData["span"] as? String == "future-events")
        #expect(deleteData["sandbox_target_unchecked"] as? Bool == true)
        #expect(factoryCalls == 0)
        #expect(fake.requestedAccess.isEmpty)
        #expect(fake.saved.isEmpty)
        #expect(fake.removed.isEmpty)
    }

    @Test("calendar doctor health builder reports ready and blocked states")
    func calendarDoctorHealthBuilder() throws {
        let ready = CalendarDoctor.Health.build(
            calStatus: .authorized,
            remStatus: .denied,
            fullDiskAccess: true,
            notes: ["synthetic preflight note"])
        #expect(ready.calendar_ready)
        #expect(ready.full_disk_access)
        #expect(ready.notes == ["synthetic preflight note"])

        let blocked = CalendarDoctor.Health.build(
            calStatus: .denied,
            remStatus: .fullAccess,
            fullDiskAccess: false,
            notes: [])
        #expect(!blocked.calendar_ready)
        #expect(blocked.notes.count == 1)
    }

    @Test("calendar doctor run emits the injected authorization and preflight states")
    func calendarDoctorRun() throws {
        // Injected stand-ins only — the real `run()` would read host TCC status and open a
        // TCC-protected path via `Permissions.preflight()`, neither of which belongs in the
        // logic tier.
        let command = try CalendarDoctor.parse([])

        let (blockedStreams, blockedOut) = streams()
        var probed: [EventStore.Entity] = []
        try Output.withStreams(blockedStreams) {
            try command.run(
                authorizationStatus: { entity in
                    probed.append(entity)
                    return entity == .event ? .denied : .notDetermined
                },
                preflight: { Permissions.Preflight(full_disk_access: false,
                                                   notes: ["synthetic preflight note"]) })
        }
        let blocked = try payload(from: blockedOut)
        #expect(blocked["calendar_authorization"] as? String == "denied")
        #expect(blocked["reminders_authorization"] as? String == "not_determined")
        #expect(blocked["calendar_ready"] as? Bool == false)
        #expect(blocked["full_disk_access"] as? Bool == false)
        let blockedNotes = try #require(blocked["notes"] as? [String])
        #expect(blockedNotes.first == "synthetic preflight note")
        #expect(blockedNotes.count == 2)   // preflight note + the not-ready note
        #expect(probed == [.event, .reminder])

        let (readyStreams, readyOut) = streams()
        try Output.withStreams(readyStreams) {
            try command.run(authorizationStatus: { _ in .fullAccess },
                            preflight: { Permissions.Preflight(full_disk_access: true) })
        }
        let ready = try payload(from: readyOut)
        #expect(ready["calendar_authorization"] as? String == "full_access")
        #expect(ready["calendar_ready"] as? Bool == true)
        #expect(ready["full_disk_access"] as? Bool == true)
        #expect((ready["notes"] as? [String])?.isEmpty == true)
    }

    @Test("calendar event read reports missing defaults and bad filters with exact codes/types")
    func eventsReadErrorBranches() throws {
        let noDefault = FakeCalendarEventStore()
        noDefault.defaultCalendar = nil
        let emptyCalendar = try EventsRead.parse(["--calendar", ""])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try emptyCalendar.run(storeFactory: { noDefault })
        }

        let fake = FakeCalendarEventStore()
        let unknownCalendar = try EventsRead.parse(["--calendar", "apple-cli-test absent"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try unknownCalendar.run(storeFactory: { fake })
        }

        let badAvailability = try EventsRead.parse(["--availability", "away"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) { _ in
            try badAvailability.run(storeFactory: { fake })
        }

        let badAccount = try EventsRead.parse(["--account", "Example Account"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try badAccount.run(storeFactory: { fake })
        }

        let missingId = try EventsRead.parse(["--id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try missingId.run(storeFactory: { fake })
        }
    }

    @Test("calendar event writes report validation and not-found branches with exact codes/types")
    func eventsWriteErrorBranches() throws {
        let fake = FakeCalendarEventStore()
        let badRange = try EventsCreate.parse([
            "--title", "apple-cli-test invalid",
            "--start", "2026-07-16",
            "--end", "2026-07-15",
        ])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) { _ in
            try badRange.run(storeFactory: { fake })
        }

        // `--span all` is delete-only; update must reject it as BAD INPUT (64), not as a
        // missing event (65) — the two are one line apart in `resolveSpan` and the id here
        // does not exist either, so only the exact code distinguishes them.
        let badUpdateSpan = try EventsUpdate.parse(["--id", "event-1", "--span", "all"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) { _ in
            try badUpdateSpan.run(storeFactory: { fake })
        }

        let conflictingClears = try EventsUpdate.parse([
            "--id", "event-1", "--clear-alarms", "--alarm", "15m",
        ])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) { _ in
            try conflictingClears.run(storeFactory: { fake })
        }

        let missingUpdate = try EventsUpdate.parse(["--id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try missingUpdate.run(storeFactory: { fake })
        }

        let noDefault = FakeCalendarEventStore()
        noDefault.defaultCalendar = nil
        let noDefaultCreate = try EventsCreate.parse([
            "--title", "apple-cli-test no default",
            "--start", "2026-07-15",
            "--end", "2026-07-16",
        ])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try noDefaultCreate.run(storeFactory: { noDefault })
        }

        let row = event(calendar: noDefault.collections[0], store: noDefault.ekStore)
        noDefault.eventsById["event-1"] = row
        let noDefaultMove = try EventsUpdate.parse(["--id", "event-1", "--target-calendar", ""])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try noDefaultMove.run(storeFactory: { noDefault })
        }

        let unknownMove = try EventsUpdate.parse([
            "--id", "event-1", "--target-calendar", "apple-cli-test absent",
        ])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try unknownMove.run(storeFactory: { noDefault })
        }

        let badDeleteSpan = try EventsDelete.parse(["--id", "event-1", "--span", "later"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) { _ in
            try badDeleteSpan.run(storeFactory: { fake })
        }

        let missingDelete = try EventsDelete.parse(["--id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) { _ in
            try missingDelete.run(storeFactory: { fake })
        }

        // Nothing above may have reached a mutator: every one of these is a pre-save rejection.
        #expect(fake.saved.isEmpty)
        #expect(fake.removed.isEmpty)
        #expect(noDefault.saved.isEmpty)
    }
}
