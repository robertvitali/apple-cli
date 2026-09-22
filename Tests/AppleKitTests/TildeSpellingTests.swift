import Testing
import Foundation
@testable import AppleKit

@Suite("TildeSpelling.ownHome")
struct TildeSpellingTests {
    @Test("the account component is compared whole and caselessly, never sliced by a lowercased length")
    func comparesTheWholeComponentCaselessly() {
        // U+0130 lowercases to TWO scalars; a length-based slice would swallow the slash.
        #expect(TildeSpelling.ownHome("~\u{0130}/x", account: "\u{0130}") == "~/x")
        #expect(TildeSpelling.ownHome("~\u{0130}", account: "\u{0130}") == "~")
        #expect(TildeSpelling.ownHome("~\u{0130}x/x", account: "\u{0130}") == nil)
        #expect(TildeSpelling.ownHome("~ALICE/x", account: "alice") == "~/x")
        #expect(TildeSpelling.ownHome("~alice/x", account: "Alice") == "~/x")
        #expect(TildeSpelling.ownHome("~alicex/x", account: "alice") == nil)
        #expect(TildeSpelling.ownHome("~ali/x", account: "alice") == nil)
    }

    @Test("bare, own-home, non-tilde and empty-account inputs")
    func passThroughAndFailClosed() {
        #expect(TildeSpelling.ownHome("~", account: "alice") == "~")
        #expect(TildeSpelling.ownHome("~/x", account: "alice") == "~/x")
        #expect(TildeSpelling.ownHome("/abs/x", account: "alice") == "/abs/x")
        #expect(TildeSpelling.ownHome("rel/x", account: "alice") == "rel/x")
        #expect(TildeSpelling.ownHome("~alice/x", account: "") == nil)
        #expect(TildeSpelling.ownHome("~\u{0301}/x", account: "alice") == nil)
    }
}
