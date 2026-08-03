import Testing
import Foundation
@testable import NotesKit

/// Keeps `ListMarkdownParityTests`'s inline rows and the generator's `goldens.json` in agreement.
///
/// `ListMarkdownParityTests` says its values came from running the oracle's own turndown build.
/// That claim decays the moment someone edits a row by hand to make a failure go away — the file
/// would still SAY the values are oracle-generated while asserting something the oracle never
/// produced, which is worse than having no parity test, because it looks like evidence.
///
/// So the generator's output is checked in at
/// `Tests/NotesKitTests/fixtures/notes-markdown-oracle/goldens.json` and compared here. Editing a
/// Swift row without regenerating fails; regenerating without updating the Swift rows fails. The
/// inline rows stay inline (readable in the file that asserts them, and `swift test` never needs
/// node), but they can no longer silently drift away from the tool that produced them.
///
/// This is what backs the "cannot drift" wording — a comment claiming two things stay in sync is
/// not a mechanism, it is a hope.
@Suite("golden/​generator agreement")
struct GoldenSyncTests {
    struct Golden: Codable, Equatable { let name: String; let html: String; let markdown: String }

    static var goldensURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/notes-markdown-oracle/goldens.json")
    }

    @Test("every checked-in golden appears in the Swift rows with the same oracle value")
    func goldensMatchSwiftRows() throws {
        let data = try Data(contentsOf: Self.goldensURL)
        let goldens = try JSONDecoder().decode([Golden].self, from: data)

        // Both lists carry oracle values: `exact` asserts the port equals it, `divergent` records
        // it beside what the port actually does. Together they must cover the corpus exactly.
        var swiftRows: [String: Golden] = [:]
        for r in ListMarkdownParityTests.exact {
            swiftRows[r.name] = Golden(name: r.name, html: r.html, markdown: r.markdown)
        }
        for r in ListMarkdownParityTests.divergent {
            swiftRows[r.name] = Golden(name: r.name, html: r.html, markdown: r.oracle)
        }

        #expect(Set(goldens.map(\.name)) == Set(swiftRows.keys),
                "corpus/Swift row names differ — regenerate goldens.json or update the Swift rows")

        for g in goldens {
            guard let row = swiftRows[g.name] else { continue }
            #expect(row.html == g.html, "\(g.name): html differs from the generator's input")
            #expect(row.markdown == g.markdown,
                    "\(g.name): expected value differs from the ORACLE's output — a row was edited by hand, or goldens.json is stale")
        }
    }
}
