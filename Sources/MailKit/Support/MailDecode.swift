import Foundation

/// Turns an `EnvelopeIndex` result row into the union `MailMessage` model. Kept separate +
/// pure(ish) so the row→model mapping is unit-testable with synthetic rows (golden snapshots
/// never touch real mail). Mailbox-path and account-name enrichment are injected so the
/// decode has no direct dependency on the DB/AppleScript layers.
public enum MailDecode {

    /// Decode a summary row (search/list/thread). `mailboxPath` and `accountName` are looked
    /// up by the caller from the mailbox ROWID; when unavailable they degrade to the UUID.
    public static func message(
        row: [String: String?],
        mailboxPath: String,
        accountLabel: String
    ) -> MailMessage {
        let rowid = intVal(row["rowid"]) ?? 0
        let senderAddr = strVal(row["sender_address"])
        let senderName = strVal(row["sender_name"])
        let flagged = (intVal(row["flagged"]) ?? 0) != 0
        let read = (intVal(row["read"]) ?? 0) != 0
        let flagColor = intVal(row["flag_color"])
        let internetID = MailFormat.stripAngleBrackets(strVal(row["message_id_header"]))
        let dateRecv = MailFormat.iso(fromUnix: intVal(row["date_received"]))
        let attachmentCount = intVal(row["attachment_count"]) ?? 0

        return MailMessage(
            id: String(rowid),
            message_id: String(rowid),
            rowid: rowid,
            internet_message_id: internetID,
            mail_link: MailFormat.mailLink(internetMessageID: internetID),
            applescript_id: nil,
            subject: strVal(row["subject"]) ?? "",
            sender: MailFormat.person(name: senderName, address: senderAddr),
            sender_name: senderName,
            sender_address: senderAddr,
            mailbox: mailboxPath,
            account: accountLabel,
            read_status: read,
            is_read: read,
            flagged: flagged,
            flag_color: flagged ? flagColor : nil,
            flag_color_name: MailFlagColor.readName(flagged: flagged, flagColor: flagColor),
            date_received: dateRecv,
            received_date: dateRecv,
            date_sent: MailFormat.iso(fromUnix: intVal(row["date_sent"])),
            has_attachments: attachmentCount > 0,
            attachment_count: attachmentCount,
            size: intVal(row["size"]),
            conversation_id: intVal(row["conversation_id"]),
            snippet: strVal(row["snippet"]),   // Envelope Index preview — fetched by baseSelect, surfaced here
            content_preview: strVal(row["snippet"]),   // MCP B wire name for the same value
            content: nil,
            to: nil, cc: nil, bcc: nil)
    }
}
