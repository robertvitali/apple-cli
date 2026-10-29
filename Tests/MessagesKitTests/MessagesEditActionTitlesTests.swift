import AppleKit
import Testing
@testable import MessagesKit

@Suite struct MessagesEditActionTitlesTests {
    @Test func resolvesAndPreservesLocalizedTitles() throws {
        let labels = ["edit.button": "Modifier", "editing.confirm.button": "Envoyer la modification", "editing.reject.button": "Annuler la modification"]
        let titles = try MessagesEditActionTitles.resolve(deadline: .millisecondsFromNow(5000)) { labels[$0] }
        #expect(titles.edit == "Modifier")
        #expect(titles.confirm == "Envoyer la modification")
        #expect(titles.cancel == "Annuler la modification")
    }
    @Test func missingEchoedAndCollidingLabelsAreUnavailable() {
        for lookup: (String) -> String? in [{ _ in nil }, { $0 }, { _ in "same" }, { _ in "bad\nlabel" }] {
            #expect(throws: (any Error).self) {
                try MessagesEditActionTitles.resolve(deadline: .millisecondsFromNow(5000), lookup: lookup)
            }
        }
    }
}
