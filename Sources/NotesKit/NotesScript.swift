import Foundation
import AppleKit

/// AppleScript bridge to Notes.app — the mechanism behind ~28 of the 34 capabilities (CRUD,
/// folders, accounts, selection, attachments, export, reveal-in-UI). Ported from
/// `apple-notes-mcp@2.5.12` `appleNotesManager.ts`.
///
/// SECURITY — the load-bearing difference from the reference: the reference string-interpolates
/// user data (titles, ids, bodies, folder names) into the AppleScript source with hand-rolled
/// escaping. apple-cli forbids that (AppleScript injection is RCE-class). EVERY user value is
/// passed through `AppleScriptRunner.run(_:arguments:)` as osascript argv and referenced inside
/// the script as `item N of argv`. Only NUMERIC, model-derived values (limits, date parts) are
/// embedded, and only after Swift-side validation.
struct NotesScript {
    let runner = AppleScriptRunner()
    let defaultAccount = "iCloud"

    // AppleScript builds field/record separators via `character id N`; we split on the same.
    static let US = "\u{1F}" // unit separator  (fields)
    static let RS = "\u{1E}" // record separator (rows)
    static let asUS = "(character id 31)"
    static let asRS = "(character id 30)"
    static let timeoutSeconds = 45

    func resolveAccount(_ account: String?) -> String {
        if let a = account, !a.isEmpty { return a }
        return defaultAccount
    }

    // MARK: script execution + error mapping

    /// Wrap a command body in `on run argv` + a `with timeout` (bounds Notes.app hangs), run it,
    /// and map osascript failures to the right `AppleError`. `tellAccount` (an argv index) scopes
    /// the body in `tell account (item i of argv)`.
    func run(_ commandBody: String, args: [String], tellAccount: Int? = nil) throws -> String {
        let accountOpen = tellAccount.map { "tell account (item \($0) of argv)\n" } ?? ""
        let accountClose = tellAccount != nil ? "end tell\n" : ""
        let script = """
        on run argv
          with timeout of \(Self.timeoutSeconds) seconds
            tell application "Notes"
              \(accountOpen)\(commandBody)
              \(accountClose)end tell
          end timeout
        end run
        """
        do {
            return try runner.run(script, arguments: args)
        } catch let e as AppleScriptRunner.RunError {
            throw Self.mapError(e)
        }
    }

    /// Run an app-level command (no account scope).
    func runApp(_ commandBody: String, args: [String]) throws -> String {
        try run(commandBody, args: args, tellAccount: nil)
    }

    static func mapError(_ e: AppleScriptRunner.RunError) -> AppleError {
        switch e {
        case .launchFailed(let m):
            return .upstream("osascript launch failed: \(m)")
        case .scriptFailed(_, let stderr):
            // NOTES-M3: AppleScript emits a CURLY apostrophe — `Notes got an error: Can’t get
            // note id "…". (-1728)` — so every `can't` / `doesn't` test below silently never fired
            // and real not-founds were classified upstream_error/69 instead of not_found/65.
            // Verified by byte-inspection of live stderr: U+2019, never U+0027. Normalise first.
            let s = stderr.lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'", options: .literal)
            if s.contains("not authorized") || s.contains("not permitted") || s.contains("access") && s.contains("denied") {
                return .permissionDenied("Notes automation not authorized. Grant access in System Settings > "
                    + "Privacy & Security > Automation, then retry.")
            }
            if s.contains("timed out") || s.contains("-1712") {
                return .upstream("Notes.app timed out. It may be unresponsive or busy syncing; try again.")
            }
            if s.contains("password protected") || s.contains("locked note") {
                return .validation("Note is password-protected. Unlock it in Notes.app first.")
            }
            // -1728 is AppleScript's canonical "can't get <specifier>" (errAENoSuchObject), matched
            // alongside the prose so a localised Notes.app still classifies correctly.
            if s.contains("can't get") || s.contains("doesn't exist") || s.contains("not found")
                || s.contains("-1728") {
                return .notFound("Notes could not find the requested item (verify the id/title/folder).")
            }
            if s.contains("already exists") {
                return .validation("A folder with that name already exists.")
            }
            return .upstream("Notes.app returned an error.")
        }
    }

    // MARK: parsing helpers

    /// Parse an AppleScript numeric date string `y-mo-d-h-mi-s` (from `asDatePartsExpr`). Falls
    /// back to `Date()` on a malformed value (matches the reference's tolerant parser).
    static func parseDate(_ raw: String) -> Date {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "-").map { Int($0) }
        if parts.count == 6, parts.allSatisfy({ $0 != nil }) {
            var c = DateComponents()
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
            c.hour = parts[3]; c.minute = parts[4]; c.second = parts[5]
            if let d = Self.gregorian.date(from: c) { return d }
        }
        return Date()
    }

    /// AppleScript dates are ALWAYS Gregorian (as is the oracle's JS `Date`), so both directions
    /// of the bridge pin the CALENDAR SYSTEM — under a non-Gregorian system locale (e.g.
    /// Buddhist, year 2569), `Calendar.current` would emit/interpret a wrong-era year.
    ///
    /// The TIME ZONE is deliberately left at its default (`TimeZone.current`) and MUST NOT be
    /// pinned: AppleScript's `current date` is local and the oracle's `new Date(y, mo-1, d, …)`
    /// / `getFullYear()` are local, so a UTC pin would shift every emitted and parsed Notes
    /// date by the local offset. This is why the shape differs from MailFormat.swift (pins UTC)
    /// and EventKitCore/DateParsing.swift (pins a caller-supplied zone) — those bridge
    /// zone-explicit formats; this one bridges a local-time API.
    static let gregorian = Calendar(identifier: .gregorian)

    /// AppleScript expression producing `y-mo-d-h-mi-s` for a variable (port of `asDatePartsExpr`).
    static func dateParts(_ v: String) -> String {
        "((year of \(v)) as text) & \"-\" & ((month of \(v)) as integer as text) & \"-\" & "
        + "((day of \(v)) as text) & \"-\" & ((hours of \(v)) as text) & \"-\" & "
        + "((minutes of \(v)) as text) & \"-\" & ((seconds of \(v)) as text)"
    }

    static func splitRows(_ output: String) -> [String] {
        output.components(separatedBy: RS).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    static func splitFields(_ row: String) -> [String] {
        row.components(separatedBy: US)
    }

    // MARK: folder path handling

    /// Split a nested folder path on unescaped `/`, unescape `\/`, drop empties (port of
    /// `splitFolderPath`).
    static func splitFolderPath(_ path: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in path {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "/" { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts.map { $0.replacingOccurrences(of: "\\/", with: "/") }.filter { !$0.isEmpty }
    }

    /// Build an AppleScript folder specifier `folder (item N)...of folder (item M)` for a nested
    /// path, referencing argv items (safe). Returns the expression plus the ordered component
    /// values to append to argv starting at `startIndex`.
    static func folderRefExpr(_ components: [String], startIndex: Int) -> (expr: String, args: [String]) {
        // Reversed: deepest folder first. argv[startIndex + k] holds components[k] (original order).
        let refs = (0..<components.count).reversed().map { k in
            "folder (item \(startIndex + k) of argv)"
        }
        return (refs.joined(separator: " of "), components)
    }

    // MARK: - Notes: read

    struct ParsedNote {
        let id: String
        let title: String
        let created: Date
        let modified: Date
        let shared: Bool
        let passwordProtected: Bool
    }

    /// Parse the 6-field note properties row (title, id, created, modified, shared, pp).
    static func parseNoteProps(_ output: String) -> ParsedNote? {
        let parts = splitFields(output)
        guard parts.count >= 6 else { return nil }
        return ParsedNote(
            id: parts[1].trimmingCharacters(in: .whitespaces),
            title: parts[0].trimmingCharacters(in: .whitespaces),
            created: parseDate(parts[2]),
            modified: parseDate(parts[3]),
            shared: parts[4].trimmingCharacters(in: .whitespaces) == "true",
            passwordProtected: parts[5].trimmingCharacters(in: .whitespaces) == "true")
    }

    func getNoteContent(title: String, account: String?) throws -> String {
        try run("return body of note (item 1 of argv)", args: [title, resolveAccount(account)], tellAccount: 2)
    }

    func getNoteContentById(id: String) throws -> String {
        try runApp("return body of note id (item 1 of argv)", args: [id])
    }

    func getNotePlaintext(title: String, account: String?) throws -> String {
        try run("get plaintext of note (item 1 of argv)", args: [title, resolveAccount(account)], tellAccount: 2)
    }

    /// macOS 12-15 fallback for `get-note-link`, mirroring the oracle's
    /// `return note link of (note id "<id>")`. The oracle string-interpolates a sanitized id;
    /// we bind it as argv instead, which is strictly safer and is the repo-wide rule.
    func noteLinkById(id: String) throws -> String {
        try runApp("return note link of (note id (item 1 of argv))", args: [id])
    }

    func getNotePlaintextById(id: String) throws -> String {
        try runApp("return plaintext of note id (item 1 of argv)", args: [id])
    }

    func getNoteById(id: String) throws -> ParsedNote? {
        let body = """
        set n to note id (item 1 of argv)
        set cd to creation date of n
        set md to modification date of n
        set noteProps to {name of n, id of n, \(Self.dateParts("cd")), \(Self.dateParts("md")), (shared of n as text), (password protected of n as text)}
        set AppleScript's text item delimiters to \(Self.asUS)
        return noteProps as text
        """
        let out = try runApp(body, args: [id])
        return Self.parseNoteProps(out)
    }

    func getNoteDetails(title: String, account: String?) throws -> ParsedNote? {
        let body = """
        set n to note (item 1 of argv)
        set cd to creation date of n
        set md to modification date of n
        set noteProps to {name of n, id of n, \(Self.dateParts("cd")), \(Self.dateParts("md")), (shared of n as text), (password protected of n as text)}
        set AppleScript's text item delimiters to \(Self.asUS)
        return noteProps as text
        """
        let out = try run(body, args: [title, resolveAccount(account)], tellAccount: 2)
        return Self.parseNoteProps(out)
    }

    // MARK: - Notes: search / list

    func searchNotes(query: String, searchContent: Bool, account: String?,
                     folder: String?, modifiedSince: Date?, limit: Int?) throws -> [NoteSummary] {
        var args = [query] // item 1
        var whereParts = [searchContent ? "body contains (item 1 of argv)" : "name contains (item 1 of argv)"]
        var dateSetup = ""
        if let d = modifiedSince {
            dateSetup = Self.dateVarSetup(d, name: "thresholdDate")
            whereParts.append("modification date >= thresholdDate")
        }
        var notesSource = "notes"
        if let folder, !folder.isEmpty {
            let comps = Self.splitFolderPath(folder)
            let (expr, fargs) = Self.folderRefExpr(comps, startIndex: args.count + 1)
            notesSource = "notes of \(expr)"
            args.append(contentsOf: fargs)
        }
        let limitCheck = (limit.map { "\n          if (count of resultList) >= \($0) then exit repeat" }) ?? ""
        let body = Self.searchBody(dateSetup: dateSetup, notesSource: notesSource,
                                   whereClause: whereParts.joined(separator: " and "),
                                   limitCheck: limitCheck)
        // Index computed on its own line: Swift evaluates the `args:` argument BEFORE the
        // inout `accountArgIndex(&args,…)` append, so an inline call would pass the pre-append
        // array while tellAccount points one past its end (an off-by-one that breaks every
        // account-scoped script). Splitting the two guarantees args includes the account.
        let acctIndex = accountArgIndex(&args, account)
        let resolvedAccount = args[acctIndex - 1] // the account we just appended (1-based index)
        let out = try run(body, args: args, tellAccount: acctIndex)
        return Self.parseSummaries(out, account: resolvedAccount)
    }

    /// The search-loop script body — the SINGLE source of the search script. `searchNotes` must
    /// never build this body inline: the regression tests in ScriptGenTests assert on THIS
    /// function's output, so an inlined second copy would drift outside their reach.
    ///
    /// TRUST CONTRACT: all four parameters are MODEL-DERIVED AppleScript fragments — numeric
    /// interpolations (`dateVarSetup`, limit counts) and argv references (`folderRefExpr`,
    /// fixed `item N of argv` where-clauses). User text must NEVER be passed in any of them;
    /// it reaches the script only as osascript argv (see the type-level SECURITY note above).
    ///
    /// Container binding is TWO-STEP, and load-bearing: the chained
    /// `set noteFolder to name of container of n` ALWAYS errors at runtime ("Can't make name of
    /// «class cntr» of «class note» ... into type Unicode text"), so the on-error fallback fired
    /// for every hit and every result was reported as folder "Notes" regardless of where it
    /// lived — including notes in Recently Deleted, which the oracle explicitly flags. Binding
    /// the container to its own variable first is what the oracle does and it resolves
    /// correctly.
    ///
    /// The per-note `created`/`modified` reads mirror the oracle's search loop exactly (three
    /// independent try-blocks, `""` on a failed date read): the oracle returns the note's REAL
    /// dates on every search hit, so a 3-field row would drop two fields the MCP emits.
    static func searchBody(dateSetup: String, notesSource: String,
                           whereClause: String, limitCheck: String) -> String {
        """
        \(dateSetup)set matchingNotes to \(notesSource) where \(whereClause)
        set resultList to {}
        set seenIds to {}
        repeat with n in matchingNotes
          try
            set noteName to name of n
            set noteId to id of n
            if seenIds does not contain noteId then
              set end of seenIds to noteId
              try
                set noteCreated to creation date of n
                set createdParts to \(Self.dateParts("noteCreated"))
              on error
                set createdParts to ""
              end try
              try
                set noteModified to modification date of n
                set modifiedParts to \(Self.dateParts("noteModified"))
              on error
                set modifiedParts to ""
              end try
              try
                set noteContainer to container of n
                set noteFolder to name of noteContainer
              on error
                set noteFolder to "Notes"
              end try
              set end of resultList to noteName & \(Self.asUS) & noteId & \(Self.asUS) & noteFolder & \(Self.asUS) & createdParts & \(Self.asUS) & modifiedParts\(limitCheck)
            end if
          end try
        end repeat
        set AppleScript's text item delimiters to \(Self.asRS)
        return resultList as text
        """
    }

    static func parseSummaries(_ out: String, account: String) -> [NoteSummary] {
        var seen = Set<String>()
        var result: [NoteSummary] = []
        for row in splitRows(out) {
            let f = splitFields(row)
            guard let title = f.first?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
            let id = f.count > 1 ? f[1].trimmingCharacters(in: .whitespaces) : ""
            if !id.isEmpty && seen.contains(id) { continue }
            if !id.isEmpty { seen.insert(id) }
            let folder = f.count > 2 ? f[2].trimmingCharacters(in: .whitespaces) : nil
            // Fields 3/4 are the note's REAL creation/modification dates (numeric y-mo-d-h-mi-s).
            // An empty field (the script's on-error branch) falls back to `Date()` inside
            // parseDate — the same now-fallback the oracle applies to an unreadable date.
            let created = parseDate(f.count > 3 ? f[3] : "")
            let modified = parseDate(f.count > 4 ? f[4] : "")
            result.append(NoteSummary(id: id, title: title, folder: folder?.isEmpty == true ? nil : folder,
                                      account: account, created: created, modified: modified))
        }
        return result
    }

    func listNotes(account: String?, folder: String?, modifiedSince: Date?, limit: Int?) throws -> [String] {
        var args: [String] = []
        var dateSetup = ""
        var baseSource = "notes"
        if let folder, !folder.isEmpty {
            let comps = Self.splitFolderPath(folder)
            let (expr, fargs) = Self.folderRefExpr(comps, startIndex: args.count + 1)
            baseSource = "notes of \(expr)"
            args.append(contentsOf: fargs)
        }
        var notesSource = baseSource
        if let d = modifiedSince {
            dateSetup = Self.dateVarSetup(d, name: "thresholdDate")
            notesSource = "(\(baseSource) whose modification date >= thresholdDate)"
        }
        let limitCheck = (limit.map { "\n            if (count of resultList) >= \($0) then exit repeat" }) ?? ""
        let body = """
        \(dateSetup)set resultList to {}
        set seenIds to {}
        repeat with n in \(notesSource)
          try
            set noteName to name of n
            set noteId to id of n
            if seenIds does not contain noteId then
              set end of seenIds to noteId
              set end of resultList to noteName & \(Self.asUS) & noteId\(limitCheck)
            end if
          end try
        end repeat
        set AppleScript's text item delimiters to \(Self.asRS)
        return resultList as text
        """
        // Index computed on its own line: Swift evaluates the `args:` argument BEFORE the
        // inout `accountArgIndex(&args,…)` append, so an inline call would pass the pre-append
        // array while tellAccount points one past its end (an off-by-one that breaks every
        // account-scoped script). Splitting the two guarantees args includes the account.
        let acctIndex = accountArgIndex(&args, account)
        let out = try run(body, args: args, tellAccount: acctIndex)
        var seen = Set<String>()
        var titles: [String] = []
        for row in Self.splitRows(out) {
            let f = Self.splitFields(row)
            guard let title = f.first?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
            let id = f.count > 1 ? f[1].trimmingCharacters(in: .whitespaces) : ""
            if !id.isEmpty && seen.contains(id) { continue }
            if !id.isEmpty { seen.insert(id) }
            titles.append(title)
        }
        return titles
    }

    /// Append the resolved account to args and return its 1-based argv index (for `tellAccount`).
    private func accountArgIndex(_ args: inout [String], _ account: String?) -> Int {
        args.append(resolveAccount(account))
        return args.count
    }

    /// AppleScript to set a date variable from a Swift `Date` (numeric parts only — safe to embed).
    static func dateVarSetup(_ date: Date, name: String) -> String {
        let c = Self.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let timeSeconds = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        // `set day of X to 1` FIRST is a rollover guard, not redundancy — it is the oracle's own
        // fix for its issue #86 and the CLI was missing it. `current date` carries TODAY's day, so
        // setting the month before clamping the day overflows whenever today's day exceeds the
        // target month's length: on 2026-07-31, `set month to 6` yields JULY 1 (June has 30 days),
        // and the later `set day to 1` cannot undo the month that already advanced. Verified live —
        // the unguarded sequence returns "July 1, 2026", the guarded one "June 1, 2026". The effect
        // was a silently short result set for `--modified-since` (list 3 vs oracle 5).
        return """
        set \(name) to current date
        set day of \(name) to 1
        set year of \(name) to \(c.year ?? 2000)
        set month of \(name) to \(c.month ?? 1)
        set day of \(name) to \(c.day ?? 1)
        set time of \(name) to \(timeSeconds)

        """
    }

    // MARK: - Notes: write

    func createNote(title: String, content: String, folder: String?, account: String?, html: Bool) throws -> String {
        let bodyHtml = NotesText.createNoteBody(title: title, content: content, html: html)
        var args = [bodyHtml] // item 1 = full body HTML
        let command: String
        if let folder, !folder.isEmpty {
            let comps = Self.splitFolderPath(folder)
            let (expr, fargs) = Self.folderRefExpr(comps, startIndex: args.count + 1)
            args.append(contentsOf: fargs)
            command = """
            set newNote to make new note at \(expr) with properties {body:(item 1 of argv)}
            return id of newNote
            """
        } else {
            command = """
            set newNote to make new note with properties {body:(item 1 of argv)}
            return id of newNote
            """
        }
        let acctIndex = accountArgIndex(&args, account) // see off-by-one note in searchNotes
        let out = try run(command, args: args, tellAccount: acctIndex)
        return Self.extractId(out, prefix: "note") ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractId(_ output: String, prefix: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(prefix) id ([^\\s]+)") else { return nil }
        let ns = output as NSString
        guard let m = re.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    func updateNoteById(id: String, newTitle: String?, newContent: String, html: Bool) throws {
        let effectiveTitle: String
        if html {
            effectiveTitle = ""
        } else if let t = newTitle, !t.isEmpty {
            effectiveTitle = t
        } else {
            effectiveTitle = (try getNoteById(id: id))?.title ?? ""
        }
        let bodyHtml = NotesText.updateNoteBody(effectiveTitle: effectiveTitle, content: newContent, html: html)
        // argv: 1 = id, 2 = body
        _ = try runApp("set body of note id (item 1 of argv) to (item 2 of argv)", args: [id, bodyHtml])
    }

    func updateNote(title: String, newTitle: String?, newContent: String, account: String?, html: Bool) throws {
        let effectiveTitle = html ? "" : (newTitle?.isEmpty == false ? newTitle! : title)
        let bodyHtml = NotesText.updateNoteBody(effectiveTitle: effectiveTitle, content: newContent, html: html)
        // argv: 1 = current title, 2 = body, 3 = account
        _ = try run("set body of note (item 1 of argv) to (item 2 of argv)",
                    args: [title, bodyHtml, resolveAccount(account)], tellAccount: 3)
    }

    func deleteNoteById(id: String) throws {
        _ = try runApp("delete note id (item 1 of argv)", args: [id])
    }

    func deleteNote(title: String, account: String?) throws {
        _ = try run("delete note (item 1 of argv)", args: [title, resolveAccount(account)], tellAccount: 2)
    }

    func moveNoteById(id: String, folder: String, account: String?) throws {
        let acct = resolveAccount(account)
        var args = [id] // item 1
        let comps = Self.splitFolderPath(folder)
        let (expr, fargs) = Self.folderRefExpr(comps, startIndex: args.count + 1)
        args.append(contentsOf: fargs)
        let acctIdx = args.count + 1
        args.append(acct)
        let body = """
        set destFolder to \(expr) of account (item \(acctIdx) of argv)
        set noteRef to note id (item 1 of argv)
        move noteRef to destFolder
        """
        _ = try runApp(body, args: args)
    }

    // MARK: - Folders

    func listFolders(account: String?) throws -> [Folder] {
        let acct = resolveAccount(account)
        let body = """
        set folderList to {}
        set allFolders to every folder
        repeat with f in allFolders
          set fRef to contents of f
          set cRef to container of fRef
          set parentId to ""
          if class of cRef is folder then
            set parentId to id of cRef
          end if
          set sharedFlag to shared of fRef as text
          set end of folderList to (id of fRef) & \(Self.asUS) & (name of fRef) & \(Self.asUS) & parentId & \(Self.asUS) & sharedFlag
        end repeat
        set AppleScript's text item delimiters to \(Self.asRS)
        return folderList as text
        """
        let out = try run(body, args: [acct], tellAccount: 1)
        return Self.buildFolderPaths(out, account: acct)
    }

    struct RawFolder { let id: String; let name: String; let parentId: String; let shared: Bool }

    static func buildFolderPaths(_ out: String, account: String) -> [Folder] {
        var raw: [RawFolder] = []
        for row in splitRows(out) {
            let f = splitFields(row)
            raw.append(RawFolder(
                id: (f.count > 0 ? f[0] : "").trimmingCharacters(in: .whitespaces),
                name: (f.count > 1 ? f[1] : "").trimmingCharacters(in: .whitespaces),
                parentId: (f.count > 2 ? f[2] : "").trimmingCharacters(in: .whitespaces),
                shared: (f.count > 3 ? f[3] : "").trimmingCharacters(in: .whitespaces).lowercased() == "true"))
        }
        let byId = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ entry: RawFolder) -> String {
            let safe = entry.name.replacingOccurrences(of: "/", with: "\\/")
            if entry.parentId.isEmpty { return safe }
            if let parent = byId[entry.parentId] { return path(parent) + "/" + safe }
            return safe
        }
        return raw.map { Folder(id: $0.id, name: path($0), account: account, shared: $0.shared) }
    }

    /// Create a folder path, creating intermediate segments and skipping existing ones (port of
    /// `createFolder`). Returns the resolved folder id (may be empty if resolution fails).
    func createFolder(name: String, account: String?) throws -> Folder {
        let acct = resolveAccount(account)
        let comps = Self.splitFolderPath(name)
        guard !comps.isEmpty else { throw AppleError.validation("Invalid folder name: \"\(name)\"") }
        for i in 0..<comps.count {
            // Check if the path up to i already exists.
            let prefix = Array(comps[0...i])
            var checkArgs: [String] = []
            let (expr, fargs) = Self.folderRefExpr(prefix, startIndex: checkArgs.count + 1)
            checkArgs.append(contentsOf: fargs)
            let acctIdx = accountArgIndex(&checkArgs, acct)
            let exists = (try? run("return id of \(expr)", args: checkArgs, tellAccount: acctIdx)) != nil
            if exists { continue }
            // Create segment i.
            if i == 0 {
                var mkArgs = [comps[0]]
                let mkAcctIdx = accountArgIndex(&mkArgs, acct) // split before call (inout eval order)
                _ = try run("make new folder with properties {name:(item 1 of argv)}",
                            args: mkArgs, tellAccount: mkAcctIdx)
            } else {
                let parent = Array(comps[0..<i])
                var mkArgs: [String] = [comps[i]] // item 1 = new segment name
                let (pexpr, pargs) = Self.folderRefExpr(parent, startIndex: mkArgs.count + 1)
                mkArgs.append(contentsOf: pargs)
                let mkAcctIdx = accountArgIndex(&mkArgs, acct) // split before call (inout eval order)
                _ = try run("make new folder at \(pexpr) with properties {name:(item 1 of argv)}",
                            args: mkArgs, tellAccount: mkAcctIdx)
            }
        }
        // Resolve the final folder id.
        var idArgs: [String] = []
        let (fullExpr, fullArgs) = Self.folderRefExpr(comps, startIndex: idArgs.count + 1)
        idArgs.append(contentsOf: fullArgs)
        let idAcctIdx = accountArgIndex(&idArgs, acct)
        let idOut = (try? run("return id of \(fullExpr)", args: idArgs, tellAccount: idAcctIdx)) ?? ""
        return Folder(id: Self.extractId(idOut, prefix: "folder") ?? "", name: name, account: acct, shared: false)
    }

    func deleteFolder(name: String, account: String?) throws {
        let acct = resolveAccount(account)
        var args: [String] = []
        let comps = Self.splitFolderPath(name)
        // SINK GUARD — `createFolder` has had this since it was written; `deleteFolder` did not,
        // and that asymmetry became exploitable the moment write-model v2 stopped refusing an
        // unlabeled name up front. With `comps` empty, `folderRefExpr([])` returns an EMPTY
        // specifier and the emitted script is a bare `delete` inside `tell account …`, whose
        // direct object binds to the ACCOUNT CONTAINER rather than a folder. Guarding at the
        // sink (not only at the command) so no future caller can re-open it.
        guard !comps.isEmpty else { throw AppleError.validation("Invalid folder name: \"\(name)\"") }
        let (expr, fargs) = Self.folderRefExpr(comps, startIndex: args.count + 1)
        args.append(contentsOf: fargs)
        let acctIndex = accountArgIndex(&args, acct) // split before call (inout eval order)
        _ = try run("delete \(expr)", args: args, tellAccount: acctIndex)
    }

    // MARK: - Accounts

    func listAccounts() throws -> [Account] {
        let body = """
        set resultList to {}
        repeat with a in accounts
          set aRef to contents of a
          set defaultFolderId to ""
          set defaultFolderName to ""
          try
            set fRef to default folder of aRef
            set defaultFolderId to id of fRef
            set defaultFolderName to name of fRef
          end try
          set upgradedFlag to upgraded of aRef as text
          set end of resultList to (id of aRef) & \(Self.asUS) & (name of aRef) & \(Self.asUS) & upgradedFlag & \(Self.asUS) & defaultFolderId & \(Self.asUS) & defaultFolderName
        end repeat
        set AppleScript's text item delimiters to \(Self.asRS)
        return resultList as text
        """
        let out = try runApp(body, args: [])
        return Self.splitRows(out).map { row -> Account in
            let f = Self.splitFields(row)
            if f.count == 1 {
                return Account(id: nil, name: f[0].trimmingCharacters(in: .whitespaces), upgraded: nil,
                               default_folder_id: nil, default_folder: nil)
            }
            let dfid = (f.count > 3 ? f[3] : "").trimmingCharacters(in: .whitespaces)
            let dfn = (f.count > 4 ? f[4] : "").trimmingCharacters(in: .whitespaces)
            return Account(
                id: (f.count > 0 ? f[0] : "").trimmingCharacters(in: .whitespaces),
                name: (f.count > 1 ? f[1] : "").trimmingCharacters(in: .whitespaces),
                upgraded: (f.count > 2 ? f[2] : "").trimmingCharacters(in: .whitespaces).lowercased() == "true",
                default_folder_id: dfid.isEmpty ? nil : dfid,
                default_folder: dfn.isEmpty ? nil : dfn)
        }
    }

    func getDefaultLocation() throws -> DefaultLocation {
        let body = """
        set aRef to default account
        set fRef to default folder of aRef
        return (id of aRef) & \(Self.asUS) & (name of aRef) & \(Self.asUS) & (upgraded of aRef as text) & \(Self.asUS) & (id of fRef) & \(Self.asUS) & (name of fRef) & \(Self.asUS) & (shared of fRef as text)
        """
        let out = try runApp(body, args: [])
        let f = Self.splitFields(out)
        guard f.count >= 6 else { throw AppleError.upstream("Failed to parse default Notes location.") }
        let accountName = f[1].trimmingCharacters(in: .whitespaces)
        let account = Account(
            id: f[0].trimmingCharacters(in: .whitespaces), name: accountName,
            upgraded: f[2].trimmingCharacters(in: .whitespaces).lowercased() == "true",
            default_folder_id: f[3].trimmingCharacters(in: .whitespaces),
            default_folder: f[4].trimmingCharacters(in: .whitespaces))
        let folder = Folder(id: f[3].trimmingCharacters(in: .whitespaces), name: f[4].trimmingCharacters(in: .whitespaces),
                            account: accountName, shared: f[5].trimmingCharacters(in: .whitespaces).lowercased() == "true")
        return DefaultLocation(account: account, folder: folder)
    }

    func listSharedNotes() throws -> [SharedNote] {
        var shared: [SharedNote] = []
        for account in try listAccounts() {
            let body = """
            set resultList to {}
            repeat with n in notes
              if shared of n is true then
                set cd to creation date of n
                set md to modification date of n
                set end of resultList to (name of n) & \(Self.asUS) & (id of n) & \(Self.asUS) & \(Self.dateParts("cd")) & \(Self.asUS) & \(Self.dateParts("md")) & \(Self.asUS) & (shared of n as text) & \(Self.asUS) & (password protected of n as text)
              end if
            end repeat
            set AppleScript's text item delimiters to \(Self.asRS)
            return resultList as text
            """
            guard let out = try? run(body, args: [account.name], tellAccount: 1) else { continue }
            for row in Self.splitRows(out) {
                let f = Self.splitFields(row)
                guard f.count >= 6 else { continue }
                shared.append(SharedNote(
                    id: f[1].trimmingCharacters(in: .whitespaces),
                    title: f[0].trimmingCharacters(in: .whitespaces),
                    account: account.name,
                    created: Self.parseDate(f[2]), modified: Self.parseDate(f[3]),
                    shared: f[4].trimmingCharacters(in: .whitespaces) == "true",
                    password_protected: f[5].trimmingCharacters(in: .whitespaces) == "true"))
            }
        }
        return shared
    }

    func getSelectedNotes() throws -> [SelectedNote] {
        let body = """
        set selectedNotes to selection
        set noteList to {}
        repeat with n in selectedNotes
          set nRef to contents of n
          set createdDate to creation date of nRef
          set modifiedDate to modification date of nRef
          set createdParts to \(Self.dateParts("createdDate"))
          set modifiedParts to \(Self.dateParts("modifiedDate"))
          set folderName to ""
          set accountName to ""
          try
            set fRef to container of nRef
            set folderName to name of fRef
            set aRef to container of fRef
            set accountName to name of aRef
          end try
          set end of noteList to (id of nRef) & \(Self.asUS) & (name of nRef) & \(Self.asUS) & createdParts & \(Self.asUS) & modifiedParts & \(Self.asUS) & (shared of nRef as text) & \(Self.asUS) & (password protected of nRef as text) & \(Self.asUS) & folderName & \(Self.asUS) & accountName
        end repeat
        set AppleScript's text item delimiters to \(Self.asRS)
        return noteList as text
        """
        let out = try runApp(body, args: [])
        return Self.splitRows(out).map { row in
            let f = Self.splitFields(row)
            func at(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
            return SelectedNote(
                id: at(0), title: at(1), created: Self.parseDate(at(2)), modified: Self.parseDate(at(3)),
                shared: at(4).lowercased() == "true", password_protected: at(5).lowercased() == "true",
                folder: at(6).isEmpty ? nil : at(6), account: at(7).isEmpty ? nil : at(7))
        }
    }

    // MARK: - Reveal in UI

    private func showById(_ kind: String, id: String, separately: Bool) throws {
        // Structural clause "separately true" — not user data; id via argv.
        let clause = separately ? " separately true" : ""
        _ = try runApp("show \(kind) id (item 1 of argv)\(clause)", args: [id])
    }
    func showNote(id: String, separately: Bool) throws { try showById("note", id: id, separately: separately) }
    func showFolder(id: String, separately: Bool) throws { try showById("folder", id: id, separately: separately) }
    func showAccount(id: String, separately: Bool) throws { try showById("account", id: id, separately: separately) }

    func showAttachment(noteId: String, attachmentId: String, separately: Bool) throws {
        let clause = separately ? " separately true" : ""
        let body = """
        set theNote to note id (item 1 of argv)
        set theAttachment to missing value
        repeat with a in attachments of theNote
          if (id of a as text) is (item 2 of argv) then
            set theAttachment to a
            exit repeat
          end if
        end repeat
        if theAttachment is missing value then
          return "ERR" & \(Self.asUS) & "attachment not found"
        end if
        show theAttachment\(clause)
        return "OK"
        """
        let out = try runApp(body, args: [noteId, attachmentId])
        if out.trimmingCharacters(in: .whitespaces).hasPrefix("ERR") {
            throw AppleError.notFound("Attachment \"\(attachmentId)\" not found on note \"\(noteId)\".")
        }
    }

    // MARK: - Attachments

    private static let attachmentScanBody = """
      set attachmentList to {}
      repeat with a in attachments of theNote
        set attachId to id of a
        set attachName to name of a
        set attachContentId to content identifier of a
        set attachUrl to ""
        try
          set attachUrl to URL of a as text
        end try
        set createdDate to creation date of a
        set modifiedDate to modification date of a
        set createdParts to \(dateParts("createdDate"))
        set modifiedParts to \(dateParts("modifiedDate"))
        set sharedFlag to shared of a as text
        set end of attachmentList to attachId & \(asUS) & attachName & \(asUS) & attachContentId & \(asUS) & attachUrl & \(asUS) & createdParts & \(asUS) & modifiedParts & \(asUS) & sharedFlag
      end repeat
      set output to ""
      repeat with recordItem in attachmentList
        set output to output & recordItem & \(asRS)
      end repeat
      return output
    """

    func listAttachmentsById(id: String) throws -> [Attachment] {
        let out = try runApp("set theNote to note id (item 1 of argv)\n\(Self.attachmentScanBody)", args: [id])
        return Self.parseAttachments(out)
    }

    func listAttachments(title: String, account: String?) throws -> [Attachment] {
        let out = try run("set theNote to note (item 1 of argv)\n\(Self.attachmentScanBody)",
                          args: [title, resolveAccount(account)], tellAccount: 2)
        return Self.parseAttachments(out)
    }

    static func parseAttachments(_ out: String) -> [Attachment] {
        splitRows(out).compactMap { row in
            let f = splitFields(row)
            guard f.count >= 3 else { return nil }
            func at(_ i: Int) -> String? { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : nil }
            let url = at(3)
            let normalizedUrl = (url == nil || url == "" || url == "missing value") ? nil : url
            return Attachment(
                id: at(0) ?? "", name: at(1) ?? "", content_type: at(2) ?? "",
                content_id: (at(2)?.isEmpty == false) ? at(2) : nil,
                url: normalizedUrl,
                created: (at(4) != nil) ? parseDate(at(4)!) : nil,
                modified: (at(5) != nil) ? parseDate(at(5)!) : nil,
                shared: at(6).map { $0.lowercased() == "true" })
        }
    }

    struct SaveResult { let ok: Bool; let savedPath: String?; let name: String?; let contentType: String?; let error: String? }

    /// Save one attachment to disk via Notes' `save` (port of `saveAttachmentById`). Path is
    /// validated by `AttachmentFS.assertSafeSavePath` before AppleScript runs.
    func saveAttachmentById(noteId: String, attachmentId: String, savePath: String) throws -> SaveResult {
        let abs: String
        do {
            abs = try AttachmentFS.assertSafeSavePath(savePath)
            try AttachmentFS.ensureParentDir(abs)
            try AttachmentFS.assertResolvedParentContained(abs) // symlink-aware re-check post-mkdir
        } catch {
            return SaveResult(ok: false, savedPath: nil, name: nil, contentType: nil,
                              error: (error as? AttachmentFS.FSError)?.description ?? String(describing: error))
        }
        // argv: 1 = noteId, 2 = attachmentId, 3 = absolute path
        let body = """
        set theNote to note id (item 1 of argv)
        set theAttachment to missing value
        repeat with a in attachments of theNote
          if (id of a as text) is (item 2 of argv) then
            set theAttachment to a
            exit repeat
          end if
        end repeat
        if theAttachment is missing value then
          return "ERR" & \(Self.asUS) & "attachment not found"
        end if
        set attachUrl to ""
        try
          set attachUrl to URL of theAttachment as text
        end try
        try
          save theAttachment in (POSIX file (item 3 of argv))
        on error errMsg
          return "ERRSAVE" & \(Self.asUS) & errMsg & \(Self.asUS) & attachUrl
        end try
        return "OK" & \(Self.asUS) & (name of theAttachment) & \(Self.asUS) & (content identifier of theAttachment)
        """
        let out = try runApp(body, args: [noteId, attachmentId, abs])
        let parts = Self.splitFields(out.trimmingCharacters(in: .whitespaces))
        if parts.first == "ERRSAVE" {
            let saveErr = (parts.count > 1 ? parts[1] : "unknown error").trimmingCharacters(in: .whitespaces)
            let rawUrl = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            let url = (rawUrl.isEmpty || rawUrl == "missing value") ? nil : rawUrl
            let hint = url.map { " This attachment appears to be a link preview (URL: \($0)) rather than a file, and link previews have no file payload to save." } ?? ""
            return SaveResult(ok: false, savedPath: nil, name: nil, contentType: nil,
                              error: "Notes could not save this attachment: \(saveErr).\(hint)")
        }
        if parts.first != "OK" {
            return SaveResult(ok: false, savedPath: nil, name: nil, contentType: nil,
                              error: parts.count > 1 ? parts[1] : "attachment not found")
        }
        if !AttachmentFS.fileExists(abs) || AttachmentFS.fileSize(abs) == 0 {
            return SaveResult(ok: false, savedPath: nil, name: nil, contentType: nil,
                              error: "Notes reported success but no file was written to \(abs)")
        }
        return SaveResult(ok: true, savedPath: abs,
                          name: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil,
                          contentType: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : nil,
                          error: nil)
    }

    struct FetchResult { let ok: Bool; let name: String?; let contentType: String?; let base64: String?; let bytes: Int?; let error: String? }

    /// Fetch attachment bytes as base64 via a temp-file round-trip + size cap (port of
    /// `getAttachmentBase64ById`).
    func fetchAttachmentBase64(noteId: String, attachmentId: String) throws -> FetchResult {
        let dir = try AttachmentFS.makeTempDir()
        defer { AttachmentFS.cleanupTempDir(dir) }
        let dest = dir + "/attachment.bin"
        let saved = try saveAttachmentById(noteId: noteId, attachmentId: attachmentId, savePath: dest)
        guard saved.ok, let path = saved.savedPath else {
            return FetchResult(ok: false, name: nil, contentType: nil, base64: nil, bytes: nil, error: saved.error)
        }
        do {
            let b64 = try AttachmentFS.readFileBase64Capped(path)
            return FetchResult(ok: true, name: saved.name, contentType: saved.contentType,
                               base64: b64, bytes: AttachmentFS.fileSize(path), error: nil)
        } catch {
            return FetchResult(ok: false, name: nil, contentType: nil, base64: nil, bytes: nil,
                               error: (error as? AttachmentFS.FSError)?.description ?? String(describing: error))
        }
    }
}
