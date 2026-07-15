import Testing
import Foundation
@testable import MailKit

@Suite("TemplateStore")
struct TemplateStoreTests {

    private func tempStore() -> TemplateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-tpl-\(UUID().uuidString)")
        return TemplateStore(homeOverride: dir.path)
    }

    @Test func saveGetListDeleteRoundTrip() throws {
        let store = tempStore()
        #expect(try store.list().isEmpty)
        try store.save(name: "welcome", body: "Hi {recipient_name},\nThanks!", subject: "Hello {recipient_name}")
        let got = try store.get("welcome")
        #expect(got.subject == "Hello {recipient_name}")
        #expect(got.body == "Hi {recipient_name},\nThanks!")
        let list = try store.list()
        #expect(list.count == 1)
        #expect(list.first?.name == "welcome")
        #expect(list.first?.subject == "Hello {recipient_name}")
        try store.delete("welcome")
        #expect(try store.list().isEmpty)
    }

    @Test func renderFillsPlaceholdersUserVarsWin() throws {
        let store = tempStore()
        try store.save(name: "greet", body: "Hi {recipient_name}, today is {today}.", subject: "Re: {original_subject}")
        let r = try store.render(
            name: "greet",
            autoVars: ["recipient_name": "Ada", "today": "2026-07-15", "original_subject": "Budget"],
            userVars: ["recipient_name": "Ada Lovelace"])   // override wins
        #expect(r.subject == "Re: Budget")
        #expect(r.body == "Hi Ada Lovelace, today is 2026-07-15.")
    }

    @Test func parseSubjectHeader() {
        let (subj, body) = TemplateStore.parse("Subject: Hi there\n\nBody line 1\nBody line 2")
        #expect(subj == "Hi there")
        #expect(body == "Body line 1\nBody line 2")
        let (noSubj, raw) = TemplateStore.parse("Just a body\nno header")
        #expect(noSubj == nil)
        #expect(raw == "Just a body\nno header")
    }

    @Test func nameValidation() {
        #expect(throws: Error.self) { try TemplateStore.validateName("has spaces") }
        #expect(throws: Error.self) { try TemplateStore.validateName("") }
        #expect(throws: Error.self) { try TemplateStore.validateName(String(repeating: "a", count: 65)) }
        #expect(throws: Never.self) { try TemplateStore.validateName("ok_name-1") }
    }

    @Test func getMissingThrowsNotFound() {
        let store = tempStore()
        #expect(throws: Error.self) { _ = try store.get("nope") }
    }
}
