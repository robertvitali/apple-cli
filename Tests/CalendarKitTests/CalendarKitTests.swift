import Testing
import Foundation
import AppleKit
import EventKitCore
@testable import CalendarKit

// Logic-tier tests for the Calendar command surface — pure flag/spec parsers, the read-window
// default, and the write guard. No EKEventStore / TCC.
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

@Suite("DateArg.windowBound")
struct WindowBoundTests {
    @Test("a bare date floors to start-of-day (midnight), matching the MCP bound")
    func bareFloorsToMidnight() throws {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let bound = try DateArg.windowBound("2026-07-15", calendar: cal)
        let comps = cal.dateComponents([.hour, .minute, .second], from: bound)
        #expect(comps.hour == 0 && comps.minute == 0 && comps.second == 0)
    }

    @Test("a timed value passes through unchanged")
    func timedUnchanged() throws {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let bound = try DateArg.windowBound("2026-07-15T09:30:00Z", calendar: cal)
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
