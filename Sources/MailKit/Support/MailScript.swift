import Foundation
import AppleKit

/// AppleScript bridge to Mail.app for operations the Envelope Index can't serve: full message
/// bodies and the live UI selection (P1), plus the write surface (P2). ALL user/data-derived
/// values are passed as `arguments:` (osascript argv) — never interpolated into script source
/// (AppleScript injection is RCE-class; see `AppleScriptRunner`).
public struct MailScript {
    public let runner: AppleScriptRunner
    public init(runner: AppleScriptRunner = AppleScriptRunner()) { self.runner = runner }

    static let RS = String(UnicodeScalar(30)!)   // record separator
    static let US = String(UnicodeScalar(31)!)   // unit separator

    // MARK: Body fetch (get --include-content)

    /// Full plaintext body of the message whose RFC-5322 `message id` matches. BOUNDED like the
    /// mutation `locator` (see below): Mail has no message-id index, so `whose message id is` is a
    /// client-side linear scan — and Gmail's "[Gmail]/All Mail" holds the whole archive, so an
    /// unbounded scan hangs. INBOX of the target account(s) first, then non-"All Mail" mailboxes;
    /// a body that lives only in a deep archive returns "" (caller falls back to the index snippet)
    /// rather than hanging.
    private static let bodyScript = """
    on run argv
        set targetID to item 1 of argv
        set acctName to item 2 of argv
        tell application "Mail"
            set accts to accounts
            if acctName is not "" then
                try
                    set accts to {first account whose name is acctName}
                end try
            end if
            repeat with a in accts
                try
                    set msgs to (messages of (mailbox "INBOX" of a) whose message id is targetID)
                    if (count of msgs) > 0 then return (content of (item 1 of msgs))
                end try
            end repeat
            repeat with a in accts
                repeat with mbx in mailboxes of a
                    set mname to (name of mbx)
                    if mname is not "INBOX" and mname does not contain "[Gmail]" then
                        try
                            set msgs to (messages of mbx whose message id is targetID)
                            if (count of msgs) > 0 then return (content of (item 1 of msgs))
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return ""
    end run
    """

    public func body(internetMessageID: String, accountName: String?) throws -> String? {
        // Mail's `message id` carries angle brackets; try the bracketed form.
        let bare = MailFormat.stripAngleBrackets(internetMessageID) ?? internetMessageID
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(MailScript.bodyScript, arguments: [candidate, accountName ?? ""])
            if !out.isEmpty { return out }
        }
        return nil
    }

    // MARK: Live selection (selected)

    public struct ScriptSelection {
        public let applescriptID: String
        public let internetMessageID: String?
        public let subject: String
        public let sender: String
        public let readStatus: Bool
        public let flagged: Bool
        public let content: String?
    }

    private static let selectionScript = """
    on run argv
        set inc to item 1 of argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        tell application "Mail"
            set sel to selection
            set out to ""
            repeat with m in sel
                set c to ""
                if inc is "1" then
                    try
                        set c to content of m
                    end try
                end if
                set mid to ""
                try
                    set mid to message id of m
                end try
                set out to out & (id of m) & US & mid & US & (subject of m) & US & (sender of m) & US & (read status of m) & US & (flagged status of m) & US & c & RS
            end repeat
            return out
        end tell
    end run
    """

    // MARK: Rules (list is a live read; mutations are gated behind --execute)

    private static let listRulesScript = """
    set US to (ASCII character 31)
    set RS to (ASCII character 30)
    tell application "Mail"
        set out to ""
        set i to 0
        repeat with r in rules
            set i to i + 1
            set out to out & i & US & (name of r) & US & (enabled of r) & RS
        end repeat
        return out
    end tell
    """

    public struct ScriptRule { public let index: Int; public let name: String; public let enabled: Bool }

    public func listRules() throws -> [ScriptRule] {
        let raw = try runner.run(MailScript.listRulesScript)
        var rules: [ScriptRule] = []
        for record in raw.components(separatedBy: MailScript.RS)
        where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = record.components(separatedBy: MailScript.US)
            guard f.count >= 3, let idx = Int(f[0].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            rules.append(ScriptRule(index: idx, name: f[1],
                                    enabled: f[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"))
        }
        return rules
    }

    /// Enable/disable a rule by 1-based index (trivially reversible). argv-passed.
    private static let setRuleEnabledScript = """
    on run argv
        set idx to (item 1 of argv) as integer
        set en to (item 2 of argv) is "1"
        tell application "Mail"
            set enabled of (rule idx) to en
            return "ok"
        end tell
    end run
    """
    public func setRuleEnabled(index: Int, enabled: Bool) throws {
        _ = try runner.run(MailScript.setRuleEnabledScript, arguments: [String(index), enabled ? "1" : "0"])
    }

    /// Delete a rule by 1-based index (irreversible). argv-passed.
    private static let deleteRuleScript = """
    on run argv
        set idx to (item 1 of argv) as integer
        tell application "Mail"
            delete (rule idx)
            return "ok"
        end tell
    end run
    """
    public func deleteRule(index: Int) throws {
        _ = try runner.run(MailScript.deleteRuleScript, arguments: [String(index)])
    }

    // MARK: Send (outbound)

    /// Compose + send a plain-text message via Mail.app. Recipients are US-delimited argv
    /// (never interpolated — injection-safe). The CALLER MUST have passed the self-only
    /// `guardOutbound` (test-mode + allowlist) first; this method performs NO gating.
    private static let sendScript = """
    on run argv
        set theSubject to item 1 of argv
        set theBody to item 2 of argv
        set toRaw to item 3 of argv
        set ccRaw to item 4 of argv
        set bccRaw to item 5 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            my addRecipients(newMsg, toRaw, US, "to")
            my addRecipients(newMsg, ccRaw, US, "cc")
            my addRecipients(newMsg, bccRaw, US, "bcc")
            send newMsg
        end tell
        return "sent"
    end run

    on addRecipients(msg, raw, US, kind)
        if raw is "" then return
        set AppleScript's text item delimiters to US
        set parts to text items of raw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with p in parts
                set addr to (p as string)
                if addr is not "" then
                    if kind is "to" then
                        make new to recipient at end of to recipients of msg with properties {address:addr}
                    else if kind is "cc" then
                        make new cc recipient at end of cc recipients of msg with properties {address:addr}
                    else
                        make new bcc recipient at end of bcc recipients of msg with properties {address:addr}
                    end if
                end if
            end repeat
        end tell
    end addRecipients
    """
    public func send(subject: String, body: String, to: [String], cc: [String], bcc: [String]) throws {
        let US = MailScript.US
        _ = try runner.run(MailScript.sendScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
        ])
    }

    // MARK: Send with attachments (outbound + file attachments)

    /// Compose + send a message carrying one or more file attachments. Every user value —
    /// subject, body, recipients, AND each attachment path — is US-delimited argv (never
    /// interpolated into source; injection-safe). Attachments are placed `at after the last
    /// paragraph of content` (the well-supported Mail form used by the parity oracle
    /// patrickfreyer apple-mail-mcp); a `delay` after each lets Mail finish loading the file
    /// before `send` fires. The CALLER MUST have passed the self-only `guardOutbound` first;
    /// this method performs NO gating.
    private static let sendWithAttachmentsScript = """
    on run argv
        set theSubject to item 1 of argv
        set theBody to item 2 of argv
        set toRaw to item 3 of argv
        set ccRaw to item 4 of argv
        set bccRaw to item 5 of argv
        set attRaw to item 6 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            my addRecipients(newMsg, toRaw, US, "to")
            my addRecipients(newMsg, ccRaw, US, "cc")
            my addRecipients(newMsg, bccRaw, US, "bcc")
            my addAttachments(newMsg, attRaw, US)
            send newMsg
        end tell
        return "sent"
    end run

    on addRecipients(msg, raw, US, kind)
        if raw is "" then return
        set AppleScript's text item delimiters to US
        set parts to text items of raw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with p in parts
                set addr to (p as string)
                if addr is not "" then
                    if kind is "to" then
                        make new to recipient at end of to recipients of msg with properties {address:addr}
                    else if kind is "cc" then
                        make new cc recipient at end of cc recipients of msg with properties {address:addr}
                    else
                        make new bcc recipient at end of bcc recipients of msg with properties {address:addr}
                    end if
                end if
            end repeat
        end tell
    end addRecipients

    on addAttachments(msg, raw, US)
        if raw is "" then return
        set AppleScript's text item delimiters to US
        set parts to text items of raw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with p in parts
                set thePath to (p as string)
                if thePath is not "" then
                    tell msg
                        make new attachment with properties {file name:(POSIX file thePath)} at after the last paragraph
                    end tell
                    delay 1
                end if
            end repeat
        end tell
    end addAttachments
    """
    /// Send `body` (plain content) with `attachmentPaths` (already resolved absolute paths).
    /// Returns normally on success; throws if the script did not report "sent".
    public func sendWithAttachments(subject: String, body: String, to: [String], cc: [String],
                                    bcc: [String], attachmentPaths: [String]) throws {
        let US = MailScript.US
        let out = try runner.run(MailScript.sendWithAttachmentsScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            attachmentPaths.joined(separator: US),
        ])
        guard out == "sent" else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "sendWithAttachments returned '\(out)'")
        }
    }

    // MARK: HTML delivery — reliable open (default) + opt-in GUI keystroke auto-send

    /// RELIABLE HTML path (Option A default). Open a generated multipart `.eml` (X-Unsent +
    /// HTML alternative, from `EmlBuilder`) in Mail as a rendered, ready-to-send compose
    /// window via LaunchServices (`/usr/bin/open -a Mail <path>`). Mail renders the HTML —
    /// its AppleScript `content` is plain-text only, so an `.eml` opened by LaunchServices is
    /// the only reliable render path (mirrors patrickfreyer `create_rich_email_draft`
    /// `open_in_mail`). This does NOT auto-send: the operator reviews and clicks Send. An
    /// earlier design tried to `open` the `.eml` via AppleScript and then programmatically
    /// `send` the resulting window located by id-diff — but LaunchServices `open` does not
    /// surface the compose window in Mail's `outgoing messages` collection, so no reference
    /// (nor this code) can reliably auto-send an opened `.eml`; auto-send of rendered HTML is
    /// the GUI-keystroke path below. Caller MUST have passed the self-only `guardOutbound`
    /// first. Injection-safe: `path` is a Process argv element, never shell-interpolated. The
    /// `.eml` must stay on disk until Mail reads it, so the caller keeps it (reported as
    /// `eml_path`) rather than deleting immediately.
    public func openEml(path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Mail", path]
        p.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw AppleScriptRunner.RunError.launchFailed("open -a Mail: \(error)")
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AppleScriptRunner.RunError.scriptFailed(status: p.terminationStatus,
                stderr: "open -a Mail failed: " + String(decoding: errData, as: UTF8.self))
        }
    }

    /// OPT-IN HTML auto-send (Option A `--gui-send`). Faithful port of patrickfreyer
    /// `_send_html_email`: place the HTML on the NSPasteboard, open a VISIBLE compose window
    /// with recipients + attachments set programmatically, then drive Mail's UI via System
    /// Events (Tab into the body, Cmd-A, Cmd-V to paste rich HTML, Cmd-Shift-D to Send). This
    /// is the ONLY way to auto-send RENDERED HTML through Mail (its AppleScript `content` is
    /// plain-text only) — but it is GUI automation: it requires Accessibility permission for
    /// the controlling process, STEALS focus, and is timing-fragile. It is therefore gated
    /// behind an explicit `--gui-send` opt-in and is NEVER the default.
    ///
    /// SAFETY: recipients are set PROGRAMMATICALLY on the outgoing message before the window is
    /// shown, and the caller MUST have passed the self-only `guardOutbound` first — so even the
    /// GUI Cmd-Shift-D send can only ever reach a self-allowlisted address. The prior clipboard
    /// contents are saved and restored around the paste. Inputs are opaque argv (`on run argv`);
    /// the HTML body is read from `htmlPath` via `cat` inside the script, so no body text is
    /// interpolated into source. Uses `runViaStdin` because the AppleScriptObjC `use framework`
    /// header requires the stdin form.
    private static let sendHtmlGuiScript = """
    use framework "Foundation"
    use framework "AppKit"
    use scripting additions
    on run argv
        set htmlPath to item 1 of argv
        set theSubject to item 2 of argv
        set toRaw to item 3 of argv
        set ccRaw to item 4 of argv
        set bccRaw to item 5 of argv
        set attRaw to item 6 of argv
        set US to (ASCII character 31)
        set htmlString to (do shell script "cat " & quoted form of htmlPath)
        set pb to current application's NSPasteboard's generalPasteboard()
        set oldClip to pb's stringForType:(current application's NSPasteboardTypeString)
        pb's clearContents()
        set htmlData to (current application's NSString's stringWithString:htmlString)'s dataUsingEncoding:(current application's NSUTF8StringEncoding)
        pb's setData:htmlData forType:(current application's NSPasteboardTypeHTML)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:"", visible:true}
            my addRecips(newMsg, toRaw, US, "to")
            my addRecips(newMsg, ccRaw, US, "cc")
            my addRecips(newMsg, bccRaw, US, "bcc")
            my addAtts(newMsg, attRaw, US)
            activate
        end tell
        delay 2.5
        -- SAFETY (review M1): the blind Cmd-Shift-D must land ONLY on the compose window THIS
        -- call created — never a stray compose window the operator left open (which could carry a
        -- real, non-self recipient and would bypass guardOutbound). Assert the frontmost Mail
        -- window is ours by matching its title to the unique subject, and refuse (fail-closed) if
        -- it is not. Restore the clipboard on every exit path.
        set sendOK to false
        tell application "System Events"
            set frontmost of process "Mail" to true
            delay 0.5
            tell process "Mail"
                if (exists front window) and ((name of front window) contains theSubject) then
                    repeat 7 times
                        key code 48
                        delay 0.1
                    end repeat
                    delay 0.3
                    keystroke "a" using command down
                    delay 0.2
                    keystroke "v" using command down
                    delay 0.5
                    keystroke "d" using {command down, shift down}
                    set sendOK to true
                end if
            end tell
        end tell
        delay 1
        if oldClip is not missing value then
            pb's clearContents()
            pb's setString:oldClip forType:(current application's NSPasteboardTypeString)
        end if
        if sendOK then
            return "sent"
        else
            return "wrong-window"
        end if
    end run

    on addRecips(msg, raw, US, kind)
        if raw is "" then return
        set AppleScript's text item delimiters to US
        set parts to text items of raw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with p in parts
                set addr to (p as string)
                if addr is not "" then
                    if kind is "to" then
                        make new to recipient at end of to recipients of msg with properties {address:addr}
                    else if kind is "cc" then
                        make new cc recipient at end of cc recipients of msg with properties {address:addr}
                    else
                        make new bcc recipient at end of bcc recipients of msg with properties {address:addr}
                    end if
                end if
            end repeat
        end tell
    end addRecips

    on addAtts(msg, raw, US)
        if raw is "" then return
        set AppleScript's text item delimiters to US
        set parts to text items of raw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with p in parts
                set thePath to (p as string)
                if thePath is not "" then
                    tell msg
                        make new attachment with properties {file name:(POSIX file thePath)} at after the last paragraph
                    end tell
                    delay 1
                end if
            end repeat
        end tell
    end addAtts
    """
    /// Auto-send a rendered-HTML message via the GUI keystroke path (see `sendHtmlGuiScript`).
    /// `htmlPath` points at a temp file holding the raw HTML body (the caller writes it and
    /// deletes it after this returns). Returns normally on "sent"; throws otherwise. Caller
    /// MUST have passed the self-only `guardOutbound` first; this method performs NO gating.
    public func sendHtmlViaGui(htmlPath: String, subject: String, to: [String],
                               cc: [String], bcc: [String], attachmentPaths: [String]) throws {
        let US = MailScript.US
        let out = try runner.runViaStdin(MailScript.sendHtmlGuiScript, arguments: [
            htmlPath, subject,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            attachmentPaths.joined(separator: US),
        ])
        guard out == "sent" else {
            let reason = out == "wrong-window"
                ? "the frontmost Mail window was not the compose window this send created (title did not match the subject) — refused the Send keystroke to avoid sending an unrelated window. Close any other open Mail compose window and retry, or use the reliable --html open path."
                : "sendHtmlViaGui returned '\(out)'"
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: reason)
        }
    }

    // MARK: Unread counts (Mail.app live property — matches the MCP oracle)

    /// The Envelope Index `read` bit diverges from server-synced seen-state (observed: index
    /// far above Mail's live count on one iCloud INBOX). MCP A/B source unread from Mail's live
    /// `unread count` property, so we do too for parity.
    private static let unreadScript = """
    on run argv
        set mode to item 1 of argv
        set incZero to item 2 of argv
        set acctFilter to item 3 of argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        tell application "Mail"
            set out to ""
            repeat with a in accounts
                set an to name of a
                if acctFilter is "" or acctFilter is an then
                    if mode is "summary" then
                        try
                            set uc to unread count of (mailbox "INBOX" of a)
                            set out to out & an & US & "INBOX" & US & uc & RS
                        end try
                    else
                        repeat with mbx in mailboxes of a
                            try
                                set uc to unread count of mbx
                                if incZero is "1" or uc > 0 then
                                    set out to out & an & US & (name of mbx) & US & uc & RS
                                end if
                            end try
                        end repeat
                    end if
                end if
            end repeat
            return out
        end tell
    end run
    """

    public struct UnreadRow { public let account: String; public let mailbox: String; public let unread: Int }

    public func unreadCounts(summary: Bool, includeZero: Bool, accountFilter: String?) throws -> [UnreadRow] {
        let raw = try runner.run(MailScript.unreadScript,
                                 arguments: [summary ? "summary" : "full", includeZero ? "1" : "0", accountFilter ?? ""])
        var rows: [UnreadRow] = []
        for record in raw.components(separatedBy: MailScript.RS)
        where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = record.components(separatedBy: MailScript.US)
            guard f.count >= 3, let uc = Int(f[2].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            rows.append(UnreadRow(account: f[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                  mailbox: f[1], unread: uc))
        }
        return rows
    }

    public func selectedMessages(includeContent: Bool) throws -> [ScriptSelection] {
        let raw = try runner.run(MailScript.selectionScript, arguments: [includeContent ? "1" : "0"])
        var result: [ScriptSelection] = []
        for record in raw.components(separatedBy: MailScript.RS)
        where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = record.components(separatedBy: MailScript.US)
            guard f.count >= 7 else { continue }
            result.append(ScriptSelection(
                applescriptID: f[0].trimmingCharacters(in: .whitespacesAndNewlines),
                internetMessageID: MailFormat.stripAngleBrackets(f[1]),
                subject: f[2],
                sender: f[3].trimmingCharacters(in: .whitespacesAndNewlines),
                readStatus: f[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true",
                flagged: f[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true",
                content: includeContent ? f[6] : nil))
        }
        return result
    }

    // MARK: - Message mutations (P2). Located by RFC message-id (tries bracketed + bare form).
    //
    // SAFETY: these methods perform NO gating. The CALLER MUST have passed the 3-flag gate
    // (--execute + --test-mode + APPLE_TEST_MODE) AND a subject-label check (mutations on an
    // existing message) or `guardOutbound` (outbound) BEFORE calling. Every user value is
    // argv-passed (never interpolated). The shared `findMsg` locator is appended to each
    // mutation script; a mutation returns "ok" (applied) / "notfound" (no matching message).

    /// AppleScript handler that locates a message by RFC `message id`. PERFORMANCE: Mail has no
    /// index on message-id, so `whose message id is` is a client-side linear scan per mailbox —
    /// and Gmail's "[Gmail]/All Mail" holds the entire archive (tens of thousands of messages),
    /// which makes a naive all-mailbox scan hang. So this is BOUNDED: INBOX of the target
    /// account(s) first (small, the common mutation case), then other mailboxes EXCEPT the
    /// "All Mail" archive. A message that lives only in a deep archive returns `missing value`
    /// (caller reports not_found) rather than hanging — mutate those in Mail.app. Appended to
    /// every mutation script below.
    private static let locator = """

    on findMsg(targetID, acctName)
        tell application "Mail"
            set accts to accounts
            if acctName is not "" then
                try
                    set accts to {first account whose name is acctName}
                end try
            end if
            repeat with a in accts
                try
                    set ms to (messages of (mailbox "INBOX" of a) whose message id is targetID)
                    if (count of ms) > 0 then return item 1 of ms
                end try
            end repeat
            repeat with a in accts
                repeat with mbx in mailboxes of a
                    set mname to (name of mbx)
                    if mname is not "INBOX" and mname does not contain "[Gmail]" then
                        try
                            set ms to (messages of mbx whose message id is targetID)
                            if (count of ms) > 0 then return item 1 of ms
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return missing value
    end findMsg
    """

    /// Run a mutation script (defines `on run argv`, calls `my findMsg`) trying the bracketed
    /// then bare message-id form. Returns true when the script applied the change ("ok").
    @discardableResult
    private func mutateLocated(_ body: String, id: String, account: String?, extra: [String]) throws -> Bool {
        let script = body + "\n" + MailScript.locator
        let bare = MailFormat.stripAngleBrackets(id) ?? id
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(script, arguments: [candidate, account ?? ""] + extra)
            if out == "ok" { return true }
        }
        return false   // notfound on both candidate forms
    }

    private static let setReadScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        tell application "Mail" to set read status of msg to ((item 3 of argv) is "1")
        return "ok"
    end run
    """
    /// Set read/unread on a located message. Trivially reversible.
    @discardableResult
    public func setRead(internetMessageID: String, accountName: String?, read: Bool) throws -> Bool {
        try mutateLocated(MailScript.setReadScript, id: internetMessageID, account: accountName, extra: [read ? "1" : "0"])
    }

    private static let setFlagScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        set doFlag to (item 3 of argv) is "1"
        set idx to (item 4 of argv) as integer
        tell application "Mail"
            set flagged status of msg to doFlag
            if doFlag and idx is greater than or equal to 0 then set flag index of msg to idx
        end tell
        return "ok"
    end run
    """
    /// Flag/unflag a located message, optionally with a color (0-6). Reversible.
    @discardableResult
    public func setFlag(internetMessageID: String, accountName: String?, flagged: Bool, colorIndex: Int?) throws -> Bool {
        try mutateLocated(MailScript.setFlagScript, id: internetMessageID, account: accountName,
                          extra: [flagged ? "1" : "0", String(colorIndex ?? -1)])
    }

    private static let moveScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        set mbxName to item 3 of argv
        tell application "Mail"
            set acctOfMsg to account of (mailbox of msg)
            set destMbx to (first mailbox of acctOfMsg whose name is mbxName)
            set mailbox of msg to destMbx
        end tell
        return "ok"
    end run
    """
    /// Move a located message to another mailbox WITHIN its own account. Reversible.
    @discardableResult
    public func move(internetMessageID: String, accountName: String?, toMailbox: String) throws -> Bool {
        try mutateLocated(MailScript.moveScript, id: internetMessageID, account: accountName, extra: [toMailbox])
    }

    private static let trashScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        tell application "Mail" to delete msg
        return "ok"
    end run
    """
    /// Move a located message to Trash (Mail's `delete` = move-to-Trash, recoverable). The
    /// permanent form is never wired — see DeleteCommand's --permanent hard-refuse.
    @discardableResult
    public func deleteToTrash(internetMessageID: String, accountName: String?) throws -> Bool {
        try mutateLocated(MailScript.trashScript, id: internetMessageID, account: accountName, extra: [])
    }

    // MARK: Attachment export (READ/EXPORT — extracts existing bytes to disk; mutates nothing in Mail)

    // Locate the message (shared bounded `findMsg`), then save POSITIONALLY: `pairBlob` is a
    // caller-built list of (0-based index, exact destination path) pairs — the caller (Swift, see
    // CommandHelpers.swift) has ALREADY resolved --name/--indices to indices and computed safe,
    // de-collided destination paths. This script does NO name matching and NO path composition —
    // matching by name would let a message with two identically-named attachments have BOTH match
    // a single --indices/--name request (wrong bytes silently landing under the wrong/colliding
    // path). Positional selection via `item (idx + 1) of (mail attachments of msg)` mirrors MCP
    // A's own `items {i} of mail attachments of msg`. Pairs are pre-parsed OUTSIDE the `tell`
    // block (mirrors createRuleScript's caution: list/delimiter manipulation stays outside `tell
    // application "Mail"`). Each `save` is wrapped in `try` so one un-fetchable attachment doesn't
    // abort the rest; the RS-joined list of successfully-saved indices is returned so the caller
    // can reconcile requested vs actually-saved (a short save is signal, never silent success).
    private static let saveAttachmentsScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        set pairBlob to item 3 of argv
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        set pairList to {}
        set AppleScript's text item delimiters to RS
        set pairRecs to text items of pairBlob
        set AppleScript's text item delimiters to ""
        repeat with pr in pairRecs
            set prs to pr as string
            if prs is not "" then
                set AppleScript's text item delimiters to US
                set fld to text items of prs
                set AppleScript's text item delimiters to ""
                set end of pairList to {idx:((item 1 of fld) as integer), dest:(item 2 of fld)}
            end if
        end repeat
        set savedOut to ""
        tell application "Mail"
            set attList to mail attachments of msg
            repeat with p in pairList
                set i to idx of p
                set d to dest of p
                try
                    set att to item (i + 1) of attList
                    save att in (POSIX file d)
                    set savedOut to savedOut & i & RS
                end try
            end repeat
        end tell
        return savedOut
    end run
    """
    /// Save specific attachments of a located message, POSITIONALLY: `pairs` is
    /// `[(index: 0-based position in the message's attachment list, destPath: exact absolute file
    /// path)]`, fully resolved by the caller (index selection, basename safety, and de-collision
    /// all happen in Swift — see CommandHelpers.swift). `index` is passed straight through to
    /// AppleScript's `item (index + 1) of (mail attachments of msg)` — i.e. it addresses Mail.app's
    /// OWN live attachment order, matching MCP A's `items {i} of mail attachments of msg`. KNOWN
    /// ASSUMPTION: the caller's index space (Envelope-Index attachments, `ORDER BY name`) is
    /// assumed to enumerate in the same order Mail.app reports live; this holds in practice but
    /// isn't independently verified here — a mismatch would select the wrong attachment by
    /// position, the same class of edge case MCP A's own index numbering has no defense against
    /// either (self-consistent only within its own listing/save pair).
    ///
    /// Locates the message by RFC message-id via the shared `findMsg` (bracketed + bare form).
    /// Returns the SET of indices actually saved — a per-item AppleScript failure (not-yet-
    /// downloaded bytes, an unwritable path) is simply absent from the set, never thrown, so the
    /// caller can report a short save instead of a false "ok". Returns `nil` when the message
    /// could not be located in Mail.app on either id form. This is a read/export; it performs no
    /// gating (caller gates on --execute) and mutates nothing in Mail.
    public func saveAttachments(internetMessageID: String, accountName: String?,
                                pairs: [(index: Int, destPath: String)]) throws -> Set<Int>? {
        let script = MailScript.saveAttachmentsScript + "\n" + MailScript.locator
        let bare = MailFormat.stripAngleBrackets(internetMessageID) ?? internetMessageID
        let blob = pairs.map { "\($0.index)\(MailScript.US)\($0.destPath)" }.joined(separator: MailScript.RS)
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(script, arguments: [candidate, accountName ?? "", blob])
            if out == "notfound" { continue }
            let saved = out.components(separatedBy: MailScript.RS)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { Int($0) }
            return Set(saved)
        }
        return nil   // not locatable on either candidate form
    }

    // MARK: Mailbox + rule creation (caller gates: create only labeled `apple-cli-test…` items)

    private static let createMailboxScript = """
    on run argv
        set acctName to item 1 of argv
        set mbxName to item 2 of argv
        tell application "Mail"
            set a to first account whose name is acctName
            make new mailbox at end of mailboxes of a with properties {name:mbxName}
        end tell
        return "ok"
    end run
    """
    /// Create a mailbox/folder under an account. Caller MUST have label-checked the name.
    public func createMailbox(accountName: String, path: String) throws {
        let out = try runner.run(MailScript.createMailboxScript, arguments: [accountName, path])
        guard out == "ok" else { throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "createMailbox returned '\(out)'") }
    }

    private static let createRuleScript = """
    on run argv
        set ruleName to item 1 of argv
        set isEnabled to (item 2 of argv) is "1"
        set condBlob to item 3 of argv
        set actBlob to item 4 of argv
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        -- Parse conditions + resolve enums OUTSIDE the Mail tell block. Two AppleScript rules:
        -- (1) a handler call (`my ruleType(...)`) inside `tell application "Mail"` is misparsed as
        -- a Mail command; (2) a handler call inside a record literal `{...}` is a syntax error.
        -- So: precompute each enum into a variable here, collect {rtype,qual,expr} records, then
        -- build the rule inside the tell block from those plain values.
        set condList to {}
        set AppleScript's text item delimiters to RS
        set condRecs to text items of condBlob
        set AppleScript's text item delimiters to ""
        repeat with cr in condRecs
            set crs to cr as string
            if crs is not "" then
                set AppleScript's text item delimiters to US
                set fld to text items of crs
                set AppleScript's text item delimiters to ""
                set rtv to my ruleType(item 1 of fld)
                set qfv to my qualifier(item 2 of fld)
                set exv to (item 3 of fld)
                set end of condList to {rtype:rtv, qual:qfv, expr:exv}
            end if
        end repeat
        set AppleScript's text item delimiters to RS
        set actToks to text items of actBlob
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            set r to make new rule with properties {name:ruleName, enabled:isEnabled}
            try
                set all conditions must be met of r to ((item 5 of argv) is "1")
            end try
            repeat with c in condList
                set rt to rtype of c
                set qf to qual of c
                set ex to expr of c
                try
                    make new rule condition at end of rule conditions of r with properties {rule type:rt, qualifier:qf, expression:ex}
                end try
            end repeat
            repeat with atk in actToks
                set tok to atk as string
                if tok is "mark_read" then
                    try
                        set mark read of r to true
                    end try
                else if tok is "mark_flagged" then
                    try
                        set mark flagged of r to true
                    end try
                else if tok is "delete" then
                    try
                        set delete message of r to true
                    end try
                end if
            end repeat
        end tell
        return "ok"
    end run

    on ruleType(f)
        tell application "Mail"
            if f is "from" then return from header
            if f is "to" then return to header
            if f is "subject" then return subject header
            if f is "body" then return message content
            if f is "any_recipient" then return to or cc header
            return from header
        end tell
    end ruleType

    on qualifier(op)
        tell application "Mail"
            if op is "contains" then return does contain value
            if op is "does_not_contain" then return does not contain value
            if op is "begins_with" then return begins with value
            if op is "ends_with" then return ends with value
            if op is "equals" then return equal to value
            return does contain value
        end tell
    end qualifier
    """
    /// Create a Mail rule with the safe action subset (mark_read / mark_flagged / delete;
    /// move_to/copy_to/forward_to are refused on live create by the caller — a forwarding rule
    /// is a latent auto-send-to-others surface). Caller MUST have label-checked the rule name.
    public func createRule(name: String, enabled: Bool, matchAll: Bool,
                           conditions: [(type: String, op: String, value: String)],
                           actions: [String]) throws {
        let condBlob = conditions.map { [$0.type, $0.op, $0.value].joined(separator: MailScript.US) }
            .joined(separator: MailScript.RS)
        let actBlob = actions.joined(separator: MailScript.RS)
        let out = try runner.run(MailScript.createRuleScript,
                                 arguments: [name, enabled ? "1" : "0", condBlob, actBlob, matchAll ? "1" : "0"])
        guard out == "ok" else { throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "createRule returned '\(out)'") }
    }

    // Patch metadata of an EXISTING rule (name/enabled/match/actions) IN PLACE. Deliberately does
    // NOT touch rule CONDITIONS: Mail's `delete rule condition` crashes Mail (-609 "Connection is
    // invalid", confirmed 2026-07-17 — every other rule op works). Condition replacement is done by
    // the CALLER as a whole-rule delete-and-recreate (deleteRule + createRule, both reliable), never
    // here. Each field carries a presence flag so "not provided" (leave as-is) is distinct from
    // "provided empty". Caller MUST have label-checked the target (requireLabeledRule) + patch first.
    private static let updateRuleMetaScript = """
    on run argv
        set idx to (item 1 of argv) as integer
        set hasName to (item 2 of argv) is "1"
        set newName to item 3 of argv
        set hasEnabled to (item 4 of argv) is "1"
        set enVal to (item 5 of argv) is "1"
        set hasMatch to (item 6 of argv) is "1"
        set matchAll to (item 7 of argv) is "1"
        set hasActs to (item 8 of argv) is "1"
        set actBlob to item 9 of argv
        set RS to (ASCII character 30)
        set actToks to {}
        if hasActs then
            set AppleScript's text item delimiters to RS
            set actToks to text items of actBlob
            set AppleScript's text item delimiters to ""
        end if
        tell application "Mail"
            set r to rule idx
            if hasName then set name of r to newName
            if hasEnabled then set enabled of r to enVal
            if hasMatch then
                try
                    set all conditions must be met of r to matchAll
                end try
            end if
            if hasActs then
                try
                    set mark read of r to false
                end try
                try
                    set mark flagged of r to false
                end try
                repeat with atk in actToks
                    set tok to atk as string
                    if tok is "mark_read" then
                        try
                            set mark read of r to true
                        end try
                    else if tok is "mark_flagged" then
                        try
                            set mark flagged of r to true
                        end try
                    end if
                end repeat
            end if
        end tell
        return "ok"
    end run
    """
    /// In-place metadata patch (name/enabled/match/actions) of rule `index`. `nil` = leave as-is.
    /// Reliable Mail ops only — never mutates conditions (see updateRuleMetaScript). Caller MUST
    /// have label-checked the target + patch. `actions` (if non-nil) is the safe mark_* token set.
    public func updateRuleMeta(index: Int, name: String?, enabled: Bool?, matchAll: Bool?,
                               actions: [String]?) throws {
        let actBlob = (actions ?? []).joined(separator: MailScript.RS)
        let args = [
            String(index),
            name != nil ? "1" : "0", name ?? "",
            enabled != nil ? "1" : "0", (enabled ?? false) ? "1" : "0",
            matchAll != nil ? "1" : "0", (matchAll ?? false) ? "1" : "0",
            actions != nil ? "1" : "0", actBlob,
        ]
        let out = try runner.run(MailScript.updateRuleMetaScript, arguments: args)
        guard out == "ok" else { throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "updateRuleMeta returned '\(out)'") }
    }

    /// A rule's scalar properties, read back so a CONDITION-replacing update can delete-and-recreate
    /// the rule while preserving the fields the caller didn't patch — without ever mutating a rule
    /// condition (Mail's `delete rule condition` crasher).
    public struct RuleScalars {
        public let name: String; public let enabled: Bool
        public let markRead: Bool; public let markFlagged: Bool
    }

    private static let readRuleScalarsScript = """
    on run argv
        set idx to (item 1 of argv) as integer
        set US to (ASCII character 31)
        tell application "Mail"
            set r to rule idx
            set en to enabled of r
            set mr to mark read of r
            set mf to mark flagged of r
            set nm to name of r
        end tell
        -- Coerce each boolean to text: `boolean & text` in AppleScript builds a LIST (joined with
        -- ", " on return), not concatenated text, when the boolean is the FIRST operand. Explicit
        -- `as text` forces string concatenation regardless of order, so name-last stays US-safe.
        return (en as text) & US & (mr as text) & US & (mf as text) & US & nm
    end run
    """
    /// Read a rule's scalar props for the recreate path. NAME IS LAST so a name that itself contains
    /// the US delimiter still round-trips (the trailing fields are rejoined). Match-logic is NOT read:
    /// a live test rule is always recreated with match=all, so the old value would be unused. Only the
    /// two mark_* action flags are read — the recreate resets a rule to the mark set (documented), so
    /// any non-mark action set manually in Mail.app is intentionally not round-tripped.
    public func readRuleScalars(index: Int) throws -> RuleScalars {
        let raw = try runner.run(MailScript.readRuleScalarsScript, arguments: [String(index)])
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: MailScript.US)
        guard f.count >= 4 else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "readRuleScalars: unexpected output '\(raw)'")
        }
        func flag(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).lowercased() == "true" }
        let name = f[3...].joined(separator: MailScript.US)
        return RuleScalars(name: name, enabled: flag(f[0]), markRead: flag(f[1]), markFlagged: flag(f[2]))
    }

    private static let ruleCondCountScript = """
    on run argv
        tell application "Mail" to return (count of rule conditions of rule ((item 1 of argv) as integer)) as string
    end run
    """
    /// Count a rule's conditions — the post-recreate SAFETY check. A rule with ZERO conditions
    /// matches ALL mail, so a delete-and-recreate that silently dropped its conditions (e.g. via a
    /// duplicate-name `make new rule`) MUST be caught before the rule is ever enabled.
    public func ruleConditionCount(index: Int) throws -> Int {
        let out = try runner.run(MailScript.ruleCondCountScript, arguments: [String(index)])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    // MARK: Drafts (Mail's real Drafts mailbox — list is a read; create/delete caller-gated)

    public struct DraftInfo { public let subject: String; public let recipient: String; public let date_sent: String }

    private static let listDraftsScript = """
    set US to (ASCII character 31)
    set RS to (ASCII character 30)
    tell application "Mail"
        set out to ""
        repeat with a in accounts
            repeat with dmbx in mailboxes of a
                -- Any "Drafts"-named mailbox: Gmail keeps drafts in "[Gmail]/Drafts", not "Drafts".
                if (name of dmbx) contains "Drafts" then
                    try
                        repeat with m in messages of dmbx
                            set rcpt to ""
                            try
                                set rcpt to address of item 1 of to recipients of m
                            end try
                            set out to out & (subject of m) & US & rcpt & US & ((date sent of m) as string) & RS
                        end repeat
                    end try
                end if
            end repeat
        end repeat
        return out
    end tell
    """
    public func listDrafts() throws -> [DraftInfo] {
        let raw = try runner.run(MailScript.listDraftsScript)
        var out: [DraftInfo] = []
        for record in raw.components(separatedBy: MailScript.RS)
        where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = record.components(separatedBy: MailScript.US)
            guard f.count >= 3 else { continue }
            out.append(DraftInfo(subject: f[0], recipient: f[1].trimmingCharacters(in: .whitespacesAndNewlines),
                                 date_sent: f[2].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }

    private static let createDraftScript = """
    on run argv
        set theSubject to item 1 of argv
        set theBody to item 2 of argv
        set toRaw to item 3 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set m to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            set AppleScript's text item delimiters to US
            set parts to text items of toRaw
            set AppleScript's text item delimiters to ""
            repeat with p in parts
                set addr to (p as string)
                if addr is not "" then make new to recipient at end of to recipients of m with properties {address:addr}
            end repeat
            save m
        end tell
        return "ok"
    end run
    """
    /// Save a message to Mail's Drafts (no send). Caller MUST have label-checked the subject.
    public func createDraft(subject: String, body: String, to: [String]) throws {
        let out = try runner.run(MailScript.createDraftScript, arguments: [subject, body, to.joined(separator: MailScript.US)])
        guard out == "ok" else { throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "createDraft returned '\(out)'") }
    }

    private static let deleteDraftScript = """
    on run argv
        set wantSubject to item 1 of argv
        set thePrefix to item 2 of argv
        set n to 0
        tell application "Mail"
            -- STABLE indexed references throughout (`account ai` / `mailbox mi of a` /
            -- `message j of dmbx`): a `repeat with x in <every ...>` loop variable is an unstable
            -- "item N of every message of every mailbox of every account" reference that fails on
            -- `delete`. Delete from the END (high index → low) so removals don't reindex the
            -- messages still to visit. Match subject in code — `whose subject is` doesn't filter
            -- draft (outgoing-message) objects reliably.
            repeat with ai from 1 to (count of accounts)
                set a to account ai
                repeat with mi from 1 to (count of mailboxes of a)
                    set dmbx to mailbox mi of a
                    if (name of dmbx) contains "Drafts" then
                        try
                            set k to (count of messages of dmbx)
                            repeat with j from k to 1 by -1
                                set m to message j of dmbx
                                set sj to ""
                                try
                                    set sj to subject of m
                                end try
                                if sj is wantSubject and sj starts with thePrefix then
                                    delete m
                                    set n to n + 1
                                end if
                            end repeat
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return (n as string)
    end run
    """
    /// Delete drafts whose subject EXACTLY matches AND starts with the test prefix (double guard).
    /// Returns the count deleted. Caller MUST have verified the subject is labeled.
    public func deleteDrafts(subject: String, prefix: String) throws -> Int {
        let out = try runner.run(MailScript.deleteDraftScript, arguments: [subject, prefix])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
