import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite("Conversation creation read-only preview")
struct MessagesConversationPreviewTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }
    private func plan(_ inputs: [String] = ["+12125550100"]) throws -> MessagesConversationPlan.Plan {
        let result = try MessagesConversationPlan.build(inputs: inputs, message: "apple-cli-test initial",
            service: "imessage", gate: .init(willExecute: false, sandboxActive: false,
                sandboxPrefix: "apple-cli-test", allowedRecipients: []),
            deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready(let plan) = result else { throw MessagesConversationStore.Failure.invalidRequest }
        return plan
    }
    private func read(_ fx: ChatFixture, _ inputs: [String] = ["+12125550100"]) throws -> MessagesConversationPreview.Payload {
        try MessagesConversationPreview.read(databasePath: fx.path, plan: plan(inputs),
                                              deadline: .millisecondsFromNow(5000))
    }

    @Test func uniqueDMIncludesRealIdentityAndInitialSendEffect() throws {
        let fx = try fixture()
        let before = try Data(contentsOf: URL(fileURLWithPath: fx.path))
        let preview = try read(fx)
        #expect(preview.advisory)
        #expect(preview.initial_send_required)
        #expect(preview.initial_message == "apple-cli-test initial")
        #expect(preview.service == "iMessage")
        #expect(preview.recipients == ["+12125550100"])
        #expect(preview.existing_dm.status == "unique")
        #expect(preview.existing_dm.chat_rowid == 3)
        #expect(preview.existing_dm.chat_guid == "iMessage;-;+12125550100")
        #expect(try Data(contentsOf: URL(fileURLWithPath: fx.path)) == before)
    }

    @Test func absentDMCannotInventNewIdentity() throws {
        let fx = try fixture(), preview = try read(fx, ["+12125550199"])
        #expect(preview.existing_dm.status == "absent")
        #expect(preview.existing_dm.chat_guid == nil)
        #expect(preview.existing_dm.chat_rowid == nil)
    }

    @Test func duplicateDMNeverChoosesNewest() throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(70,'synthetic-another',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(70,1);
            """)
        let preview = try read(fx)
        #expect(preview.existing_dm.status == "ambiguous")
        #expect(preview.existing_dm.chat_guid == nil)
        #expect(preview.existing_dm.chat_rowid == nil)
    }

    @Test func groupDoesNotPromiseExistingGroupReuse() throws {
        let fx = try fixture(), preview = try read(fx, ["+12125550101", "+12125550102"])
        #expect(preview.existing_dm.status == "not_applicable")
        #expect(preview.existing_dm.chat_guid == nil)
        #expect(preview.existing_dm.chat_rowid == nil)
    }

    @Test func serializationHasNoExecutionBaselineOrContactProvenance() throws {
        let fx = try fixture()
        let bytes = try JSONEncoder().encode(read(fx))
        let value = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(value.keys) == ["advisory", "initial_send_required", "initial_message", "service", "recipients", "existing_dm"])
    }

    @Test func databaseFailureIsNotAbsentPreview() throws {
        let prepared = try plan()
        #expect(throws: (any Error).self) {
            try MessagesConversationPreview.read(databasePath: "/synthetic-missing", plan: prepared,
                                                  deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func freshPreviewDoesNotCachePreviousBaseline() throws {
        let fx = try fixture()
        #expect(try read(fx, ["+12125550199"]).existing_dm.status == "absent")
        try fx.exec("""
            INSERT INTO handle(ROWID,id) VALUES(99,'+12125550199');
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(70,'synthetic-arrived',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(70,99);
            """)
        #expect(try read(fx, ["+12125550199"]).existing_dm.chat_rowid == 70)
    }
}
