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
        /// Local-time ISO-8601 (no zone suffix) as Mail reports it; nil when unreadable.
        public let dateReceived: String?
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
                -- Oracle A's get_selected_messages always returns date_received; omitting it
                -- meant the non-index fallback path emitted a null date. ISO-8601 is assembled
                -- from components so the value does not depend on the machine's locale format.
                set dr to ""
                try
                    set d to date received of m
                    set dr to my isoDate(d)
                end try
                set out to out & (id of m) & US & mid & US & (subject of m) & US & (sender of m) & US & (read status of m) & US & (flagged status of m) & US & dr & US & c & RS
            end repeat
            return out
        end tell
    end run

    on isoDate(d)
        set y to year of d
        set mo to (month of d as integer)
        set dy to day of d
        set hh to hours of d
        set mm to minutes of d
        set ss to seconds of d
        return (my pad4(y)) & "-" & (my pad2(mo)) & "-" & (my pad2(dy)) & "T" & (my pad2(hh)) & ":" & (my pad2(mm)) & ":" & (my pad2(ss))
    end isoDate

    on pad2(n)
        if n < 10 then return "0" & (n as string)
        return n as string
    end pad2

    on pad4(n)
        set t to n as string
        repeat while (length of t) < 4
            set t to "0" & t
        end repeat
        return t
    end pad4
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
        set senderAddr to item 6 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            if senderAddr is not "" then set sender of newMsg to senderAddr
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
    /// `sender`, when non-nil, sets the outgoing message's From identity (a bare account address
    /// resolved from `--account`); nil sends from Mail's default account. Injection-safe (argv).
    public func send(subject: String, body: String, to: [String], cc: [String], bcc: [String],
                     sender: String? = nil) throws {
        let US = MailScript.US
        _ = try runner.run(MailScript.sendScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            sender ?? "",
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
        set senderAddr to item 7 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            if senderAddr is not "" then set sender of newMsg to senderAddr
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
                                    bcc: [String], attachmentPaths: [String], sender: String? = nil) throws {
        let US = MailScript.US
        let out = try runner.run(MailScript.sendWithAttachmentsScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            attachmentPaths.joined(separator: US), sender ?? "",
        ])
        guard out == "sent" else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "sendWithAttachments returned '\(out)'")
        }
    }

    /// SHARED outbound address guard, appended to EVERY script that dispatches an outgoing
    /// message (the send-draft path and the native reply/forward path). Deliberately ONE
    /// implementation: an earlier revision of the native path grew a second, weaker comparator
    /// that folded diacritics and let an unreadable address pass as all-clear — both fail-open
    /// bugs this pair already closes. Do not reintroduce a per-script variant.
    private static let addressGuardHelpers = """

    on collectAddrs(theMsg)
        set out to {}
        tell application "Mail"
            repeat with r in (to recipients of theMsg)
                set end of out to (address of r)
            end repeat
            repeat with r in (cc recipients of theMsg)
                set end of out to (address of r)
            end repeat
            repeat with r in (bcc recipients of theMsg)
                set end of out to (address of r)
            end repeat
        end tell
        return out
    end collectAddrs

    on firstDisallowed(addrs, allowList)
        -- Returns the FIRST address not in allowList, or "" ONLY when every address is allowlisted
        -- (the all-clear sentinel). SAFETY: empty / missing (`missing value`) addresses fail CLOSED —
        -- they return the non-empty token "<empty-address>" (a block), NEVER "". This closes the
        -- sentinel-collision fail-open where an empty-address recipient ordered before a real one
        -- (`{"", "victim@x"}`) would hit `return ""` early and be read as all-clear. Because a real
        -- address is compared only after the empty guard, no real address can ever be "", so "" is
        -- unambiguously all-clear. The `try` also blocks (rather than crashes on) a recipient whose
        -- `address` coerces with an error (e.g. `missing value`).
        repeat with adr in addrs
            set a to ""
            try
                set a to (adr as string)
            end try
            if a is "" then return "<empty-address>"
            set okFlag to false
            repeat with al in allowList
                -- `considering diacriticals but ignoring case` = case-insensitive + diacritic-SENSITIVE,
                -- matching Swift `guardOutbound`'s `.lowercased()` exact compare. Without it, AppleScript
                -- `is` folds diacritics too, so this self-only gate would be strictly MORE permissive than
                -- every other outbound path (e.g. allowlist `me@sélf.test` would match a draft to
                -- `me@self.test`). Keeping the two comparators identical closes that divergence.
                considering diacriticals but ignoring case
                    if a is (al as string) then set okFlag to true
                end considering
            end repeat
            if not okFlag then return a
        end repeat
        return ""
    end firstDisallowed
    """

    // MARK: Native reply / forward (Mail's own `reply` + `forward` verbs)
    //
    // WHY THESE EXIST (parity): composing a brand-new outgoing message with a string-built
    // "Re: " subject is NOT equivalent to Mail's `reply`/`forward`. Only the native verbs set
    // the In-Reply-To / References threading headers, mark the original message's replied-to /
    // forwarded-to state, and (for forward) carry the original's ATTACHMENTS and rich
    // formatting. Both parity oracles use the native verbs (s-morgan `mail_connector.py`
    // `reply_to_message` / `forward_message`; each returns `id of` the new outgoing message as
    // `reply_id` / `forward_id`), so a re-composed plain-text quote drops real capability.
    //
    // Signatures are the authoritative ones from `Mail.sdef`:
    //   reply   <message> [opening window <bool>] [reply to all <bool>] -> outgoing message
    //   forward <message> [opening window <bool>]                       -> outgoing message
    //   send    <outgoing message> -> BOOLEAN (true iff sending succeeded)
    // and `outgoing message` responds-to exactly `save` / `close` / `send` — NOT `delete`. So a
    // draft is discarded with `close … saving no`; `delete` would raise and silently leave a
    // fully-composed message in Mail's outgoing store.
    // (Note the s-morgan oracle writes `reply to all origMsg`, which is not valid dictionary
    // syntax — its reply_all=True path cannot have worked. We implement the correct form.)
    //
    // SAFETY — this is the one outbound path where recipients are chosen by MAIL, not by the
    // caller: `reply` auto-populates the original sender (plus every to/cc under reply-to-all),
    // so a caller-side `guardOutbound` on a *predicted* recipient list is not sufficient. These
    // methods therefore RE-READ the created message's actual to/cc/bcc and refuse unless EVERY
    // address is in the operator's self-only allowlist, closing the draft rather than sending.
    // Three fail-closed properties, each of which a reviewer caught missing in an earlier draft:
    //   1. an unreadable recipient list refuses (the readback is seeded non-empty);
    //   2. a ZERO-recipient message refuses — "every recipient is allowlisted" is vacuously true
    //      of the empty set, and an empty read can also mean the property access half-failed;
    //   3. whether the refused draft was actually discarded is REPORTED, never assumed, so the
    //      caller can tell the operator to remove it by hand instead of being told it is gone.
    // Callers MUST still have passed the 3-flag gate + `guardOutbound` before calling.

    // Script results use the pre-existing `US` as the FIELD separator and `RS` (already defined
    // above) to separate items within one field (recipient lists).

    /// Shared recipient/attachment/allowlist handlers appended to the native reply/forward
    /// scripts. AppleScript string comparison is case-insensitive by default, which is exactly
    /// the semantics wanted for email-address matching.
    private static let outboundGuardHelpers = """

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

    -- Discard a composed outgoing message. `close … saving no` is the DECLARED handler for an
    -- outgoing message (Mail.sdef responds-to: save/close/send); `delete` is NOT declared for it
    -- and would raise, silently leaving the draft behind. Returns "1" only when the draft is
    -- definitely gone, "0" when it may still be in Mail's outgoing store.
    on discardDraft(msg)
        try
            tell application "Mail" to close msg saving no
            return "1"
        on error
            return "0"
        end try
    end discardDraft

    -- Collect + audit with a bounded poll, because Mail can populate an outgoing message's
    -- recipient collections LAZILY. An empty read must never be mistaken for "no disallowed
    -- recipients" — the same hazard sendDraftScript already polls for.
    on auditedAddrs(msg, allowList)
        set addrs to {}
        repeat 30 times
            try
                set addrs to my collectAddrs(msg)
            end try
            if (count of addrs) > 0 then exit repeat
            delay 0.5
        end repeat
        return addrs
    end auditedAddrs
    """

    /// Body shared by the reply and forward scripts: audit the created message's real recipients,
    /// refuse fail-closed (discarding the draft and reporting whether that worked), otherwise
    /// attach, send, and report the send's own boolean result.
    private static let guardAndSendTail = """
                set AppleScript's text item delimiters to US
                set allowList to text items of allowRaw
                set AppleScript's text item delimiters to ""
                set addrs to my auditedAddrs(m, allowList)
                if (count of addrs) is 0 then
                    return "refused" & US & "(no recipients populated)" & US & my discardDraft(m)
                end if
                set bad to my firstDisallowed(addrs, allowList)
                if bad is not "" then
                    return "refused" & US & bad & US & my discardDraft(m)
                end if
                -- Attach only AFTER the guard passes, so a refused send never loads files.
                my addAttachments(m, attRaw, US)
                -- RE-VERIFY immediately before dispatch. addAttachments delays ~1s PER FILE, so
                -- the set verified above is stale by send time; the send-draft path re-checks for
                -- exactly this reason. Any delta (or a now-empty read) refuses.
                set addrs2 to {}
                try
                    set addrs2 to my collectAddrs(m)
                end try
                if (count of addrs2) is 0 then
                    return "refused" & US & "(recipients vanished before send)" & US & my discardDraft(m)
                end if
                set bad2 to my firstDisallowed(addrs2, allowList)
                if bad2 is not "" then
                    return "refused" & US & bad2 & US & my discardDraft(m)
                end if
                set newID to ""
                try
                    tell application "Mail" to set newID to (id of m) as string
                end try
                set AppleScript's text item delimiters to RS
                set verified to addrs2 as string
                set AppleScript's text item delimiters to ""
                -- Mail.sdef: `send` returns a BOOLEAN (true iff sending succeeded). Ignoring it
                -- reported executed:true for a send Mail said had failed.
                set sentOK to false
                tell application "Mail" to set sentOK to (send m)
                if sentOK is false then return "sendfail" & US & newID & US & verified
                return "ok" & US & newID & US & verified
    """

    private static let nativeReplyScript = """
    on run argv
        set theBody to item 3 of argv
        set doAll to (item 4 of argv) is "1"
        set senderAddr to item 5 of argv
        set allowRaw to item 6 of argv
        set attRaw to item 7 of argv
        set ccRaw to item 8 of argv
        set bccRaw to item 9 of argv
        set mbxHint to item 10 of argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        set msg to my findMsgHinted(item 1 of argv, item 2 of argv, mbxHint)
        if msg is missing value then return "notfound"
        set m to missing value
        try
            tell application "Mail"
                if doAll then
                    set m to reply msg opening window false reply to all true
                else
                    set m to reply msg opening window false reply to all false
                end if
            end tell
        on error errMsg
            return "createfail" & US & errMsg
        end try
        -- EVERY step between creating the draft and the guard is wrapped: the draft already
        -- exists and is addressed by MAIL to whoever it chose, so bailing out uncaught would
        -- orphan a possibly-real-recipient message in Mail's outgoing store.
        try
            tell application "Mail"
                -- Mail pre-fills the native quoted original; PREPEND the body so the quote
                -- survives (the s-morgan oracle clobbers `content`, losing its own quote).
                try
                    set content of m to theBody & return & return & (content of m)
                on error
                    set content of m to theBody
                end try
                if senderAddr is not "" then set sender of m to senderAddr
            end tell
            -- Mail addresses the reply itself; --cc/--bcc are ADDITIONS on top, and the audit
            -- below validates the union, so a caller-supplied Cc cannot escape the allowlist.
            my addRecipients(m, ccRaw, US, "cc")
            my addRecipients(m, bccRaw, US, "bcc")
        on error errMsg
            return "setupfail" & US & errMsg & US & my discardDraft(m)
        end try
    """ + guardAndSendTail + """

    end run
    """

    private static let nativeForwardScript = """
    on run argv
        set theBody to item 3 of argv
        set toRaw to item 4 of argv
        set ccRaw to item 5 of argv
        set bccRaw to item 6 of argv
        set senderAddr to item 7 of argv
        set allowRaw to item 8 of argv
        set attRaw to item 9 of argv
        set mbxHint to item 10 of argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        set msg to my findMsgHinted(item 1 of argv, item 2 of argv, mbxHint)
        if msg is missing value then return "notfound"
        set m to missing value
        try
            tell application "Mail" to set m to forward msg opening window false
        on error errMsg
            return "createfail" & US & errMsg
        end try
        try
            tell application "Mail"
                if theBody is not "" then
                    try
                        set content of m to theBody & return & return & (content of m)
                    on error
                        set content of m to theBody
                    end try
                end if
                if senderAddr is not "" then set sender of m to senderAddr
            end tell
            my addRecipients(m, toRaw, US, "to")
            my addRecipients(m, ccRaw, US, "cc")
            my addRecipients(m, bccRaw, US, "bcc")
        on error errMsg
            return "setupfail" & US & errMsg & US & my discardDraft(m)
        end try
    """ + guardAndSendTail + """

    end run
    """

    /// Result of a native reply/forward.
    public enum NativeComposeOutcome: Sendable, Equatable {
        /// Sent. `recipients` is what MAIL actually populated (not the caller's prediction).
        case sent(newMessageID: String, recipients: [String])
        case notFound
        /// NOTHING was sent. `discarded == false` means the composed draft could NOT be removed
        /// and is still in Mail's outgoing store — the operator must delete it by hand.
        case refused(nonSelfRecipients: String, discarded: Bool)
        /// `send` returned false (offline / SMTP refused). The draft may still exist.
        case sendFailed(newMessageID: String)
    }

    /// Like `mutateLocated`, but returns the script's raw output (for scripts that report a
    /// value, e.g. the new message id) instead of a Bool. nil == "notfound" on BOTH id forms.
    private func runLocated(_ body: String, id: String, account: String?, extra: [String]) throws -> String? {
        let script = body + "\n" + MailScript.locator + "\n" + MailScript.hintedLocator
            + "\n" + MailScript.outboundGuardHelpers
            + "\n" + MailScript.addressGuardHelpers + "\n" + MailScript.mailboxPathResolver
        let bare = MailFormat.stripAngleBrackets(id) ?? id
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(script, arguments: [candidate, account ?? ""] + extra)
            if out != "notfound" { return out }
        }
        return nil
    }

    /// Internal (not private) so the logic tier can regression-lock the fail-closed mapping
    /// without a live Mail — the "unrecognized output is a refusal, never a success" rule is the
    /// safety-critical half of this parser.
    static func parseNativeCompose(_ out: String?) -> NativeComposeOutcome {
        guard let out else { return .notFound }
        let f = out.components(separatedBy: US)
        func list(_ i: Int) -> [String] {
            guard f.count > i else { return [] }
            return f[i].components(separatedBy: RS).filter { !$0.isEmpty }
        }
        switch f.first {
        case "ok" where f.count > 1:
            return .sent(newMessageID: f[1], recipients: list(2))
        case "sendfail" where f.count > 1:
            return .sendFailed(newMessageID: f[1])
        case "refused" where f.count > 1:
            // A missing discard flag is read as NOT discarded — the pessimistic reading.
            return .refused(nonSelfRecipients: list(1).joined(separator: ", "),
                            discarded: f.count > 2 && f[2] == "1")
        case "createfail":
            // The native verb itself threw, so no draft was ever created — nothing to discard.
            let why = f.count > 1 ? f[1] : "(no detail)"
            return .refused(nonSelfRecipients: "(Mail could not create the message: \(why))", discarded: true)
        case "setupfail":
            // A throw AFTER the draft existed. The script attempted to close it; report whether
            // that actually worked rather than assuming it did.
            let why = f.count > 1 ? f[1] : "(no detail)"
            return .refused(nonSelfRecipients: "(composing the message failed: \(why))",
                            discarded: f.count > 2 && f[2] == "1")
        default:
            // Anything unrecognized is a refusal, never a success — and we cannot claim the
            // draft was cleaned up, so report it as possibly-present.
            return .refused(nonSelfRecipients: "(unrecognized script result '\(out)')", discarded: false)
        }
    }

    /// Reply to a located message with Mail's native `reply` verb (threading headers +
    /// replied-to state + native quoted original), prepending `body`. `cc`/`bcc` are ADDED on
    /// top of Mail's own addressing. `selfAllowlist` is the operator's self-only address set;
    /// every recipient Mail ends up with must match it or the reply is discarded unsent.
    public func nativeReply(internetMessageID: String, accountName: String?, body: String,
                            replyAll: Bool, sender: String?, selfAllowlist: [String],
                            cc: [String] = [], bcc: [String] = [],
                            attachmentPaths: [String] = [], mailboxHint: String = "") throws -> NativeComposeOutcome {
        let US = MailScript.US
        return MailScript.parseNativeCompose(try runLocated(MailScript.nativeReplyScript, id: internetMessageID, account: accountName,
                                                            extra: [body, replyAll ? "1" : "0", sender ?? "",
                                                                    selfAllowlist.joined(separator: US),
                                                                    attachmentPaths.joined(separator: US),
                                                                    cc.joined(separator: US), bcc.joined(separator: US),
                                                                    mailboxHint]))
    }

    /// Forward a located message with Mail's native `forward` verb (carries the original's
    /// attachments + rich formatting), prepending `body`. Recipients come from the caller, but
    /// are still re-read and allowlist-checked before send (defense in depth).
    public func nativeForward(internetMessageID: String, accountName: String?, body: String,
                              to: [String], cc: [String], bcc: [String], sender: String?,
                              selfAllowlist: [String], attachmentPaths: [String] = [],
                              mailboxHint: String = "") throws -> NativeComposeOutcome {
        let US = MailScript.US
        return MailScript.parseNativeCompose(try runLocated(MailScript.nativeForwardScript, id: internetMessageID, account: accountName,
                                                             extra: [body, to.joined(separator: US), cc.joined(separator: US),
                                                                     bcc.joined(separator: US), sender ?? "",
                                                                     selfAllowlist.joined(separator: US),
                                                                     attachmentPaths.joined(separator: US),
                                                                     mailboxHint]))
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
        set senderAddr to item 7 of argv
        set US to (ASCII character 31)
        set htmlString to (do shell script "cat " & quoted form of htmlPath)
        set pb to current application's NSPasteboard's generalPasteboard()
        set oldClip to pb's stringForType:(current application's NSPasteboardTypeString)
        pb's clearContents()
        set htmlData to (current application's NSString's stringWithString:htmlString)'s dataUsingEncoding:(current application's NSUTF8StringEncoding)
        pb's setData:htmlData forType:(current application's NSPasteboardTypeHTML)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:"", visible:true}
            if senderAddr is not "" then set sender of newMsg to senderAddr
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
                               cc: [String], bcc: [String], attachmentPaths: [String],
                               sender: String? = nil) throws {
        let US = MailScript.US
        let out = try runner.runViaStdin(MailScript.sendHtmlGuiScript, arguments: [
            htmlPath, subject,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            attachmentPaths.joined(separator: US), sender ?? "",
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
            guard f.count >= 8 else { continue }
            // The script emits LOCAL calendar components; convert to the same UTC `…Z` form
            // `MailFormat.iso` produces for the index path. Without this one response could carry
            // two different time semantics in `date_received` — index rows in UTC, selection-only
            // rows in naive local — silently off by the machine's UTC offset.
            let dr = MailScript.utcFromLocalComponents(f[6].trimmingCharacters(in: .whitespacesAndNewlines))
            result.append(ScriptSelection(
                applescriptID: f[0].trimmingCharacters(in: .whitespacesAndNewlines),
                internetMessageID: MailFormat.stripAngleBrackets(f[1]),
                subject: f[2],
                sender: f[3].trimmingCharacters(in: .whitespacesAndNewlines),
                readStatus: f[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true",
                flagged: f[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true",
                dateReceived: dr,
                content: includeContent ? f[7] : nil))
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
                -- FAIL-CLOSED on an unresolvable account. The old form left `accts` as EVERY
                -- account when the named one did not exist, silently widening a scoped mutation
                -- into an unbounded cross-account scan — and the native reply/forward verbs made
                -- that an OUTBOUND concern (the message whose body gets forwarded would be
                -- chosen by that widened scan). A named account that does not resolve is now a
                -- clean no-match instead.
                --
                -- Match by NAME **or** by account id: `MailMessage.account` is
                -- `nameByUUID[uuid] ?? uuid`, so a message whose account has no directory entry
                -- carries a RAW UUID (this store has several, e.g. "Recovered Messages"). Matching
                -- on name alone would make every mutation on those messages fail-closed with a
                -- misleading "not reachable in Mail.app".
                set hitsA to (accounts whose name is acctName)
                if (count of hitsA) is 0 then
                    try
                        set hitsA to (accounts whose id is acctName)
                    end try
                end if
                if (count of hitsA) is 0 then return missing value
                set accts to hitsA
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

    /// Appended ONLY to the native reply/forward assembly (its sole caller). It lives here rather
    /// than in the shared `locator` because it calls `resolveMailboxPath`: putting it in the
    /// locator made every mutation script reference a handler it was never given — inert, since
    /// nothing called it, but exactly the kind of latent assembly drift the syntax harness's
    /// handler-definition check exists to catch.
    private static let hintedLocator = """

    -- Locate with a MAILBOX HINT first, then fall back to the bounded scan above.
    --
    -- WHY: `findMsg` deliberately skips "[Gmail]" mailboxes because scanning EVERY mailbox by
    -- message-id hangs. That bound is correct for a blind scan, but it also made an ARCHIVED
    -- message unreachable — a capability regression for reply/forward, which both oracles perform
    -- on any message. The caller already knows the mailbox from the Envelope Index row it
    -- resolved, so hand it over and search only there.
    --
    -- HONEST COST: this is still a linear scan (Mail has no message-id index), just of ONE
    -- mailbox instead of all of them. When that mailbox IS "[Gmail]/All Mail" the scan is large —
    -- on this live store the overwhelming majority of messages live there — so an archived-message reply is
    -- SLOW, not free. It is bounded by osascript's Apple-event timeout rather than unbounded, and
    -- the fallback below still applies. The trade is deliberate: a slow reply beats "cannot reply
    -- to archived mail at all", which is what the oracles can do and the CLI could not.
    on findMsgHinted(targetID, acctName, mbxName)
        if mbxName is not "" then
            tell application "Mail"
                set accts to accounts
                if acctName is not "" then
                    set hitsA to (accounts whose name is acctName)
                    if (count of hitsA) is 0 then
                        try
                            set hitsA to (accounts whose id is acctName)
                        end try
                    end if
                    if (count of hitsA) is 0 then return missing value
                    set accts to hitsA
                end if
                repeat with a in accts
                    try
                        set mb to my resolveMailboxPath(a, mbxName)
                        if mb is not missing value then
                            set ms to (messages of mb whose message id is targetID)
                            if (count of ms) > 0 then return item 1 of ms
                        end if
                    end try
                end repeat
            end tell
        end if
        return my findMsg(targetID, acctName)
    end findMsgHinted
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
            if doFlag then
                if idx is greater than or equal to 0 then set flag index of msg to idx
            else
                -- Oracle A emits BOTH the flagged-status and the flag-index write on every call,
                -- mapping flag_color "none" to index -1 (utils.py get_flag_index). Clearing only
                -- `flagged status` left the old colour behind, so a later re-flag in the Mail UI
                -- resurrected it. `try` because some stores reject an index write while unflagged.
                try
                    set flag index of msg to -1
                end try
            end if
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

    /// Resolve a destination mailbox name that MAY be a "/"-separated nested path
    /// ("Projects/2024" → `mailbox "2024" of mailbox "Projects" of acct`), matching oracle B's
    /// documented `to_mailbox` nesting (`core.py` `build_mailbox_ref`).
    ///
    /// DIVERGENCE (deliberate, and a correctness superset): the exact flat name is tried FIRST.
    /// Mail really does have mailboxes whose own name contains a slash — Gmail's
    /// "[Gmail]/All Mail" is exactly that — and oracle B splits unconditionally, so it can never
    /// address them. Exact-first addresses both shapes; only a name that does NOT exist flat is
    /// re-read as a nesting. Returns `missing value` when nothing resolves (caller → "nodest").
    /// Move variant of `mutateLocated`: also appends the nested-mailbox resolver, and maps the
    /// script's "nodest" token to a precise `not_found` instead of the opaque AppleScript error a
    /// bare `first mailbox … whose name is` raised before.
    private func moveLocated(_ body: String, id: String, account: String?, toMailbox: String) throws -> Bool {
        let script = body + "\n" + MailScript.locator + "\n" + MailScript.mailboxPathResolver
        let bare = MailFormat.stripAngleBrackets(id) ?? id
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(script, arguments: [candidate, account ?? "", toMailbox])
            if out == "ok" { return true }
            if out == "nodest" {
                throw AppleError.notFound("destination mailbox '\(toMailbox)' not found in the message's account (for a nested mailbox use \"Parent/Child\").")
            }
        }
        return false
    }

    private static let mailboxPathResolver = """

    on resolveMailboxPath(acct, pathRaw)
        tell application "Mail"
            -- Use a PLURAL `whose` filter + count instead of `first mailbox … whose`. A `first …
            -- whose` specifier for a non-matching name can evaluate lazily and hand back an
            -- unresolved reference rather than raising, which would make an enclosing `try` a
            -- no-op: exact-first would then "succeed" for every input, the nesting loop below
            -- would be dead code, and the caller would get the opaque Mail error this resolver
            -- exists to replace. `count of` forces resolution now, so the branch is real.
            set hits to (mailboxes of acct whose name is pathRaw)
            if (count of hits) > 0 then return (item 1 of hits)
            set AppleScript's text item delimiters to "/"
            set parts to text items of pathRaw
            set AppleScript's text item delimiters to ""
            set mbx to missing value
            repeat with i from 1 to (count of parts)
                set seg to (item i of parts) as string
                if seg is not "" then
                    try
                        if mbx is missing value then
                            set segHits to (mailboxes of acct whose name is seg)
                        else
                            set segHits to (mailboxes of mbx whose name is seg)
                        end if
                        if (count of segHits) is 0 then return missing value
                        set mbx to (item 1 of segHits)
                    on error
                        return missing value
                    end try
                end if
            end repeat
            return mbx
        end tell
    end resolveMailboxPath
    """

    private static let moveScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        set mbxName to item 3 of argv
        tell application "Mail"
            set acctOfMsg to account of (mailbox of msg)
            set destMbx to my resolveMailboxPath(acctOfMsg, mbxName)
            if destMbx is missing value then return "nodest"
            set mailbox of msg to destMbx
        end tell
        return "ok"
    end run
    """
    /// Move a located message to another mailbox WITHIN its own account. Reversible.
    @discardableResult
    public func move(internetMessageID: String, accountName: String?, toMailbox: String) throws -> Bool {
        try moveLocated(MailScript.moveScript, id: internetMessageID, account: accountName, toMailbox: toMailbox)
    }

    private static let gmailMoveScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        set mbxName to item 3 of argv
        tell application "Mail"
            set acctOfMsg to account of (mailbox of msg)
            set destMbx to my resolveMailboxPath(acctOfMsg, mbxName)
            if destMbx is missing value then return "nodest"
            duplicate msg to destMbx
            delete msg
        end tell
        return "ok"
    end run
    """
    /// Gmail label-move semantics (parity oracle `move_messages(gmail_mode=True)`): DUPLICATE the
    /// located message into the destination mailbox, then DELETE the ORIGINAL. On Gmail's
    /// label-backed mailboxes a direct `set mailbox` can misbehave, so the copy+delete dance is used
    /// instead. `delete msg` targets the ORIGINAL reference (which, after `duplicate`, still points
    /// at the SOURCE message) and moves it to Trash — the SAME recoverable move-to-Trash as
    /// `deleteToTrash`, never a permanent delete. Destination is resolved WITHIN the message's own
    /// account, exactly like `move`. Reuses the shared `findMsg` locator via `mutateLocated`.
    @discardableResult
    public func gmailMove(internetMessageID: String, accountName: String?, toMailbox: String) throws -> Bool {
        try moveLocated(MailScript.gmailMoveScript, id: internetMessageID, account: accountName, toMailbox: toMailbox)
    }

    private static let trashScript = """
    on run argv
        set msg to my findMsg(item 1 of argv, item 2 of argv)
        if msg is missing value then return "notfound"
        tell application "Mail" to delete msg
        return "ok"
    end run
    """
    /// Move a located message to Trash (Mail's `delete` = move-to-Trash, recoverable).
    @discardableResult
    public func deleteToTrash(internetMessageID: String, accountName: String?) throws -> Bool {
        try mutateLocated(MailScript.trashScript, id: internetMessageID, account: accountName, extra: [])
    }

    // MARK: Permanent delete + empty trash (IRREVERSIBLE — see the gates in WriteManageCommands)

    /// A mailbox counts as "trash" if its name looks like one. There is NO reliable per-account
    /// trash property in Mail's AppleScript API (`trash mailbox` exists only on the application and
    /// resolves to the unified "All Trash" smart mailbox; `trash mailbox of account` errors), and
    /// the obvious hardcoded `mailbox "Trash" of account X` is WRONG on iCloud — that account
    /// carries BOTH an empty "Trash" and the real "Deleted Messages". (The parity oracle hardcodes
    /// "Trash" and so silently no-ops on iCloud; matching that bug would be worse than exceeding it.)
    /// An EXACT-name allowlist, not a substring test: `contains("deleted")` would also match a
    /// personal folder like "Deleted drafts to revisit", and auto-selecting that for an
    /// irreversible erase is unacceptable. Names below are the real ones observed across the
    /// account types on this fleet. Pure + case-insensitive so the rule is unit-testable, and it
    /// is the SINGLE source of truth — the AppleScript never re-implements it; the resolved names
    /// are passed in as argv.
    public static let trashMailboxNames: Set<String> = [
        "trash", "deleted messages", "deleted items", "bin",
        "[gmail]trash", "[gmail]/trash",
    ]
    public static func isTrashMailboxName(_ name: String) -> Bool {
        trashMailboxNames.contains(name.lowercased())
    }

    /// `name<US>count` for EVERY mailbox of the account, RS-separated. A READ. The script does no
    /// trash classification — Swift filters the result through `isTrashMailboxName`, so the
    /// allowlist lives in exactly one place.
    private static let mailboxCountsScript = """
    on run argv
        set acctName to item 1 of argv
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        set rows to {}
        tell application "Mail"
            repeat with ai from 1 to (count of accounts)
                set a to account ai
                if acctName is "" or (name of a) is acctName then
                    repeat with mi from 1 to (count of mailboxes of a)
                        try
                            set mbx to mailbox mi of a
                            set end of rows to (name of mbx) & US & ((count of (messages of mbx)) as string)
                        end try
                    end repeat
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        set s to rows as string
        set AppleScript's text item delimiters to ""
        return s
    end run
    """
    public struct TrashMailbox { public let name: String; public let count: Int }

    /// Decide WHICH trash mailbox an empty-trash should act on. Pure (no Mail) so the rules are
    /// unit-testable, and FAIL-CLOSED: an account can expose several trash-like mailboxes (iCloud
    /// has "Trash" and "Deleted Messages"), and picking the wrong one for an IRREVERSIBLE erase is
    /// unacceptable — so ambiguity throws and asks the operator to name it explicitly rather than
    /// guessing. Returns nil when there is simply nothing to erase.
    public static func resolveTrashMailbox(_ boxes: [TrashMailbox], explicit: String?) throws -> TrashMailbox? {
        if let explicit {
            guard let hit = boxes.first(where: { $0.name.lowercased() == explicit.lowercased() }) else {
                let known = boxes.map(\.name).joined(separator: ", ")
                throw AppleError.notFound("no trash mailbox named '\(explicit)' on this account\(known.isEmpty ? "" : " (found: \(known))").")
            }
            return hit
        }
        let nonEmpty = boxes.filter { $0.count > 0 }
        switch nonEmpty.count {
        case 0: return nil
        case 1: return nonEmpty[0]
        default:
            let detail = nonEmpty.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
            throw AppleError.validation("this account has more than one non-empty trash mailbox — \(detail). Refusing to guess which to erase; name it with --trash-mailbox.")
        }
    }
    /// EVERY mailbox of an account with its message count (a READ), unfiltered. An empty result
    /// means the account name matched nothing — callers must treat that as "unknown account"
    /// rather than "nothing to do", or a typo'd `--account` reads as a successful no-op.
    public func allMailboxes(accountName: String) throws -> [TrashMailbox] {
        let out = try runner.run(MailScript.mailboxCountsScript, arguments: [accountName])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return [] }
        return out.components(separatedBy: MailScript.RS).compactMap { row in
            let f = row.components(separatedBy: MailScript.US)
            guard f.count == 2, let c = Int(f[1]) else { return nil }
            return TrashMailbox(name: f[0], count: c)
        }
    }

    /// Every trash mailbox of an account, with its message count. Classification happens HERE, in
    /// Swift, against `isTrashMailboxName` — the AppleScript never classifies.
    public func trashMailboxes(accountName: String) throws -> [TrashMailbox] {
        try allMailboxes(accountName: accountName).filter { MailScript.isTrashMailboxName($0.name) }
    }

    /// Deliberately does NOT use the shared `findMsg` locator: the search is scoped to TRASH-LIKE
    /// mailboxes only. That mirrors the parity oracle's intent (`manage_trash` matches within the
    /// account's trash) and is load-bearing safety — a message must ALREADY have been trashed, so a
    /// permanent delete can never erase an inbox message in one step. Mail's `delete` on a message
    /// that already lives in trash is what erases it for good.
    private static let deletePermanentScript = """
    on run argv
        set targetID to item 1 of argv
        set acctName to item 2 of argv
        set RS to (ASCII character 30)
        set AppleScript's text item delimiters to RS
        set trashNames to text items of (item 3 of argv)
        set AppleScript's text item delimiters to ""
        set didDelete to false
        tell application "Mail"
            repeat with ai from 1 to (count of accounts)
                set a to account ai
                if acctName is "" or (name of a) is acctName then
                    -- Pass 1: erase from any mailbox Swift classified as trash (exact names only).
                    repeat with mi from 1 to (count of mailboxes of a)
                        try
                            set mbx to mailbox mi of a
                            if trashNames contains (name of mbx) then
                                set ms to (messages of mbx whose message id is targetID)
                                if (count of ms) > 0 then
                                    delete (item 1 of ms)
                                    set didDelete to true
                                end if
                            end if
                        end try
                    end repeat
                    if didDelete then
                        -- Pass 2: VERIFY the erase actually took. Mail's `delete` on an
                        -- already-trashed message is a SILENT NO-OP on IMAP (confirmed on iCloud:
                        -- the message survives and `deleted status` stays false) because
                        -- AppleScript cannot drive an expunge. The parity oracle reports success
                        -- unconditionally; we re-query instead.
                        -- Scoped to the SAME trash mailboxes we may erase from — deliberately NOT
                        -- every mailbox, which would touch Gmail's `[Gmail]/All Mail` and hang
                        -- (the shared locator skips those for the same reason).
                        -- FAILS CLOSED: any error while verifying counts as "not proven erased",
                        -- so a verification failure can never be reported as a successful erase.
                        set stillThere to false
                        set verifyFailed to false
                        repeat with mi from 1 to (count of mailboxes of a)
                            try
                                set vbx to mailbox mi of a
                                if trashNames contains (name of vbx) then
                                    if (count of (messages of vbx whose message id is targetID)) > 0 then
                                        set stillThere to true
                                    end if
                                end if
                            on error
                                set verifyFailed to true
                            end try
                        end repeat
                        if stillThere or verifyFailed then return "noop"
                        return "ok"
                    end if
                end if
            end repeat
        end tell
        return "notfound"
    end run
    """
    /// Outcome of a permanent-delete attempt — `unsupported` is its own case because a silent
    /// no-op and a genuine miss are very different things to report to the caller.
    public enum PermanentDeleteOutcome { case erased, notInTrash, unsupported }

    /// PERMANENTLY erase a message that is already in trash, VERIFYING the erase took effect.
    /// - `.erased` — the message is gone.
    /// - `.notInTrash` — no message with that id in any trash-like mailbox (it may still be sitting
    ///   in a normal mailbox; that is a deliberate no-op, not a failure — trash it first).
    /// - `.unsupported` — the message WAS found in trash and `delete` was issued, but the message
    ///   survived: Mail's AppleScript cannot expunge on this account type (IMAP/iCloud).
    /// Caller MUST have label-gated the target.
    public func deletePermanentlyFromTrash(internetMessageID: String, accountName: String?,
                                           trashNames: [String]) throws -> PermanentDeleteOutcome {
        guard !trashNames.isEmpty else { return .notInTrash }
        let bare = MailFormat.stripAngleBrackets(internetMessageID) ?? internetMessageID
        let blob = trashNames.joined(separator: MailScript.RS)
        var sawNoop = false
        for candidate in ["<\(bare)>", bare] {
            let out = try runner.run(MailScript.deletePermanentScript, arguments: [candidate, accountName ?? "", blob])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out == "ok" { return .erased }
            if out == "noop" { sawNoop = true }
        }
        return sawNoop ? .unsupported : .notInTrash
    }

    /// Repeatedly deletes the FIRST message rather than indexing a snapshot list: deleting while
    /// walking an index range mutates the collection underneath the iterator (Mail raises -1728).
    /// Takes an explicitly RESOLVED mailbox name — the choice of which trash to empty is made in
    /// Swift (see `resolveTrashMailbox`) so it is unit-testable and fail-closed on ambiguity.
    private static let emptyTrashScript = """
    on run argv
        set acctName to item 1 of argv
        set mbxName to item 2 of argv
        set maxN to (item 3 of argv) as integer
        set removed to 0
        set stalled to "0"
        tell application "Mail"
            set tmbx to (first mailbox of account acctName whose name is mbxName)
            set total to count of (every message of tmbx)
            repeat while removed < maxN
                -- NB: `beforeCount`, not `before` — `before` is an AppleScript reserved word
                -- (relative-position keyword), so `set before to …` is a SYNTAX error and the
                -- whole script fails to compile at runtime. Caught by the osacompile harness in
                -- bats/helpers/applescript_syntax_check.py, which exists because these bodies are
                -- Swift string literals no Swift-side test can see.
                set beforeCount to count of (every message of tmbx)
                if beforeCount is 0 then exit repeat
                delete (item 1 of (every message of tmbx))
                -- Count AFTER each delete and bail the moment one has no effect. On IMAP accounts
                -- `delete` cannot expunge a message that is already in trash, so without this the
                -- loop would spin maxN times and report maxN phantom erasures.
                if (count of (every message of tmbx)) is greater than or equal to beforeCount then
                    set stalled to "1"
                    exit repeat
                end if
                set removed to removed + 1
            end repeat
        end tell
        return (removed as string) & "/" & (total as string) & "/" & stalled
    end run
    """
    /// IRREVERSIBLE: permanently erase up to `max` messages from one resolved trash mailbox.
    /// Returns (removed, totalBefore). This is the one operation that cannot be scoped to test
    /// data, so the command layer gates it on an operator-only env var and never runs it
    /// autonomously.
    /// `stalled` is true when a `delete` had no effect — i.e. this account type cannot be expunged
    /// from AppleScript, so the erase silently did nothing and the caller must be told.
    public func emptyTrash(accountName: String, mailboxName: String, max: Int) throws -> (removed: Int, total: Int, stalled: Bool) {
        let out = try runner.run(MailScript.emptyTrashScript, arguments: [accountName, mailboxName, String(max)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.split(separator: "/").map(String.init)
        guard parts.count == 3, let removed = Int(parts[0]), let total = Int(parts[1]) else {
            throw AppleError.upstream("empty-trash returned an unexpected result '\(out)'.")
        }
        return (removed, total, parts[2] == "1")
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
                set hdv to ""
                if (count of fld) > 3 then set hdv to (item 4 of fld)
                set end of condList to {rtype:rtv, qual:qfv, expr:exv, hdr:hdv}
            end if
        end repeat
        set AppleScript's text item delimiters to RS
        set actToks to text items of actBlob
        set AppleScript's text item delimiters to ""
        -- Precompute move/copy targets ("Account/Mailbox/Path" → account + mailbox-path) OUTSIDE the
        -- tell block (delimiter/list ops misparse inside `tell application "Mail"`), like conditions.
        set moveTo to item 6 of argv
        set copyTo to item 7 of argv
        set flagIdx to item 8 of argv
        set mvAcct to ""
        set mvMbx to ""
        set cpAcct to ""
        set cpMbx to ""
        if moveTo is not "" then
            set AppleScript's text item delimiters to "/"
            set mvParts to text items of moveTo
            set mvAcct to item 1 of mvParts
            set mvMbx to (items 2 thru -1 of mvParts) as string
            set AppleScript's text item delimiters to ""
        end if
        if copyTo is not "" then
            set AppleScript's text item delimiters to "/"
            set cpParts to text items of copyTo
            set cpAcct to item 1 of cpParts
            set cpMbx to (items 2 thru -1 of cpParts) as string
            set AppleScript's text item delimiters to ""
        end if
        tell application "Mail"
            -- Pre-resolve move/copy targets BEFORE creating the rule, so an unresolvable target (bad
            -- account/mailbox, or a nested path Mail's `name` doesn't match) fails cleanly with NO
            -- partial rule left behind — and the CLI never reports an action that didn't attach.
            set mvMailbox to missing value
            set cpMailbox to missing value
            if moveTo is not "" then
                try
                    set mvMailbox to (first mailbox of account mvAcct whose name is mvMbx)
                end try
                if mvMailbox is missing value then return "unresolved:move_to=" & moveTo
            end if
            if copyTo is not "" then
                try
                    set cpMailbox to (first mailbox of account cpAcct whose name is cpMbx)
                end try
                if cpMailbox is missing value then return "unresolved:copy_to=" & copyTo
            end if
            set r to make new rule with properties {name:ruleName, enabled:isEnabled}
            try
                set all conditions must be met of r to ((item 5 of argv) is "1")
            end try
            repeat with c in condList
                set rt to rtype of c
                set qf to qual of c
                set ex to expr of c
                set hd to hdr of c
                try
                    if hd is not "" then
                        -- `header` is the rule condition's "Rule header key" property; it is what
                        -- makes a `header key` rule type actually name a header.
                        make new rule condition at end of rule conditions of r with properties {rule type:rt, qualifier:qf, expression:ex, header:hd}
                    else
                        make new rule condition at end of rule conditions of r with properties {rule type:rt, qualifier:qf, expression:ex}
                    end if
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
                end if
            end repeat
            -- Apply the pre-resolved move/copy targets + flag color. `should move/copy message` is the
            -- boolean that ACTIVATES the action; `move/copy message` only names the target mailbox
            -- (setting the target ALONE leaves the action inactive). Mirrors the MCP oracle's
            -- _build_action_lines, which pairs `set should move message … to true` with the target.
            if mvMailbox is not missing value then
                set should move message of r to true
                set move message of r to mvMailbox
            end if
            if cpMailbox is not missing value then
                set should copy message of r to true
                set copy message of r to cpMailbox
            end if
            if flagIdx is not "" then
                set mark flagged of r to true
                set mark flag index of r to (flagIdx as integer)
            end if
        end tell
        return "ok"
    end run

    on ruleType(f)
        tell application "Mail"
            if f is "from" then return from header
            if f is "to" then return to header
            if f is "subject" then return subject header
            if f is "body" then return message content
            -- Mail.sdef's RuleType enum has BOTH `any recipient` and `to or cc header`, and they
            -- are different rules: `any recipient` covers Bcc, `to or cc header` does not. Mapping
            -- any_recipient onto to-or-cc built a rule that silently missed Bcc'd mail.
            if f is "any_recipient" then return any recipient
            -- `header key` pairs with the condition's `header` property (set at creation).
            if f is "header_name" then return header key
        end tell
        -- Never silently fall back to `from header`: that would build a DIFFERENT rule than the
        -- caller asked for and quietly act on real mail. Upstream validation should make this
        -- unreachable, so failing loudly is correct.
        error "unknown rule condition field: " & f
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
    /// Create a Mail rule with the live-safe action plan (mark_read / mark_flagged / flag_color /
    /// move_to / copy_to). forward_to (auto-send) and delete (auto-trash) are refused upstream by
    /// `RuleSchema.liveActionPlan`. move_to/copy_to resolve `Account/Mailbox` to a concrete target
    /// mailbox in the script. Caller MUST have label-checked the rule name + self-scoped it.
    public func createRule(name: String, enabled: Bool, matchAll: Bool,
                           conditions: [(type: String, op: String, value: String, header: String)],
                           plan: RuleLiveGuards.LiveActionPlan) throws {
        let condBlob = conditions.map { [$0.type, $0.op, $0.value, $0.header].joined(separator: MailScript.US) }
            .joined(separator: MailScript.RS)
        var toks: [String] = []
        if plan.markRead { toks.append("mark_read") }
        if plan.markFlagged { toks.append("mark_flagged") }
        let actBlob = toks.joined(separator: MailScript.RS)
        let out = try runner.run(MailScript.createRuleScript,
                                 arguments: [name, enabled ? "1" : "0", condBlob, actBlob, matchAll ? "1" : "0",
                                             plan.moveTo ?? "", plan.copyTo ?? "",
                                             plan.flagColorIndex.map { String($0) } ?? ""])
        if out.hasPrefix("unresolved:") {
            throw AppleError.notFound("rule action target could not be resolved: \(out.dropFirst("unresolved:".count)). Use 'Account/Mailbox' and check the mailbox exists (nested names may need the leaf). No rule was created.")
        }
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
        -- move/copy target splits precomputed OUTSIDE the tell (delimiter ops misparse inside it).
        set moveTo to item 10 of argv
        set copyTo to item 11 of argv
        set flagIdx to item 12 of argv
        set mvAcct to ""
        set mvMbx to ""
        set cpAcct to ""
        set cpMbx to ""
        if moveTo is not "" then
            set AppleScript's text item delimiters to "/"
            set mvParts to text items of moveTo
            set mvAcct to item 1 of mvParts
            set mvMbx to (items 2 thru -1 of mvParts) as string
            set AppleScript's text item delimiters to ""
        end if
        if copyTo is not "" then
            set AppleScript's text item delimiters to "/"
            set cpParts to text items of copyTo
            set cpAcct to item 1 of cpParts
            set cpMbx to (items 2 thru -1 of cpParts) as string
            set AppleScript's text item delimiters to ""
        end if
        tell application "Mail"
            set r to rule idx
            -- Pre-resolve move/copy targets first, so an unresolvable target fails cleanly before
            -- any patch is applied (and the CLI never claims an action that didn't attach).
            set mvMailbox to missing value
            set cpMailbox to missing value
            if moveTo is not "" then
                try
                    set mvMailbox to (first mailbox of account mvAcct whose name is mvMbx)
                end try
                if mvMailbox is missing value then return "unresolved:move_to=" & moveTo
            end if
            if copyTo is not "" then
                try
                    set cpMailbox to (first mailbox of account cpAcct whose name is cpMbx)
                end try
                if cpMailbox is missing value then return "unresolved:copy_to=" & copyTo
            end if
            if hasMatch then
                try
                    set all conditions must be met of r to matchAll
                end try
            end if
            if hasActs then
                -- actions REPLACE wholesale (mirror the MCP oracle's update_rule reset): the
                -- `should move/copy message` booleans are what CLEAR the move/copy actions — Mail
                -- REFUSES `set move message … to missing value` (-1700 "can't make missing value into
                -- type mailbox") and `delete move message …` is a silent no-op, so the boolean is the
                -- only real toggle. Reset every supported action flag, then reapply the new plan. No
                -- `try` masking: the old `try`-wrapped `missing value` clears failed SILENTLY, leaving
                -- stale move/copy actions behind — a bare set surfaces any real failure instead.
                set should move message of r to false
                set should copy message of r to false
                set mark read of r to false
                set mark flagged of r to false
                set mark flag index of r to -1
                set delete message of r to false
                -- (No forward-message clear here: a rule carrying a `forward message` is REFUSED up
                -- front by checkSupportedActions, so it never reaches this reset — forward is a named
                -- dangerous action handled by refusal, not by clear-and-proceed.)
                repeat with atk in actToks
                    set tok to atk as string
                    if tok is "mark_read" then
                        set mark read of r to true
                    else if tok is "mark_flagged" then
                        set mark flagged of r to true
                    end if
                end repeat
                if mvMailbox is not missing value then
                    set should move message of r to true
                    set move message of r to mvMailbox
                end if
                if cpMailbox is not missing value then
                    set should copy message of r to true
                    set copy message of r to cpMailbox
                end if
                if flagIdx is not "" then
                    set mark flagged of r to true
                    set mark flag index of r to (flagIdx as integer)
                end if
            end if
            -- `enabled` AFTER the action reset: Mail (Tahoe) silently reverts an enabled set that
            -- PRECEDES the reset block, so apply it here (mirrors the oracle's documented ordering).
            if hasEnabled then set enabled of r to enVal
            -- Rename LAST: renaming invalidates the rule reference for subsequent property accesses
            -- (Tahoe), so every other patch runs against the still-stably-named rule first.
            if hasName then set name of r to newName
        end tell
        return "ok"
    end run
    """
    /// In-place metadata patch (name/enabled/match/actions) of rule `index`. `nil` = leave as-is.
    /// Reliable Mail ops only — never mutates conditions (see updateRuleMetaScript). Caller MUST
    /// have label-checked the target + patch. `plan` (if non-nil) is the live-safe action set,
    /// applied in place (mark flags reset+reapplied; move/copy/flag applied if present).
    public func updateRuleMeta(index: Int, name: String?, enabled: Bool?, matchAll: Bool?,
                               plan: RuleLiveGuards.LiveActionPlan?) throws {
        var toks: [String] = []
        if let plan {
            if plan.markRead { toks.append("mark_read") }
            if plan.markFlagged { toks.append("mark_flagged") }
        }
        let actBlob = toks.joined(separator: MailScript.RS)
        let args = [
            String(index),
            name != nil ? "1" : "0", name ?? "",
            enabled != nil ? "1" : "0", (enabled ?? false) ? "1" : "0",
            matchAll != nil ? "1" : "0", (matchAll ?? false) ? "1" : "0",
            plan != nil ? "1" : "0", actBlob,
            plan?.moveTo ?? "", plan?.copyTo ?? "", plan?.flagColorIndex.map { String($0) } ?? "",
        ]
        let out = try runner.run(MailScript.updateRuleMetaScript, arguments: args)
        if out.hasPrefix("unresolved:") {
            throw AppleError.notFound("rule action target could not be resolved: \(out.dropFirst("unresolved:".count)). Use 'Account/Mailbox' and check the mailbox exists (nested names may need the leaf). The rule was not modified.")
        }
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

    private static let checkSupportedActionsScript = """
    on run argv
        set idx to (item 1 of argv) as integer
        set US to (ASCII character 31)
        set bad to {}
        tell application "Mail"
            set r to rule idx
            -- Probe the rule-action properties the CLI does NOT model (mirrors the MCP oracle's
            -- `_check_supported_actions`, mail_connector.py) PLUS `forward message` (the auto-forward
            -- recipients — a named dangerous action; the oracle only checks its sibling `forward text`
            -- and clears `forward message` on action-update, but an enable-only update would leave it
            -- live, so the CLI REFUSES any rule carrying it — a deliberate, safety-stricter divergence).
            -- Each probe FAILS CLOSED: an `on error` (property renamed/absent in a future Mail) records
            -- the property as unverifiable so the rule is REFUSED, never silently treated as clean — a
            -- swallowed probe error on a run-script (RCE) / auto-forward gate is the wrong direction.
            try
                if (run script of r) is not missing value then set end of bad to "run script"
            on error
                set end of bad to "run script (unreadable)"
            end try
            try
                if (play sound of r) is not missing value then set end of bad to "play sound"
            on error
                set end of bad to "play sound (unreadable)"
            end try
            try
                if (redirect message of r) is not "" then set end of bad to "redirect message"
            on error
                set end of bad to "redirect message (unreadable)"
            end try
            try
                if (forward message of r) is not "" then set end of bad to "forward message"
            on error
                set end of bad to "forward message (unreadable)"
            end try
            try
                if (forward text of r) is not "" then set end of bad to "forward text"
            on error
                set end of bad to "forward text (unreadable)"
            end try
            try
                if (reply text of r) is not "" then set end of bad to "reply text"
            on error
                set end of bad to "reply text (unreadable)"
            end try
            try
                if (highlight text using color of r) then set end of bad to "highlight text using color"
            on error
                set end of bad to "highlight text using color (unreadable)"
            end try
            try
                if ((color message of r) as text) is not "none" then set end of bad to "color message"
            on error
                set end of bad to "color message (unreadable)"
            end try
        end tell
        set AppleScript's text item delimiters to US
        set s to bad as string
        set AppleScript's text item delimiters to ""
        return s
    end run
    """
    /// Refuse to update a rule whose EXISTING actions include something the CLI can't model
    /// (run-script / play-sound / redirect / forward-message / forward-text / reply-text / highlight /
    /// color-message) — mirrors the oracle's `_check_supported_actions` (plus `forward message`, which
    /// the oracle clears-on-action-update but we refuse, so an enable-only update can never leave a
    /// live auto-forwarder). Without this, an in-place update would silently PRESERVE+misrepresent
    /// such an action (the JSON would claim a clean action set) and a recreate would silently DROP it.
    /// A CLI-authored rule never carries these (create/liveActionPlan only ever set move/copy/mark/
    /// flag); a hand-made labeled rule might. Worst cases guarded: a run-AppleScript action
    /// (RCE-on-incoming-mail) and a forward-to-others action (auto-send). FAILS CLOSED — an
    /// unreadable probe or a script-level error REFUSES the update rather than risk a silent bypass.
    public func checkSupportedActions(index: Int) throws {
        let raw: String
        do {
            raw = try runner.run(MailScript.checkSupportedActionsScript, arguments: [String(index)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Fail CLOSED: if the probe script itself errors (e.g. the rule vanished, or a Mail-version
            // change broke the tell block), REFUSE rather than proceed blind past an unmodeled action.
            throw AppleError.mailSafety("could not verify rule \(index)'s existing actions are within the supported schema (\(error)) — refusing to update; edit this rule in Mail.app's Rules pane.")
        }
        guard !raw.isEmpty else { return }
        let names = raw.components(separatedBy: MailScript.US).joined(separator: ", ")
        throw AppleError.mailSafety("rule \(index) uses actions outside the supported schema: \(names). The CLI can't safely update a rule whose existing actions it doesn't model (they'd be silently preserved or dropped) — edit this rule in Mail.app's Rules pane instead.")
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
        set ccRaw to item 4 of argv
        set bccRaw to item 5 of argv
        set senderAddr to item 6 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set m to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            if senderAddr is not "" then set sender of m to senderAddr
            my addDraftRecips(m, toRaw, US, "to")
            my addDraftRecips(m, ccRaw, US, "cc")
            my addDraftRecips(m, bccRaw, US, "bcc")
            save m
        end tell
        return "ok"
    end run

    on addDraftRecips(msg, raw, US, kind)
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
    end addDraftRecips
    """
    /// Save a message to Mail's Drafts (no send), with cc/bcc and an optional `sender` From
    /// identity (a bare account address — manage_drafts create parity). Caller MUST have
    /// label-checked the subject. All values argv-passed (injection-safe).
    public func createDraft(subject: String, body: String, to: [String],
                            cc: [String] = [], bcc: [String] = [], sender: String? = nil) throws {
        let US = MailScript.US
        let out = try runner.run(MailScript.createDraftScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            sender ?? "",
        ])
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

    /// Send an EXISTING Drafts item (manage_drafts action=send). SAFETY-CRITICAL on two axes:
    ///
    /// 1. Recipients are PRE-SET (baked into the stored draft, not passed by this call), so the
    ///    draft's OWN to/cc/bcc are read and EVERY address is verified against the self-only
    ///    allowlist BEFORE anything is opened or sent — fail-closed. Any non-allowlisted address
    ///    refuses (`blocked:<addr>`); an empty allowlist blocks everything; a recipient-less draft
    ///    refuses (`norecipients`). AppleScript string `is` is case-insensitive by default, matching
    ///    `guardOutbound`. Then the OPENED message's recipients are re-verified (defense in depth).
    ///
    /// 2. THE MECHANISM — open-then-send, NOT `send <stored draft>`. Mail throws -1708 ("doesn't
    ///    understand the send message") when you `send` a stored Drafts `message` object; the
    ///    reference oracle (patrickfreyer manage_drafts action=send) has this SAME bug and returns
    ///    the error string. The working path — a CLI-exceeds-oracle win — is: `open` the stored
    ///    draft (which registers a sendable `outgoing message`), locate that outgoing message, then
    ///    `send` it. `send` (unlike `delete`, which is a no-op on outgoing messages) DISPATCHES it —
    ///    the mail actually leaves for the recipients and lands in Sent. Mail normally drops the
    ///    outgoing-message object from the outbox once sent; that removal can lag if the outbox is
    ///    in a stuck state, but the send itself has completed. The original Drafts item is then
    ///    best-effort deleted (action=send consumes a draft).
    ///
    ///    The outgoing message is located by its UNIQUE labeled subject (label prefix + timestamp),
    ///    NOT by an id-diff snapshot: re-opening an already-open draft REUSES its outgoing message
    ///    (no new id to diff), and Mail can populate the outgoing subject lazily after `open` — an
    ///    id-diff poll misses both. Subject-match is safe because that unique subject can only ever
    ///    belong to THIS draft's own outgoing copy — Mail's outgoing store is SHARED with the
    ///    operator's live compose windows, but those never carry a test subject, and step (4)
    ///    re-verifies every recipient against the allowlist before `send` regardless. The draft
    ///    itself is located by EXACT subject + the label-prefix double guard (STABLE indexed
    ///    references; subject matched in code — `whose subject is` doesn't filter outgoing-message
    ///    objects reliably). All values argv-passed (injection-safe).
    private static let sendDraftScript = """
    on run argv
        set wantSubject to item 1 of argv
        set thePrefix to item 2 of argv
        set acctFilter to item 3 of argv
        set allowRaw to item 4 of argv
        set US to (ASCII character 31)
        set AppleScript's text item delimiters to US
        set allowList to text items of allowRaw
        set AppleScript's text item delimiters to ""
        tell application "Mail"
            repeat with ai from 1 to (count of accounts)
                set a to account ai
                if acctFilter is "" or (name of a) is acctFilter then
                    repeat with mi from 1 to (count of mailboxes of a)
                        set dmbx to mailbox mi of a
                        if (name of dmbx) contains "Drafts" then
                            try
                                set k to (count of messages of dmbx)
                                repeat with j from 1 to k
                                    set m to message j of dmbx
                                    set sj to ""
                                    try
                                        set sj to subject of m
                                    end try
                                    if sj is wantSubject and sj starts with thePrefix then
                                        -- (1) verify the STORED draft's recipients BEFORE any open.
                                        -- Outside the open/send `try` below so a genuine block/no-recip
                                        -- returns its own sentinel (never masked as a send error).
                                        set addrs to my collectAddrs(m)
                                        if (count of addrs) is 0 then return "norecipients"
                                        set bad to my firstDisallowed(addrs, allowList)
                                        if bad is not "" then return "blocked:" & bad
                                        -- (2)–(6) open-then-send CRITICAL SECTION, wrapped in its OWN
                                        -- `try` with an `on error`: a throw here (open, `send`, SMTP /
                                        -- network, Mail-internal) must surface as a DISTINCT "senderror:"
                                        -- sentinel, NOT be swallowed by the enclosing mailbox-scan `try`
                                        -- into a misleading "notfound". The clean `return` sentinels
                                        -- inside (openfailed/norecipients/blocked/sent) still exit
                                        -- normally — only actual thrown errors reach `on error`.
                                        try
                                            -- (2) open the stored draft => Mail registers (or REUSES, if
                                            -- it was opened before) an outgoing message with this subject
                                            open m
                                            -- (3) locate the outgoing message by this UNIQUE labeled
                                            -- subject. Match by SUBJECT, not an id-diff snapshot: an
                                            -- already-open draft reuses its outgoing message (NO new id),
                                            -- and Mail can populate the subject lazily after open — an
                                            -- id-diff poll misses both. The subject carries the label
                                            -- prefix + a unique timestamp, so only THIS draft's own
                                            -- outgoing copy can match (the operator's real compose windows
                                            -- never share it); step (4) re-verifies recipients regardless.
                                            -- Patient (up to 30s): Mail can lag surfacing the message.
                                            set target to missing value
                                            repeat 60 times
                                                repeat with om in (every outgoing message)
                                                    set osj to ""
                                                    try
                                                        set osj to subject of om
                                                    end try
                                                    if osj is wantSubject then
                                                        set target to om
                                                        exit repeat
                                                    end if
                                                end repeat
                                                if target is not missing value then exit repeat
                                                delay 0.5
                                            end repeat
                                            if target is missing value then return "openfailed"
                                            -- (4) re-verify the OPENED message's recipients (defense in
                                            -- depth — this is the object actually about to be sent)
                                            set addrs2 to my collectAddrs(target)
                                            if (count of addrs2) is 0 then return "norecipients"
                                            set bad2 to my firstDisallowed(addrs2, allowList)
                                            if bad2 is not "" then return "blocked:" & bad2
                                            -- Build the sent-recipient report BEFORE dispatch. Any error in
                                            -- this coercion then throws BEFORE `send` (=> senderror, nothing
                                            -- sent), and — critically — NOTHING that can throw runs AFTER
                                            -- `send target`. A post-send throw would return `senderror` and
                                            -- wrongly advise the operator to "retry", risking a DUPLICATE
                                            -- send of a message that already left.
                                            set AppleScript's text item delimiters to US
                                            set sentList to (addrs2 as text)
                                            set AppleScript's text item delimiters to ""
                                            -- (5) send the opened outgoing message (dispatches it => Sent)
                                            send target
                                            -- (6) manage_drafts action=send semantics: a sent draft is
                                            -- consumed. Best-effort delete of the ORIGINAL draft(s),
                                            -- re-located by the SAME subject+prefix double guard (never a
                                            -- blind index delete — that could hit the wrong message);
                                            -- end-to-start so removals don't reindex the rest. Its OWN inner
                                            -- try makes a delete failure a no-op (never re-raising post-send),
                                            -- so the send already succeeded => a lingering draft is cosmetic.
                                            -- (Deletes ALL exact-subject labeled matches; in the
                                            -- unique-timestamped test flow there is exactly one.)
                                            try
                                                set kk to (count of messages of dmbx)
                                                repeat with jj from kk to 1 by -1
                                                    set dm to message jj of dmbx
                                                    set dsj to ""
                                                    try
                                                        set dsj to subject of dm
                                                    end try
                                                    if dsj is wantSubject and dsj starts with thePrefix then delete dm
                                                end repeat
                                            end try
                                            return "sent" & US & sentList
                                        on error errMsg number errNum
                                            return "senderror:" & (errNum as string)
                                        end try
                                    end if
                                end repeat
                            end try
                        end if
                    end repeat
                end if
            end repeat
        end tell
        return "notfound"
    end run

    """
    /// Outcome of `sendDraft`. `.sent` carries the verified recipients the mail was dispatched to
    /// (the draft's OWN pre-set to/cc/bcc — the command never supplied them). `.sendError` carries
    /// the Mail/AppleScript error number when `open`/`send` itself threw; it is DISTINCT from
    /// `.notFound`, which now means only "no such labeled draft" and never a swallowed send failure.
    public enum DraftSendResult: Equatable {
        case sent([String])
        case notFound
        case noRecipients
        case blocked(String)
        case openFailed
        case sendError(String)

        /// Pure parser for `sendDraftScript`'s raw stdout → result. Extracted so the safety-critical
        /// string→enum mapping (esp. the `blocked:<addr>` verdict and the recipient split) is
        /// unit-testable WITHOUT a live Mac / Mail: the AppleScript can't run in CI, but this mapping
        /// is exactly where a future edit could silently mishandle a `blocked` verdict, so it earns a
        /// logic-tier regression lock. Returns nil for an unrecognized string (caller then throws).
        /// `us` is the field separator the script uses (`MailScript.US`).
        public static func parse(_ raw: String, us: String) -> DraftSendResult? {
            if raw == "notfound" { return .notFound }
            if raw == "norecipients" { return .noRecipients }
            if raw == "openfailed" { return .openFailed }
            if raw.hasPrefix("blocked:") { return .blocked(String(raw.dropFirst("blocked:".count))) }
            if raw.hasPrefix("senderror:") { return .sendError(String(raw.dropFirst("senderror:".count))) }
            if raw == "sent" { return .sent([]) }
            if raw.hasPrefix("sent" + us) {
                let rest = String(raw.dropFirst(("sent" + us).count))
                return .sent(rest.components(separatedBy: us).filter { !$0.isEmpty })
            }
            return nil
        }
    }
    /// Send the existing labeled draft matching `subject` (optionally within `account`), after
    /// in-script verification that every stored recipient is in `allowlist`. Caller MUST have
    /// passed the test-mode gate + label check; this method re-enforces the label prefix and the
    /// allowlist inside the script (defense in depth) but performs no flag gating itself. Uses the
    /// open-then-send mechanism (see `sendDraftScript` doc); a successful `.sent([recipients])`
    /// carries the verified recipients dispatched to and also consumes the original Drafts item
    /// (best-effort delete). `.openFailed` means the draft opened but its outgoing message never
    /// materialized within the 30s poll window (an upstream Mail hiccup) — the draft is left
    /// untouched so the caller can retry or send it manually. `.sendError(detail)` means `open`/`send`
    /// itself threw (Mail/network) AFTER recipient verification — reported honestly, never masked as
    /// `.notFound`.
    public func sendDraft(subject: String, prefix: String, account: String?, allowlist: [String]) throws -> DraftSendResult {
        // `addressGuardHelpers` (collectAddrs + firstDisallowed) used to live inside this
        // script's own literal; it is now the SHARED block appended to every dispatching script.
        let out = try runner.run(MailScript.sendDraftScript + "\n" + MailScript.addressGuardHelpers, arguments: [
            subject, prefix, account ?? "", allowlist.joined(separator: MailScript.US),
        ])
        guard let result = DraftSendResult.parse(out, us: MailScript.US) else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "sendDraft returned '\(out)'")
        }
        return result
    }

    // MARK: Draft save / open (NON-SENDING — never call AppleScript `send`)
    //
    // These back `send --mode draft`, `send --mode open`'s draft sibling, `draft open`, and
    // `draft-rich --open/--save-as-draft`. Every user value is US-delimited argv (never
    // interpolated; injection-safe). Each osascript string is INDEPENDENT, so a script that calls
    // a handler carries its OWN copy of it. NONE of these emit a `send` — a draft/open is not a
    // send. Callers gate: `saveDraft`/`saveOpenAsDraft` behind label + test-mode; `openDraft`
    // behind a labeled subject; `openEml` (above) opens a review window the operator sends manually.

    /// Make a `{visible:false}` outgoing message (subject/body/recipients/attachments + optional
    /// `sender`) and `save` it to Mail's Drafts — no send. Recipients + attachment paths are
    /// US-delimited argv. Caller MUST have label-checked the subject + passed the test-mode gate.
    private static let saveDraftScript = """
    on run argv
        set theSubject to item 1 of argv
        set theBody to item 2 of argv
        set toRaw to item 3 of argv
        set ccRaw to item 4 of argv
        set bccRaw to item 5 of argv
        set attRaw to item 6 of argv
        set senderAddr to item 7 of argv
        set US to (ASCII character 31)
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            if senderAddr is not "" then set sender of newMsg to senderAddr
            my addRecipients(newMsg, toRaw, US, "to")
            my addRecipients(newMsg, ccRaw, US, "cc")
            my addRecipients(newMsg, bccRaw, US, "bcc")
            my addAttachments(newMsg, attRaw, US)
            save newMsg
        end tell
        return "saved"
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
    /// Save a message to Mail's Drafts with recipients + attachments + optional `sender` (no send).
    /// `sender`, when non-nil, sets the outgoing message's From identity (a bare account address).
    /// Caller MUST have label-checked the subject + passed the test-mode gate. Throws on non-"saved".
    public func saveDraft(subject: String, body: String, to: [String], cc: [String], bcc: [String],
                          attachmentPaths: [String], sender: String? = nil) throws {
        let US = MailScript.US
        let out = try runner.run(MailScript.saveDraftScript, arguments: [
            subject, body,
            to.joined(separator: US), cc.joined(separator: US), bcc.joined(separator: US),
            attachmentPaths.joined(separator: US), sender ?? "",
        ])
        guard out == "saved" else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "saveDraft returned '\(out)'")
        }
    }

    /// Open an EXISTING draft (located by exact subject) in a Mail compose window — no send. Scans
    /// any "Drafts"-named mailbox (Gmail keeps drafts in "[Gmail]/Drafts"), optionally restricted to
    /// `acctName`. STABLE indexed references (`account ai` / `mailbox mi` / `message j`) + subject
    /// matched in code, mirroring `deleteDraftScript` — a `whose subject is` filter doesn't match
    /// draft (outgoing-message) objects reliably. Returns "opened" on the first match, else "notfound".
    private static let openDraftScript = """
    on run argv
        set wantSubject to item 1 of argv
        set acctFilter to item 2 of argv
        tell application "Mail"
            repeat with ai from 1 to (count of accounts)
                set a to account ai
                if acctFilter is "" or (name of a) is acctFilter then
                    repeat with mi from 1 to (count of mailboxes of a)
                        set dmbx to mailbox mi of a
                        if (name of dmbx) contains "Drafts" then
                            try
                                set k to (count of messages of dmbx)
                                repeat with j from 1 to k
                                    set m to message j of dmbx
                                    set sj to ""
                                    try
                                        set sj to subject of m
                                    end try
                                    if sj is wantSubject then
                                        open m
                                        return "opened"
                                    end if
                                end repeat
                            end try
                        end if
                    end repeat
                end if
            end repeat
        end tell
        return "notfound"
    end run
    """
    /// Open an existing draft by exact subject (optionally within `account`). Returns true when a
    /// matching draft was found + opened. Caller MUST have verified the subject is labeled.
    @discardableResult
    public func openDraft(subject: String, account: String?) throws -> Bool {
        let out = try runner.run(MailScript.openDraftScript, arguments: [subject, account ?? ""])
        return out == "opened"
    }

}

extension MailScript {
    /// Convert the selection script's `yyyy-MM-ddTHH:mm:ss` LOCAL components into the UTC
    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` form every other date in the Mail envelope uses.
    ///
    /// The AppleScript emits numeric components rather than a formatted date string precisely so
    /// the value does not depend on the machine's locale; this is where the timezone is applied.
    /// Returns nil for empty/unparseable input rather than guessing — a wrong timestamp is worse
    /// than an absent one.
    static func utcFromLocalComponents(_ raw: String, timeZone: TimeZone = .current) -> String? {
        guard !raw.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return out.string(from: date)
    }
}
