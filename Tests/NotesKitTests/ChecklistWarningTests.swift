import Testing
import Foundation
import AppleKit
@testable import NotesKit

/// `detectChecklistAttempt` — the checklist content warning (NOTES-M8).
///
/// Apple Notes checklists cannot be created through AppleScript: `<input type="checkbox">` is
/// stripped, checklist CSS classes are dropped, and markdown `- [ ]` arrives as literal text. So an
/// agent that writes a checklist gets `ok: true` and a note that silently is not one. The oracle
/// warns on create and both update paths; we did not.
///
/// The rows below are hand-picked boundary cases — 23 ASCII rows plus the ECMAScript-vs-ICU
/// divergence probes — and every verdict was machine-produced by executing the oracle's own three
/// regexes in node (they are also in `gen-corpus.mjs`'s named list, so the checked-in corpus
/// re-derives them). That is agreement on hand-picked inputs, not proof over the input space; the
/// generated corpus in `corpusAgreement` below widens the net. The edge rows are the point — they
/// are the ones a hand-written port gets wrong: `- []` and `-[ ]` and `- [y]` do NOT warn,
/// `class="nottodo"` does NOT, but `class="my-checklist-thing"` DOES (the hyphen is a word
/// boundary), `class="CHECKLIST"` DOES (case-insensitive), and the non-ASCII rows split exactly
/// where JS (no `u` flag) and ICU semantics part ways — see `NotesText.detectChecklistAttempt`'s
/// doc comment for the four divergences.
@Suite("checklist content warning")
struct ChecklistWarningTests {

    /// (input, warns) — oracle-verified.
    static let cases: [(String, Bool)] = [
        ("", false),
        ("plain text", false),

        // markdownCheckbox: /^[ \t]*[-*]\s+\[[ xX]\]/m
        ("- [ ] milk", true),
        ("- [x] milk", true),
        ("- [X] milk", true),
        ("* [ ] milk", true),
        ("  - [ ] indented", true),
        ("\t- [ ] tabbed", true),
        ("intro\n- [ ] second line", true),   // MULTILINE — not only at the very start
        ("- [] empty brackets", false),       // `[ xX]` needs one of space/x/X
        ("- [y] wrong char", false),
        ("-[ ] no space", false),             // `\s+` after the bullet is required
        ("a - [ ] mid-line only", false),     // `^` anchors to a line start
        ("<ul><li>[ ] not a dash</li></ul>", false),

        // htmlCheckbox: /<input\b[^>]*\btype\s*=\s*["']checkbox["']/i
        ("<input type=\"checkbox\">", true),
        ("<INPUT TYPE='CHECKBOX'>", true),
        ("<input class=x type = \"checkbox\">", true),   // whitespace around `=` allowed
        ("<input type=\"text\">", false),

        // checklistClass: /class\s*=\s*["'][^"']*\b(?:checklist|todo)\b/i
        ("<div class=\"checklist\">x</div>", true),
        ("<div class='todo-item'>x</div>", true),
        ("<div class=\"my-checklist-thing\">x</div>", true),
        ("<div class=\"CHECKLIST\">x</div>", true),
        ("<div class=\"nottodo\">x</div>", false),       // `\b` — not a suffix match

        // ECMAScript-vs-ICU divergence probes — the rows a naive inline-flag ICU transcription
        // gets WRONG (review measured 10/14 disagreeing). Verdicts machine-produced by running
        // the oracle's own regexes in node; do not edit by reasoning.
        ("x\u{0B}- [ ] milk", false),        // VT: ICU (?m)^ newline, JS not
        ("x\u{0C}- [ ] milk", false),        // FF: same
        ("x\u{85}- [ ] milk", false),        // NEL: same
        ("x\u{2028}- [ ] milk", true),       // LS: line terminator in both
        ("x\u{2029}- [ ] milk", true),       // PS: same
        ("x\r- [ ] milk", true),             // CR: same
        ("-\u{FEFF}[ ] milk", true),         // BOM: JS \s includes it, ICU does not
        ("-\u{85}[ ] milk", false),          // NEL: JS \s excludes it, ICU includes it
        ("-\u{A0}[ ] milk", true),           // NBSP: JS \s
        ("-\u{3000}[ ] milk", true),         // IDEOGRAPHIC SPACE: JS \s
        ("<input\u{E9} type=\"checkbox\">", true),    // é: JS ASCII \b sees a boundary after input
        ("<input\u{212A} type=\"checkbox\">", true),  // KELVIN after input: same
        ("<input\u{300} type=\"checkbox\">", true),   // combining grave after input: same
        ("<input type=\"chec\u{212A}box\">", false),  // KELVIN inside checkbox: ICU (?i) folds, JS not
        ("<div class=\"todo\u{E9}\">", true),         // é after todo: JS \b boundary
        ("<div class=\"todo\u{301}\">", true),        // combining acute after todo: same
        ("<div class=\"tod\u{F3}\">", false),         // ó replacing o: no engine matches
        ("<div class=\"\u{2713}todo\">", true),       // check mark before todo
        ("<div class=\"todo\u{1F44D}\">", true),      // astral emoji after todo
    ]

    @Test("detection matches the oracle on every hand-picked row")
    func matchesOracle() {
        for (input, shouldWarn) in Self.cases {
            let got = NotesText.detectChecklistAttempt(input)
            #expect((got != nil) == shouldWarn,
                    "\(input.debugDescription): expected warn=\(shouldWarn), got \(got == nil ? "nil" : "warning")")
        }
    }

    /// Reach control: the corpus must actually exercise all three rules and both outcomes, or a
    /// detector that hard-coded one branch could still pass.
    @Test("corpus reach control")
    func reachControl() {
        #expect(Self.cases.filter { $0.1 }.count >= 12, "not enough positive rows")
        #expect(Self.cases.filter { !$0.1 }.count >= 8, "not enough negative rows")
        // one row per rule, each of which must warn ONLY via its own rule
        #expect(NotesText.detectChecklistAttempt("- [ ] a") != nil)          // markdown
        #expect(NotesText.detectChecklistAttempt("<input type=\"checkbox\">") != nil)  // html
        #expect(NotesText.detectChecklistAttempt("<b class=\"todo\">") != nil)         // class
    }

    // MARK: - Generated corpus (490 rows, oracle-executed)

    struct CorpusRow: Codable { let input: String; let warns: Bool }

    static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/checklist-warning-oracle/corpus.json")
    }

    /// Every row of the generated corpus was executed through the oracle's own regexes by
    /// `gen-corpus.mjs` (deterministic, seed 20260803); the port must agree with all of them.
    /// The count pins catch a truncated or regenerated-differently fixture masquerading as a pass;
    /// 366 of the rows carry non-ASCII or control characters, which is where JS-vs-ICU semantics
    /// actually diverge.
    @Test("detection matches the oracle on all 536 generated corpus rows")
    func corpusAgreement() throws {
        let rows = try JSONDecoder().decode([CorpusRow].self,
                                            from: Data(contentsOf: Self.corpusURL))
        #expect(rows.count == 536, "corpus should have 536 rows, found \(rows.count)")
        #expect(rows.filter(\.warns).count == 81, "corpus should have 81 positive rows")
        for row in rows {
            let got = NotesText.detectChecklistAttempt(row.input) != nil
            #expect(got == row.warns,
                    "\(row.input.debugDescription): oracle says warn=\(row.warns), port says \(got)")
        }
    }

    /// Exact equality against an INDEPENDENT copy of the oracle's string (444 B UTF-8), not
    /// substrings: a review pass showed a mutant deleting a whole sentence survived a
    /// five-substring check.
    @Test("the warning text is the oracle's, byte for byte")
    func warningText() throws {
        let w = try #require(NotesText.detectChecklistAttempt("- [ ] milk"))
        let oracle = "\n\n\u{26A0}\u{FE0F} Your content looks like a checklist, but Apple Notes "
            + "checklists cannot be created via AppleScript \u{2014} `<input type=\"checkbox\">` "
            + "is stripped, checklist CSS classes are dropped, and markdown `- [ ]` lines arrive "
            + "as literal text. The note was created with the surrounding structure (list items "
            + "or paragraphs) intact. To convert it to a real Apple Notes checklist, open the "
            + "note, select the items, and press \u{21E7}\u{2318}L (Format \u{2192} Checklist)."
        #expect(w == oracle)
    }

    /// Red-proofed against the regex form this scan replaced: review measured the `[^>]*`
    /// backtracking at 0.46 / 1.82 / 7.48 / 29.6 s for 6 / 12 / 24 / 48 KB of repeated
    /// unterminated `<input` — this 700 KB bomb would run for hours on it. `--content` allows
    /// 5 MiB, and the detector sits on the create/update WRITE path.
    @Test("html detection is linear, not quadratic, in `<input` count")
    func detectionIsNotQuadratic() {
        let bomb = String(repeating: "<input ", count: 100_000)   // 700 KB, no `>` anywhere
        let started = Date()
        #expect(NotesText.detectChecklistAttempt(bomb) == nil)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 5.0, "detectChecklistAttempt took \(elapsed)s — the O(n²) scan is back")
    }

    // MARK: - Envelope level: the warning reaches the emitted JSON and the human line

    /// These execute the response builders and encode through the REAL envelope path
    /// (`Output.encodeSuccess`, exactly what `emitNotesWrite` calls), so the two mutants a
    /// reviewer named die behaviorally rather than by source inspection: compute the warning
    /// correctly but emit `warning: nil` (the `data` object then lacks the key and the positive
    /// tests fail), and feed the detector the TITLE instead of the body (the crossed cases below
    /// fail — a checklist-looking title must not warn, a checklist body must).
    func envelope<T: Encodable>(_ data: T) throws -> [String: Any] {
        let encoded = try Output.encodeSuccess(tool: "notes", data: data)
        let obj = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return try #require(obj["data"] as? [String: Any])
    }

    @Test("create: a checklist body puts the warning in the JSON and the human line")
    func createWarns() throws {
        let r = NotesText.createResponse(id: "x", title: "plain title", folder: nil,
                                         account: nil, content: "- [ ] milk")
        let data = try envelope(r.note)
        let warning = try #require(data["warning"] as? String)
        #expect(warning.contains("cannot be created via AppleScript"))
        #expect(r.human.hasPrefix("Created \"plain title\" [x]."))
        #expect(r.human.hasSuffix(warning))
    }

    @Test("create: a plain body OMITS the warning key — absent, not null")
    func createOmits() throws {
        let r = NotesText.createResponse(id: "x", title: "- [ ] checklist-looking title",
                                         folder: nil, account: nil, content: "plain body")
        let data = try envelope(r.note)
        #expect(!data.keys.contains("warning"),
                "warning must be omitted entirely; `if \"warning\" in data` is the client test")
        #expect(r.human == "Created \"- [ ] checklist-looking title\" [x].")
    }

    @Test("update: the warning is computed from the REPLACEMENT body, on both branches")
    func updateWarns() throws {
        // by-id branch
        let byId = NotesText.updateResponse(id: "n1", title: "t", shared: false,
                                            newContent: "<input type=\"checkbox\">")
        let idData = try envelope(byId.note)
        #expect((idData["warning"] as? String)?.contains("cannot be created via AppleScript") == true)
        #expect(byId.human.hasPrefix("Updated \"t\"."))
        // by-title branch (id nil, matching the oracle)
        let byTitle = NotesText.updateResponse(id: nil, title: "t", shared: true,
                                               newContent: "- [x] done")
        let titleData = try envelope(byTitle.note)
        #expect(!titleData.keys.contains("id"), "by-title branch carries no id")
        #expect(titleData["warning"] is String)
    }

    @Test("update: a checklist-looking TITLE with a plain body does not warn")
    func updateOmits() throws {
        let r = NotesText.updateResponse(id: "n1", title: "- [ ] sneaky title", shared: false,
                                         newContent: "plain body")
        let data = try envelope(r.note)
        #expect(!data.keys.contains("warning"))
        #expect(r.human == "Updated \"- [ ] sneaky title\".")
    }

    // MARK: - Wiring: the commands call the response builders with the right arguments

    /// The envelope tests above prove the BUILDERS are correct; this pins that the commands
    /// actually route through them and feed them the BODY. The one mutant the behavioral tier
    /// cannot reach (the commands run AppleScript against Notes.app) is an argument swap at the
    /// call site — `content: title` — so the body-argument spellings are asserted as source text.
    /// The honest end-to-end check is a sandboxed live create of an `apple-cli-test…` note with a
    /// `- [ ]` body asserting `warning` in the JSON — that belongs in the live tier (needs
    /// Notes.app + TCC), not here.
    @Test("the commands route through the response builders, fed the body, at the right sites")
    func wiringIsCorrect() throws {
        let src = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/NotesKitTests/ChecklistWarningTests.swift",
                                  with: "Sources/NotesKit/NotesWriteCommands.swift"), encoding: .utf8)

        // The commands never call the detector directly — the testable builders are the only path.
        #expect(!src.contains("detectChecklistAttempt"),
                "commands must go through createResponse/updateResponse, not the raw detector")

        // Exactly the oracle's three call sites: create + the two update branches.
        #expect(src.components(separatedBy: "NotesText.createResponse(").count - 1 == 1,
                "expected exactly 1 createResponse site")
        #expect(src.components(separatedBy: "NotesText.updateResponse(").count - 1 == 2,
                "expected exactly 2 updateResponse sites (by-id + by-title)")

        // …fed the BODY, not the title: `create` passes `content`; both `update` branches pass
        // `newContent` (the replacement body), never the note's existing text.
        // (Anchors carry the preceding argument: bare `newContent: newContent)` would also match
        // the two `resolveUpdateResponseTitle` calls.)
        #expect(src.contains("account: account, content: content)"),
                "create must inspect the new body")
        #expect(src.components(separatedBy: "shared: note.shared, newContent: newContent)").count - 1 == 2,
                "both update branches must inspect newContent")

        // …and the built response is what gets emitted, JSON and human both, at all three sites.
        #expect(src.components(separatedBy: "emitNotesExecutedWrite(r.note").count - 1 == 3,
                "each site must emit the built note")
        #expect(src.components(separatedBy: "human: r.human)").count - 1 == 3,
                "each site must emit the built human line")

        // append emits an explicit nil — the oracle does not warn there.
        #expect(src.contains("title: note.title, shared: note.shared, warning: nil)"))
        #expect(src.contains("title: noteTitle, shared: note.shared, warning: nil)"))
    }
}
