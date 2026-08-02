import Foundation
import AppleKit
import EventKitCore
import EventKit

// Shared helpers for the Reminders command surface. Everything here is PURE + unit-testable
// (no EKEventStore, no TCC): CLI-native alarm/recurrence spec parsers (a friendlier superset of
// the MCP's JSON-blob inputs), the priority word↔int bridge, the dueWithin windows, the native
// tag + subtask model (notes-field storage, byte-compatible with the apple-events MCP), the
// phase write-guard, and the Encodable output DTOs.
//
// SUBTASK / TAG STORAGE — intentional model note. The apple-events MCP stores subtasks and tags
// INSIDE the reminder notes field (`---SUBTASKS---` block + `[#tag]` markers) because EventKit's
// PUBLIC API exposes NO native subtask/parent or tag surface on EKReminder / EKCalendarItem
// (verified against the macOS SDK headers: EKReminder only adds start/due components, completed,
// completionDate, priority; EKCalendarItem exposes title/notes/url/location/calendar/alarms/
// recurrenceRules/timeZone — nothing else). A "native parent-linkage" subtask model is therefore
// not reachable through the public framework (only via private API or an Apple-Shortcuts
// dependency, neither safe nor verifiable for an autonomous run). This port matches the MCP's
// notes-field storage: it preserves 100% operation-parity for all six subtask ops AND stays
// byte-compatible with the live MCP oracle so read output diffs cleanly. `Reminder.tags` is
// populated from the notes markers on read; `Reminder.parent_id` stays nil (no native linkage
// exists to populate it).
//
// (ReminderAlarmSpec / ReminderRecurrenceSpec duplicate the equivalent CalendarKit parsers by
// necessity — the natural shared home is EventKitCore, which is frozen; a future unfreeze should
// hoist them. The names are Reminder-prefixed to avoid any cross-module ambiguity in `apple`.)
//
// URL — intentional deviation. The reference MCP Swift backend ALSO mirrors a reminder's URL into
// its notes as a "URLs:\n- <url>" line (so a notes search matches the URL). This port stores the
// URL ONLY in the native `reminder.url` field (no notes pollution) and instead adds `reminder.url`
// to the `tasks read --search` predicate — so URL search-parity is preserved WITHOUT the notes
// mutation. The `url` output field is never dropped, so consumers keying on it are unaffected.
//
// INPUT VALIDATION — superset posture. The MCP imposes length caps (title 200 / note 2000 / …),
// a printable-Unicode charset, and an SSRF/non-http URL blocklist. This CLI deliberately does NOT
// replicate those *rejections*: a strict superset must ACCEPT everything the MCP accepts, and
// accepting MORE (a longer title, a non-http URL) is a valid superset. There is no injection or
// SSRF sink here — writes go straight to EventKit (no AppleScript/shell/SQL), and a stored URL is
// NEVER dereferenced — so relaxing the MCP's input rejections adds capability without risk. The
// few places we DO reject (empty subtask title, out-of-range priority/recurrence) are cases the
// MCP also rejects AND where acceptance would silently corrupt data.

// MARK: - Priority (0 none · 1 high · 5 medium · 9 low — the MCP convention)

public enum ReminderPriority {
    /// Parse a `--priority` value (int 0…9 or word none|high|medium|low) into EventKit's 0…9.
    /// The MCP enum is {0,1,5,9}; the CLI accepts any 0…9 int + the words as a documented superset.
    public static func parse(_ raw: String) throws -> Int {
        guard let v = EKEnum.priorityInt(from: raw) else {
            throw AppleError.validation("bad --priority '\(raw)' (0|1|5|9 or none|high|medium|low)")
        }
        guard (0...9).contains(v) else {
            throw AppleError.validation("--priority \(v) out of range (0…9; 0=none 1=high 5=medium 9=low)")
        }
        return v
    }

    /// Map a `--filter-priority` word to the EventKit integer it filters on (none0/high1/med5/low9).
    /// Mirrors the MCP's PRIORITY_FILTER_MAP exactly.
    public static func filterValue(_ word: String) throws -> Int {
        switch word.lowercased() {
        case "none": return 0
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default:
            throw AppleError.validation("bad --filter-priority '\(word)' (high|medium|low|none)")
        }
    }
}

// MARK: - dueWithin windows (parity: EventKitCLI.getReminders / dateFiltering.ts)

public enum DueWithin {
    public static let options = ["today", "tomorrow", "this-week", "overdue", "no-date"]

    public static func validate(_ s: String) throws {
        guard options.contains(s.lowercased()) else {
            throw AppleError.validation("bad --due-within '\(s)' (\(options.joined(separator: "|")))")
        }
    }

    /// Whether a reminder with the given due date matches a dueWithin window. `now`/`calendar`
    /// are injectable for deterministic tests. Mirrors the reference EventKitCLI semantics:
    /// no-date → reminder has no due date; overdue → due < startOfToday; today/tomorrow → the
    /// due date falls on that calendar day; this-week → within the current week-of-year interval.
    public static func matches(due: Date?, filter rawFilter: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let filter = rawFilter.lowercased()
        if filter == "no-date" { return due == nil }
        guard let due else { return false }
        let startToday = calendar.startOfDay(for: now)
        switch filter {
        case "overdue":
            return due < startToday
        case "today":
            let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) ?? startToday
            return due >= startToday && due < startTomorrow
        case "tomorrow":
            let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) ?? startToday
            let startDayAfter = calendar.date(byAdding: .day, value: 2, to: startToday) ?? startTomorrow
            return due >= startTomorrow && due < startDayAfter
        case "this-week":
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
            return week.contains(due)
        default:
            return false
        }
    }
}

// MARK: - Tags (notes-field `[#tag]` markers — parity with the MCP tagUtils.ts)

public enum ReminderTags {
    // /\[#([^\]]+)\]/g
    private static let tagRegex = try! NSRegularExpression(pattern: "\\[#([^\\]]+)\\]")

    /// Validate a tag against the MCP's rule: `^#?[a-zA-Z0-9_-]+$`, 1…50 chars (after optional #).
    public static func validate(_ tag: String) throws {
        let bare = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        guard (1...50).contains(bare.count),
              bare.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" }) else {
            throw AppleError.validation("bad tag '\(tag)' (letters, numbers, _ or -, 1…50 chars)")
        }
    }

    /// Strip a leading #, trim, lowercase (mirror normalizeTag).
    public static func normalize(_ tag: String) -> String {
        var s = tag
        if s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Extract tag names (deduped, lowercased, no `#`) from notes.
    public static func extract(_ notes: String?) -> [String] {
        guard let notes, !notes.isEmpty else { return [] }
        var out: [String] = []
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        for m in tagRegex.matches(in: notes, range: range) {
            guard let r = Range(m.range(at: 1), in: notes) else { continue }
            let tag = String(notes[r]).trimmingCharacters(in: .whitespaces).lowercased()
            if !tag.isEmpty && !out.contains(tag) { out.append(tag) }
        }
        return out
    }

    /// Remove `[#tag]` markers, trim, collapse 3+ newlines to 2 (mirror stripTags).
    public static func strip(_ notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return "" }
        var s = replaceAll(tagRegex, in: notes, with: "")
        s = s.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s
    }

    /// Format tags into `[#a] [#b]` (deduped/normalized, dropping empties).
    public static func format(_ tags: [String]) -> String {
        let formatted = tags.map(normalize).filter { !$0.isEmpty }.map { "[#\($0)]" }
        return formatted.joined(separator: " ")
    }

    /// Combine tags + notes: normalized/deduped tags prepended (mirror combineTagsAndNotes).
    public static func combine(tags: [String]?, notes: String?) -> String {
        let existing = extract(notes)
        let clean = strip(notes)
        let merged = (tags ?? []) + existing
        let all = dedup(merged.map(normalize))
        let formatted = format(all)
        if !formatted.isEmpty && !clean.isEmpty { return "\(formatted)\n\(clean)" }
        if !formatted.isEmpty { return formatted }
        return clean
    }

    /// Add tags to notes (merge with existing).
    public static func add(_ toAdd: [String], to notes: String?) -> String {
        let existing = extract(notes)
        let clean = strip(notes)
        let all = dedup(existing + toAdd.map(normalize))
        return recombine(format(all), clean)
    }

    /// Remove tags from notes.
    public static func remove(_ toRemove: [String], from notes: String?) -> String {
        let existing = extract(notes)
        let clean = strip(notes)
        let drop = Set(toRemove.map(normalize))
        let remaining = existing.filter { !drop.contains($0) }
        return recombine(format(remaining), clean)
    }

    /// A reminder has ALL filter tags (mirror hasAllTags).
    public static func hasAll(reminderTags: [String]?, filterTags: [String]) -> Bool {
        if filterTags.isEmpty { return true }
        guard let reminderTags, !reminderTags.isEmpty else { return false }
        let have = Set(reminderTags.map(normalize))
        return filterTags.map(normalize).allSatisfy { have.contains($0) }
    }

    private static func recombine(_ formatted: String, _ clean: String) -> String {
        if !formatted.isEmpty && !clean.isEmpty { return "\(formatted)\n\(clean)" }
        if !formatted.isEmpty { return formatted }
        return clean
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }
}

// MARK: - Subtasks (notes-field `---SUBTASKS---` block — parity with the MCP subtaskUtils.ts)
//
// `Subtask` + `SubtaskProgress` are defined in EventKitCore (so the shared `Reminder` model can
// carry `subtasks`/`subtask_progress` on read); this enum is the pure notes-field engine over them.

public enum ReminderSubtasks {
    public static let startMarker = "---SUBTASKS---"
    public static let endMarker = "---END SUBTASKS---"
    // /---SUBTASKS---\n([\s\S]*?)---END SUBTASKS---/
    private static let sectionRegex = try! NSRegularExpression(pattern: "---SUBTASKS---\\n([\\s\\S]*?)---END SUBTASKS---")
    // /^\[([ x])\]\s*\{([a-f0-9]+)\}\s*(.+)$/
    private static let lineRegex = try! NSRegularExpression(pattern: "^\\[([ x])\\]\\s*\\{([a-f0-9]+)\\}\\s*(.+)$")

    /// 8 hex chars (4 random bytes). Overridable in tests for determinism.
    public static func generateId() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Validate a subtask id (`^[a-f0-9]+$`, non-empty).
    public static func validateId(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ ($0.isNumber || ("a"..."f").contains($0)) && $0.isASCII }) else {
            throw AppleError.validation("bad subtask id '\(id)' (lowercase hex)")
        }
    }

    /// Parse the ordered subtasks out of a notes string.
    public static func parse(_ notes: String?) -> [Subtask] {
        guard let notes, !notes.isEmpty else { return [] }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        guard let m = sectionRegex.firstMatch(in: notes, range: range),
              let contentRange = Range(m.range(at: 1), in: notes) else { return [] }
        let content = String(notes[contentRange])
        var out: [Subtask] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lr = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let lm = lineRegex.firstMatch(in: line, range: lr),
                  let markR = Range(lm.range(at: 1), in: line),
                  let idR = Range(lm.range(at: 2), in: line),
                  let titleR = Range(lm.range(at: 3), in: line) else { continue }
            out.append(Subtask(
                id: String(line[idR]),
                title: String(line[titleR]).trimmingCharacters(in: .whitespaces),
                completed: line[markR] == "x"))
        }
        return out
    }

    /// Serialize subtasks into the `---SUBTASKS---` block (empty string if none).
    public static func serialize(_ subtasks: [Subtask]) -> String {
        guard !subtasks.isEmpty else { return "" }
        let lines = subtasks.map { "\($0.completed ? "[x]" : "[ ]") {\($0.id)} \($0.title)" }
        return "\(startMarker)\n\(lines.joined(separator: "\n"))\n\(endMarker)"
    }

    /// Remove the subtask block from notes, collapse 3+ newlines, trim (mirror stripSubtasks).
    public static func strip(_ notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return "" }
        var s = replaceAll(sectionRegex, in: notes, with: "")
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recombine subtasks with notes (subtasks appended after clean notes).
    public static func combine(subtasks: [Subtask], notes: String?) -> String {
        let clean = strip(notes)
        let section = serialize(subtasks)
        if !clean.isEmpty && !section.isEmpty { return "\(clean)\n\n\(section)" }
        if !section.isEmpty { return section }
        return clean
    }

    /// Reject an empty/whitespace subtask title (mirrors the MCP's min-1 rule). An empty title
    /// would serialize to `[ ] {id} ` and then silently VANISH on re-parse (the line regex needs
    /// ≥1 title char), so this fails loudly instead of losing the subtask.
    static func validatedTitle(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw AppleError.validation("subtask title cannot be empty") }
        return t
    }

    /// Build subtasks from titles (for create-with-subtasks). Throws on any empty title.
    public static func fromTitles(_ titles: [String], idGen: () -> String = generateId) throws -> [Subtask] {
        try titles.map { Subtask(id: idGen(), title: try validatedTitle($0), completed: false) }
    }

    public static func progress(_ subtasks: [Subtask]) -> SubtaskProgress {
        guard !subtasks.isEmpty else { return SubtaskProgress(completed: 0, total: 0, percentage: 100) }
        let done = subtasks.filter { $0.completed }.count
        return SubtaskProgress(completed: done, total: subtasks.count,
                               percentage: Int((Double(done) / Double(subtasks.count) * 100).rounded()))
    }

    // Mutations return the new (notes, subtasks) so the caller can save + echo.

    public static func add(title: String, notes: String?, idGen: () -> String = generateId) throws -> (notes: String, subtask: Subtask) {
        let clean = try validatedTitle(title)
        var subs = parse(notes)
        let new = Subtask(id: idGen(), title: clean, completed: false)
        subs.append(new)
        return (combine(subtasks: subs, notes: notes), new)
    }

    public static func update(id: String, title: String?, completed: Bool?, notes: String?) throws -> (notes: String, subtask: Subtask) {
        let cleanTitle = try title.map { try validatedTitle($0) }
        var subs = parse(notes)
        guard let idx = subs.firstIndex(where: { $0.id == id }) else {
            throw AppleError.notFound("subtask with id '\(id)' not found")
        }
        let cur = subs[idx]
        let updated = Subtask(id: cur.id, title: cleanTitle ?? cur.title, completed: completed ?? cur.completed)
        subs[idx] = updated
        return (combine(subtasks: subs, notes: notes), updated)
    }

    public static func remove(id: String, notes: String?) throws -> String {
        var subs = parse(notes)
        guard let idx = subs.firstIndex(where: { $0.id == id }) else {
            throw AppleError.notFound("subtask with id '\(id)' not found")
        }
        subs.remove(at: idx)
        return combine(subtasks: subs, notes: notes)
    }

    public static func toggle(id: String, notes: String?) throws -> (notes: String, subtask: Subtask) {
        var subs = parse(notes)
        guard let idx = subs.firstIndex(where: { $0.id == id }) else {
            throw AppleError.notFound("subtask with id '\(id)' not found")
        }
        let cur = subs[idx]
        let toggled = Subtask(id: cur.id, title: cur.title, completed: !cur.completed)
        subs[idx] = toggled
        return (combine(subtasks: subs, notes: notes), toggled)
    }

    public static func reorder(order: [String], notes: String?) throws -> (notes: String, subtasks: [Subtask]) {
        let subs = parse(notes)
        let byId = Dictionary(subs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in order where byId[id] == nil {
            throw AppleError.notFound("subtask with id '\(id)' not found")
        }
        let orderSet = Set(order)
        for s in subs where !orderSet.contains(s.id) {
            throw AppleError.validation("reorder is missing subtask id '\(s.id)' — all ids must be included")
        }
        let reordered = order.compactMap { byId[$0] }
        return (combine(subtasks: reordered, notes: notes), reordered)
    }
}

// MARK: - Notes rebuild on update (preserve subtasks + tags — parity with rebuildNotesForUpdate)

public enum ReminderNotes {
    /// Rebuild a reminder's notes for an update, preserving its subtasks and reconciling tags,
    /// exactly mirroring the MCP's `rebuildNotesForUpdate`. `current` is the reminder's existing
    /// notes. Returns the new notes string. Only call when note/tags/addTags/removeTags changed.
    public static func rebuildForUpdate(
        current: String?, newNote: String?, tags: [String]?, addTags: [String]?, removeTags: [String]?
    ) -> String {
        let existing = current ?? ""
        let existingSubtasks = ReminderSubtasks.parse(existing)
        let notesWithoutSubtasks = ReminderSubtasks.strip(existing)

        var notesWithTags = notesWithoutSubtasks
        if let addTags, !addTags.isEmpty { notesWithTags = ReminderTags.add(addTags, to: notesWithTags) }
        if let removeTags, !removeTags.isEmpty { notesWithTags = ReminderTags.remove(removeTags, from: notesWithTags) }

        if let tags {
            let baseNote: String
            if let newNote { baseNote = ReminderSubtasks.strip(ReminderTags.strip(newNote)) }
            else { baseNote = ReminderTags.strip(notesWithoutSubtasks) }
            notesWithTags = ReminderTags.combine(tags: tags, notes: baseNote)
        } else if let newNote {
            let cleanNewNote = ReminderSubtasks.strip(ReminderTags.strip(newNote))
            let tagsFromExisting = ReminderTags.extract(notesWithTags)
            notesWithTags = ReminderTags.combine(tags: tagsFromExisting, notes: cleanNewNote)
        }

        return ReminderSubtasks.combine(subtasks: existingSubtasks, notes: notesWithTags)
    }
}

// Shared regex "replace all" helper (NSRegularExpression → String).
func replaceAll(_ re: NSRegularExpression, in s: String, with template: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
}

// MARK: - Alarm spec parsing (--alarm, repeatable) — superset of the MCP alarm JSON

public enum ReminderAlarmSpec {
    /// Parse one `--alarm` spec into an `Alarm`:
    ///   relative : `-15m`, `-2h`, `-1d`, `+30m`, or bare seconds `-900` (negative = before)
    ///   geofence : `geo:<lat>,<lon>[,<radius>][,enter|leave][,<title>]`
    ///   absolute : any date string DateParsing accepts (e.g. `2026-07-15T09:00:00`)
    public static func parse(_ raw: String) throws -> Alarm {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw AppleError.validation("empty --alarm spec") }
        if s.lowercased().hasPrefix("geo:") {
            return try parseGeofence(String(s.dropFirst(4)))
        }
        if let offset = parseRelativeOffset(s) {
            return Alarm(relative_offset: offset)
        }
        if let parsed = try? DateParsing.parse(s) {
            return Alarm(absolute_date: parsed.date)
        }
        throw AppleError.validation("unrecognized --alarm '\(raw)' (use -15m|-2h|-1d, geo:lat,lon,…, or a date)")
    }

    static func parseRelativeOffset(_ s: String) -> Double? {
        guard let first = s.first, first == "-" || first == "+" else { return nil }
        let sign: Double = first == "-" ? -1 : 1
        let body = s.dropFirst()
        guard let unit = body.last else { return nil }
        if unit.isNumber { return Double(s) } // bare seconds, e.g. -900
        let magnitude = body.dropLast()
        guard let value = Double(magnitude) else { return nil }
        switch unit.lowercased() {
        case "s": return sign * value
        case "m": return sign * value * 60
        case "h": return sign * value * 3600
        case "d": return sign * value * 86_400
        default: return nil
        }
    }

    static func parseGeofence(_ body: String) throws -> Alarm {
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            throw AppleError.validation("geofence alarm needs at least lat,lon (got '\(body)')")
        }
        var radius = 100.0
        var proximity = "enter"
        var title: String?
        // Scan every part after lat,lon position-independently: a proximity keyword sets proximity,
        // a number sets radius, anything else is the title. (Position-independent so
        // `geo:lat,lon,leave` correctly sets proximity=leave rather than silently keeping enter.)
        for extra in parts.dropFirst(2) {
            let low = extra.lowercased()
            if low == "enter" || low == "leave" || low == "depart" || low == "exit" {
                proximity = low
            } else if let r = Double(extra) {
                radius = r
            } else if !extra.isEmpty {
                title = extra
            }
        }
        return Alarm(location_trigger: LocationTrigger(
            title: title, latitude: lat, longitude: lon, radius: radius, proximity: proximity))
    }
}

// MARK: - Recurrence spec parsing (--recurrence, repeatable) — superset of the MCP recurrence JSON

public enum ReminderRecurrenceSpec {
    /// Parse one `--recurrence` spec (`key=value;key=value`) into a `RecurrenceRule`:
    ///   freq=daily|weekly|monthly|yearly (required) · interval=N · count=N · until=YYYY-MM-DD
    ///   byday=1..7 (1=Sun) · bymonthday=1..31/-1..-31 · bymonth=1..12 · bysetpos=N
    public static func parse(_ raw: String) throws -> RecurrenceRule {
        var fields: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else {
                throw AppleError.validation("bad --recurrence segment '\(pair)' (use key=value)")
            }
            fields[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        guard let freq = fields["freq"], !freq.isEmpty else {
            throw AppleError.validation("--recurrence requires freq=daily|weekly|monthly|yearly")
        }
        let interval = try fields["interval"].map { try intOf($0, "interval") } ?? 1
        let count = try fields["count"].map { try intOf($0, "count") }
        var endDate: Date?
        if let until = fields["until"] { endDate = try DateParsing.parse(until).date }
        return RecurrenceRule(
            frequency: freq.lowercased(),
            interval: interval,
            end_date: endDate,
            occurrence_count: count,
            days_of_week: try intList(fields["byday"], "byday"),
            days_of_month: try intList(fields["bymonthday"], "bymonthday"),
            months_of_year: try intList(fields["bymonth"], "bymonth"),
            set_positions: try intList(fields["bysetpos"], "bysetpos"))
    }

    static func intOf(_ s: String, _ name: String) throws -> Int {
        guard let v = Int(s) else { throw AppleError.validation("--recurrence \(name) must be an integer (got '\(s)')") }
        return v
    }

    static func intList(_ s: String?, _ name: String) throws -> [Int]? {
        guard let s, !s.isEmpty else { return nil }
        return try s.split(separator: ",").map { try intOf($0.trimmingCharacters(in: .whitespaces), name) }
    }
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md) — the command-layer half of EventKitCore's
// write-guard contract. The EventKitCore engine never self-gates; this is the only gate there is.

/// Emit a reminders write result, tagging the envelope when the sandbox is engaged so a caller can
/// tell a restricted write from a normal one without re-reading the environment.
func emitRemindersWrite<T: Encodable>(_ data: T, sandboxActive: Bool) throws {
    try Output.emit(tool: "reminders", data: data, sandboxActive: sandboxActive)
}

public enum ReminderWriteGuard {
    /// The resolved write posture for one reminders command. Bound ONCE at the top of every write
    /// `run()` and threaded from there — never re-derived mid-command.
    public struct Gate {
        public let willExecute: Bool
        public let sandboxActive: Bool
    }

    /// Resolve a reminders write under write-model v2: **it executes by default**, exactly as
    /// calling the equivalent `mcp-server-apple-events` `reminders_*` action does. `--dry-run`
    /// previews; `APPLE_DRY_RUN` truthy restores dry-run-by-default; `--test-mode` or
    /// `APPLE_TEST_MODE` truthy engages the opt-in sandbox.
    ///
    /// ORACLE EVIDENCE (`mcp-server-apple-events@1.4.0` — the same bundle Calendar cites; see
    /// `CalendarWriteGuard.resolve` for the full derivation): no runtime env gate exists to mirror,
    /// `tools/index.ts` is pure routing, and `reminderRepository.deleteReminder` /
    /// `deleteReminderList` shell straight to the Swift CLI with no confirmation step. All eleven
    /// reminders writes are therefore bucket 3 — the v1 gate was CLI-only and becomes sandbox-only.
    /// NO `defaultDryRun` parameter, deliberately — see `CalendarWriteGuard.resolve`. All eleven
    /// Reminders writes execute by default with no per-surface exception, so the signature
    /// offers no choice to get wrong.
    public static func resolve(_ global: GlobalOptions) throws -> Gate {
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)
        return Gate(willExecute: willExecute, sandboxActive: sandboxActive)
    }

    /// SANDBOX-ONLY label check for an argv-supplied name — a new reminder/list title, a rename
    /// target, or a DESTINATION list. Runs on the preview path too: the value comes from argv, so a
    /// preview that skipped it would be withholding a check it can perfectly well perform.
    /// `nil` means "the caller had no such name to check" and is a no-op.
    ///
    /// Checking the DESTINATION (`--target-list`, `--new-name`) and not just the subject is the
    /// same fix the Notes flip needed: a sandboxed write that lands a labeled item inside a REAL
    /// list still modifies real user data, which is exactly what the sandbox promises not to do.
    ///
    /// `prefix:` is a test seam — see `CalendarWriteGuard.requireLabeled` for why a logic-tier test
    /// must not inherit the env-backed `TestMode.sandboxPrefix` it hard-codes expectations about.
    public static func requireLabeled(_ name: String?, what: String, sandboxActive: Bool,
                                      prefix: String? = nil) throws {
        guard sandboxActive, let name else { return }
        let required = prefix ?? TestMode.sandboxPrefix
        guard name.hasPrefix(required) else {
            throw AppleError.validation(
                "Sandbox is engaged: refusing to write to \(what) \"\(name)\" — it must be a "
                + "labeled '\(required)…' test item.")
        }
    }

    /// SANDBOX-ONLY check for a DESTINATION LIST, which `--target-list` documents as "name **or
    /// id**" and which `EventStore.calendar(matching:)` resolves id-first. A plain argv label test
    /// is WRONG here: a labeled list's opaque EventKit identifier does not begin with the sandbox
    /// prefix, so checking the raw string would refuse the very flow the repo's own conduct rules
    /// prescribe (`lists create` returns the list DTO including its id; `TEST-CLEANUP.md` tracks
    /// items BY id, so passing that id back is the natural next call).
    ///
    /// So: a value that IS labeled by name is accepted outright, on both paths. Anything else may
    /// still be the id of a perfectly labeled list, so the decision is DEFERRED to the execute
    /// path, where `requireLabeledDestinationList` re-checks the RESOLVED list's title.
    /// Returns `true` when the check was deferred, so the caller can disclose it via
    /// `sandbox_target_unchecked` instead of letting a silent non-refusal read as approval.
    public static func destinationCheckDeferred(_ nameOrId: String?, sandboxActive: Bool,
                                                prefix: String? = nil) -> Bool {
        guard sandboxActive, let nameOrId else { return false }
        return !nameOrId.hasPrefix(prefix ?? TestMode.sandboxPrefix)
    }
}

/// SANDBOX-ONLY post-resolution check for a list reached by name-or-id. Pairs with
/// `ReminderWriteGuard.destinationCheckDeferred`: call this on the execute path once the
/// `EKCalendar` is in hand, so an id-addressed list is vetted by its real title.
///
/// Used for BOTH roles a list can play: the DESTINATION of a create/move (`--target-list`) and the
/// SUBJECT of `lists update` / `lists delete` (`--name`). Every one of those flags is documented
/// "name or id" and resolves through `EventStore.calendar(matching:)`, which tries the identifier
/// FIRST — so none of them can be settled by a raw argv label test.
func requireLabeledList(_ list: EKCalendar, what: String = "destination list",
                        sandboxActive: Bool, prefix: String? = nil) throws {
    guard sandboxActive else { return }
    let required = prefix ?? TestMode.sandboxPrefix
    guard list.title.hasPrefix(required) else {
        throw AppleError.validation(
            "Sandbox is engaged: refusing to write to \(what) \"\(list.title)\" — it "
            + "must be a labeled '\(required)…' test list.")
    }
}

// MARK: - Reminder read enrichment (populate native-from-notes tags on the frozen model)

public enum ReminderRead {
    /// Map an EKReminder-derived base model and populate the notes-parsed enrichments the shared
    /// `ReminderMapping.reminder` leaves nil: `tags` (from `[#tag]` markers) plus `subtasks` +
    /// `subtask_progress` (from the `---SUBTASKS---` block) — so `tasks read` surfaces structured
    /// subtasks per reminder exactly like the MCP does, not just raw notes.
    public static func enrich(_ base: Reminder) -> Reminder {
        let tags = ReminderTags.extract(base.notes)
        let subs = ReminderSubtasks.parse(base.notes)
        return Reminder(
            id: base.id, title: base.title, notes: base.notes, url: base.url, location: base.location,
            list: base.list, list_id: base.list_id, account: base.account, time_zone: base.time_zone,
            external_id: base.external_id, completed: base.completed, completion_date: base.completion_date,
            due_date: base.due_date, start_date: base.start_date, priority: base.priority,
            has_recurrence: base.has_recurrence, recurrence_rules: base.recurrence_rules, alarms: base.alarms,
            location_trigger: base.location_trigger, tags: tags.isEmpty ? nil : tags, parent_id: base.parent_id,
            subtasks: subs.isEmpty ? nil : subs,
            subtask_progress: subs.isEmpty ? nil : ReminderSubtasks.progress(subs),
            last_modified: base.last_modified, creation_date: base.creation_date)
    }
}

// MARK: - Write-target label guard (shared by tasks + subtasks mutation paths)

public enum LabelGuard {
    /// Pure predicate: is `name` a labeled test target (has the sandbox prefix)? The env-gated
    /// enable check lives in `TestMode`/`ReminderWriteGuard`; this is the label discriminator the
    /// post-fetch guard applies, kept pure so the write-safety refusal is unit-testable.
    public static func isLabeled(_ name: String?) -> Bool {
        (name ?? "").hasPrefix(TestMode.sandboxPrefix)
    }
}

/// Fetch a reminder by id or throw `.notFound`.
func fetchReminder(_ store: EventStore, _ id: String) throws -> EKReminder {
    guard let r = store.reminder(withIdentifier: id) else {
        throw AppleError.notFound("no reminder with id '\(id)'")
    }
    return r
}

/// SANDBOX-ONLY post-fetch write-safety gate for a mutation that targets an EXISTING reminder by
/// opaque id. `ReminderWriteGuard.requireLabeled` can only vet a string the CALLER passes — it
/// cannot vet a by-id target, whose title lives in EventKit. So every by-id mutation (tasks
/// update/delete, all subtask ops) calls this AFTER fetching and BEFORE any
/// `store.save`/`store.remove`.
///
/// Outside the sandbox this is a no-op: the oracle's `reminders_tasks action=delete` deletes any
/// reminder by id on call, and write-model v2 says the CLI behaves the same. Inside the sandbox it
/// is fail-closed.
func requireLabeledReminder(_ reminder: EKReminder, sandboxActive: Bool,
                            prefix: String? = nil) throws {
    guard sandboxActive else { return }
    let required = prefix ?? TestMode.sandboxPrefix
    guard (reminder.title ?? "").hasPrefix(required) else {
        throw AppleError.validation(
            "Sandbox is engaged: refusing to mutate '\(reminder.title ?? "")' — it is not a labeled "
            + "test item (must start with '\(required)').")
    }
}

// MARK: - Output DTOs (the reminders wire shapes)

/// `tasks read` (no id): lists + reminders, mirroring the MCP's ReadResult.
public struct RemindersReadData: Encodable {
    public let lists: [ReminderList]
    public let reminders: [Reminder]
    public init(lists: [ReminderList], reminders: [Reminder]) {
        self.lists = lists
        self.reminders = reminders
    }
}

/// `lists read`: the reminder lists.
public struct ListsData: Encodable {
    public let lists: [ReminderList]
    public init(lists: [ReminderList]) { self.lists = lists }
}

/// `tasks delete` result.
public struct ReminderDeleteData: Encodable {
    /// Always `false` — see `ListDeleteData.dry_run`.
    public let dry_run: Bool
    public let id: String
    public let deleted: Bool
    public init(id: String, deleted: Bool) { self.dry_run = false; self.id = id; self.deleted = deleted }
}

/// `lists delete` result.
public struct ListDeleteData: Encodable {
    /// Always `false`: this DTO is only emitted from the EXECUTE path, so the flag states outright
    /// that the delete happened rather than leaving the caller to infer it from the ABSENCE of the
    /// preview's `dry_run: true`. Write-model v2 makes execute the default, so "no dry_run key"
    /// would be the common case and silence is the wrong signal for a destructive op.
    public let dry_run: Bool
    public let name: String
    public let deleted: Bool
    public init(name: String, deleted: Bool) { self.dry_run = false; self.name = name; self.deleted = deleted }
}

/// `subtasks read` + subtask mutation result: the parent + the full ordered subtask list + progress.
public struct SubtasksData: Encodable {
    public let reminder_id: String
    public let reminder_title: String?
    public let progress: SubtaskProgress
    public let subtasks: [Subtask]
    public let subtask: Subtask?
    public init(reminder_id: String, reminder_title: String?, progress: SubtaskProgress, subtasks: [Subtask], subtask: Subtask? = nil) {
        self.reminder_id = reminder_id
        self.reminder_title = reminder_title
        self.progress = progress
        self.subtasks = subtasks
        self.subtask = subtask
    }
}

/// Dry-run preview of a task create/update/delete — echoes the parsed + normalized intent so the
/// parse is verifiable without touching the live store (the default for a write without --execute).
public struct ReminderWritePreview: Encodable {
    public let dry_run: Bool
    public let action: String
    public let id: String?
    public let title: String?
    public let start_date: Date?
    public let due_date: Date?
    public let completion_date: Date?
    public let completed: Bool?
    public let priority: Int?
    public let note: String?
    public let location: String?
    public let url: String?
    public let target_list: String?
    public let tags: [String]?
    public let add_tags: [String]?
    public let remove_tags: [String]?
    public let subtasks: [String]?
    public let alarms: [Alarm]?
    public let recurrence_rules: [RecurrenceRule]?
    public let location_trigger: LocationTrigger?
    public let clear_alarms: Bool?
    public let clear_recurrence: Bool?
    public let clear_location_trigger: Bool?
    /// `true` when the sandbox is engaged AND this write is addressed by opaque id (update/delete),
    /// so the label check on the EXISTING reminder's title could not run at preview time — only the
    /// execute path fetches it. Absent whenever every applicable check DID run, which for `create`
    /// is always: its title and `--target-list` are both argv-computable and both are checked here.
    public let sandbox_target_unchecked: Bool?

    public init(
        action: String, id: String? = nil, title: String? = nil, start_date: Date? = nil,
        due_date: Date? = nil, completion_date: Date? = nil, completed: Bool? = nil, priority: Int? = nil,
        note: String? = nil, location: String? = nil, url: String? = nil, target_list: String? = nil,
        tags: [String]? = nil, add_tags: [String]? = nil, remove_tags: [String]? = nil, subtasks: [String]? = nil,
        alarms: [Alarm]? = nil, recurrence_rules: [RecurrenceRule]? = nil, location_trigger: LocationTrigger? = nil,
        clear_alarms: Bool? = nil, clear_recurrence: Bool? = nil, clear_location_trigger: Bool? = nil,
        sandbox_target_unchecked: Bool? = nil
    ) {
        self.dry_run = true
        self.sandbox_target_unchecked = sandbox_target_unchecked
        self.action = action
        self.id = id
        self.title = title
        self.start_date = start_date
        self.due_date = due_date
        self.completion_date = completion_date
        self.completed = completed
        self.priority = priority
        self.note = note
        self.location = location
        self.url = url
        self.target_list = target_list
        self.tags = tags
        self.add_tags = add_tags
        self.remove_tags = remove_tags
        self.subtasks = subtasks
        self.alarms = alarms
        self.recurrence_rules = recurrence_rules
        self.location_trigger = location_trigger
        self.clear_alarms = clear_alarms
        self.clear_recurrence = clear_recurrence
        self.clear_location_trigger = clear_location_trigger
    }
}

/// Dry-run preview of a list create/update/delete.
public struct ListWritePreview: Encodable {
    public let dry_run: Bool
    public let action: String
    public let name: String
    public let new_name: String?
    public let color: String?
    /// `true` when the sandbox is engaged AND `--name` could not be settled from argv because it
    /// is documented "name **or** id" and resolves id-first — so the label check runs on the
    /// resolved list's title, which only the execute path fetches. Absent on `create`, whose
    /// `--name` IS the new title and is therefore fully argv-checkable.
    public let sandbox_target_unchecked: Bool?
    public init(action: String, name: String, new_name: String? = nil, color: String? = nil,
                sandbox_target_unchecked: Bool? = nil) {
        self.dry_run = true
        self.action = action
        self.name = name
        self.new_name = new_name
        self.color = color
        self.sandbox_target_unchecked = sandbox_target_unchecked
    }
}

/// Dry-run preview of a subtask create/update/delete/toggle/reorder.
public struct SubtaskWritePreview: Encodable {
    public let dry_run: Bool
    public let action: String
    public let reminder_id: String
    public let subtask_id: String?
    public let title: String?
    public let completed: Bool?
    public let order: [String]?
    /// `true` when the sandbox is engaged: EVERY subtask op is addressed by parent reminder id, so
    /// the label check runs on the fetched parent and only the execute path fetches it. Disclosed
    /// rather than silently skipped — a preview that omits a check it cannot perform must say so.
    public let sandbox_target_unchecked: Bool?
    public init(action: String, reminder_id: String, subtask_id: String? = nil, title: String? = nil,
                completed: Bool? = nil, order: [String]? = nil,
                sandbox_target_unchecked: Bool? = nil) {
        self.dry_run = true
        self.action = action
        self.reminder_id = reminder_id
        self.subtask_id = subtask_id
        self.title = title
        self.completed = completed
        self.order = order
        self.sandbox_target_unchecked = sandbox_target_unchecked
    }
}
