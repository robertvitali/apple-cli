import Foundation
import ArgumentParser
import AppleKit
import EventKitCore

/// `apple reminders doctor` — permission/health preflight. Reports EventKit authorization for
/// Reminders (and Calendar, for a shared picture) plus Full Disk Access, WITHOUT triggering a
/// write or prompting. Read-only; safe to run anytime.
public struct RemindersDoctor: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report EventKit (Reminders/Calendar) authorization + Full Disk Access.")

    @OptionGroup public var global: GlobalOptions
    public init() {}

    struct Health: Encodable {
        let reminders_authorization: String
        let calendar_authorization: String
        let reminders_ready: Bool
        let full_disk_access: Bool
        let notes: [String]

        static func build(remStatus: EventStore.AuthStatus,
                          calStatus: EventStore.AuthStatus,
                          fullDiskAccess: Bool,
                          notes preflightNotes: [String]) -> Health {
            var notes = preflightNotes
            let ready = remStatus == .fullAccess || remStatus == .authorized
            if !ready {
                notes.append("Reminders access is '\(remStatus.rawValue)' — grant Full Access in "
                             + "System Settings › Privacy & Security › Reminders (first live run will prompt).")
            }
            return Health(
                reminders_authorization: remStatus.rawValue,
                calendar_authorization: calStatus.rawValue,
                reminders_ready: ready,
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
        try runGuarded(tool: "reminders") {
            let remStatus = authorizationStatus(.reminder)
            let calStatus = authorizationStatus(.event)
            let pre = preflight()
            try Output.emit(tool: "reminders", data: Health.build(
                remStatus: remStatus,
                calStatus: calStatus,
                fullDiskAccess: pre.full_disk_access,
                notes: pre.notes), text: global.text)
        }
    }
}
