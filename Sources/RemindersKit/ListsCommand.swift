import Foundation
import ArgumentParser
import AppleKit
import EventKitCore
import EventKit
import CoreGraphics

/// `apple reminders lists …` — the reminders_lists strict superset (read/create/update/delete).
public struct ListsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "Reminder lists — read/create/update/delete + color (ports reminders_lists).",
        subcommands: [ListsRead.self, ListsCreate.self, ListsUpdate.self, ListsDelete.self],
        defaultSubcommand: ListsRead.self
    )
    public init() {}
}

// MARK: - read

public struct ListsRead: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "List all reminder lists (id/title/account/account_type/color/…).")

    @OptionGroup public var global: GlobalOptions
    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .read)
            let lists = store.calendars(for: .reminder)
                .map { ReadMapping.reminderList(from: $0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            try Output.emit(tool: "reminders", data: ListsData(lists: lists))
        }
    }
}

// MARK: - create

public struct ListsCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a reminder list (dry-run by default; --execute writes under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "List name (required).") public var name: String
    @Option(name: .long, help: "Hex color, e.g. #FF5733.") public var color: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let cg = try color.map { hex -> CGColorBox in
                guard let c = ReadMapping.cgColor(fromHex: hex) else {
                    throw AppleError.validation("bad --color '\(hex)' (use #RRGGBB, e.g. #FF5733)")
                }
                return CGColorBox(c)
            }

            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: name) else {
                try Output.emit(tool: "reminders", data: ListWritePreview(action: "create", name: name, color: color))
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            guard let list = store.newCalendar(for: .reminder) else {
                throw AppleError.upstream("no writable reminders source available to create a list")
            }
            list.title = name
            if let cg { list.cgColor = cg.value }
            try store.saveCalendar(list)
            try Output.emit(tool: "reminders", data: ReadMapping.reminderList(from: list))
        }
    }
}

// MARK: - update (rename + recolor)

public struct ListsUpdate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Rename/recolor a reminder list (dry-run by default; --execute writes under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Current list name (required).") public var name: String
    @Option(name: .customLong("new-name"), help: "New list name.") public var newName: String?
    @Option(name: .long, help: "New hex color, e.g. #FF5733.") public var color: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard newName != nil || color != nil else {
                throw AppleError.validation("nothing to update — provide --new-name and/or --color")
            }
            let cg = try color.map { hex -> CGColorBox in
                guard let c = ReadMapping.cgColor(fromHex: hex) else {
                    throw AppleError.validation("bad --color '\(hex)' (use #RRGGBB, e.g. #FF5733)")
                }
                return CGColorBox(c)
            }

            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: name) else {
                try Output.emit(tool: "reminders", data: ListWritePreview(action: "update", name: name, new_name: newName, color: color))
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            guard let list = store.calendar(matching: name, entity: .reminder) else {
                throw AppleError.notFound("no reminder list named or id '\(name)'")
            }
            if let newName, !newName.isEmpty { list.title = newName }
            if let cg { list.cgColor = cg.value }
            try store.saveCalendar(list)
            try Output.emit(tool: "reminders", data: ReadMapping.reminderList(from: list))
        }
    }
}

// MARK: - delete

public struct ListsDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder list AND its items (dry-run by default; --execute under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "List name (required).") public var name: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: name) else {
                try Output.emit(tool: "reminders", data: ListWritePreview(action: "delete", name: name))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            guard let list = store.calendar(matching: name, entity: .reminder) else {
                throw AppleError.notFound("no reminder list named or id '\(name)'")
            }
            try store.removeCalendar(list)
            try Output.emit(tool: "reminders", data: ListDeleteData(name: name, deleted: true))
        }
    }
}

/// A tiny box so an optional parsed `CGColor` can cross the dry-run/execute boundary without
/// re-parsing (CGColor isn't `Sendable`; this is single-threaded CLI use).
struct CGColorBox {
    let value: CGColor
    init(_ v: CGColor) { self.value = v }
}
