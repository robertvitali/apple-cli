import sys, pathlib

# Rewrites the TRACKED source in place. Copy the file aside first and restore it after the
# measurement (cp both ways) — there is no automatic restore, and a survived mutant left in the
# tree would be committed silently.
F = pathlib.Path("Sources/NotesKit/NotesText.swift")

MUTANTS = {
    # name: (find, replace)
    "drop-markdown": (
        '''            || content.range(of: markdownCheckboxPattern, options: .regularExpression) != nil
''', ""),
    "drop-class": (
        '''            || content.range(of: checklistClassPattern, options: .regularExpression) != nil
''', ""),
    "drop-html": (
        '''        guard htmlCheckboxAttempt(content)''',
        '''        guard false'''),
    # NOTE: anchor on the executable pattern-constant lines, not bare regex fragments. The doc
    # comment above the detector quotes the oracle's JS regexes verbatim, so a bare-pattern find
    # matches the COMMENT first and mutates nothing executable — two mutants "survived" that way
    # before this was caught, which would have certified test coverage that does not exist.
    "class-loses-wordboundary": (
        r'''["'][^"']*(?<![\#(jsWord)])(?:''',
        r'''["'][^"']*(?:'''),
    "markdown-loses-multiline": (
        r'''#"(?:\A|[\n\r\u2028\u2029])[ \t]*''',
        r'''#"\A[ \t]*'''),
    "markdown-accepts-empty-brackets": (
        r'''+\[[ xX]\]"#''',
        r'''+\[[ xX]?\]"#'''),
    "html-loses-input-boundary": (
        '''pattern: "<[iI][nN][pP][uU][tT](?![\\(jsWord)])")''',
        '''pattern: "<[iI][nN][pP][uU][tT]")'''),
    # The two wiring mutants the reviewers named — compute the warning correctly but never emit
    # it, and feed the detector the title instead of the body. Both must die at the envelope
    # tests, not just at source-text assertions.
    "builder-emits-nil": (
        '''        return (CreatedNote(ok: true, id: id, title: title, folder: folder, account: account,
                            warning: warning),''',
        '''        return (CreatedNote(ok: true, id: id, title: title, folder: folder, account: account,
                            warning: nil),'''),
    "builder-title-swap": (
        '''                               content: String) -> (note: CreatedNote, human: String) {
        let warning = detectChecklistAttempt(content)''',
        '''                               content: String) -> (note: CreatedNote, human: String) {
        let warning = detectChecklistAttempt(title)'''),
}

name = sys.argv[1]
find, repl = MUTANTS[name]
src = F.read_text(encoding="utf-8")
if find not in src:
    print(f"ANCHOR-MISS::{name}")
    sys.exit(3)
F.write_text(src.replace(find, repl, 1), encoding="utf-8")
print(f"APPLIED::{name}")
