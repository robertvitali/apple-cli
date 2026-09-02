import Foundation
import ArgumentParser
import AppleKit
import EventKitCore

/// `apple calendar doctor` — permission/health preflight. Reports EventKit authorization for
/// Calendar (and Reminders, for a shared picture) plus Full Disk Access, WITHOUT triggering a
/// write. Read-only; safe to run anytime.
public struct CalendarDoctor: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report EventKit (Calendar/Reminders) authorization + Full Disk Access.")

    @OptionGroup public var global: GlobalOptions
    public init() {}

    struct Health: Encodable {
        let calendar_authorization: String
        let reminders_authorization: String
        let calendar_ready: Bool
        let full_disk_access: Bool
        let notes: [String]

        static func build(calStatus: EventStore.AuthStatus,
                          remStatus: EventStore.AuthStatus,
                          fullDiskAccess: Bool,
                          notes preflightNotes: [String]) -> Health {
            var notes = preflightNotes
            let ready = calStatus == .fullAccess || calStatus == .authorized
            if !ready {
                notes.append("Calendar access is '\(calStatus.rawValue)' — grant Full Access in "
                             + "System Settings › Privacy & Security › Calendars (first live run will prompt).")
            }
            return Health(
                calendar_authorization: calStatus.rawValue,
                reminders_authorization: remStatus.rawValue,
                calendar_ready: ready,
                full_disk_access: fullDiskAccess,
                notes: notes)
        }
    }

    public func run() throws {
        try run(authorizationStatus: EventStore.authorizationStatus(for:),
                preflight: Permissions.preflight)
    }

    /// Test seam. The public `run()` binds the real EventKit status probe and the real Full
    /// Disk Access preflight; logic tests bind pure stand-ins so no test reads host TCC state
    /// or opens a protected path. Neither injected dependency prompts.
    func run(authorizationStatus: (EventStore.Entity) -> EventStore.AuthStatus,
             preflight: () -> Permissions.Preflight) throws {
        try runGuarded(tool: "calendar") {
            let calStatus = authorizationStatus(.event)
            let remStatus = authorizationStatus(.reminder)
            let pre = preflight()
            try Output.emit(tool: "calendar", data: Health.build(
                calStatus: calStatus,
                remStatus: remStatus,
                fullDiskAccess: pre.full_disk_access,
                notes: pre.notes), text: global.text)
        }
    }
}
