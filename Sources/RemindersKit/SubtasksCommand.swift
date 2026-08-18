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

// Every subtask op mutates an EXISTING reminder's notes and is addressed by PARENT reminder id,
// so each mutating op calls the shared `requireLabeledReminder(_:sandboxActive:)` post-fetch (see
// RemindersSupport). Under write-model v2 that check is SANDBOX-ONLY: unsandboxed, these ops touch
// any reminder by id exactly as the oracle's `reminders_subtasks` actions do. Because the parent's
// title is never argv-computable, the check can only ever run on the execute path — so every
// subtask preview sets `sandbox_target_unchecked` when the sandbox is engaged rather than letting
// a silent non-refusal read as approval.

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
                progress: ReminderSubtasks.progress(subs), subtasks: subs), text: global.text)
        }
    }
}

// MARK: - create

public struct SubtasksCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Add a subtask (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .long, help: "Subtask title (required).") public var title: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(SubtaskWritePreview(
                    action: "create", reminder_id: reminderId, title: title,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil), gate: gate)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            let (newNotes, created) = try ReminderSubtasks.add(title: title, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try emitRemindersExecutedWrite(SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: created), gate: gate)
        }
    }
}

// MARK: - update

public struct SubtasksUpdate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update a subtask's title/completion (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String
    @Option(name: .long, help: "New subtask title.") public var title: String?
    @Flag(inversion: .prefixedNo, help: "Mark the subtask completed/uncompleted.") public var completed: Bool?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(SubtaskWritePreview(
                    action: "update", reminder_id: reminderId, subtask_id: subtaskId, title: title,
                    completed: completed,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil), gate: gate)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            let (newNotes, updated) = try ReminderSubtasks.update(id: subtaskId, title: title, completed: completed, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try emitRemindersExecutedWrite(SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: updated), gate: gate)
        }
    }
}

// MARK: - delete

public struct SubtasksDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Remove a subtask (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(SubtaskWritePreview(
                    action: "delete", reminder_id: reminderId, subtask_id: subtaskId,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil), gate: gate)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            let newNotes = try ReminderSubtasks.remove(id: subtaskId, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try emitRemindersExecutedWrite(SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs), gate: gate)
        }
    }
}

// MARK: - toggle

public struct SubtasksToggle: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "toggle", abstract: "Flip a subtask's completion (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .customLong("subtask-id"), help: "Subtask identifier (required, lowercase hex).") public var subtaskId: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            try ReminderSubtasks.validateId(subtaskId)
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(SubtaskWritePreview(
                    action: "toggle", reminder_id: reminderId, subtask_id: subtaskId,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil), gate: gate)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            let (newNotes, toggled) = try ReminderSubtasks.toggle(id: subtaskId, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            let subs = ReminderSubtasks.parse(newNotes)
            try emitRemindersExecutedWrite(SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(subs), subtasks: subs, subtask: toggled), gate: gate)
        }
    }
}

// MARK: - reorder

public struct SubtasksReorder: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reorder", abstract: "Reorder subtasks (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .customLong("reminder-id"), help: "Parent reminder identifier (required).") public var reminderId: String
    @Option(name: .long, help: "Subtask id in desired order (repeatable; must include ALL ids).") public var order: [String] = []

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard !order.isEmpty else { throw AppleError.validation("reorder needs at least one --order <subtask-id>") }
            for oid in order { try ReminderSubtasks.validateId(oid) }
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(SubtaskWritePreview(
                    action: "reorder", reminder_id: reminderId, order: order,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil), gate: gate)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, reminderId)
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            let (newNotes, reordered) = try ReminderSubtasks.reorder(order: order, notes: reminder.notes)
            reminder.notes = newNotes
            try store.save(reminder)
            try emitRemindersExecutedWrite(SubtasksData(
                reminder_id: reminderId, reminder_title: reminder.title,
                progress: ReminderSubtasks.progress(reordered), subtasks: reordered), gate: gate)
        }
    }
}
