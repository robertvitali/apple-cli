import Foundation
import ArgumentParser
import AppleKit
import EventKitCore
import EventKit

/// `apple reminders tasks …` — the reminders_tasks strict superset (read/create/update/delete).
public struct TasksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tasks",
        abstract: "Reminder tasks — read/create/update/delete (ports reminders_tasks).",
        subcommands: [TasksRead.self, TasksCreate.self, TasksUpdate.self, TasksDelete.self],
        defaultSubcommand: TasksRead.self
    )
    public init() {}
}

// MARK: - read

public struct TasksRead: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read reminders (lists + reminders) with filters, or a single reminder by --id.")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Read a single reminder by its identifier.") public var id: String?
    @Option(name: .customLong("filter-list"), help: "Only reminders in this list (name or id).") public var filterList: String?
    @Flag(name: .customLong("show-completed"), help: "Include completed reminders (default: hide them).") public var showCompleted = false
    @Option(name: .long, help: "Substring filter over title/notes.") public var search: String?
    @Option(name: .customLong("due-within"), help: "Due-date window: today|tomorrow|this-week|overdue|no-date.") public var dueWithin: String?
    @Option(name: .customLong("filter-priority"), help: "Only this priority: high|medium|low|none.") public var filterPriority: String?
    @Flag(name: .customLong("filter-recurring"), help: "Only recurring reminders.") public var filterRecurring = false
    @Flag(name: .customLong("filter-location-based"), help: "Only geofence/location-trigger reminders.") public var filterLocationBased = false
    @Option(name: .customLong("filter-tag"), help: "Only reminders with ALL these tags (repeatable).") public var filterTag: [String] = []

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            if let dueWithin { try DueWithin.validate(dueWithin) }
            let priorityFilterValue = try filterPriority.map { try ReminderPriority.filterValue($0) }

            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .read)

            if let id {
                guard let r = store.reminder(withIdentifier: id) else {
                    throw AppleError.notFound("no reminder with id '\(id)'")
                }
                try Output.emit(tool: "reminders", data: ReminderRead.enrich(ReminderMapping.reminder(from: r)))
                return
            }

            let all = try store.reminders(matching: store.predicateForReminders(in: nil))
            let now = Date()
            let filtered = all.filter { r in
                if !showCompleted && r.isCompleted { return false }
                if let filterList,
                   !(r.calendar?.title == filterList || r.calendar?.calendarIdentifier == filterList) { return false }
                if let term = search?.lowercased(), !term.isEmpty {
                    let inTitle = r.title?.lowercased().contains(term) ?? false
                    let inNotes = r.notes?.lowercased().contains(term) ?? false
                    // The MCP mirrors the url into notes so search matches it; we keep the url
                    // structured (never in notes) and search reminder.url directly for parity.
                    let inUrl = r.url?.absoluteString.lowercased().contains(term) ?? false
                    if !inTitle && !inNotes && !inUrl { return false }
                }
                if let dueWithin,
                   !DueWithin.matches(due: r.dueDateComponents?.date, filter: dueWithin, now: now) { return false }
                if let priorityFilterValue, r.priority != priorityFilterValue { return false }
                if filterRecurring && !r.hasRecurrenceRules { return false }
                if filterLocationBased && !(r.alarms?.contains(where: { $0.structuredLocation != nil }) ?? false) { return false }
                if !filterTag.isEmpty && !ReminderTags.hasAll(reminderTags: ReminderTags.extract(r.notes), filterTags: filterTag) { return false }
                return true
            }

            let lists = store.calendars(for: .reminder)
                .map { ReadMapping.reminderList(from: $0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let reminders = filtered.map { ReminderRead.enrich(ReminderMapping.reminder(from: $0)) }
            try Output.emit(tool: "reminders", data: RemindersReadData(lists: lists, reminders: reminders))
        }
    }
}

// MARK: - create

public struct TasksCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a reminder (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Reminder title (required).") public var title: String
    @Option(name: .long, help: "Start date.") public var start: String?
    @Option(name: .long, help: "Due date.") public var due: String?
    @Option(name: .long, help: "Notes/body.") public var note: String?
    @Option(name: .long, help: "Plain-text location (EKCalendarItem.location).") public var location: String?
    @Option(name: .long, help: "Associated URL.") public var url: String?
    @Flag(name: .long, help: "Create it already completed.") public var completed = false
    @Option(name: .long, help: "Priority: 0|1|5|9 or none|high|medium|low.") public var priority: String?
    @Option(name: .customLong("target-list"), help: "List to create in (name or id; default: default list).") public var targetList: String?
    @Option(name: .long, help: "Alarm spec (repeatable): -15m|-2h|-1d, geo:lat,lon,…, or a date.") public var alarm: [String] = []
    @Option(name: .long, help: "Recurrence spec (repeatable): freq=weekly;interval=2;byday=2,4;count=10.") public var recurrence: [String] = []
    @Option(name: .customLong("geo-lat"), help: "Location-trigger latitude.") public var geoLat: Double?
    @Option(name: .customLong("geo-lon"), help: "Location-trigger longitude.") public var geoLon: Double?
    @Option(name: .customLong("geo-radius"), help: "Location-trigger radius (m, default 100).") public var geoRadius: Double?
    @Option(name: .customLong("geo-title"), help: "Location-trigger title.") public var geoTitle: String?
    @Option(name: .customLong("geo-proximity"), help: "Location-trigger proximity: enter|leave (default enter).") public var geoProximity: String?
    @Option(name: .long, help: "Tag (repeatable) — stored as [#tag] in notes.") public var tag: [String] = []
    @Option(name: .long, help: "Initial subtask title (repeatable) — stored in the notes checklist.") public var subtask: [String] = []

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppleError.validation("reminder title cannot be empty")
            }
            let startParsed = try start.map { try DateParsing.parse($0) }
            let dueParsed = try due.map { try DateParsing.parse($0) }
            let priorityValue = try priority.map { try ReminderPriority.parse($0) }
            for t in tag { try ReminderTags.validate(t) }
            for s in subtask { _ = try ReminderSubtasks.validatedTitle(s) } // reject empty subtask titles early (dry-run too)
            let alarms = try alarm.map { try ReminderAlarmSpec.parse($0) }
            let rules = try recurrence.map { try ReminderRecurrenceSpec.parse($0) }
            let locTrigger = try parsedLocationTrigger()
            // Validate the EK objects build (throws on bad range) even in dry-run.
            _ = try alarms.map { try AlarmMapping.ekAlarm(from: $0) }
            _ = try rules.map { try RecurrenceMapping.ekRule(from: $0) }
            if let locTrigger { _ = try AlarmMapping.ekAlarm(from: Alarm(location_trigger: locTrigger)) }

            let gate = try ReminderWriteGuard.resolve(global)
            // The title is argv-computable, so it is checked on both paths. The destination
            // matters too — creating a labeled item inside a REAL list still modifies real user
            // data — but `--target-list` takes a name OR an opaque id, so a raw argv label test
            // would refuse every id. A labeled NAME passes here; anything else defers to the
            // resolved list's title on the execute path (and is disclosed in the preview).
            try ReminderWriteGuard.requireLabeled(title, what: "reminder", sandboxActive: gate.sandboxActive)
            let destinationDeferred = ReminderWriteGuard.destinationCheckDeferred(
                targetList, sandboxActive: gate.sandboxActive)

            guard gate.willExecute else {
                try emitRemindersWrite(ReminderWritePreview(
                    action: "create", title: title, start_date: startParsed?.date, due_date: dueParsed?.date,
                    completed: completed ? true : nil, priority: priorityValue, note: note, location: location,
                    url: url, target_list: targetList, tags: tag.isEmpty ? nil : tag, subtasks: subtask.isEmpty ? nil : subtask,
                    alarms: alarms.isEmpty ? nil : alarms, recurrence_rules: rules.isEmpty ? nil : rules,
                    location_trigger: locTrigger,
                    sandbox_target_unchecked: destinationDeferred ? true : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            guard let list = resolveList(store: store, name: targetList) else {
                throw AppleError.notFound("no list named or id '\(targetList ?? "")' and no default reminders list")
            }
            // Post-resolution destination check — ONLY when a destination was explicitly named.
            // This is what catches the id-addressed case the argv test had to defer.
            //
            // The DEFAULT list (no --target-list) is deliberately exempt, for the same reason
            // Calendar's `--target-calendar` is: requiring a labeled default would make plain
            // sandboxed creation impossible until the agent first creates a list, and AGENTS.md's
            // conduct rule is "create clearly-LABELED test data", not "into labeled containers
            // only". Naming a real list explicitly is a deliberate act and is refused; falling
            // back to the operator's default list is not.
            if targetList != nil {
                try requireLabeledList(list, sandboxActive: gate.sandboxActive)
            }
            let reminder = store.newReminder(in: list)
            reminder.title = title
            reminder.isCompleted = completed
            if let priorityValue { reminder.priority = priorityValue }
            if let location { reminder.location = location.isEmpty ? nil : location }
            if let url, !url.isEmpty { reminder.url = URL(string: url) }

            // Notes = tags (prepended) + user note, then subtasks (appended). Mirrors the MCP order.
            var notes: String? = tag.isEmpty ? note : ReminderTags.combine(tags: tag, notes: note)
            if !subtask.isEmpty {
                notes = ReminderSubtasks.combine(subtasks: try ReminderSubtasks.fromTitles(subtask), notes: notes)
            }
            if let notes, !notes.isEmpty { reminder.notes = notes }

            if let startParsed { reminder.startDateComponents = DateParsing.components(from: startParsed.date, dateOnly: startParsed.isDateOnly) }
            if let dueParsed { reminder.dueDateComponents = DateParsing.components(from: dueParsed.date, dateOnly: dueParsed.isDateOnly) }
            if startParsed != nil || dueParsed != nil { reminder.timeZone = TimeZone.current }

            // Alarms: explicit --alarm wins; else the --geo-* location trigger (mirrors MCP create).
            if !alarms.isEmpty {
                for a in alarms { reminder.addAlarm(try AlarmMapping.ekAlarm(from: a)) }
            } else if let locTrigger {
                reminder.addAlarm(try AlarmMapping.ekAlarm(from: Alarm(location_trigger: locTrigger)))
            }
            for rule in rules { reminder.addRecurrenceRule(try RecurrenceMapping.ekRule(from: rule)) }

            try store.save(reminder)
            try emitRemindersWrite(ReminderRead.enrich(ReminderMapping.reminder(from: reminder)),
                                   sandboxActive: gate.sandboxActive)
        }
    }

    func parsedLocationTrigger() throws -> LocationTrigger? {
        if geoLat == nil && geoLon == nil && geoRadius == nil && geoTitle == nil && geoProximity == nil { return nil }
        guard let lat = geoLat, let lon = geoLon else {
            throw AppleError.validation("location trigger needs both --geo-lat and --geo-lon")
        }
        let prox = (geoProximity ?? "enter").lowercased()
        guard ["enter", "leave", "depart", "exit"].contains(prox) else {
            throw AppleError.validation("bad --geo-proximity '\(geoProximity ?? "")' (enter|leave)")
        }
        return LocationTrigger(title: geoTitle, latitude: lat, longitude: lon, radius: geoRadius ?? 100, proximity: prox)
    }

    func resolveList(store: EventStore, name: String?) -> EKCalendar? {
        if let name { return store.calendar(matching: name, entity: .reminder) }
        return store.defaultCalendarForReminders
    }
}

// MARK: - update

public struct TasksUpdate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a reminder (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Reminder identifier (required).") public var id: String
    @Option(name: .long, help: "New title.") public var title: String?
    @Option(name: .long, help: "New start date.") public var start: String?
    @Option(name: .long, help: "New due date.") public var due: String?
    @Option(name: .customLong("completion-date"), help: "Set the completion date/time.") public var completionDate: String?
    @Option(name: .long, help: "New notes/body.") public var note: String?
    @Option(name: .long, help: "New plain-text location.") public var location: String?
    @Option(name: .long, help: "New URL (empty string clears it).") public var url: String?
    @Flag(inversion: .prefixedNo, help: "Mark completed/uncompleted (--completed / --no-completed).") public var completed: Bool?
    @Option(name: .long, help: "Priority: 0|1|5|9 or none|high|medium|low.") public var priority: String?
    @Option(name: .customLong("target-list"), help: "Move to this list (cross-list move; name or id).") public var targetList: String?
    @Option(name: .long, help: "Alarm spec (repeatable) — replaces ALL existing alarms.") public var alarm: [String] = []
    @Flag(name: .customLong("clear-alarms"), help: "Remove all alarms.") public var clearAlarms = false
    @Option(name: .long, help: "Recurrence spec (repeatable) — replaces existing rules.") public var recurrence: [String] = []
    @Flag(name: .customLong("clear-recurrence"), help: "Remove recurrence.") public var clearRecurrence = false
    @Option(name: .customLong("geo-lat"), help: "Location-trigger latitude (replaces the location alarm).") public var geoLat: Double?
    @Option(name: .customLong("geo-lon"), help: "Location-trigger longitude.") public var geoLon: Double?
    @Option(name: .customLong("geo-radius"), help: "Location-trigger radius (m, default 100).") public var geoRadius: Double?
    @Option(name: .customLong("geo-title"), help: "Location-trigger title.") public var geoTitle: String?
    @Option(name: .customLong("geo-proximity"), help: "Location-trigger proximity: enter|leave.") public var geoProximity: String?
    @Flag(name: .customLong("clear-location-trigger"), help: "Remove only location-trigger alarms.") public var clearLocationTrigger = false
    @Option(name: .long, help: "Replace ALL tags with these (repeatable).") public var tag: [String] = []
    @Option(name: .customLong("add-tag"), help: "Add a tag (repeatable, merges with existing).") public var addTag: [String] = []
    @Option(name: .customLong("remove-tag"), help: "Remove a tag (repeatable).") public var removeTag: [String] = []
    @Flag(name: .customLong("clear-tags"), help: "Remove ALL tags (conflicts with --tag).") public var clearTags = false

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            if let title, title.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("reminder title cannot be empty")
            }
            if clearTags && !tag.isEmpty {
                throw AppleError.validation("--clear-tags conflicts with --tag (use one)")
            }
            // Effective tag replacement: --clear-tags → empty-but-present ([] clears all);
            // --tag values → replace; neither → nil (leave tags untouched).
            let tagsArg: [String]? = clearTags ? [] : (tag.isEmpty ? nil : tag)
            let startParsed = try start.map { try DateParsing.parse($0) }
            let dueParsed = try due.map { try DateParsing.parse($0) }
            let completionParsed = try completionDate.map { try DateParsing.parse($0) }
            let priorityValue = try priority.map { try ReminderPriority.parse($0) }
            for t in tag { try ReminderTags.validate(t) }
            for t in addTag { try ReminderTags.validate(t) }
            for t in removeTag { try ReminderTags.validate(t) }
            let alarms = try alarm.map { try ReminderAlarmSpec.parse($0) }
            let rules = try recurrence.map { try ReminderRecurrenceSpec.parse($0) }
            let locTrigger = try parsedLocationTrigger()
            _ = try alarms.map { try AlarmMapping.ekAlarm(from: $0) }
            _ = try rules.map { try RecurrenceMapping.ekRule(from: $0) }
            if let locTrigger { _ = try AlarmMapping.ekAlarm(from: Alarm(location_trigger: locTrigger)) }

            let gate = try ReminderWriteGuard.resolve(global)
            // The RENAME target and the destination list are argv-computable — check both on both
            // paths so a sandboxed update cannot rename a test item to a real-looking name or move
            // it into a real list. The EXISTING title is not argv-computable; it is checked
            // post-fetch below, and the preview discloses that deferral.
            try ReminderWriteGuard.requireLabeled(title, what: "new reminder title",
                                                  sandboxActive: gate.sandboxActive)
            // `--target-list` is name-OR-id, so it is vetted post-resolution on the execute path
            // (see TasksCreate). No separate disclosure flag is needed here: update is addressed
            // by opaque id, so its preview already reports `sandbox_target_unchecked`
            // unconditionally whenever the sandbox is engaged.

            guard gate.willExecute else {
                try emitRemindersWrite(ReminderWritePreview(
                    action: "update", id: id, title: title, start_date: startParsed?.date, due_date: dueParsed?.date,
                    completion_date: completionParsed?.date, completed: completed, priority: priorityValue, note: note,
                    location: location, url: url, target_list: targetList, tags: tagsArg,
                    add_tags: addTag.isEmpty ? nil : addTag, remove_tags: removeTag.isEmpty ? nil : removeTag,
                    alarms: alarms.isEmpty ? nil : alarms, recurrence_rules: rules.isEmpty ? nil : rules,
                    location_trigger: locTrigger, clear_alarms: clearAlarms ? true : nil,
                    clear_recurrence: clearRecurrence ? true : nil, clear_location_trigger: clearLocationTrigger ? true : nil,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, id)
            // Sandbox-only post-fetch check on the EXISTING title (the by-id target).
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            if let title { reminder.title = title }
            if let location { reminder.location = location.isEmpty ? nil : location }
            if let url { reminder.url = url.isEmpty ? nil : URL(string: url) }

            // Rebuild notes (preserving subtasks + reconciling tags) only when note/tags changed.
            if note != nil || tagsArg != nil || !addTag.isEmpty || !removeTag.isEmpty {
                reminder.notes = ReminderNotes.rebuildForUpdate(
                    current: reminder.notes, newNote: note,
                    tags: tagsArg,
                    addTags: addTag.isEmpty ? nil : addTag,
                    removeTags: removeTag.isEmpty ? nil : removeTag)
            }

            if let completionParsed { reminder.completionDate = completionParsed.date }
            if let completed { reminder.isCompleted = completed }
            if let priorityValue { reminder.priority = priorityValue }

            if clearRecurrence {
                reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
            } else if !rules.isEmpty {
                reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
                for rule in rules { reminder.addRecurrenceRule(try RecurrenceMapping.ekRule(from: rule)) }
            }

            // Alarms first (replace-all), then the location trigger (location-only), mirroring MCP.
            if clearAlarms {
                reminder.alarms?.forEach { reminder.removeAlarm($0) }
            } else if !alarms.isEmpty {
                reminder.alarms?.forEach { reminder.removeAlarm($0) }
                for a in alarms { reminder.addAlarm(try AlarmMapping.ekAlarm(from: a)) }
            }
            if clearLocationTrigger {
                reminder.alarms?.filter { $0.structuredLocation != nil }.forEach { reminder.removeAlarm($0) }
            } else if let locTrigger {
                reminder.alarms?.filter { $0.structuredLocation != nil }.forEach { reminder.removeAlarm($0) }
                reminder.addAlarm(try AlarmMapping.ekAlarm(from: Alarm(location_trigger: locTrigger)))
            }

            if let startParsed { reminder.startDateComponents = DateParsing.components(from: startParsed.date, dateOnly: startParsed.isDateOnly) }
            if let dueParsed { reminder.dueDateComponents = DateParsing.components(from: dueParsed.date, dateOnly: dueParsed.isDateOnly) }
            if startParsed != nil || dueParsed != nil { reminder.timeZone = TimeZone.current }

            if let targetList {
                guard let list = store.calendar(matching: targetList, entity: .reminder) else {
                    throw AppleError.notFound("no list named or id '\(targetList)'")
                }
                // Post-resolution destination check — the cross-list move is the one way a
                // sandboxed update can put a labeled item into a REAL list, and `--target-list`
                // takes a name or an id so only the resolved title can settle it.
                try requireLabeledList(list, sandboxActive: gate.sandboxActive)
                reminder.calendar = list
            }

            try store.save(reminder)
            try emitRemindersWrite(ReminderRead.enrich(ReminderMapping.reminder(from: reminder)),
                                   sandboxActive: gate.sandboxActive)
        }
    }

    func parsedLocationTrigger() throws -> LocationTrigger? {
        if geoLat == nil && geoLon == nil && geoRadius == nil && geoTitle == nil && geoProximity == nil { return nil }
        guard let lat = geoLat, let lon = geoLon else {
            throw AppleError.validation("location trigger needs both --geo-lat and --geo-lon")
        }
        let prox = (geoProximity ?? "enter").lowercased()
        guard ["enter", "leave", "depart", "exit"].contains(prox) else {
            throw AppleError.validation("bad --geo-proximity '\(geoProximity ?? "")' (enter|leave)")
        }
        return LocationTrigger(title: geoTitle, latitude: lat, longitude: lon, radius: geoRadius ?? 100, proximity: prox)
    }
}

// MARK: - delete

public struct TasksDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder (executes on call, like the MCP; --dry-run previews).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Reminder identifier (required).") public var id: String

    public init() {}

    public func run() throws {
        try runGuarded(tool: "reminders") {
            let gate = try ReminderWriteGuard.resolve(global)

            guard gate.willExecute else {
                try emitRemindersWrite(ReminderWritePreview(
                    action: "delete", id: id,
                    sandbox_target_unchecked: gate.sandboxActive ? true : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = EventStore()
            try store.requestAccess(to: .reminder, mode: .write)
            let reminder = try fetchReminder(store, id)
            // Sandbox-only post-fetch check: only delete a labeled test item inside the sandbox.
            try requireLabeledReminder(reminder, sandboxActive: gate.sandboxActive)
            try store.remove(reminder)
            try emitRemindersWrite(ReminderDeleteData(id: id, deleted: true),
                                   sandboxActive: gate.sandboxActive)
        }
    }
}
