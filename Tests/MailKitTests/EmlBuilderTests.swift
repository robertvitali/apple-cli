import Testing
import Foundation
@testable import MailKit

@Suite("EmlBuilder")
struct EmlBuilderTests {
    @Test func plainTextMessage() throws {
        let eml = try EmlBuilder(from: "me@x.io", to: ["a@y.io"], subject: "Hi", textBody: "Hello there").build()
        #expect(eml.contains("From: me@x.io"))
        #expect(eml.contains("To: a@y.io"))
        #expect(eml.contains("Subject: Hi"))
        #expect(eml.contains("MIME-Version: 1.0"))
        #expect(eml.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(eml.contains("Hello there"))
    }

    @Test func htmlMultipartAlternative() throws {
        let eml = try EmlBuilder(to: ["a@y.io"], subject: "Rich", textBody: "plain", htmlBody: "<b>bold</b>").build()
        #expect(eml.contains("multipart/alternative"))
        #expect(eml.contains("text/plain"))
        #expect(eml.contains("text/html"))
        #expect(eml.contains("<b>bold</b>"))
        #expect(eml.contains("plain"))
    }

    @Test func attachmentsMultipartMixedBase64() throws {
        let att = EmlBuilder.Attachment(filename: "note.txt", mimeType: "text/plain", data: Data("hi".utf8))
        let eml = try EmlBuilder(to: ["a@y.io"], subject: "See file", textBody: "body", attachments: [att]).build()
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
            _ = try EmlBuilder(to: ["a@y.io"], subject: "Hi\r\nBcc: attacker@evil.com", textBody: "x").build()
        }
        #expect(throws: Error.self) {
            _ = try EmlBuilder(to: ["victim@x.io\r\nBcc: attacker@evil.com"], subject: "Hi", textBody: "x").build()
        }
        #expect(throws: Error.self) {
            let att = EmlBuilder.Attachment(filename: "a\r\nX-Evil: 1.txt", mimeType: "text/plain", data: Data())
            _ = try EmlBuilder(to: ["a@y.io"], subject: "s", textBody: "x", attachments: [att]).build()
        }
    }

    @Test func rfc2822DateShape() {
        // 2026-01-02T03:04:05Z
        let s = EmlBuilder.rfc2822Date(Date(timeIntervalSince1970: 1767323045))
        #expect(s.contains("02 Jan 2026"))
        #expect(s.hasSuffix("+0000"))
    }

    @Test func htmlToTextFallback() {
        #expect(EmlBuilder.stripHTML("<p>Hi</p><br>there").contains("Hi"))
        #expect(!EmlBuilder.stripHTML("<b>x</b>").contains("<"))
    }

    @Test func bccNeverWrittenAsHeader() throws {
        // A Bcc: header would leak the blind-copy list to every recipient — it must not appear.
        let eml = try EmlBuilder(to: ["a@y.io"], bcc: ["secret@z.io"], subject: "s", textBody: "b").build()
        #expect(!eml.contains("Bcc:"))
        #expect(!eml.contains("secret@z.io"))
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
        let eml = try EmlBuilder(to: ["a@y.io"], subject: "s", textBody: "b", attachments: [att]).build()
        let b64Lines = eml.components(separatedBy: "\r\n").filter { line in
            line.count > 4 && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        }
        #expect(!b64Lines.isEmpty)
        for line in b64Lines { #expect(line.count <= 76) }
    }
}
