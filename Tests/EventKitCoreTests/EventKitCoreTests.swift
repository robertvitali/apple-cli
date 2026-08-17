import Testing
import Foundation
import EventKit
import AppleKit
@testable import EventKitCore

// Logic-tier tests for the shared EventKit engine — NO EKEventStore / TCC required.
// EKRecurrenceRule, EKAlarm, and EKStructuredLocation are plain value objects constructible
// in-memory, so the EK⇄model round-trips run in CI without Calendar/Reminders permission.
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

    @Test("impossible calendar dates are rejected (isLenient = false)")
    func nonLenient() {
        #expect(throws: DateParsing.ParseError.self) { _ = try DateParsing.parse("2026-13-45") }
        #expect(throws: DateParsing.ParseError.self) { _ = try DateParsing.parse("2026-02-30 10:00:00") }
    }

    @Test("bareDateString round-trips a parsed bare date in UTC")
    func bareRoundTrip() throws {
        let utc = TimeZone(identifier: "UTC")!
        let parsed = try DateParsing.parse("2026-07-15", timeZone: utc)
        #expect(DateParsing.bareDateString(parsed.date, timeZone: utc) == "2026-07-15")
    }

    @Test("components() yields date-only vs timed granularity for reminder due/start writes")
    func componentsBridge() throws {
        let utc = TimeZone(identifier: "UTC")!
        let bare = try DateParsing.parse("2026-07-15", timeZone: utc)
        let dateOnly = DateParsing.components(from: bare.date, dateOnly: bare.isDateOnly, timeZone: utc)
        #expect(dateOnly.year == 2026 && dateOnly.month == 7 && dateOnly.day == 15)
        #expect(dateOnly.hour == nil) // no time components for an all-day/date-only value

        let timed = try DateParsing.parse("2026-07-15 09:30:00", timeZone: utc)
        let tc = DateParsing.components(from: timed.date, dateOnly: timed.isDateOnly, timeZone: utc)
        #expect(tc.hour == 9 && tc.minute == 30 && tc.second == 0)
        #expect(tc.timeZone == utc)
    }
}

// MARK: - Recurrence round-trips + validation

@Suite("RecurrenceMapping")
struct RecurrenceMappingTests {
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

    @Test("occurrence count survives and wins over end date")
    func occurrenceCount() throws {
        let ek = try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "monthly", interval: 1, occurrence_count: 5))
        let back = RecurrenceMapping.rule(from: ek)
        #expect(back.occurrence_count == 5)
        #expect(back.end_date == nil)
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

    @Test("non-finite doubles are coerced so encoding stays total")
    func nonFinite() {
        #expect(finite(Double.nan) == nil)
        #expect(finite(Double.infinity) == nil)
        #expect(finite(1.5) == 1.5)
        #expect(finiteOrZero(Double.nan) == 0)
        #expect(finiteOrZero(42) == 42)
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

// MARK: - Geofence spec (shared Calendar/Reminders parser — CAL-04 / REM-05)

@Suite("GeofenceSpec")
struct GeofenceSpecTests {

    /// CAL-04's headline case: a street address IS a comma-bearing title, and the old parser
    /// kept only its LAST fragment.
    @Test("a comma-bearing title survives verbatim, spacing intact")
    func commaTitle() throws {
        let g = try GeofenceSpec.parse("40.0,-74.0,100,enter,742 Evergreen Terrace, Springfield, OR 97475")
        #expect(g.radius == 100)
        #expect(g.proximity == "enter")
        #expect(g.title == "742 Evergreen Terrace, Springfield, OR 97475")
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
            due_date: Date(timeIntervalSince1970: 1_784_116_800), priority: 5, has_recurrence: true,
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
