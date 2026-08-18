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
    }

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let remStatus = EventStore.authorizationStatus(for: .reminder)
            let calStatus = EventStore.authorizationStatus(for: .event)
            let pre = Permissions.preflight()
            var notes = pre.notes
            let ready = remStatus == .fullAccess || remStatus == .authorized
            if !ready {
                notes.append("Reminders access is '\(remStatus.rawValue)' — grant Full Access in "
                             + "System Settings › Privacy & Security › Reminders (first live run will prompt).")
            }
            try Output.emit(tool: "reminders", data: Health(
                reminders_authorization: remStatus.rawValue,
                calendar_authorization: calStatus.rawValue,
                reminders_ready: ready,
                full_disk_access: pre.full_disk_access,
                notes: notes), text: global.text)
        }
    }
}
