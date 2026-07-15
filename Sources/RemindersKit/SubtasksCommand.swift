import Foundation
import ArgumentParser
import AppleKit
import EventKitCore
import EventKit

/// `apple reminders subtasks …` — the reminders_subtasks strict superset (6 ops:
/// read/create/update/delete/toggle/reorder).
///
/// Subtasks live in the parent reminder's notes field (`---SUBTASKS---` block, `[ ] {id} title`
/// lines), byte-compatible with the apple-events MCP. EventKit's public API exposes no native
/// subtask/parent surface (see RemindersSupport.swift), so op-parity is preserved via notes-field
/// storage; the storage model matches the MCP verbatim so read output diffs cleanly against it.
public struct SubtasksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "subtasks",
        abstract: "Reminder subtasks — read/create/update/delete/toggle/reorder (ports reminders_subtasks).",
        subcommands: [SubtasksRead.self, SubtasksCreate.self, SubtasksUpdate.self,
                      SubtasksDelete.self, SubtasksToggle.self, SubtasksReorder.self],
        defaultSubcommand: SubtasksRead.self
    )
    public init() {}
}

// A subtask op mutates an EXISTING reminder's notes, so beyond the standard write gate every
// mutating op ALSO calls the shared `requireLabeledReminder(_:)` post-fetch (see RemindersSupport)
// so an autonomous run can never touch a real reminder's notes.

// MARK: - read

public struct SubtasksRead: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "read", abstract: "List a reminder's subtasks + completion progress.")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .read)
            let reminder = try fetchReminder(store, reminderId)
            let subs = ReminderSubtasks.parse(reminder.notes)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs))
        }
    }
}

// MARK: - create

public struct SubtasksCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Add a subtask (dry-run by default; --execute under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .long, help: "Subtask title (required).") public var title: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: nil) else {
                try Output.emit(tool: "reminders", data: SubtaskWritePreview(action: "create", reminder_id: reminderId, title: title))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder)
            let (newNotes, created) = try ReminderSubtasks.add(title: title, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: created))
        }
    }
}

// MARK: - update

public struct SubtasksUpdate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update a subtask's title/completion (dry-run by default; --execute gated).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String
    @Option(name: .long, help: "New subtask title.") public var title: String?
    @Flag(inversion: .prefixedNo, help: "Mark the subtask completed/uncompleted.") public var completed: Bool?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: nil) else {
                try Output.emit(tool: "reminders", data: SubtaskWritePreview(
                    action: "update", reminder_id: reminderId, subtask_id: subtaskId, title: title, completed: completed))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder)
            let (newNotes, updated) = try ReminderSubtasks.update(id: subtaskId, title: title, completed: completed, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: updated))
        }
    }
}

// MARK: - delete

public struct SubtasksDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Remove a subtask (dry-run by default; --execute gated).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: nil) else {
                try Output.emit(tool: "reminders", data: SubtaskWritePreview(action: "delete", reminder_id: reminderId, subtask_id: subtaskId))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder)
            let newNotes = try ReminderSubtasks.remove(id: subtaskId, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs))
        }
    }
}

// MARK: - toggle

public struct SubtasksToggle: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "toggle", abstract: "Flip a subtask's completion (dry-run by default; --execute gated).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: nil) else {
                try Output.emit(tool: "reminders", data: SubtaskWritePreview(action: "toggle", reminder_id: reminderId, subtask_id: subtaskId))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder)
            let (newNotes, toggled) = try ReminderSubtasks.toggle(id: subtaskId, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: toggled))
        }
    }
}

// MARK: - reorder

public struct SubtasksReorder: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reorder", abstract: "Reorder subtasks (dry-run by default; --execute gated).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .long, help: "Subtask id in desired order (repeatable; must include ALL ids).") public var order: [String] = []

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard !order.isEmpty else { throw AppleError.validation("reorder needs at least one --order <subtask-id>") }
            for oid in order { try ReminderSubtasks.validateId(oid) }
            guard try ReminderWriteGuard.shouldExecute(global: global, labeledName: nil) else {
                try Output.emit(tool: "reminders", data: SubtaskWritePreview(action: "reorder", reminder_id: reminderId, order: order))
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder)
            let (newNotes, reordered) = try ReminderSubtasks.reorder(order: order, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            try Output.emit(tool: "reminders", data: SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(reordered), subtasks: reordered))
        }
    }
}
