import Foundation
import ArgumentParser
import AppleKit

// P1 message reads: search, list, get, selected, thread, attachments list.

// MARK: search

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search messages (subject/sender/body/date/read/flagged/attachment; paginated).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit to search all accounts.") var account: String?
    @Option(name: .long, help: "Mailbox name (default INBOX; use 'All' for every mailbox).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Substring match on subject (repeatable — matches ANY, MCP B subject_keywords).") var subject: [String] = []
    @Option(name: .long, help: "Substring match on sender name/email.") var sender: String?
    @Option(name: .long, help: "Substring match on the indexed body preview.") var body: String?
    @Option(name: .long, help: "Lower bound on date received (YYYY-MM-DD).") var fromDate: String?
    @Option(name: .long, help: "Upper bound on date received (YYYY-MM-DD, inclusive).") var toDate: String?
    @Flag(name: .long, help: "Only read messages.") var read = false
    @Flag(name: .long, help: "Only unread messages.") var unread = false
    @Flag(name: .long, help: "Only flagged messages.") var flagged = false
    @Flag(name: .long, help: "Only unflagged messages.") var unflagged = false
    @Flag(name: .long, help: "Only messages with attachments.") var hasAttachment = false
    @Flag(name: .long, help: "Only messages without attachments.") var noAttachment = false
    @Option(name: .long, help: "Max results per page (default 50; 0 = all).") var limit: Int = 50
    @Option(name: .long, help: "Results to skip (pagination).") var offset: Int = 0
    @Option(name: .long, help: "Sort order: date_desc (default) or date_asc.") var sort: String = "date_desc"
    @Flag(name: .long, inversion: .prefixedNo, help: "Include the indexed body preview (default on).") var content = true
    @Option(name: .long, help: "Truncate each included body preview to N chars (0 = unlimited; MCP B max_content_length).") var maxContentLength: Int?
    @Flag(name: .long, help: "With --mailbox All, also sweep the system mailboxes MCP B skips. Excluded by leaf name: Trash, Junk, Junk Email, Deleted Items, Deleted Messages, Sent, Sent Items, Sent Messages, Drafts, Spam. Provider-specific names outside that list (notably Gmail's '[Gmail]/Sent Mail' and '[Gmail]/All Mail') are NOT excluded.") var includeSystemFolders = false

    func run() throws {
        try runGuarded(tool: "mail") {
            if let maxContentLength, maxContentLength < 0 {
                throw AppleError.validation("--max-content-length must be >= 0 (0 = unlimited).")
            }
            let ctx = try MailContext()
            var f = EnvelopeIndex.MessageFilters()
            if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
            f.mailboxName = mailbox
            // MCP B excludes SKIP_FOLDERS from a broad "All" sweep, so an All-search used to
            // return Trash/Sent/Junk hits the oracle never would. Naming a system mailbox
            // explicitly still searches it — the exclusion only changes what "All" means.
            f.includeSystemFolders = includeSystemFolders
            f.subjectContainsAny = subject
            f.senderContains = sender
            f.bodyContains = body
            f.readStatus = try triState(read, unread, "read", "unread")
            f.flagged = try triState(flagged, unflagged, "flagged", "unflagged")
            f.hasAttachment = try triState(hasAttachment, noAttachment, "has-attachment", "no-attachment")
            if let fromDate { f.dateFromUnix = try requireISODate(fromDate, name: "from-date") }
            if let toDate { f.dateToUnix = try requireISODate(toDate, name: "to-date", endOfDay: true) }
            // Oracle B validates `sort` against {date_desc, date_asc} and raises
            // "Invalid sort. Use: date_desc, date_asc" (tools/search.py). Accepting anything and
            // silently falling back to date_desc — while echoing the bogus token back in the
            // envelope's `sort` field — told the caller their sort was honoured when it wasn't.
            guard sort == "date_desc" || sort == "date_asc" else {
                throw AppleError.validation("invalid --sort '\(sort)'. Use: date_desc, date_asc.")
            }
            f.sortAscending = (sort == "date_asc")
            f.limit = (limit == 0) ? Int.max : limit
            f.offset = offset

            let rows = try ctx.index.queryMessages(f)
            var messages = rows.map { ctx.decodeSummary($0) }
            // `snippet` and `content_preview` are ONE value under two wire names (A/B dual-key
            // rule), so every mutation below must touch both — otherwise --no-content would clear
            // `snippet` and leave the same text exposed under `content_preview`.
            if !content {
                for i in messages.indices {
                    messages[i].snippet = nil
                    messages[i].content_preview = nil
                }
            }
            // MCP B max_content_length: cap each included preview (0 = unlimited → no cap).
            else if let cap = maxContentLength, cap > 0 {
                for i in messages.indices where (messages[i].snippet?.count ?? 0) > cap {
                    let capped = String(messages[i].snippet!.prefix(cap))
                    messages[i].snippet = capped
                    messages[i].content_preview = capped
                }
            }
            let total = try ctx.index.countMessages(f)
            // Empty page must NOT report has_more (else a paginating client loops on the same offset).
            let hasMore = !messages.isEmpty && (offset + messages.count < total)
            let isAllSweep = EnvelopeIndex.isAllWildcard(mailbox)
            let result = MailMessagesResult(
                account: account, mailbox: mailbox, messages: messages, count: messages.count,
                offset: offset, limit: limit, has_more: hasMore,
                next_offset: hasMore ? offset + messages.count : nil, sort: sort,
                // Disclose the narrowing: it is otherwise undetectable from the envelope, and this
                // is the surface an operator previews a bulk mutation with — see the scope note
                // BulkPreview emits for "All".
                system_folders_excluded: isAllSweep ? !includeSystemFolders : nil)
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: list (recent inbox — MCP B list_inbox_emails)

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent inbox messages (MCP B list_inbox_emails).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit for all accounts.") var account: String?
    @Flag(name: .long, help: "Only unread messages.") var unread = false
    @Option(name: .long, help: "Max messages (default 50; 0 = all).") var limit: Int = 50
    @Flag(name: .long, inversion: .prefixedNo, help: "Include the indexed body preview (default on; MCP B include_content).") var content = true

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var f = EnvelopeIndex.MessageFilters()
            if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
            f.mailboxName = "INBOX"
            if unread { f.readStatus = false }
            f.limit = (limit == 0) ? Int.max : limit
            let rows = try ctx.index.queryMessages(f)
            var messages = rows.map { ctx.decodeSummary($0) }
            if !content {
                for i in messages.indices {
                    messages[i].snippet = nil
                    messages[i].content_preview = nil   // same value, second wire name
                }
            }
            let result = MailMessagesResult(
                account: account, mailbox: "INBOX", messages: messages, count: messages.count,
                offset: 0, limit: limit, has_more: nil, next_offset: nil, sort: "date_desc")
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: get

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get one message by ROWID, RFC Message-ID, or message:// link.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (Envelope Index ROWID, RFC-5322 Message-ID, or message:// link).") var id: String
    @Option(name: .long, help: "Scope the lookup to this account (name or UUID; MCP A account param). Rejects if the message is elsewhere.") var account: String?
    @Option(name: .long, help: "Scope the lookup to this mailbox (MCP A mailbox param). Rejects if the message is elsewhere.") var mailbox: String?
    @Flag(name: .long, help: "Return headers/metadata only (skip recipients + preview).") var headersOnly = false
    @Flag(name: .long, help: "Fetch the full body via Mail.app (slow AppleScript scan; default returns the indexed preview).") var content = false
    @Flag(name: .long, help: "Alias/compat: never fetch the full body (default behavior).") var noContent = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                throw AppleError.notFound("no message for id '\(id)'.")
            }
            var msg = ctx.decodeSummary(row)
            // MCP A get_message account/mailbox: the CLI resolves by globally-unique id, so these
            // are SCOPING assertions — the returned message must be in that account/mailbox, else
            // not_found. Account compares canonically (name-or-UUID → UUID both sides); mailbox
            // matches the full path or its leaf component, case-insensitively.
            if let account {
                let wantUUID = try ctx.requireAccountUUID(account)
                let msgUUID = (try? ctx.requireAccountUUID(msg.account)) ?? ""
                guard wantUUID == msgUUID else {
                    throw AppleError.notFound("message '\(id)' is not in account '\(account)'.")
                }
            }
            if let mailbox {
                let want = mailbox.lowercased()
                let path = msg.mailbox.lowercased()
                let leaf = path.split(separator: "/").last.map(String.init) ?? path
                guard path == want || leaf == want else {
                    throw AppleError.notFound("message '\(id)' is not in mailbox '\(mailbox)' (it is in '\(msg.mailbox)').")
                }
            }
            if !headersOnly {
                let rowid = intVal(row["rowid"]) ?? 0
                let recips = try ctx.index.recipients(messageRowid: rowid)
                msg.to = recips.to; msg.cc = recips.cc; msg.bcc = recips.bcc.isEmpty ? nil : recips.bcc
                msg.snippet = strVal(row["snippet"])
                msg.content_preview = msg.snippet
            } else {
                // `--headers-only` documents "skip … preview", but decodeSummary has already
                // populated both preview keys, and re-assigning `snippet` to itself above never
                // cleared them. Clear BOTH (the dual keys are one value).
                msg.snippet = nil
                msg.content_preview = nil
            }
            // Full body is opt-in: the AppleScript scan is slow (Mail has no body index,
            // mirroring MCP A's own slow-path caveat). The indexed `snippet` covers the fast case.
            if content && !noContent && !headersOnly, let internetID = msg.internet_message_id {
                msg.content = try MailScript().body(internetMessageID: internetID, accountName: msg.account)
            }
            let result = MailMessageResult(message: msg)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { printMessageText(msg, full: true) }
        }
    }
}

// MARK: selected (Mail UI selection)

struct SelectedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selected", abstract: "Get the message(s) currently selected in Mail.app.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Do not include body content.") var noContent = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try? MailContext()   // used to enrich from the index when possible
            let selections: [MailScript.ScriptSelection]
            do {
                selections = try MailScript().selectedMessages(includeContent: !noContent)
            } catch {
                throw AppleError.upstream("could not read Mail selection — is Mail.app running with automation permitted? (\(error))")
            }
            var messages: [MailMessage] = []
            for sel in selections {
                if let internetID = sel.internetMessageID, let ctx,
                   let row = try? ctx.index.message(internetMessageID: internetID) {
                    var m = ctx.decodeSummary(row)
                    m.applescript_id = sel.applescriptID
                    m.content = sel.content
                    m.snippet = strVal(row["snippet"])
                    messages.append(m)
                } else {
                    messages.append(MailMessage.fromSelection(sel))
                }
            }
            let result = MailMessagesResult(
                account: nil, mailbox: nil, messages: messages, count: messages.count,
                offset: nil, limit: nil, has_more: nil, next_offset: nil, sort: nil)
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: thread

struct ThreadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thread", abstract: "All messages in a conversation — by message id (Apple conversation) or by subject keyword.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "A message id in the thread (ROWID / RFC Message-ID / message:// link).") var id: String?
    @Option(name: .long, help: "Subject keyword identifying the thread.") var subject: String?
    @Option(name: .long, help: "Account name or UUID (for subject-based lookup).") var account: String?
    @Option(name: .long, help: "Mailbox for subject-based lookup (default All).") var mailbox: String = "All"
    @Option(name: .long, help: "Max messages (default 50; 0 = the complete thread).") var limit: Int = 50
    // NO --include-system-folders here, deliberately. MCP B applies SKIP_FOLDERS only in
    // `search_emails` and analytics (tools/search.py `_search_mail_records`); its
    // `get_email_thread` has NO skip script and iterates every mailbox. Excluding here was both a
    // parity DROP and wrong on its own terms: Sent/Sent Messages/Drafts hold the operator's OWN
    // half of the conversation, so a "thread" missing your replies is not the thread. It also made
    // the two addressing modes disagree — the by-id conversation branch never applied the flag, so
    // the same thread returned 10 by id and 9 by subject.
    @Flag(name: .long, help: "Thread by RFC References/In-Reply-To headers (MCP A get_thread) instead of Apple's conversation grouping.") var references = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var messages: [MailMessage] = []
            var matchedBy = ""
            // `--limit 0` == the complete thread (oracle A's get_thread is uncapped), matching
            // the `0 = all` convention search/list already use. Before, 0 reached the query as a
            // literal 0, returned nothing, and fell through to the singleton fallback — so asking
            // for the WHOLE thread returned exactly one message.
            let effectiveLimit = (self.limit == 0) ? Int.max : self.limit
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                    throw AppleError.notFound("no message for id '\(id)'.")
                }
                let rowid = intVal(row["rowid"]) ?? 0
                if references {
                    // MCP A header-threading: messages sharing this one's References/In-Reply-To
                    // chain (via the Envelope Index message_references table), chronologically.
                    matchedBy = "references"
                    messages = try ctx.index.referencesThread(rowid: rowid, limit: effectiveLimit).map { ctx.decodeSummary($0) }
                } else {
                    matchedBy = "message_id"
                    let convID = intVal(row["conversation_id"]) ?? 0
                    if convID != 0 {
                        // Query the whole conversation directly (Apple's own thread id), chronologically.
                        var f = EnvelopeIndex.MessageFilters()
                        f.mailboxName = "All"; f.conversationID = convID; f.sortAscending = true; f.limit = effectiveLimit
                        messages = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
                    }
                }
                if messages.isEmpty { messages = [ctx.decodeSummary(row)] } // singleton thread
            } else if let subject {
                matchedBy = "subject_keyword"
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                // Oracle B strips Re:/RE:/Fwd:/FW:/Fw: from the keyword before matching, so
                // `--subject "Re: Budget"` finds the whole thread rather than only the replies.
                let cleaned = MailFormat.stripThreadPrefixes(subject)
                // A keyword that is ONLY thread prefixes strips to "" — and an empty
                // `subjectContains` makes EnvelopeIndex append no WHERE clause at all, turning a
                // thread lookup into a full-store dump reported as ok:true.
                // "Re: " is exactly what gets copy-pasted off a subject line, so refuse it.
                guard !cleaned.isEmpty else {
                    throw AppleError.validation("--subject '\(subject)' is only reply/forward prefixes; provide an actual subject keyword.")
                }
                f.mailboxName = mailbox; f.subjectContains = cleaned
                // EXPLICIT, same reasoning as resolveTargets: a thread must span EVERY mailbox.
                // Oracle B applies SKIP_FOLDERS in `_search_mail_records` (tools/search.py:236,
                // All-only) and analytics, but `get_email_thread` (tools/search.py:595) builds
                // its own script with no skip. Excluding here dropped the account's own Sent
                // replies out of their own conversation (measured 34 → 24 on this store). The
                // struct already defaults true, but leaving that implicit is what let the
                // regression land silently once — a future default flip must not re-break it.
                f.includeSystemFolders = true
                f.sortAscending = true; f.limit = effectiveLimit
                let rows = try ctx.index.queryMessages(f)
                messages = rows.map { ctx.decodeSummary($0) }
            } else {
                throw AppleError.validation("provide a message id argument or --subject keyword.")
            }
            let result = MailThreadResult(messages: messages, count: messages.count, matched_by: matchedBy)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { for m in messages { printMessageText(m, full: false) } }
        }
    }
}

// MARK: attachments

struct AttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments",
        abstract: "List and save message attachments.",
        subcommands: [AttachmentsList.self, AttachmentsSave.self],
        defaultSubcommand: AttachmentsList.self)
}

struct AttachmentsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List attachments by message id or subject keyword.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (ROWID / RFC Message-ID / message:// link).") var id: String?
    @Option(name: .long, help: "Subject keyword to find messages.") var subject: String?
    @Option(name: .long, help: "Account name or UUID (for subject search).") var account: String?
    @Option(name: .long, help: "Max messages to inspect for --subject (default 10).") var maxResults: Int = 10

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var atts: [MailAttachment] = []
            var matchedBy = ""
            if let id {
                matchedBy = "message_id"
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                    throw AppleError.notFound("no message for id '\(id)'.")
                }
                let rowid = intVal(row["rowid"]) ?? 0
                atts = try ctx.index.attachments(messageRowid: rowid).map {
                    MailAttachment(name: $0.name, attachment_id: $0.attachmentID, size: nil, message_id: String(rowid))
                }
            } else if let subject {
                matchedBy = "subject_keyword"
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = maxResults; f.hasAttachment = true
                let rows = try ctx.index.queryMessages(f)
                for row in rows {
                    let rowid = intVal(row["rowid"]) ?? 0
                    atts += try ctx.index.attachments(messageRowid: rowid).map {
                        MailAttachment(name: $0.name, attachment_id: $0.attachmentID, size: nil, message_id: String(rowid))
                    }
                }
            } else {
                throw AppleError.validation("provide a message id argument or --subject keyword.")
            }
            let result = MailAttachmentsResult(attachments: atts, count: atts.count, matched_by: matchedBy)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { for a in atts { print("\(a.name)\(a.attachment_id.map { "  [\($0)]" } ?? "")  (msg \(a.message_id))") } }
        }
    }
}
