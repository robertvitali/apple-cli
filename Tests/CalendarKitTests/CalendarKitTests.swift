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

@Suite("CalendarWriteGuard")
struct WriteGuardTests {
    @Test("no execute → dry-run gate closed (false), never throws")
    func dryRun() throws {
        #expect(try CalendarWriteGuard.gateOpen(willExecute: false, testMode: false) == false)
        #expect(try CalendarWriteGuard.gateOpen(willExecute: false, testMode: true) == false)
    }

    @Test("execute without test-mode is rejected")
    func executeNeedsTestMode() {
        #expect(throws: AppleError.self) {
            _ = try CalendarWriteGuard.gateOpen(willExecute: true, testMode: false)
        }
    }

    @Test("execute + test-mode without APPLE_TEST_MODE is rejected (fail-closed)")
    func executeNeedsEnv() {
        // APPLE_TEST_MODE is not set in the test environment ⇒ TestMode.isEnabled == false.
        if !TestMode.isEnabled {
            #expect(throws: AppleError.self) {
                _ = try CalendarWriteGuard.gateOpen(willExecute: true, testMode: true)
            }
        }
    }

    @Test("requireLabeled rejects an unlabeled target (guards existing-event mutation)")
    func requireLabeledFailClosed() {
        // requireLabeled fails closed when APPLE_TEST_MODE is off OR the name lacks the prefix.
        #expect(throws: AppleError.self) { try CalendarWriteGuard.requireLabeled("Real Meeting") }
        #expect(throws: AppleError.self) { try CalendarWriteGuard.requireLabeled("") }
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
