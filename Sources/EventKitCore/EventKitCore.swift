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
public enum EventKitCore {
    /// Placeholder marker; replaced by the real EKEventStore-backed engine.
    public static let ready = false
}
