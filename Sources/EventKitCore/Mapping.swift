import Foundation
import EventKit
import CoreLocation
import CoreGraphics
import AppleKit

// EventKit ⇄ model mapping. The pure enum/recurrence/alarm mappers here are unit-testable
// WITHOUT an EKEventStore (no TCC): they operate on values constructed in-memory. The
// `from EKEvent/EKReminder/EKCalendar` readers require live objects and run in the live tier.
//
// Write mappers throw `AppleError.validation` (exit 64) directly — NOT a private error type —
// so a domain command that builds an EKObject inside `runGuarded` BEFORE `store.save` surfaces
// a proper `validation_error`/64 instead of hitting the generic catch (`unknown`/70). Enum
// string VALUES here are verified verbatim against the reference EventKitCLI.swift @1.4.0.

// MARK: - Enum string mappings (pure, testable)

public enum EKEnum {

    // Availability (EKEventAvailability) ⇄ string
    public static func availabilityString(_ a: EKEventAvailability) -> String {
        switch a {
        case .notSupported: return "not-supported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "not-supported"
        }
    }

    public static func availability(from s: String) -> EKEventAvailability? {
        switch s.lowercased() {
        case "busy": return .busy
        case "free": return .free
        case "tentative": return .tentative
        case "unavailable": return .unavailable
        case "not-supported", "notsupported": return .notSupported
        default: return nil
        }
    }

    // Status (EKEventStatus) → string (read-only)
    public static func statusString(_ s: EKEventStatus) -> String {
        switch s {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    // Participant status / role / type → string (read-only)
    public static func participantStatusString(_ s: EKParticipantStatus) -> String {
        switch s {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in-process"
        @unknown default: return "unknown"
        }
    }

    public static func participantRoleString(_ r: EKParticipantRole) -> String {
        switch r {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "non-participant"
        @unknown default: return "unknown"
        }
    }

    public static func participantTypeString(_ t: EKParticipantType) -> String {
        switch t {
        case .unknown: return "unknown"
        case .person: return "person"
        case .room: return "room"
        case .resource: return "resource"
        case .group: return "group"
        @unknown default: return "unknown"
        }
    }

    // Calendar type (EKCalendarType) → string
    public static func calendarTypeString(_ t: EKCalendarType) -> String {
        switch t {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    // Source type (EKSourceType) → string (account type). Verbatim from EventKitCLI.swift @1.4.0.
    public static func sourceTypeString(_ t: EKSourceType) -> String {
        switch t {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    // Alarm type (EKAlarmType) → string (read-only, EventKit-computed)
    public static func alarmTypeString(_ t: EKAlarmType) -> String {
        switch t {
        case .display: return "display"
        case .audio: return "audio"
        case .procedure: return "procedure"
        case .email: return "email"
        @unknown default: return "display"
        }
    }

    // Proximity (EKAlarmProximity) ⇄ string
    public static func proximityString(_ p: EKAlarmProximity) -> String {
        switch p {
        case .none: return "none"
        case .enter: return "enter"
        case .leave: return "leave"
        @unknown default: return "none"
        }
    }

    /// Parse a proximity for a WRITE. Mirrors the MCP: "leave"/"depart"/"exit" → leave, and
    /// anything else (including empty/unknown) → enter (the MCP's default for a geofence write).
    public static func proximity(from s: String) -> EKAlarmProximity {
        switch s.lowercased() {
        case "leave", "depart", "exit": return .leave
        default: return .enter
        }
    }

    // Frequency (EKRecurrenceFrequency) ⇄ string
    public static func frequencyString(_ f: EKRecurrenceFrequency) -> String {
        switch f {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "daily"
        }
    }

    public static func frequency(from s: String) -> EKRecurrenceFrequency? {
        switch s.lowercased() {
        case "daily": return .daily
        case "weekly": return .weekly
        case "monthly": return .monthly
        case "yearly": return .yearly
        default: return nil
        }
    }

    // Span (EKSpan) ⇄ string. The MCP accepts "this-event"/"future-events"; the CLI also
    // accepts "all" (delete-whole-series) at the command layer — EKSpan itself has no "all",
    // so that superset is handled above this mapper.
    public static func span(from s: String) -> EKSpan? {
        switch s.lowercased() {
        case "this-event", "this", "thisevent": return .thisEvent
        case "future-events", "future", "futureevents": return .futureEvents
        default: return nil
        }
    }

    // Priority word ⇄ int (0 none, 1 high, 5 medium, 9 low — the MCP convention). EventKit
    // stores 0…9 raw; these help the Reminders lane accept/emit the word form as a superset.
    public static func priorityInt(from word: String) -> Int? {
        switch word.lowercased() {
        case "none", "0": return 0
        case "high", "1": return 1
        case "medium", "5": return 5
        case "low", "9": return 9
        default: return Int(word)
        }
    }

    public static func priorityWord(from value: Int) -> String {
        switch value {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }
}

// MARK: - Recurrence mapping

public enum RecurrenceMapping {

    /// EKRecurrenceRule → model (read).
    public static func rule(from ek: EKRecurrenceRule) -> RecurrenceRule {
        var endDate: Date?
        var count: Int?
        if let end = ek.recurrenceEnd {
            if end.occurrenceCount > 0 {
                count = end.occurrenceCount
            } else {
                endDate = end.endDate
            }
        }
        let dow = ek.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue }
        let dom = ek.daysOfTheMonth?.map { $0.intValue }
        let moy = ek.monthsOfTheYear?.map { $0.intValue }
        let woy = ek.weeksOfTheYear?.map { $0.intValue }
        let doy = ek.daysOfTheYear?.map { $0.intValue }
        let setpos = ek.setPositions?.map { $0.intValue }
        return RecurrenceRule(
            frequency: EKEnum.frequencyString(ek.frequency),
            interval: ek.interval,
            end_date: endDate,
            occurrence_count: count,
            days_of_week: (dow?.isEmpty == false) ? dow : nil,
            days_of_month: (dom?.isEmpty == false) ? dom : nil,
            months_of_year: (moy?.isEmpty == false) ? moy : nil,
            weeks_of_year: (woy?.isEmpty == false) ? woy : nil,
            days_of_year: (doy?.isEmpty == false) ? doy : nil,
            set_positions: (setpos?.isEmpty == false) ? setpos : nil
        )
    }

    /// model → EKRecurrenceRule (write). Throws `AppleError.validation` on an unknown frequency,
    /// a non-positive interval, or any out-of-range by-part value (a strict superset REJECTS
    /// input the MCP would silently corrupt rather than swallowing it).
    public static func ekRule(from m: RecurrenceRule) throws -> EKRecurrenceRule {
        guard let freq = EKEnum.frequency(from: m.frequency) else {
            throw AppleError.validation("recurrence frequency '\(m.frequency)' (use daily|weekly|monthly|yearly)")
        }
        guard m.interval >= 1 else {
            throw AppleError.validation("recurrence interval must be >= 1 (got \(m.interval))")
        }
        var end: EKRecurrenceEnd?
        if let c = m.occurrence_count, c > 0 {
            end = EKRecurrenceEnd(occurrenceCount: c)
        } else if let d = m.end_date {
            end = EKRecurrenceEnd(end: d)
        }

        let daysOfWeek = try m.days_of_week.map { days -> [EKRecurrenceDayOfWeek] in
            try days.map { n in
                // MUST range-check FIRST: EKWeekday(rawValue:) is an imported Obj-C enum that
                // accepts ANY Int (does not fail), and +[EKRecurrenceDayOfWeek dayOfWeek:]
                // throws an UNCATCHABLE NSException ("Invalid day number") on out-of-range input.
                guard (1...7).contains(n), let wd = EKWeekday(rawValue: n) else {
                    throw AppleError.validation("day_of_week \(n) out of range (1=Sun … 7=Sat)")
                }
                return EKRecurrenceDayOfWeek(wd)
            }
        }
        let daysOfMonth = try validatedNumbers(m.days_of_month, name: "day_of_month") { (1...31).contains($0) || (-31 ... -1).contains($0) }
        let monthsOfYear = try validatedNumbers(m.months_of_year, name: "month_of_year") { (1...12).contains($0) }
        let weeksOfYear = try validatedNumbers(m.weeks_of_year, name: "week_of_year") { (1...53).contains($0) || (-53 ... -1).contains($0) }
        let daysOfYear = try validatedNumbers(m.days_of_year, name: "day_of_year") { (1...366).contains($0) || (-366 ... -1).contains($0) }
        let setPositions = try validatedNumbers(m.set_positions, name: "set_position") { $0 != 0 }

        // Use the rich initializer only when a by-part array is present; otherwise the simple one.
        if (daysOfWeek?.isEmpty == false) || daysOfMonth != nil || monthsOfYear != nil
            || weeksOfYear != nil || daysOfYear != nil || setPositions != nil {
            return EKRecurrenceRule(
                recurrenceWith: freq,
                interval: m.interval,
                daysOfTheWeek: (daysOfWeek?.isEmpty == false) ? daysOfWeek : nil,
                daysOfTheMonth: daysOfMonth,
                monthsOfTheYear: monthsOfYear,
                weeksOfTheYear: weeksOfYear,
                daysOfTheYear: daysOfYear,
                setPositions: setPositions,
                end: end
            )
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: m.interval, end: end)
    }

    private static func validatedNumbers(_ ints: [Int]?, name: String, allowed: (Int) -> Bool) throws -> [NSNumber]? {
        guard let ints, !ints.isEmpty else { return nil }
        for n in ints where !allowed(n) {
            throw AppleError.validation("\(name) value \(n) is out of range")
        }
        return ints.map { NSNumber(value: $0) }
    }
}

// MARK: - Alarm mapping

public enum AlarmMapping {

    /// EKAlarm → model (read). Non-finite coordinates are coerced to nil / 0 so one malformed
    /// geofence can't make the whole JSON envelope an opaque encode failure.
    public static func alarm(from ek: EKAlarm) -> Alarm {
        var trigger: LocationTrigger?
        if let loc = ek.structuredLocation {
            trigger = LocationTrigger(
                title: loc.title,
                latitude: finite(loc.geoLocation?.coordinate.latitude),
                longitude: finite(loc.geoLocation?.coordinate.longitude),
                radius: finiteOrZero(loc.radius),
                proximity: EKEnum.proximityString(ek.proximity)
            )
        }
        return Alarm(
            relative_offset: (ek.absoluteDate == nil && trigger == nil) ? finite(ek.relativeOffset) : nil,
            absolute_date: ek.absoluteDate,
            type: EKEnum.alarmTypeString(ek.type),
            location_trigger: trigger
        )
    }

    /// model → EKAlarm (write). Exactly one trigger kind must be set.
    public static func ekAlarm(from m: Alarm) throws -> EKAlarm {
        if let trigger = m.location_trigger {
            let alarm = EKAlarm()
            let loc = EKStructuredLocation(title: trigger.title ?? "")
            if let lat = trigger.latitude, let lon = trigger.longitude {
                loc.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            loc.radius = trigger.radius
            alarm.structuredLocation = loc
            alarm.proximity = EKEnum.proximity(from: trigger.proximity)
            return alarm
        }
        if let abs = m.absolute_date {
            return EKAlarm(absoluteDate: abs)
        }
        if let off = m.relative_offset {
            return EKAlarm(relativeOffset: off)
        }
        throw AppleError.validation("alarm needs exactly one of relative_offset, absolute_date, or location_trigger")
    }
}

// MARK: - Participant / location / calendar readers (live-tier)

public enum ReadMapping {

    public static func participant(from p: EKParticipant) -> Participant {
        var email: String?
        let urlStr = p.url.absoluteString
        if urlStr.lowercased().hasPrefix("mailto:") {
            email = String(urlStr.dropFirst("mailto:".count))
        }
        return Participant(
            name: p.name,
            email: email,
            url: urlStr,
            status: EKEnum.participantStatusString(p.participantStatus),
            role: EKEnum.participantRoleString(p.participantRole),
            type: EKEnum.participantTypeString(p.participantType),
            is_current_user: p.isCurrentUser
        )
    }

    public static func structuredLocation(from loc: EKStructuredLocation) -> StructuredLocation {
        StructuredLocation(
            title: loc.title,
            latitude: finite(loc.geoLocation?.coordinate.latitude),
            longitude: finite(loc.geoLocation?.coordinate.longitude),
            radius: finiteOrZero(loc.radius)
        )
    }

    /// model → EKStructuredLocation (event structured-location WRITE). Shared so both the
    /// Calendar structured-location and any Reminders location write build it the same way.
    public static func ekStructuredLocation(from m: StructuredLocation) -> EKStructuredLocation {
        let loc = EKStructuredLocation(title: m.title ?? "")
        if let lat = m.latitude, let lon = m.longitude {
            loc.geoLocation = CLLocation(latitude: lat, longitude: lon)
        }
        loc.radius = m.radius
        return loc
    }

    public static func collection(from cal: EKCalendar) -> CalendarCollection {
        CalendarCollection(
            id: cal.calendarIdentifier,
            title: cal.title,
            account: cal.source?.title,
            account_type: cal.source.map { EKEnum.sourceTypeString($0.sourceType) },
            color: hexColor(from: cal.cgColor),
            type: EKEnum.calendarTypeString(cal.type),
            allows_modifications: cal.allowsContentModifications,
            is_immutable: cal.isImmutable,
            is_subscribed: cal.isSubscribed
        )
    }

    public static func reminderList(from cal: EKCalendar) -> ReminderList {
        ReminderList(
            id: cal.calendarIdentifier,
            title: cal.title,
            account: cal.source?.title,
            account_type: cal.source.map { EKEnum.sourceTypeString($0.sourceType) },
            color: hexColor(from: cal.cgColor),
            allows_modifications: cal.allowsContentModifications
        )
    }

    /// CGColor → `#RRGGBB`. Converts to sRGB first so non-RGB spaces (gray) still resolve.
    public static func hexColor(from cg: CGColor?) -> String? {
        guard let cg else { return nil }
        var color = cg
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cg.converted(to: srgb, intent: .defaultIntent, options: nil) {
            color = converted
        }
        guard let comps = color.components, !comps.isEmpty else { return nil }
        let r: CGFloat, g: CGFloat, b: CGFloat
        if comps.count >= 3 {
            r = comps[0]; g = comps[1]; b = comps[2]
        } else if comps.count == 2 {
            r = comps[0]; g = comps[0]; b = comps[0] // grayscale: [white, alpha]
        } else {
            return nil
        }
        func clamp(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// `#RRGGBB` → CGColor (list/calendar color WRITE). Mirrors the MCP's `CGColor.fromHex`.
    /// Accepts an optional leading `#`; returns nil on a malformed hex.
    public static func cgColor(fromHex hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Event / reminder readers (live-tier)

public enum EventMapping {

    public static func event(from e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: e.eventIdentifier ?? e.calendarItemIdentifier,
            title: e.title,
            notes: e.notes,
            location: e.location,
            url: e.url?.absoluteString,
            start_date: e.startDate,
            end_date: e.endDate,
            is_all_day: e.isAllDay,
            availability: EKEnum.availabilityString(e.availability),
            status: EKEnum.statusString(e.status),
            calendar: e.calendar?.title,
            calendar_id: e.calendar?.calendarIdentifier,
            account: e.calendar?.source?.title,
            time_zone: e.timeZone?.identifier,
            is_detached: e.isDetached,
            has_recurrence: e.hasRecurrenceRules,
            occurrence_date: e.occurrenceDate,
            external_id: e.calendarItemExternalIdentifier,
            organizer: e.organizer.map { ReadMapping.participant(from: $0) },
            attendees: e.attendees?.map { ReadMapping.participant(from: $0) },
            recurrence_rules: e.recurrenceRules?.map { RecurrenceMapping.rule(from: $0) },
            alarms: e.alarms?.map { AlarmMapping.alarm(from: $0) },
            structured_location: e.structuredLocation.map { ReadMapping.structuredLocation(from: $0) },
            last_modified: e.lastModifiedDate,
            creation_date: e.creationDate
        )
    }
}

public enum ReminderMapping {

    public static func reminder(from r: EKReminder) -> Reminder {
        let due = r.dueDateComponents?.date
        let start = r.startDateComponents?.date
        // Convenience: the first location-based alarm (mirrors the MCP's `locationTrigger`).
        let locationTrigger: LocationTrigger? = r.alarms?
            .first(where: { $0.structuredLocation != nil })
            .map { AlarmMapping.alarm(from: $0).location_trigger } ?? nil
        return Reminder(
            id: r.calendarItemIdentifier,
            title: r.title,
            notes: r.notes,
            url: r.url?.absoluteString,
            location: r.location,
            list: r.calendar?.title,
            list_id: r.calendar?.calendarIdentifier,
            account: r.calendar?.source?.title,
            time_zone: r.timeZone?.identifier,
            external_id: r.calendarItemExternalIdentifier,
            completed: r.isCompleted,
            completion_date: r.completionDate,
            due_date: due,
            start_date: start,
            priority: r.priority,
            has_recurrence: r.hasRecurrenceRules,
            recurrence_rules: r.recurrenceRules?.map { RecurrenceMapping.rule(from: $0) },
            alarms: r.alarms?.map { AlarmMapping.alarm(from: $0) },
            location_trigger: locationTrigger,
            tags: nil,        // populated by RemindersKit from the notes [#tag] markers — see Models.swift
            parent_id: nil,   // reserved (no native parent linkage in public EventKit); subtasks live in notes
            last_modified: r.lastModifiedDate,
            creation_date: r.creationDate
        )
    }
}

// MARK: - Non-finite Double coercion (keeps the JSON envelope total)

/// Return the value only if finite; a NaN/Inf coordinate becomes nil rather than aborting the
/// whole encode (JSONEncoder's default float strategy throws on non-finite).
func finite(_ d: Double?) -> Double? {
    guard let d, d.isFinite else { return nil }
    return d
}

func finiteOrZero(_ d: Double) -> Double { d.isFinite ? d : 0 }
