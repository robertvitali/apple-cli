import Testing
import Foundation
@testable import MailKit

@Suite("EmlBuilder")
struct EmlBuilderTests {
    @Test func plainTextMessage() throws {
        let eml = try EmlBuilder(from: "me@example.com", to: ["a@example.org"], subject: "Hi", textBody: "Hello there").build()
        #expect(eml.contains("From: me@example.com"))
        #expect(eml.contains("To: a@example.org"))
        #expect(eml.contains("Subject: Hi"))
        #expect(eml.contains("MIME-Version: 1.0"))
        #expect(eml.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(eml.contains("Hello there"))
    }

    @Test func htmlMultipartAlternative() throws {
        let eml = try EmlBuilder(to: ["a@example.org"], subject: "Rich", textBody: "plain", htmlBody: "<b>bold</b>").build()
        #expect(eml.contains("multipart/alternative"))
        #expect(eml.contains("text/plain"))
        #expect(eml.contains("text/html"))
        #expect(eml.contains("<b>bold</b>"))
        #expect(eml.contains("plain"))
    }

    @Test func attachmentsMultipartMixedBase64() throws {
        let att = EmlBuilder.Attachment(filename: "note.txt", mimeType: "text/plain", data: Data("hi".utf8))
        let eml = try EmlBuilder(to: ["a@example.org"], subject: "See file", textBody: "body", attachments: [att]).build()
        #expect(eml.contains("multipart/mixed"))
        #expect(eml.contains("Content-Disposition: attachment; filename=\"note.txt\""))
        #expect(eml.contains("Content-Transfer-Encoding: base64"))
        #expect(eml.contains(Data("hi".utf8).base64EncodedString()))
    }

    @Test func nonASCIISubjectEncoded() throws {
        #expect(try EmlBuilder.encodeHeader("Plain") == "Plain")
        #expect(try EmlBuilder.encodeHeader("Café ☕").hasPrefix("=?UTF-8?B?"))
    }

    @Test func rejectsCRLFHeaderInjection() {
        // Email header injection (CWE-93): a subject/recipient with \r\n must throw, not smuggle
        // a Bcc/From header into the generated .eml.
        #expect(throws: Error.self) {
            _ = try EmlBuilder(to: ["a@example.org"], subject: "Hi\r\nBcc: attacker@evil.com", textBody: "x").build()
        }
        #expect(throws: Error.self) {
            _ = try EmlBuilder(to: ["victim@example.com\r\nBcc: attacker@evil.com"], subject: "Hi", textBody: "x").build()
        }
        #expect(throws: Error.self) {
            let att = EmlBuilder.Attachment(filename: "a\r\nX-Evil: 1.txt", mimeType: "text/plain", data: Data())
            _ = try EmlBuilder(to: ["a@example.org"], subject: "s", textBody: "x", attachments: [att]).build()
        }
    }

    @Test func rfc2822DateShape() {
        // 2026-01-02T03:04:05Z (invented anchor)
        let s = EmlBuilder.rfc2822Date(Date(timeIntervalSince1970: 1767323045))
        #expect(s.contains("02 Jan 2026"))
        #expect(s.hasSuffix("+0000"))
    }

    @Test func htmlToTextFallback() {
        #expect(EmlBuilder.stripHTML("<p>Hi</p><br>there").contains("Hi"))
        #expect(!EmlBuilder.stripHTML("<b>x</b>").contains("<"))
    }

    @Test func emitsXUnsentHeaderSoMailOpensAsOutgoing() throws {
        // X-Unsent:1 is what makes `open`-ing the .eml yield an editable OUTGOING message the
        // send path can deliver, rather than a read-only received-message viewer. Present on
        // every generated .eml (plain, html, and attachment forms).
        let plain = try EmlBuilder(to: ["a@example.org"], subject: "s", textBody: "b").build()
        #expect(plain.contains("X-Unsent: 1"))
        let html = try EmlBuilder(to: ["a@example.org"], subject: "s", textBody: "b", htmlBody: "<b>x</b>").build()
        #expect(html.contains("X-Unsent: 1"))
    }

    @Test func escapeHTMLNeutralizesMarkup() {
        // A quoted original embedded into an HTML reply body must not inject markup.
        #expect(EmlBuilder.escapeHTML("<script>alert('x')</script>")
            == "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;")
        #expect(EmlBuilder.escapeHTML("a & b \"c\"") == "a &amp; b &quot;c&quot;")
        #expect(EmlBuilder.escapeHTML("plain text") == "plain text")
    }

    @Test func bccNeverWrittenAsHeader() throws {
        // DEFAULT (emitBcc: false): a Bcc: header would leak the blind-copy list to every recipient
        // on a wire-sent .eml — it must not appear.
        let eml = try EmlBuilder(to: ["a@example.org"], bcc: ["secret@example.net"], subject: "s", textBody: "b").build()
        #expect(!eml.contains("Bcc:"))
        #expect(!eml.contains("secret@example.net"))
    }

    @Test func bccEmittedOnlyWhenEmitBccSet() throws {
        // emitBcc:true — used ONLY for a compose-window .eml (Mail moves Bcc to the bcc field and
        // strips the header on send) — DOES emit the Bcc: header so the opened window carries bcc.
        let opened = try EmlBuilder(to: ["a@example.org"], bcc: ["secret@example.net"], subject: "s", textBody: "b", emitBcc: true).build()
        #expect(opened.contains("Bcc: secret@example.net"))
        // CRLF injection through bcc is still rejected even when emitting.
        #expect(throws: Error.self) {
            _ = try EmlBuilder(to: ["a@example.org"], bcc: ["x@example.net\r\nX-Evil: 1"], subject: "s", textBody: "b", emitBcc: true).build()
        }
    }

    @Test func mimeTypeInference() {
        #expect(EmlBuilder.mimeType(forFilename: "report.pdf") == "application/pdf")
        #expect(EmlBuilder.mimeType(forFilename: "photo.PNG") == "image/png")
        #expect(EmlBuilder.mimeType(forFilename: "data.bin") == "application/octet-stream")
    }

    @Test func base64Wraps76Cols() throws {
        // Base64 CONTENT lines must wrap at ≤76 cols (headers/boundaries may be longer).
        let att = EmlBuilder.Attachment(filename: "big.bin", mimeType: "application/octet-stream",
                                        data: Data(repeating: 0x41, count: 200))
        let eml = try EmlBuilder(to: ["a@example.org"], subject: "s", textBody: "b", attachments: [att]).build()
        let b64Lines = eml.components(separatedBy: "\r\n").filter { line in
            line.count > 4 && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        }
        #expect(!b64Lines.isEmpty)
        for line in b64Lines { #expect(line.count <= 76) }
    }
}
