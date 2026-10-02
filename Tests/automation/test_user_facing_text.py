"""User-facing text never names the retired servers this CLI replaced.

Checks, on the real tree:
  * every line of the generated manual (docs/manual/**/*.md), which carries every command
    summary, option help and discussion the binary prints;
  * every string in docs/manual-prose.json, the curated prose merged into the manual;
  * every line of README.md, the repository's front page;
  * every Swift string literal under Sources/ outside comments, which carries runtime errors,
    warnings and free-text JSON values such as `note` and `gate_note`. Interpolated expressions
    are dropped and escape sequences (\\n, \\t, \\r, \\0, \\', \\", \\\\, \\u{...}) are decoded.
    In a literal that contains a script marker (`on run argv`, `tell application "`,
    `ObjC.import(`, `Application(`), the script's own comments (AppleScript --, # and (* *);
    JXA // and /* */) are removed before matching, because they are internal like Swift's; the
    script's string literals are still scanned, because `error` and `return` strings reach
    callers.
Every input must be a regular file inside the repository; a symlink anywhere in a scanned tree
(file or directory), or a path resolving outside the repository, is refused rather than followed
or skipped.

None of that text may use the parity vocabulary (MCP, also inside identifiers such as
APPLE_MAIL_MCP_HOME; oracle; superset; parity; port-specs; "CLI-only" or "CLI extra"; "Extra:";
"curated extras"; "(ports ...)"), a parity-worklist id (extra32, gap7), or any name in
RETIRED_NAMES. The one sanctioned use of "oracle" is the `mail export --layout` value, an
accepted input whose name cannot change without breaking callers; EXEMPT_PHRASES removes exactly
its spellings before matching.

RETIRED_NAMES is recorded here, never parsed from docs/port-specs, so the list is reviewable and
cannot grow by accident. It holds only names the CLI does not use itself: the retired servers' short
names and their tool, parameter, environment-variable and helper names that are not CLI commands,
options, JSON keys or wire values; the events server's bare short name has its own pattern that
skips the dotted entitlement suffix (com.apple.security.automation.apple-events). Several retired
Contacts and Notes tool names ARE wire values (a preview's `operation`, such as `delete_contact` or
`create-note`) and are deliberately absent. A self-check fails if a recorded name equals a command
or option the generated manual documents.

Residual, stated rather than implied: this is a recorded-list check, not a proof. A retired name
missing from RETIRED_NAMES, a paraphrase of the parity vocabulary, or text built at runtime from
pieces that are individually clean is not caught, and Swift comments, tests, the CHANGELOG and the
governance documents are out of scope by design (internal text may keep "oracle"). Under Sources
only .swift files are read, so a non-Swift resource added there (.applescript, .js, .json) would not
be scanned until it is added here deliberately. Inside scripts the comment stripper knows only
double-quoted strings, so a comment marker inside a single-quoted or template JXA string hides the
rest of that line (an AppleScript string may span lines and is followed to its closing quote),
nested AppleScript block comments close at the first `*)` (the rest is read as script, so an
unpaired quote left in it re-pairs the strings that follow and a later string's text after `--` or
`#` is dropped), the script languages' own escapes inside a script string (an AppleScript or JXA
\\n) are not decoded, so a word written right after one joins the escape letter, and scripts are
recognised by the markers alone, so a non-script literal that merely contains one has its
comment-like text dropped. Swift regex literals are not recognised: their contents are read as Swift
code, so paired quotes become a string literal, a `//` hides the rest of the line, and only an
unpaired quote or an unclosed `/*` raises.
"""
import json
import pathlib
import re
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANUAL = ROOT / "docs" / "manual"
PROSE = ROOT / "docs" / "manual-prose.json"
README = ROOT / "README.md"
SOURCES = ROOT / "Sources"

VOCABULARY = re.compile(
    r"(?i)(?<![a-z0-9])MCPs?(?![a-z0-9])|(?<![a-z])oracles?(?![a-z])|\bsuperset\b|\bparity\b"
    r"|port-specs|\bCLI-only\b|\bCLI[- ]extras?\b|\bExtra:|\bcurated extras?\b|\(ports\b"
    r"|\bports\s+[a-z]+[_-][a-z]|\b(?:extra|gap)\d+\b"
)
# The `mail export --layout oracle` value, as its help, its error and its literal spell it.
EXEMPT_PHRASES = ("'oracle' (default)", "Use: oracle, flat", "--layout oracle")
EXEMPT_LITERALS = frozenset({"oracle"})

RETIRED_NAMES = (
    # events server (Calendar + Reminders)
    "calendar_calendars", "calendar_events", "reminders_lists", "reminders_tasks",
    "reminders_subtasks",
    # Notes server
    "append-to-note", "get-note-link", "get-note-markdown", "get-note-metadata",
    "get-checklist-state", "get-sync-status", "list-notes", "search-notes", "list-folders",
    "list-accounts", "list-attachments", "get-note-by-id", "get-note-content", "get-note-details",
    "get-note-plaintext", "get-notes-stats", "get-selected-notes", "get-default-location",
    "export-notes-json", "list-shared-notes",
    # Mail servers
    "compose_email", "create_rich_email_draft", "delete_messages", "export_emails",
    "forward_email", "forward_message", "get_awaiting_reply", "get_email_thread",
    "get_inbox_overview", "get_mailbox_unread_counts", "get_needs_response", "get_statistics",
    "get_top_senders", "inbox_dashboard", "list_inbox_emails", "list_rules", "list_templates",
    "manage_drafts", "manage_trash", "mark_as_read", "move_email", "move_messages",
    "reply_to_email", "reply_to_message", "search_emails", "send_email",
    "send_email_with_attachments", "list_accounts", "list_mailboxes", "get_message", "get_thread",
    "search_messages", "get_selected_messages", "flag_message", "update_email_status",
    "get_attachments", "list_email_attachments", "save_attachments", "save_email_attachment",
    "create_rule", "update_rule", "delete_rule", "set_rule_enabled", "get_template",
    "save_template", "delete_template", "render_template", "validate_bulk_operation",
    "validate_send_operation", "confirm_empty", "max_deletes", "max_emails", "max_results",
    "expensive_ops", "include_content", "headers_only", "summary_only", "include_zero",
    "include_counts", "include_read", "output_format", "older_than", "to_mailbox",
    "source_mailbox", "apply_to_all", "reply_body", "reply_to_all", "max_moves", "max_updates",
    "max_recipients", "max_items", "open_in_mail", "save_as_draft", "html_body", "body_html",
    "date_from", "has_attach", "exclude_noreply",
    # Contacts server (read and diagnostic tools; its write tools are preview wire values)
    "check_authorization", "check_test_mode_safety", "export_vcard", "get_contact",
    "get_contacts_in_group", "list_contacts", "list_containers", "list_groups", "read_note",
    "read_photo", "search_contacts", "vcard_text", "include_niche", "container_identifier",
    # Messages server
    "tool_check_addressbook", "tool_check_contacts", "tool_check_db_access",
    "tool_check_imessage_availability", "tool_find_contact", "tool_fuzzy_search_messages",
    "tool_get_chats", "tool_get_recent_messages", "tool_send_message", "check_db_access",
    "find_contact", "fuzzy_search_messages", "get_chats", "get_recent_messages", "max_messages",
    "check_addressbook", "check_contacts", "check_imessage_availability", "send_message",
    # parameter, environment-variable, helper and server names the retired servers used
    "body_text", "max_content_length", "subject_keywords", "text_body", "save_directory",
    "parent_mailbox", "top_n", "require_test_mode_for", "CONTACTS_TEST_MODE",
    "move_to_trash", "escaped_mailbox", "mailbox_param", "skip_folders_condition",
    "mail_connector", "smart_inbox", "contacts_connector", "draft_subject", "only_read",
    "is_flagged", "date_to", "message_ids", "TIER_LIMITS", "check_rate_limit",
    "MailTemplateMissingVariableError", "_check_supported_actions", "DEFAULT_SEARCH_LIMIT",
    "daily-task-organizer", "smart-reminder-creator", "reminder-review-assistant",
    "weekly-planning-workflow",
)
# The events server's bare short name gets its own alternative: a '.' before it is excluded so the
# Automation entitlement com.apple.security.automation.apple-events is not refused.
NAMES = re.compile(
    r"(?<![\w-])(?:" + "|".join(re.escape(n) for n in RETIRED_NAMES) + r")(?![\w-])"
    r"|(?<![\w.-])apple-events(?![\w-])"
)
ESCAPES = {'"': '"', "\\": "\\", "'": "'", "n": "\n", "t": "\t", "r": "\r", "0": "\0"}
RAW_OPEN = re.compile(r'(#*)("""|")')
# Swift's \u{n}: one to eight hex digits naming a Unicode scalar, nothing else.
UNICODE_ESCAPE = re.compile(r"\{([0-9A-Fa-f]{1,8})\}")
SCRIPT_MARKERS = ("on run argv", 'tell application "', "ObjC.import(", "Application(")
JXA_MARKERS = ("ObjC.import(", "Application(")
# Each alternative ends at its terminator or at the end of the input, and a JXA string also at
# the end of its line (a JavaScript string cannot hold a line break; an AppleScript string can),
# so the scan stays linear on unterminated input; group 1 is set only when a block comment closes.
APPLESCRIPT_STRING = r'"(?:\\.|[^"\\])*(?:"|\\?\Z)'
JXA_STRING = r'"(?:\\.|[^"\\\n])*(?:"|\\?$)'
APPLESCRIPT_COMMENT = re.compile(
    APPLESCRIPT_STRING + r"|\(\*.*?(?:(\*\))|\Z)|(?:--|#)[^\n]*", re.S | re.M
)
JXA_COMMENT = re.compile(JXA_STRING + r"|/\*.*?(?:(\*/)|\Z)|//[^\n]*", re.S | re.M)


def strip_script_comments(text):
    """Blank comment text by script kind (AppleScript --, # and (* *); JXA // and /* */) and keep
    code and double-quoted strings. JXA is recognised by its markers, so `i--` is code there. An
    unterminated string or block comment is kept, not blanked, so it cannot hide what follows.
    """

    def keep(match):
        token = match.group(0)
        unclosed = token.startswith(("(*", "/*")) and match.group(1) is None
        return token if token.startswith('"') or unclosed else " "

    rx = JXA_COMMENT if any(marker in text for marker in JXA_MARKERS) else APPLESCRIPT_COMMENT
    return rx.sub(keep, text)


def swift_literals(text):
    """Return (line, content) for every string literal outside comments, interpolations dropped.

    Handles line and (nested) block comments, single-line and multi-line literals, raw
    (#-delimited) literals, line continuations, escape sequences (decoded, so a script inside a
    literal keeps its string delimiters, a script whose lines are separated by \\n is split into
    real lines, and an escape letter never joins the next word) and nested interpolation. Regex
    literals (`/.../`, `#/.../#`) are not recognised: their contents are read as code, so paired
    quotes become a string literal and `//` drops the rest of the line; only an unpaired quote or
    an unclosed `/*` raises. Raises on an unterminated literal or block comment, or a malformed
    `\\u{...}` escape, so a tokenizer gap shows up as a failure rather than as a silently skipped
    file.
    """
    out, n = [], len(text)

    def string(i, line, multi, hashes):
        buf, start = [], line
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        while i < n:
            if text.startswith(close, i):
                out.append((start, "".join(buf)))
                return i + len(close), line
            c = text[i]
            if c == "\n":
                if not multi:
                    raise ValueError(f"unterminated string literal at line {start}")
                line += 1
            if text.startswith(escape, i) and i + len(escape) < n:
                j = i + len(escape)
                if text[j] == "(":
                    i, line = code(j + 1, line, 1)
                    buf.append(" ")
                    continue
                if text[j] == "\n":
                    line += 1
                if text[j] == "u":
                    m = UNICODE_ESCAPE.match(text, j + 1)
                    scalar = int(m.group(1), 16) if m else -1
                    if not 0 <= scalar <= 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
                        raise ValueError(f"malformed unicode escape at line {line}")
                    buf.append(chr(scalar))
                    i = m.end()
                    continue
                buf.append(ESCAPES.get(text[j], text[i:j + 1]))
                i = j + 1
                continue
            buf.append(c)
            i += 1
        raise ValueError(f"unterminated string literal at line {start}")

    def code(i, line, depth):
        while i < n:
            if text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            if text.startswith("/*", i):
                start, i, nest = line, i + 2, 1
                while nest:
                    if i >= n:
                        raise ValueError(f"unterminated block comment at line {start}")
                    if text.startswith("/*", i):
                        nest, i = nest + 1, i + 2
                    elif text.startswith("*/", i):
                        nest, i = nest - 1, i + 2
                    else:
                        line += text[i] == "\n"
                        i += 1
                continue
            if text[i] == "#":
                j = i
                while j < n and text[j] == "#":
                    j += 1
                if j >= n or text[j] != '"':
                    i = j
                    continue
            m = RAW_OPEN.match(text, i)
            if m:
                i, line = string(m.end(), line, m.group(2) == '"""', len(m.group(1)))
                continue
            c = text[i]
            if c == "\n":
                line += 1
            elif depth and c == "(":
                depth += 1
            elif depth and c == ")":
                depth -= 1
                if depth == 0:
                    return i + 1, line
            i += 1
        return i, line

    code(0, 1, 0)
    return out


def prose_strings(node, path=""):
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from prose_strings(value, f"{path}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from prose_strings(value, f"{path}[{index}]")


def repo_file(path):
    """Return path when it is a regular in-repository file; refuse anything else."""
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
        raise AssertionError(
            f"{path.name}: symlink, non-regular file or path outside the repository; refused")
    return path


def tree_files(base, suffix):
    """Yield the files under base ending in suffix; refuse a symlink anywhere in the tree.

    rglob reports a directory symlink as an entry but does not descend into it, and the file
    filter below (suffix and is_file) would then drop that entry, so without this check the tree
    behind one would go unscanned while the scan reports green.
    """
    for path in sorted(base.rglob("*")):
        if path.is_symlink():
            raise AssertionError(f"{path.name}: symlink in a scanned tree; refused")
        if path.name.endswith(suffix) and path.is_file():
            yield repo_file(path)


def user_facing_units():
    units = []
    for page in tree_files(MANUAL, ".md"):
        rel = page.relative_to(ROOT)
        for number, line in enumerate(page.read_text(encoding="utf-8").split("\n"), 1):
            units.append((f"{rel}:{number}", line))
    for path, value in prose_strings(json.loads(repo_file(PROSE).read_text(encoding="utf-8"))):
        units.append((f"docs/manual-prose.json {path}", value))
    for number, line in enumerate(repo_file(README).read_text(encoding="utf-8").split("\n"), 1):
        units.append((f"README.md:{number}", line))
    for source in tree_files(SOURCES, ".swift"):
        rel = source.relative_to(ROOT)
        for line, value in swift_literals(source.read_text(encoding="utf-8")):
            if value in EXEMPT_LITERALS:
                continue
            if any(marker in value for marker in SCRIPT_MARKERS):
                value = strip_script_comments(value)
            units.append((f"{rel}:{line}", value))
    return units


def violations(units):
    found = []
    for where, text in units:
        for phrase in EXEMPT_PHRASES:
            text = text.replace(phrase, "")
        for rx in (VOCABULARY, NAMES):
            for match in rx.finditer(text):
                found.append(f"{where}: {match.group(0)!r}")
    return found


class SwiftLiteralTokenizerTests(unittest.TestCase):
    def test_comments_are_skipped_and_literals_kept(self):
        text = '// "oracle"\nlet a = "kept" /* "gone" */ + "also"\n'
        self.assertEqual([v for _, v in swift_literals(text)], ["kept", "also"])

    def test_interpolation_is_dropped_including_nested_literals(self):
        text = 'let a = "x \\(f("inner")) y"\n'
        self.assertEqual([v for _, v in swift_literals(text)], ["inner", "x   y"])

    def test_multiline_and_raw_literals(self):
        text = 'let a = """\n  one "quoted"\n  """\nlet b = #"raw "q" \\d"#\n'
        values = [v for _, v in swift_literals(text)]
        self.assertEqual(values, ['\n  one "quoted"\n  ', 'raw "q" \\d'])

    def test_unterminated_literal_fails_loudly(self):
        with self.assertRaises(ValueError):
            swift_literals('let a = "open\n')

    def test_line_continuation_keeps_later_line_numbers(self):
        text = 'let a = """\n  x \\\n  y\n  """\nlet b = "after"\n'
        self.assertEqual(swift_literals(text)[-1], (5, "after"))
        raw = 'let a = #"""\n  x \\#\n  y\n  """#\nlet b = "after"\n'
        self.assertEqual(swift_literals(raw)[-1], (5, "after"))

    def test_escaped_quotes_and_backslashes_are_decoded(self):
        text = 'let a = "say \\"hi\\" \\\\ \\n"\nlet b = #"raw \\" \\#" end"#\n'
        self.assertEqual([v for _, v in swift_literals(text)], ['say "hi" \\ \n', 'raw \\" " end'])

    def test_other_escapes_are_decoded_so_words_stay_separate(self):
        text = 'let a = "x\\nMCP \\toracle \\u{2014}gap3 it\\\'s"\nlet b = #"y\\#nparity"#\n'
        values = [v for _, v in swift_literals(text)]
        self.assertEqual(values, ["x\nMCP \toracle \u2014gap3 it's", "y\nparity"])
        self.assertEqual(violations([("a", values[0]), ("b", values[1])]),
                         ["a: 'MCP'", "a: 'oracle'", "a: 'gap3'", "b: 'parity'"])

    def test_malformed_unicode_escape_fails_loudly_with_its_line(self):
        for body in ("\\u{41", "\\u{zz}", "\\u{}", "\\u{110000}", "\\u{D800}", "\\u{+41}",
                     "\\u{ 41}", "\\u{123456789}", "\\u41"):
            with self.assertRaisesRegex(ValueError, "malformed unicode escape at line 2"):
                swift_literals('let a = 1\nlet b = "x' + body + 'y"\n')

    def test_regex_literal_residual_is_as_documented(self):
        self.assertEqual(swift_literals('let r = /"a"/\n'), [(1, "a")])
        with self.assertRaises(ValueError):
            swift_literals('let r = /a"b/\n')

    def test_long_hash_runs_stay_fast(self):
        self.assertEqual(swift_literals("let a = 1 " + "#" * 200000 + "\n"), [])

    def test_block_comments_nest(self):
        text = 'let a = 1 /* x /* "inner" */ "still comment" */ + "kept"\n'
        self.assertEqual([v for _, v in swift_literals(text)], ["kept"])

    def test_unterminated_nested_block_comment_fails_loudly(self):
        with self.assertRaises(ValueError):
            swift_literals('/* a /* b */\nlet x = "k"\n')


class MatcherTests(unittest.TestCase):
    def test_vocabulary_and_names_are_caught(self):
        units = [("a", "Calendar events (ports calendar_events)."),
                 ("b", "Use list-folders to see folders."),
                 ("c", "Notes recent. CLI-only superset."),
                 ("d", "same posture, see docs/port-specs/mail.md"),
                 ("e", "APPLE_MAIL_MCP_HOME and mac_messages_mcp are no longer read."),
                 ("f", "they differ from Mail's own order — extra32"),
                 ("g", "Truncate previews (max_content_length); gate needs CONTACTS_TEST_MODE."),
                 ("h", "Reminders (replaces apple-events).")]
        self.assertEqual(violations(units), [
            "a: '(ports'", "a: 'calendar_events'", "b: 'list-folders'",
            "c: 'CLI-only'", "c: 'superset'", "d: 'port-specs'",
            "e: 'MCP'", "e: 'mcp'", "f: 'extra32'",
            "g: 'max_content_length'", "g: 'CONTACTS_TEST_MODE'", "h: 'apple-events'"])

    def test_cli_vocabulary_and_the_layout_value_pass(self):
        units = [("a", "File layout: 'oracle' (default): single_email"),
                 ("b", "invalid --layout ' '. Use: oracle, flat."),
                 ("c", "Run apple notes folders, apple messages find-contact or get-link."),
                 ("d", "System Settings → Privacy & Security → Contacts."),
                 ("e", "The CLI only reads the index."),
                 ("f", "Requires the com.apple.security.automation.apple-events entitlement.")]
        self.assertEqual(violations(units), [])


class ScriptCommentTests(unittest.TestCase):
    def test_script_comments_are_dropped_but_script_strings_are_scanned(self):
        script = 'on run argv\n  -- oracle parity note\n  error "use list-folders" -- MCP\n'
        script += '  return "a --b" (* gap3 *) # superset\nend run'
        self.assertEqual(violations([("s", strip_script_comments(script))]), ["s: 'list-folders'"])

    def test_markers_inside_strings_and_multiline_block_comments(self):
        script = 'on run argv\n  return "https://x/a--b" -- oracle\n  (* oracle\n  MCP *)\nend run'
        self.assertEqual(strip_script_comments(script),
                         'on run argv\n  return "https://x/a--b"  \n   \nend run')

    def test_jxa_decrement_is_code_not_a_comment(self):
        jxa = 'Application("X"); for (i=3;i>0;i--) { throw new Error("oracle") } // MCP'
        self.assertEqual(violations([("j", strip_script_comments(jxa))]), ["j: 'oracle'"])

    def test_a_single_line_script_with_escaped_quotes_is_scanned(self):
        text = 'let s = "Application(\\"Mail\\").run(\\"a // b oracle\\") // gap3"\n'
        value = swift_literals(text)[0][1]
        self.assertEqual(violations([("s", strip_script_comments(value))]), ["s: 'oracle'"])

    def test_an_applescript_string_may_span_lines(self):
        script = 'on run argv\n  return "first\n  -- oracle" -- MCP\nend run'
        self.assertEqual(violations([("s", strip_script_comments(script))]), ["s: 'oracle'"])

    def test_a_single_line_script_split_by_newline_escapes_is_scanned_per_line(self):
        text = 'let s = "on run argv\\n  -- note\\n  error \\"use list-folders\\"\\nend run"\n'
        value = swift_literals(text)[0][1]
        self.assertEqual(violations([("s", strip_script_comments(value))]), ["s: 'list-folders'"])

    def test_unterminated_input_is_kept_and_stays_fast(self):
        tail = '"' + '\\"' * 100000 + "\\"
        self.assertEqual(strip_script_comments(tail), tail)
        self.assertEqual(strip_script_comments("(*" * 100000), "(*" * 100000)


class RepoFileTests(unittest.TestCase):
    def test_symlinks_and_outside_paths_are_refused(self):
        self.assertEqual(repo_file(PROSE), PROSE)
        with tempfile.TemporaryDirectory() as tmp:
            outside = pathlib.Path(tmp, "outside.md")
            outside.write_text("x", encoding="utf-8")
            link = pathlib.Path(tmp, "alias.md")
            link.symlink_to(PROSE)
            folder = pathlib.Path(tmp, "dir.md")
            folder.mkdir()
            for path in (outside, link, folder):
                with self.assertRaises(AssertionError):
                    repo_file(path)
        with self.assertRaises(AssertionError):
            repo_file(MANUAL)

    def test_a_directory_symlink_in_a_scanned_tree_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp, "target")
            target.mkdir()
            pathlib.Path(target, "page.md").write_text("MCP", encoding="utf-8")
            tree = pathlib.Path(tmp, "tree")
            tree.mkdir()
            pathlib.Path(tree, "linked").symlink_to(target, target_is_directory=True)
            with self.assertRaises(AssertionError):
                list(tree_files(tree, ".md"))


class UserFacingTextTests(unittest.TestCase):
    def test_no_retired_server_vocabulary_in_user_facing_text(self):
        found = violations(user_facing_units())
        self.assertEqual(found, [], "retired-server vocabulary in user-facing text:\n"
                         + "\n".join(found))

    def test_the_scan_sees_all_four_surfaces(self):
        units = user_facing_units()
        self.assertTrue(any(w.startswith("docs/manual/") for w, _ in units))
        self.assertTrue(any(w.startswith("docs/manual-prose.json") for w, _ in units))
        self.assertTrue(any(w.startswith("README.md:") for w, _ in units))
        self.assertTrue(any(w.startswith("Sources/") for w, _ in units))

    def test_no_recorded_name_is_a_documented_command_or_option(self):
        tokens = set()
        for page in tree_files(MANUAL, ".md"):
            for line in page.read_text(encoding="utf-8").split("\n"):
                if line.startswith("# apple "):
                    tokens.update(line[len("# apple "):].split())
                tokens.update(re.findall(r"(?<![\w-])--([a-z][a-z0-9-]*)", line))
        self.assertTrue(tokens, "no commands or options read from the manual")
        self.assertEqual(sorted(tokens & set(RETIRED_NAMES)), [])


if __name__ == "__main__":
    unittest.main()
