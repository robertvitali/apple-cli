import Foundation

/// Shared EventKit engine for the Calendar and Reminders domains.
///
/// IMPORTANT (parallel-work coordination): Calendar and Reminders are two separate
/// worktrees but BOTH depend on this one module. Build the shared `EKEventStore`
/// access, model types (events, reminders, calendars, recurrence, alarms), date/
/// timezone handling, and permission preflight HERE, once. Do NOT edit this target
/// from both worktrees simultaneously — land the shared core first, then flesh out
/// the two domain surfaces in parallel.
///
/// Asana:
///   Calendar  — feat/asana-GID-REDACTED-calendar
///   Reminders — feat/asana-GID-REDACTED-reminders
///
/// Fork/reference base: FradSer/event (MIT) — its Swift models already read the
/// full surface (attendees/availability/recurrence/alarms/structuredLocation).
///
/// The real engine lives in sibling files of this target:
///   - `EventStore.swift`   — EKEventStore access, auth (.event + .reminder), fetch/save,
///                            EKError → AppleError mapping.
///   - `Models.swift`       — Encodable wire shapes (CalendarEvent, Reminder, ReminderList,
///                            CalendarCollection, RecurrenceRule, Alarm, LocationTrigger,
///                            StructuredLocation, Participant).
///   - `Mapping.swift`      — EK ⇄ model conversions (recurrence, alarms, participants,
///                            locations, availability/status/type enums).
///   - `DateParsing.swift`  — MCP-compatible date parsing + all-day inference.
public enum EventKitCore {
    /// The shared engine is built. Retained as a lightweight readiness marker so the
    /// pre-rebase RemindersKit stub (which references it) keeps compiling; the real entry
    /// point is `EventStore`.
    public static let ready = true

    /// Convenience factory for a fresh shared store.
    public static func makeStore() -> EventStore { EventStore() }
}
