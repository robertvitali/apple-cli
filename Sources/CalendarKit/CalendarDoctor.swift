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
    }

    public func run() throws {
        try runGuarded(tool: "calendar") {
            let calStatus = EventStore.authorizationStatus(for: .event)
            let remStatus = EventStore.authorizationStatus(for: .reminder)
            let pre = Permissions.preflight()
            var notes = pre.notes
            let ready = calStatus == .fullAccess || calStatus == .authorized
            if !ready {
                notes.append("Calendar access is '\(calStatus.rawValue)' — grant Full Access in "
                             + "System Settings › Privacy & Security › Calendars (first live run will prompt).")
            }
            try Output.emit(tool: "calendar", data: Health(
                calendar_authorization: calStatus.rawValue,
                reminders_authorization: remStatus.rawValue,
                calendar_ready: ready,
                full_disk_access: pre.full_disk_access,
                notes: notes), text: global.text)
        }
    }
}
