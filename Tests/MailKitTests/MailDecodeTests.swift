import Testing
import Foundation
import AppleKit
@testable import MailKit

@Suite("MailDecode + envelope shape")
struct MailDecodeTests {

    /// A synthetic Envelope Index row (mirrors the `baseSelect` column names) — NO real mail.
    static let syntheticRow: [String: String?] = [
        "rowid": "11111",
        "mail_message_id": "111111111111111111",
        "subject": "Your quarterly statement is ready",
        "sender_address": "news@vendor.example",
        "sender_name": "Vendor Newsletter",
        "date_received": "1767323045",   // 2026-01-02T03:04:05Z
        "date_sent": "1767323039",
        "read": "0",
        "flagged": "1",
        "flag_color": "5",               // purple
        "size": "12345",
        "conversation_id": "22222",
        "message_id_header": "<33333333@host.local>",
        "mailbox_rowid": "4",
        "attachment_count": "2",
        "snippet": "A wholly synthetic preview sentence…",
    ]

    @Test func unionFieldsPopulated() {
        let m = MailDecode.message(row: Self.syntheticRow, mailboxPath: "INBOX", accountLabel: "iCloud")
        // Identifier union: MCP A `id` == MCP B `message_id` == ROWID
        #expect(m.id == "11111")
        #expect(m.message_id == "11111")
        #expect(m.rowid == 11111)
        #expect(m.internet_message_id == "33333333@host.local")
        #expect(m.mail_link == "message://%3C33333333@host.local%3E")
        // Read-status union: MCP A `read_status` + MCP B `is_read`
        #expect(m.read_status == false)
        #expect(m.is_read == false)
        // Date union: MCP A `date_received` + MCP B `received_date`, both ISO-8601 UTC
        #expect(m.date_received == "2026-01-02T03:04:05Z")
        #expect(m.received_date == "2026-01-02T03:04:05Z")
        // Flags
        #expect(m.flagged == true)
        #expect(m.flag_color == 5)
        #expect(m.flag_color_name == "purple")
        // Sender + attachments + account/mailbox enrichment
        #expect(m.sender == "Vendor Newsletter <news@vendor.example>")
        #expect(m.has_attachments == true)
        #expect(m.attachment_count == 2)
        #expect(m.account == "iCloud")
        #expect(m.mailbox == "INBOX")
    }

    @Test func unflaggedMessageHasNoColor() {
        var row = Self.syntheticRow
        row["flagged"] = "0"
        let m = MailDecode.message(row: row, mailboxPath: "INBOX", accountLabel: "iCloud")
        #expect(m.flag_color == nil)
        #expect(m.flag_color_name == nil)
    }

    /// Golden shape: the encoded envelope carries schema_version + tool + both union field
    /// names, so a consumer written against either MCP finds its keys.
    @Test func envelopeGoldenShape() throws {
        let m = MailDecode.message(row: Self.syntheticRow, mailboxPath: "INBOX", accountLabel: "iCloud")
        let result = MailMessageResult(message: m)
        let data = try Output.encodeSuccess(tool: "mail", data: result)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["schema_version"] as? Int == 1)
        #expect(obj["tool"] as? String == "mail")
        #expect(obj["ok"] as? Bool == true)
        let msg = ((obj["data"] as! [String: Any])["message"] as! [String: Any])
        for key in ["id", "message_id", "internet_message_id", "mail_link", "read_status",
                    "is_read", "date_received", "received_date", "flag_color_name",
                    "sender", "sender_address", "account", "mailbox", "has_attachments"] {
            #expect(msg[key] != nil, "missing union field \(key)")
        }
    }
}
