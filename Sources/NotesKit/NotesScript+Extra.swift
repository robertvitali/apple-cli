import Foundation
import AppleKit

extension NotesScript {

    // MARK: - Note id validation (port of sanitizeId — used before batch AppleScript loops)

    static func isValidNoteId(_ id: String) -> Bool {
        let coreData = "^x-coredata://[0-9A-Fa-f-]+/IC[A-Za-z]+/p\\d+$"
        let temp = "^temp-\\d+-\\d+$"
        return id.range(of: coreData, options: .regularExpression) != nil
            || id.range(of: temp, options: .regularExpression) != nil
    }

    static func mapBatchStatus(_ id: String, _ status: String?, op: String) -> BatchItemResult {
        switch status {
        case "ok": return BatchItemResult(id: id, success: true, error: nil)
        case "pw": return BatchItemResult(id: id, success: false, error: "Note is password-protected")
        case "missing": return BatchItemResult(id: id, success: false, error: "Note not found")
        case "fail": return BatchItemResult(id: id, success: false, error: op == "delete" ? "Deletion failed" : "Move failed")
        default: return BatchItemResult(id: id, success: false, error: "Unknown error")
        }
    }

    // MARK: - Batch delete / move

    /// Partition ids into valid (runnable) + invalid, run the AppleScript loop on the valid ones,
    /// and merge results back in original order. Mirrors the reference's per-id independent loop.
    func batchDeleteNotes(ids: [String]) -> [BatchItemResult] {
        if ids.isEmpty { return [] }
        var results = [BatchItemResult?](repeating: nil, count: ids.count)
        var runnableIdx: [Int] = []
        for (i, id) in ids.enumerated() {
            if Self.isValidNoteId(id) { runnableIdx.append(i) }
            else { results[i] = BatchItemResult(id: id, success: false, error: "Invalid note ID") }
        }
        if !runnableIdx.isEmpty {
            let args = runnableIdx.map { ids[$0] } // argv = the runnable ids
            let body = """
            set out to ""
            repeat with rawId in argv
              set theId to (rawId as text)
              set noteRef to missing value
              try
                set noteRef to note id theId
              end try
              if noteRef is missing value then
                set out to out & "missing" & \(Self.asRS)
              else
                set isPw to false
                try
                  set isPw to (password protected of noteRef)
                end try
                if isPw then
                  set out to out & "pw" & \(Self.asRS)
                else
                  try
                    delete noteRef
                    set out to out & "ok" & \(Self.asRS)
                  on error
                    set out to out & "fail" & \(Self.asRS)
                  end try
                end if
              end if
            end repeat
            return out
            """
            do {
                let out = try runApp(body, args: args)
                let statuses = Self.splitRows(out).map { $0.trimmingCharacters(in: .whitespaces) }
                for (k, idx) in runnableIdx.enumerated() {
                    results[idx] = Self.mapBatchStatus(ids[idx], k < statuses.count ? statuses[k] : nil, op: "delete")
                }
            } catch {
                let msg = (error as? AppleError)?.message ?? "Batch delete failed"
                for idx in runnableIdx { results[idx] = BatchItemResult(id: ids[idx], success: false, error: msg) }
            }
        }
        return results.compactMap { $0 }
    }

    func batchMoveNotes(ids: [String], folder: String, account: String?) -> [BatchItemResult] {
        if ids.isEmpty { return [] }
        let acct = resolveAccount(account)
        var results = [BatchItemResult?](repeating: nil, count: ids.count)
        var runnableIdx: [Int] = []
        for (i, id) in ids.enumerated() {
            if Self.isValidNoteId(id) { runnableIdx.append(i) }
            else { results[i] = BatchItemResult(id: id, success: false, error: "Invalid note ID") }
        }
        if !runnableIdx.isEmpty {
            let runnableIds = runnableIdx.map { ids[$0] }
            let n = runnableIds.count
            // argv layout: [ids(1..n), folderComps(n+1..n+m), account(last)]
            var args = runnableIds
            let comps = Self.splitFolderPath(folder)
            let (expr, fargs) = Self.folderRefExpr(comps, startIndex: n + 1)
            args.append(contentsOf: fargs)
            let acctIdx = args.count + 1
            args.append(acct)
            let body = """
            set destFolder to \(expr) of account (item \(acctIdx) of argv)
            set out to ""
            repeat with i from 1 to \(n)
              set theId to (item i of argv) as text
              set noteRef to missing value
              try
                set noteRef to note id theId
              end try
              if noteRef is missing value then
                set out to out & "missing" & \(Self.asRS)
              else
                set isPw to false
                try
                  set isPw to (password protected of noteRef)
                end try
                if isPw then
                  set out to out & "pw" & \(Self.asRS)
                else
                  try
                    move noteRef to destFolder
                    set out to out & "ok" & \(Self.asRS)
                  on error
                    set out to out & "fail" & \(Self.asRS)
                  end try
                end if
              end if
            end repeat
            return out
            """
            do {
                let out = try runApp(body, args: args)
                let statuses = Self.splitRows(out).map { $0.trimmingCharacters(in: .whitespaces) }
                for (k, idx) in runnableIdx.enumerated() {
                    results[idx] = Self.mapBatchStatus(ids[idx], k < statuses.count ? statuses[k] : nil, op: "move")
                }
            } catch {
                let msg = (error as? AppleError)?.message ?? "Batch move failed"
                for idx in runnableIdx { results[idx] = BatchItemResult(id: ids[idx], success: false, error: msg) }
            }
        }
        return results.compactMap { $0 }
    }

    // MARK: - Health check

    func healthCheck() -> (healthy: Bool, checks: [HealthCheckItem]) {
        var checks: [HealthCheckItem] = []
        // Notes.app reachable?
        let appOK = (try? runApp("return \"ok\"", args: [])) == "ok"
        if appOK {
            checks.append(HealthCheckItem(name: "notes_app", passed: true, message: "Notes.app is accessible"))
        } else {
            checks.append(HealthCheckItem(name: "notes_app", passed: false, message: "Notes.app is not accessible"))
            return (false, checks)
        }
        // Automation permission?
        do {
            _ = try runApp("return name of account 1", args: [])
            checks.append(HealthCheckItem(name: "permissions", passed: true, message: "AppleScript automation permissions granted"))
        } catch {
            let denied = (error as? AppleError)?.type == AppleErrorType.permissionDenied
            checks.append(HealthCheckItem(name: "permissions", passed: !denied,
                message: denied ? "AppleScript permissions denied. Grant access in System Settings > Privacy & Security > Automation"
                                : "Permission check returned an error"))
            if denied { return (false, checks) }
        }
        // Accounts present?
        let accounts = (try? listAccounts()) ?? []
        if accounts.isEmpty {
            checks.append(HealthCheckItem(name: "accounts", passed: false,
                message: "No Notes accounts found. Set up an account in Notes.app first."))
            return (false, checks)
        }
        checks.append(HealthCheckItem(name: "accounts", passed: true,
            message: "Found \(accounts.count) account(s): \(accounts.map { $0.name }.joined(separator: ", "))"))
        // Basic op.
        let defaultAccountName = accounts.first?.name ?? "iCloud"
        let notes = (try? listNotes(account: defaultAccountName, folder: nil, modifiedSince: nil, limit: nil)) ?? []
        checks.append(HealthCheckItem(name: "operations", passed: true,
            message: "Basic operations working (\(notes.count) note(s) in \(defaultAccountName))"))
        return (checks.allSatisfy { $0.passed }, checks)
    }

    // MARK: - Stats

    func getNotesStats() throws -> NotesStats {
        let accounts = try listAccounts()
        var accountStats: [AccountStat] = []
        var warnings: [CoverageWarning] = []
        var totalNotes = 0
        for account in accounts {
            let body = """
            set out to ""
            repeat with fldr in folders
              set out to out & (name of fldr) & \(Self.asUS) & (count of notes of fldr) & \(Self.asRS)
            end repeat
            return out
            """
            do {
                let out = try run(body, args: [account.name], tellAccount: 1)
                var folderStats: [FolderStat] = []
                var accountTotal = 0
                for rec in Self.splitRows(out) {
                    let f = Self.splitFields(rec)
                    guard f.count >= 2 else { continue }
                    let count = Int(f[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    accountTotal += count
                    folderStats.append(FolderStat(name: f[0].trimmingCharacters(in: .whitespaces), note_count: count))
                }
                totalNotes += accountTotal
                accountStats.append(AccountStat(name: account.name, total_notes: accountTotal,
                                                folder_count: folderStats.count, folders: folderStats))
            } catch {
                warnings.append(CoverageWarning(scope: account.name,
                    reason: (error as? AppleError)?.message ?? "unknown error"))
            }
        }
        if !accounts.isEmpty && accountStats.isEmpty {
            throw AppleError.upstream("Failed to read folder stats for any of \(accounts.count) account(s).")
        }
        let recent = getRecentlyModifiedCounts()
        if let err = recent.error { warnings.append(CoverageWarning(scope: "recent-activity", reason: err)) }
        let scanned = accounts.count + 1
        let covered = scanned - warnings.count
        return NotesStats(
            total_notes: totalNotes, accounts: accountStats, recently_modified: recent.counts,
            coverage: Coverage(complete: warnings.isEmpty, scanned: scanned, covered: covered, warnings: warnings))
    }

    func getRecentlyModifiedCounts() -> (counts: RecentlyModified, error: String?) {
        let now = Date()
        let d1 = now.addingTimeInterval(-24 * 3600)
        let d7 = now.addingTimeInterval(-7 * 24 * 3600)
        let d30 = now.addingTimeInterval(-30 * 24 * 3600)
        let body = """
        \(Self.dateVarSetup(d1, name: "d1"))\(Self.dateVarSetup(d7, name: "d7"))\(Self.dateVarSetup(d30, name: "d30"))set c1 to 0
        set c7 to 0
        set c30 to 0
        repeat with acct in accounts
          set c1 to c1 + (count of (notes of acct whose modification date >= d1))
          set c7 to c7 + (count of (notes of acct whose modification date >= d7))
          set c30 to c30 + (count of (notes of acct whose modification date >= d30))
        end repeat
        return (c1 as text) & \(Self.asUS) & (c7 as text) & \(Self.asUS) & (c30 as text)
        """
        do {
            let out = try runApp(body, args: [])
            let f = Self.splitFields(out.trimmingCharacters(in: .whitespaces))
            func toInt(_ i: Int) -> Int { i < f.count ? (Int(f[i].trimmingCharacters(in: .whitespaces)) ?? 0) : 0 }
            return (RecentlyModified(last_24h: toInt(0), last_7d: toInt(1), last_30d: toInt(2)), nil)
        } catch {
            return (RecentlyModified(last_24h: 0, last_7d: 0, last_30d: 0),
                    (error as? AppleError)?.message ?? "unknown error")
        }
    }

    // MARK: - Export

    func exportNotesAsJson() throws -> NotesExport {
        let accounts = try listAccounts()
        var exportAccounts: [ExportAccount] = []
        var totalNotes = 0
        var totalFolders = 0
        for account in accounts {
            let folders = (try? listFolders(account: account.name)) ?? []
            var exportFolders: [ExportFolder] = []
            for folder in folders {
                var exportNotes: [ExportNote] = []
                let titles = (try? listNotes(account: account.name, folder: folder.name, modifiedSince: nil, limit: nil)) ?? []
                for title in titles {
                    guard let note = try? getNoteDetails(title: title, account: account.name) else { continue }
                    var content = ""
                    if !note.passwordProtected { content = (try? getNoteContent(title: title, account: account.name)) ?? "" }
                    exportNotes.append(ExportNote(
                        id: note.id, title: note.title, content: content,
                        plaintext: NotesText.htmlToPlaintext(content),
                        folder: folder.name, account: account.name,
                        created: note.created, modified: note.modified,
                        shared: note.shared, password_protected: note.passwordProtected))
                    totalNotes += 1
                }
                exportFolders.append(ExportFolder(name: folder.name, notes: exportNotes))
                totalFolders += 1
            }
            exportAccounts.append(ExportAccount(name: account.name, folders: exportFolders))
        }
        return NotesExport(export_date: Date(), version: "1.0", accounts: exportAccounts,
                           summary: ExportSummary(total_notes: totalNotes, total_folders: totalFolders,
                                                  total_accounts: accounts.count))
    }

    // MARK: - Markdown (AppleScript body + SQLite checklist enrichment)

    func getNoteMarkdown(title: String, account: String?) throws -> String {
        let html = try getNoteContent(title: title, account: account)
        if html.isEmpty { return "" }
        var md = NotesText.htmlToMarkdown(html)
        if let note = try? getNoteDetails(title: title, account: account) {
            let result = NotesStore.checklistItems(noteId: note.id)
            if let items = result.items { md = NotesText.enrichMarkdownWithChecklists(md, items: items) }
        }
        return md
    }

    func getNoteMarkdownById(id: String) throws -> String {
        let html = try getNoteContentById(id: id)
        if html.isEmpty { return "" }
        var md = NotesText.htmlToMarkdown(html)
        let result = NotesStore.checklistItems(noteId: id)
        if let items = result.items { md = NotesText.enrichMarkdownWithChecklists(md, items: items) }
        return md
    }
}
