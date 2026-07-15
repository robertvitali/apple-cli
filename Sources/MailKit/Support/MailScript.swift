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

    /// Full plaintext body of the message whose RFC-5322 `message id` matches. Scans the
    /// given account's mailboxes first (fast), then all accounts. Returns nil if not found.
    /// The scan is Mail's inherent cost when addressing by Message-ID (no index for bodies).
    private static let bodyScript = """
    on run argv
        set targetID to item 1 of argv
        set acctName to item 2 of argv
        tell application "Mail"
            if acctName is not "" then
                try
                    set a to first account whose name is acctName
                    repeat with mbx in mailboxes of a
                        try
                            set msgs to (messages of mbx whose message id is targetID)
                            if (count of msgs) > 0 then return (content of (item 1 of msgs))
                        end try
                    end repeat
                end try
            end if
            repeat with a in accounts
                repeat with mbx in mailboxes of a
                    try
                        set msgs to (messages of mbx whose message id is targetID)
                        if (count of msgs) > 0 then return (content of (item 1 of msgs))
                    end try
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
}
