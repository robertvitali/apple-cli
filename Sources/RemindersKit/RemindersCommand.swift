import ArgumentParser
import AppleKit
import EventKitCore

/// `apple reminders …` — Reminders (EventKit).
///
/// Ports the Reminders half of `mcp-server-apple-events` (@ 1.4.0) to a strict superset:
///   reminders tasks read      → reminders_tasks read   (filters/--id → lists + reminders)
///   reminders tasks create    → reminders_tasks create (recurrence/alarms/tags/subtasks/…)
///   reminders tasks update    → reminders_tasks update (+ completionDate, cross-list move, tag add/remove)
///   reminders tasks delete    → reminders_tasks delete
///   reminders lists read      → reminders_lists read
///   reminders lists create    → reminders_lists create (name + color)
///   reminders lists update    → reminders_lists update (rename + recolor)
///   reminders lists delete    → reminders_lists delete
///   reminders subtasks {read,create,update,delete,toggle,reorder} → reminders_subtasks (6 ops)
///   reminders doctor          → permission/health preflight (extra)
///
/// All heavy EventKit work lives in the shared `EventKitCore` engine (models + mapping +
/// EKEventStore access); this module is the command tree only. Writes default to a dry-run
/// preview; a live write requires `--execute` under the `--test-mode` + `APPLE_TEST_MODE`
/// safety gate.
///
/// SUBTASKS + TAGS are stored in the reminder notes field (`---SUBTASKS---` block / `[#tag]`
/// markers), byte-compatible with the apple-events MCP — EventKit's public API exposes no
/// native subtask/parent or tag surface (see RemindersSupport.swift for the full rationale).
///
/// Asana parent GID: GID-REDACTED
public struct RemindersCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders — tasks/lists/subtasks (EventKit; ports apple-events reminders half).",
        subcommands: [TasksCommand.self, ListsCommand.self, SubtasksCommand.self, RemindersDoctor.self],
        defaultSubcommand: TasksCommand.self
    )
    public init() {}
}
