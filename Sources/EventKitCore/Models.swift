import Foundation

// Shared, Encodable model types for the Calendar and Reminders domains. These are the
// JSON-wire shapes both `apple calendar …` and `apple reminders …` emit, so field names
// ARE the wire keys (snake_case, per docs/DESIGN.md — the Output encoder does NO key-case
// conversion). Dates encode as ISO-8601 (Output sets `.iso8601`). Optionals that are `nil`
// are omitted by JSONEncoder, keeping payloads compact; consumers are tolerant readers.
//
// These shapes read the FULL apple-events MCP surface (verified field-by-field against the
// reference EventKitCLI.swift @1.4.0): events carry attendees/organizer/status/availability/
// recurrence/alarms/structuredLocation/occurrenceDate/externalId; reminders carry due/start/
// priority/url/location/timeZone/locationTrigger/recurrence/alarms/externalId. The apple-cli
// contract re-cases the MCP's camelCase keys to snake_case by design — semantic parity, not
// byte-identical keys — AND, honestly (REM-13), four keys are RENAMED beyond re-casing:
// `Reminder.completed` (MCP `isCompleted` — re-casing would give `is_completed`),
// `Reminder.last_modified` / `CalendarEvent.last_modified` (MCP `lastModifiedDate` — would be
// `last_modified_date`), `Alarm.type` (MCP `alarmType` — would be `alarm_type`), and
// `Subtask.completed` (same as Reminder's). These shipped in the first cut and are load-bearing
// wire keys now; renaming them is a MAJOR bump, so they are documented instead of "fixed".
// Enum VALUES (availability/status/participant/source strings) DO match the MCP verbatim so a
// consumer keying on a value survives the swap.
//
// STABILITY: RemindersKit imports these unchanged. All optional init params carry `= nil`
// defaults so an additive field stays source-compatible (a schema-MINOR change per the
// versioning policy). Do NOT rename/retype an existing field without a coordinated bump.

// MARK: - Calendar collection (EKCalendar for events; `calendar_calendars`)

/// A calendar collection (the container an event lives in). MCP parity: id/title/account/
/// account_type; plus color + mutability + type as supersets.
public struct CalendarCollection: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let account: String?
    public let account_type: String?
    public let color: String?
    public let type: String
    public let allows_modifications: Bool
    public let is_immutable: Bool
    public let is_subscribed: Bool

    public init(
        id: String, title: String, account: String? = nil, account_type: String? = nil,
        color: String? = nil, type: String, allows_modifications: Bool,
        is_immutable: Bool, is_subscribed: Bool
    ) {
        self.id = id
        self.title = title
        self.account = account
        self.account_type = account_type
        self.color = color
        self.type = type
        self.allows_modifications = allows_modifications
        self.is_immutable = is_immutable
        self.is_subscribed = is_subscribed
    }
}

// MARK: - Reminder list (EKCalendar for reminders; `reminders_lists`)

/// A reminder list (the EKCalendar of `.reminder` entity type). Used by the Reminders lane;
/// lives here because both domains share the EKCalendar mapping. MCP parity: id/title/color.
public struct ReminderList: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let account: String?
    public let account_type: String?
    public let color: String?
    public let allows_modifications: Bool

    public init(
        id: String, title: String, account: String? = nil, account_type: String? = nil,
        color: String? = nil, allows_modifications: Bool
    ) {
        self.id = id
        self.title = title
        self.account = account
        self.account_type = account_type
        self.color = color
        self.allows_modifications = allows_modifications
    }
}

// MARK: - Participant (attendee / organizer; READ-only — EventKit cannot write attendees)

public struct Participant: Encodable, Sendable, Equatable {
    public let name: String?
    public let email: String?
    public let url: String?
    public let status: String
    public let role: String
    public let type: String
    public let is_current_user: Bool

    public init(
        name: String? = nil, email: String? = nil, url: String? = nil, status: String,
        role: String, type: String, is_current_user: Bool
    ) {
        self.name = name
        self.email = email
        self.url = url
        self.status = status
        self.role = role
        self.type = type
        self.is_current_user = is_current_user
    }
}

// MARK: - Recurrence

/// A recurrence rule. Round-trips with EKRecurrenceRule (see Mapping.swift). `days_of_week`
/// uses 1=Sunday … 7=Saturday (EKWeekday / the MCP convention, verified against the reference
/// EventKitCLI.swift @1.4.0).
public struct RecurrenceRule: Encodable, Sendable, Equatable {
    public let frequency: String            // daily | weekly | monthly | yearly
    public let interval: Int
    public let end_date: Date?
    public let occurrence_count: Int?
    public let days_of_week: [Int]?          // 1=Sun … 7=Sat
    public let days_of_month: [Int]?         // 1…31 (or -1…-31 counting from month end)
    public let months_of_year: [Int]?        // 1…12
    public let weeks_of_year: [Int]?
    public let days_of_year: [Int]?
    public let set_positions: [Int]?

    public init(
        frequency: String, interval: Int, end_date: Date? = nil, occurrence_count: Int? = nil,
        days_of_week: [Int]? = nil, days_of_month: [Int]? = nil, months_of_year: [Int]? = nil,
        weeks_of_year: [Int]? = nil, days_of_year: [Int]? = nil, set_positions: [Int]? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.end_date = end_date
        self.occurrence_count = occurrence_count
        self.days_of_week = days_of_week
        self.days_of_month = days_of_month
        self.months_of_year = months_of_year
        self.weeks_of_year = weeks_of_year
        self.days_of_year = days_of_year
        self.set_positions = set_positions
    }
}

// MARK: - Geofence / structured location

/// A geofence trigger for a location-based alarm (EKAlarm.structuredLocation + proximity).
public struct LocationTrigger: Encodable, Sendable, Equatable {
    public let title: String?
    public let latitude: Double?
    public let longitude: Double?
    public let radius: Double
    public let proximity: String            // enter | leave | none

    public init(title: String? = nil, latitude: Double? = nil, longitude: Double? = nil, radius: Double, proximity: String) {
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.proximity = proximity
    }
}

/// A structured (geo) location on an event (EKEvent.structuredLocation).
public struct StructuredLocation: Encodable, Sendable, Equatable {
    public let title: String?
    public let latitude: Double?
    public let longitude: Double?
    public let radius: Double

    public init(title: String? = nil, latitude: Double? = nil, longitude: Double? = nil, radius: Double) {
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

// MARK: - Alarm

/// An alarm (EKAlarm). Exactly one trigger kind is set on write (relative offset, absolute
/// date, or geofence); on read all populated fields are surfaced. `type` is EventKit-computed
/// and READ-only (display/audio/procedure/email).
public struct Alarm: Encodable, Sendable, Equatable {
    public let relative_offset: Double?      // seconds; negative = before start
    /// Wire value: the oracle's `formatEventDate` rendering in the ITEM's zone (the sixth date
    /// site CAL-03's first pass missed — `alarms[].absoluteDate` goes through the same
    /// formatter as the event dates, always timed).
    public let absolute_date: String?
    public let type: String?                 // display | audio | procedure | email (read-only)
    public let location_trigger: LocationTrigger?
    /// The parsed instant for WRITE paths (`ekAlarm(from:)`); NOT encoded — the wire carries
    /// the pre-formatted `absolute_date` above.
    public let absoluteDateValue: Date?

    enum CodingKeys: String, CodingKey {
        case relative_offset, absolute_date, type, location_trigger
    }

    public init(
        relative_offset: Double? = nil, absolute_date: String? = nil,
        type: String? = nil, location_trigger: LocationTrigger? = nil,
        absoluteDateValue: Date? = nil
    ) {
        self.relative_offset = relative_offset
        self.absolute_date = absolute_date
        self.type = type
        self.location_trigger = location_trigger
        self.absoluteDateValue = absoluteDateValue
    }
}

// MARK: - Calendar event

/// A calendar event (EKEvent), reading the full MCP surface plus extras. Attendees/organizer/
/// status/availability are READ-only per EventKit (attendee writes are impossible).
///
/// The five date fields are pre-formatted STRINGS in the oracle's rendering (CAL-03), not
/// `Date`s handed to the envelope's UTC ISO encoder: the oracle emits every event date in the
/// EVENT's own zone (`event.timeZone ?? .current`), start/end as date-only `yyyy-MM-ddZZZZZ`
/// when the event is all-day (`2026-07-28-04:00`), and always-timed forms for
/// occurrence/creation/last-modified. Emitting UTC instants instead was a live diff on every
/// all-day event. See `EventDateFormat`.
public struct CalendarEvent: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let notes: String?
    public let location: String?
    public let url: String?
    public let start_date: String?
    public let end_date: String?
    public let is_all_day: Bool
    public let availability: String
    public let status: String
    public let calendar: String?
    public let calendar_id: String?
    public let account: String?
    public let time_zone: String?
    public let is_detached: Bool
    public let has_recurrence: Bool
    public let occurrence_date: String?
    public let external_id: String?
    public let organizer: Participant?
    public let attendees: [Participant]?
    public let recurrence_rules: [RecurrenceRule]?
    public let alarms: [Alarm]?
    public let structured_location: StructuredLocation?
    public let last_modified: String?
    public let creation_date: String?

    public init(
        id: String, title: String? = nil, notes: String? = nil, location: String? = nil,
        url: String? = nil, start_date: String? = nil, end_date: String? = nil, is_all_day: Bool,
        availability: String, status: String, calendar: String? = nil, calendar_id: String? = nil,
        account: String? = nil, time_zone: String? = nil, is_detached: Bool, has_recurrence: Bool,
        occurrence_date: String? = nil, external_id: String? = nil, organizer: Participant? = nil,
        attendees: [Participant]? = nil, recurrence_rules: [RecurrenceRule]? = nil,
        alarms: [Alarm]? = nil, structured_location: StructuredLocation? = nil,
        last_modified: String? = nil, creation_date: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.location = location
        self.url = url
        self.start_date = start_date
        self.end_date = end_date
        self.is_all_day = is_all_day
        self.availability = availability
        self.status = status
        self.calendar = calendar
        self.calendar_id = calendar_id
        self.account = account
        self.time_zone = time_zone
        self.is_detached = is_detached
        self.has_recurrence = has_recurrence
        self.occurrence_date = occurrence_date
        self.external_id = external_id
        self.organizer = organizer
        self.attendees = attendees
        self.recurrence_rules = recurrence_rules
        self.alarms = alarms
        self.structured_location = structured_location
        self.last_modified = last_modified
        self.creation_date = creation_date
    }
}

// MARK: - Subtask (notes-field checklist item; RemindersKit populates these on read)

/// A reminder subtask/checklist item. EventKit's public API exposes NO native subtask surface,
/// so both the apple-events MCP and this port store subtasks inside the reminder notes field
/// (`---SUBTASKS---` block, `[ ] {id} title` lines). RemindersKit parses that block and populates
/// `Reminder.subtasks` + `Reminder.subtask_progress` on read. `completed` is the snake_case wire
/// key (there is no MCP JSON subtask contract to byte-match; the MCP surfaces subtasks in markdown).
public struct Subtask: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let completed: Bool
    public init(id: String, title: String, completed: Bool) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}

/// Subtask completion progress (mirrors the MCP's SubtaskProgress; empty → 100%).
public struct SubtaskProgress: Encodable, Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let percentage: Int
    public init(completed: Int, total: Int, percentage: Int) {
        self.completed = completed
        self.total = total
        self.percentage = percentage
    }
}

// MARK: - Reminder

/// A reminder (EKReminder). Used by the Reminders lane; modeled here because it shares the
/// EventKit alarm/recurrence/priority machinery. `priority` follows the MCP convention
/// (0 none, 1 high, 5 medium, 9 low — EventKit stores 0…9, surfaced raw).
///
/// `tags`, `subtasks`, and `subtask_progress` extend the MCP's read output; EventKit has no
/// native tag/subtask API, so RemindersKit parses them from the notes field (`[#tag]` markers /
/// `---SUBTASKS---` block) and populates them on read. `parent_id` is reserved for a future native
/// parent/child linkage (none exists in the public EventKit API today) and stays nil. All of these
/// default nil so the shared contract already carries the fields (additive, schema-MINOR).
public struct Reminder: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let notes: String?
    public let url: String?
    public let location: String?
    public let list: String?
    public let list_id: String?
    public let account: String?
    public let time_zone: String?
    public let external_id: String?
    public let completed: Bool
    /// REM-02: the five date fields are pre-formatted STRINGS in the oracle's rendering.
    /// due/start come from `OracleDates.dueDateString` — timed iff the stored components
    /// carry an hour, date-only otherwise, in the components' own zone — so the date-only vs
    /// timed distinction survives the wire; completion/creation/last-modified render through
    /// `EventDateFormat.string` (always timed) in the reminder's zone.
    public let completion_date: String?
    public let due_date: String?
    public let start_date: String?
    public let priority: Int
    public let has_recurrence: Bool
    public let recurrence_rules: [RecurrenceRule]?
    public let alarms: [Alarm]?
    public let location_trigger: LocationTrigger?
    public let tags: [String]?
    public let parent_id: String?
    public let subtasks: [Subtask]?
    public let subtask_progress: SubtaskProgress?
    public let last_modified: String?
    public let creation_date: String?

    public init(
        id: String, title: String? = nil, notes: String? = nil, url: String? = nil,
        location: String? = nil, list: String? = nil, list_id: String? = nil,
        account: String? = nil, time_zone: String? = nil, external_id: String? = nil,
        completed: Bool, completion_date: String? = nil, due_date: String? = nil,
        start_date: String? = nil, priority: Int, has_recurrence: Bool,
        recurrence_rules: [RecurrenceRule]? = nil, alarms: [Alarm]? = nil,
        location_trigger: LocationTrigger? = nil, tags: [String]? = nil, parent_id: String? = nil,
        subtasks: [Subtask]? = nil, subtask_progress: SubtaskProgress? = nil,
        last_modified: String? = nil, creation_date: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.url = url
        self.location = location
        self.list = list
        self.list_id = list_id
        self.account = account
        self.time_zone = time_zone
        self.external_id = external_id
        self.completed = completed
        self.completion_date = completion_date
        self.due_date = due_date
        self.start_date = start_date
        self.priority = priority
        self.has_recurrence = has_recurrence
        self.recurrence_rules = recurrence_rules
        self.alarms = alarms
        self.location_trigger = location_trigger
        self.tags = tags
        self.parent_id = parent_id
        self.subtasks = subtasks
        self.subtask_progress = subtask_progress
        self.last_modified = last_modified
        self.creation_date = creation_date
    }
}
