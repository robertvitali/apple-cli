import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "dependency_policy.py"
DEPENDABOT_PATH = REPO_ROOT / ".github" / "dependabot.yml"
DOCS_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "docs.yml"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
REQUIREMENTS_IN_PATH = REPO_ROOT / "docs" / "requirements.in"
REQUIREMENTS_LOCK_PATH = REPO_ROOT / "docs" / "requirements.txt"
WORKFLOW_POLICY_PATH = REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
SYNTHETIC_HASH = "a" * 64
SYNTHETIC_HASH_OPTION = "--hash=sha256:" + SYNTHETIC_HASH
SECOND_HASH = "b" * 64
SECOND_HASH_OPTION = "--hash=sha256:" + SECOND_HASH
# Whitespace and separators pip, git and the shell do not treat as Python does, plus the other
# refused classes: a no-break space, an em space, an ideographic space, the Unicode line and
# paragraph separators, NEL, a vertical tab, a form feed, a carriage return, NUL, DEL, a C1
# control, a byte-order mark and a bidirectional control.
REFUSED_SAMPLES = (
    "\u00a0", "\u2003", "\u3000", "\u2028", "\u2029", "\x85", "\x0b", "\x0c", "\r", "\x00",
    "\x7f", "\x86", "\ufeff", "\u202e",
)


def load_checker() -> ModuleType:
    spec = importlib.util.spec_from_file_location("dependency_policy", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load dependency policy checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_docs_inputs(root: Path, requirements_in: str, requirements_lock: str) -> None:
    docs = root / "docs"
    docs.mkdir()
    (docs / "requirements.in").write_bytes(requirements_in.encode("utf-8"))
    (docs / "requirements.txt").write_bytes(requirements_lock.encode("utf-8"))


def refused(codepoint: str) -> str:
    return "character {} is refused".format(re.escape(codepoint))


def read_tracked(path: Path) -> str:
    # Bytes, not read_text(): universal newlines would hide a carriage return.
    return path.read_bytes().decode("utf-8")


class DocsDependencyPolicyTests(unittest.TestCase):
    def test_repository_docs_dependencies_are_fully_locked_and_fresh(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_docs_dependencies(REPO_ROOT), [])
        pins = checker.parse_input_pins(REQUIREMENTS_IN_PATH.read_text(encoding="utf-8"))
        locked = checker.parse_hash_lock(REQUIREMENTS_LOCK_PATH.read_text(encoding="utf-8"))
        self.assertEqual(set(pins), {"mkdocs-material"})
        self.assertEqual(locked["mkdocs-material"].version, pins["mkdocs-material"])
        self.assertTrue(all(requirement.hashes for requirement in locked.values()))

    def test_lock_records_python_312_linux_resolution_contract(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            shutil.copyfile(REQUIREMENTS_IN_PATH, root / "docs" / "requirements.in")
            stale_lock = REQUIREMENTS_LOCK_PATH.read_text(encoding="utf-8").replace(
                "--python-version 3.12",
                "--python-version 3.11",
                1,
            )
            (root / "docs" / "requirements.txt").write_text(
                stale_lock,
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("Python 3.12" in error for error in errors))

    def test_changed_top_level_pin_makes_the_lock_stale(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, root / "docs" / "requirements.txt")
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.8\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("top-level lock is stale" in error for error in errors))

    def test_unhashed_or_unpinned_requirement_is_rejected(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            (docs / "requirements.in").write_text("mkdocs-material>=9\n", encoding="utf-8")
            (docs / "requirements.txt").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("exactly pinned" in error for error in errors))
            self.assertTrue(any("hash" in error for error in errors))

    def test_missing_docs_lock_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("requirements.txt is missing" in error for error in errors))

    def test_rejects_symlinked_and_oversized_docs_policy_inputs(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            target = root / "requirements-source.in"
            target.write_text("mkdocs-material==9.7.7\n", encoding="utf-8")
            (docs / "requirements.in").symlink_to(target)
            (docs / "requirements.txt").write_text(
                "#" * (checker.MAX_LOCK_BYTES + 1),
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("requirements.in" in error for error in errors))
            self.assertTrue(any("requirements.txt" in error for error in errors))

    def test_rejects_nonregular_docs_policy_input_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            os.mkfifo(docs / "requirements.in")
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            )

            self.assertNotEqual(result.returncode, 0)

    def test_workflows_install_docs_dependencies_only_from_hash_locked_file(self) -> None:
        docs_workflow = DOCS_WORKFLOW_PATH.read_text(encoding="utf-8")
        ci_workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        approved_command = (
            "python -m pip install --require-hashes -r docs/requirements.txt"
        )

        # Two jobs install the documentation toolchain, both from the hash-locked file and
        # nothing else: the supply-chain lock-closure proof (ci.yml) and the site-assembly
        # rehearsal (docs.yml). No other `pip install` form is admitted anywhere.
        self.assertEqual(docs_workflow.count("pip install"), 1)
        self.assertIn(approved_command, docs_workflow)
        self.assertIn(approved_command, ci_workflow)
        self.assertNotIn("pip install mkdocs-material", ci_workflow)
        self.assertNotIn("python -m pip install mkdocs-material", ci_workflow)

        install_lines = []
        for path in sorted((REPO_ROOT / ".github" / "workflows").rglob("*.yml")):
            for line in path.read_text(encoding="utf-8").splitlines():
                if re.search(r"\bpip +install\b", line):
                    install_lines.append(line.strip())
        self.assertEqual(len(install_lines), 2)
        self.assertTrue(
            all(
                line in {approved_command, f"run: {approved_command}"}
                for line in install_lines
            )
        )

    def test_refuses_unicode_space_indenting_a_hash_line(self) -> None:
        # This reader took a no-break or em space as continuation indentation and attached the
        # hash. pip continues a line only at a trailing backslash and splits tokens on a space,
        # so the character stays in pip's requirement string and the install fails on a lock
        # this check had passed.
        checker = load_checker()
        lock = read_tracked(REQUIREMENTS_LOCK_PATH)
        for character in ("\u00a0", "\u2003"):
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                indented = lock.replace("\n    --hash=", "\n" + character + "   --hash=", 1)
                self.assertNotEqual(indented, lock)
                write_docs_inputs(root, read_tracked(REQUIREMENTS_IN_PATH), indented)

                errors = checker.validate_docs_dependencies(root)

                self.assertTrue(
                    any(
                        error.startswith("docs/requirements.txt: line ") and codepoint in error
                        for error in errors
                    ),
                    errors,
                )
                with self.assertRaisesRegex(ValueError, refused(codepoint)):
                    checker.parse_hash_lock(
                        "examplepkg==1.0 \\\n" + character + "   " + SYNTHETIC_HASH_OPTION + "\n"
                    )

    def test_refuses_unicode_space_before_a_continuation_backslash(self) -> None:
        # `\s*\\` admitted a no-break space before the backslash; pip keeps it in the
        # requirement string.
        checker = load_checker()
        lock = read_tracked(REQUIREMENTS_LOCK_PATH)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spaced = lock.replace(" \\\n", "\u00a0\\\n", 1)
            self.assertNotEqual(spaced, lock)
            write_docs_inputs(root, read_tracked(REQUIREMENTS_IN_PATH), spaced)

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(
                any(
                    error.startswith("docs/requirements.txt: line ") and "U+00A0" in error
                    for error in errors
                ),
                errors,
            )
        for text in (
            "examplepkg==1.0\u00a0\\\n    " + SYNTHETIC_HASH_OPTION + "\n",
            "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + "\u00a0\\\n"
            "    --hash=sha256:" + "b" * 64 + "\n",
        ):
            with self.subTest(text=ascii(text)):
                with self.assertRaisesRegex(ValueError, refused("U+00A0")):
                    checker.parse_hash_lock(text)

    def test_continuation_backslash_admits_only_a_space_or_a_tab_before_it(self) -> None:
        # Checked on the patterns directly: the refusal runs first, so a parse cannot show them.
        checker = load_checker()
        start = checker.LOCK_START_PATTERN
        option = checker.HASH_PATTERN
        for separator in ("", " ", "\t", " \t "):
            with self.subTest(separator=ascii(separator)):
                self.assertIsNotNone(start.fullmatch("examplepkg==1.0" + separator + "\\"))
                self.assertIsNotNone(option.fullmatch(SYNTHETIC_HASH_OPTION + separator + "\\"))
        for character in REFUSED_SAMPLES + ("\n", "\x1c", "\x1f"):
            with self.subTest(codepoint="U+{:04X}".format(ord(character))):
                self.assertIsNone(start.fullmatch("examplepkg==1.0" + character + "\\"))
                self.assertIsNone(option.fullmatch(SYNTHETIC_HASH_OPTION + character + "\\"))
        # A space or a tab before the backslash, then space indentation: the forms pip reads
        # still parse. A tab in the indentation is refused (see the next test).
        for separator, indent in (("", "  "), (" ", "    "), ("\t", "    ")):
            with self.subTest(separator=ascii(separator), indent=ascii(indent)):
                self.assertEqual(
                    checker.parse_hash_lock(
                        "# synthetic\n\nexamplepkg==1.0" + separator + "\\\n"
                        + indent + SYNTHETIC_HASH_OPTION + "\n"
                    ),
                    {"examplepkg": checker.LockedRequirement("1.0", (SYNTHETIC_HASH,))},
                )

    def test_refuses_a_tab_in_continuation_indentation(self) -> None:
        # pip joins a continued line onto the requirement and splits the tokens on a space, so a
        # tab directly before the first hash option keeps `--hash=...` inside the requirement
        # string and pip refuses the file. This reader took any leading space or tab as
        # indentation and attached the hash.
        checker = load_checker()
        lock = read_tracked(REQUIREMENTS_LOCK_PATH)
        requirements_in = read_tracked(REQUIREMENTS_IN_PATH)
        first_hash = lock.index("\n    --hash=") + 1
        expected = (
            "docs/requirements.txt: line {}: locked docs requirement continuation must be "
            "indented with spaces only".format(lock[:first_hash].count("\n") + 1)
        )
        for indent in ("\t", "  \t"):
            with self.subTest(indent=ascii(indent)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                tabbed = lock[:first_hash] + indent + lock[first_hash + 4:]
                self.assertTrue(tabbed[first_hash:].startswith(indent + "--hash="))
                write_docs_inputs(root, requirements_in, tabbed)

                errors = checker.validate_docs_dependencies(root)

                # The refusal is the only error: an unparsed lock is not compared with the pins.
                self.assertEqual(errors, [expected])
        # Every continuation line is held to spaces. That is stricter than pip wherever a space
        # has already split the option off: a tab followed by spaces, or a tab before a later
        # hash line, which pip reads.
        for text in (
            "# synthetic\nexamplepkg==1.0 \\\n\t" + SYNTHETIC_HASH_OPTION + "\n",
            "# synthetic\nexamplepkg==1.0 \\\n  \t" + SYNTHETIC_HASH_OPTION + "\n",
            "# synthetic\nexamplepkg==1.0 \\\n\t  " + SYNTHETIC_HASH_OPTION + "\n",
            "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\n\t--hash=sha256:"
            + "b" * 64 + "\n",
        ):
            with self.subTest(text=ascii(text)):
                with self.assertRaises(ValueError) as raised:
                    checker.parse_hash_lock(text)
                # Value-free: the line number and the rule, nothing from the file.
                self.assertEqual(
                    str(raised.exception),
                    "line 3: locked docs requirement continuation must be indented with spaces "
                    "only",
                )
        # A tab-indented comment or blank line is not a continuation; pip drops both as well.
        self.assertEqual(
            checker.parse_hash_lock(
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + "\n\t# synthetic\n\t\n"
            ),
            {"examplepkg": checker.LockedRequirement("1.0", (SYNTHETIC_HASH,))},
        )

    def test_unparsed_lock_is_not_compared_with_the_pins(self) -> None:
        # A lock that fails to parse reports that failure alone, without a stale-lock error per
        # top-level pin; a lock that parses but lacks a pin is still stale.
        checker = load_checker()
        lock = read_tracked(REQUIREMENTS_LOCK_PATH)
        requirements_in = read_tracked(REQUIREMENTS_IN_PATH)
        for label, broken in (
            ("refused character", lock.replace("\n    --hash=", "\n\u00a0   --hash=", 1)),
            ("missing hash", lock + "examplepkg==1.0\n"),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.assertNotEqual(broken, lock)
                write_docs_inputs(root, requirements_in, broken)

                errors = checker.validate_docs_dependencies(root)

                self.assertEqual(len(errors), 1, errors)
                self.assertTrue(errors[0].startswith("docs/requirements.txt: "), errors)
                self.assertNotIn("stale", errors[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_docs_inputs(root, requirements_in + "examplepkg==1.0\n", lock)

            self.assertEqual(
                checker.validate_docs_dependencies(root),
                ["docs requirements top-level lock is stale"],
            )

    def test_refuses_unicode_space_around_an_input_pin(self) -> None:
        # strip() took no-break spaces around a pin as blank; the input's consumer is
        # `uv pip compile`, whose reader was not shown to agree, so the character is refused.
        checker = load_checker()
        requirements_in = read_tracked(REQUIREMENTS_IN_PATH)
        lines = requirements_in.split("\n")
        index = next(
            number for number, line in enumerate(lines)
            if "==" in line and not line.startswith("#")
        )
        lines[index] = "\u00a0" + lines[index] + "\u00a0"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_docs_inputs(root, "\n".join(lines), read_tracked(REQUIREMENTS_LOCK_PATH))

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(
                any(
                    error.startswith("docs/requirements.in: line {}: ".format(index + 1))
                    and "U+00A0" in error
                    for error in errors
                ),
                errors,
            )
        with self.assertRaisesRegex(ValueError, refused("U+00A0")):
            checker.parse_input_pins("\u00a0examplepkg==1.0\u00a0\n")

    def test_refuses_every_refused_class_in_either_file(self) -> None:
        # Line and paragraph separators, NEL, a vertical tab, a form feed and a carriage return
        # split lines for splitlines() but not for a line-feed reader; the other samples are
        # refused by the shared rule wherever they appear.
        checker = load_checker()
        for character in REFUSED_SAMPLES:
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint):
                with self.assertRaisesRegex(ValueError, refused(codepoint)):
                    checker.parse_input_pins("examplepkg==1.0" + character + "\n")
                with self.assertRaisesRegex(ValueError, refused(codepoint)):
                    checker.parse_hash_lock(
                        "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + character + "\n"
                    )

    def test_refusal_names_only_the_line_and_code_point(self) -> None:
        checker = load_checker()
        with self.assertRaises(ValueError) as raised:
            checker.parse_hash_lock(
                "# synthetic\nexamplepkg==1.0 \\\n\u00a0   " + SYNTHETIC_HASH_OPTION + "\n"
            )
        message = str(raised.exception)
        self.assertTrue(message.startswith("line 3: character U+00A0 is refused"), message)
        for value in ("examplepkg", SYNTHETIC_HASH, "\u00a0", "--hash"):
            self.assertNotIn(value, message)

    def test_refused_character_rule_matches_the_workflow_scan(self) -> None:
        # The rule is carried here, in workflow_policy.py and in action_pins.py; every code
        # point must agree.
        checker = load_checker()
        spec = importlib.util.spec_from_file_location("workflow_policy", WORKFLOW_POLICY_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError("unable to load the workflow policy scan")
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        disagreements = [
            code for code in range(0x110000)
            if checker._refused_character(chr(code)) != policy.refused_character(chr(code), " \t")
        ]
        self.assertEqual(disagreements, [])
        self.assertFalse(checker._refused_character(" "))
        self.assertFalse(checker._refused_character("\t"))
        # Line feeds are split out before the check.
        self.assertTrue(checker._refused_character("\n"))

    def test_continuation_backslash_must_be_the_last_character_on_its_line(self) -> None:
        # pip continues a line only when its last character is the backslash. This reader
        # stripped trailing whitespace before looking, so a space or a tab after the backslash
        # still read as a continuation, while pip kept the backslash in the requirement (an
        # invalid requirement) or in the hash options (a parse error) and refused the lock.
        checker = load_checker()
        for label, text, line in (
            (
                "E1 space after the requirement line's backslash",
                "examplepkg==1.0 \\ \n    " + SYNTHETIC_HASH_OPTION + "\n",
                1,
            ),
            (
                "E2 tab after the requirement line's backslash",
                "examplepkg==1.0 \\\t\n    " + SYNTHETIC_HASH_OPTION + "\n",
                1,
            ),
            (
                "E3 space after a hash line's backslash, another hash line next",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\ \n    "
                + SECOND_HASH_OPTION + "\n",
                2,
            ),
            (
                "E10 tab after the last hash line's backslash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\t\n",
                2,
            ),
        ):
            with self.subTest(label):
                with self.assertRaises(ValueError) as raised:
                    checker.parse_hash_lock(text)
                message = str(raised.exception)
                # Value-free: the line number and the rule, nothing from the file.
                self.assertEqual(
                    message,
                    "line {}: a continuation backslash must be the last character on its "
                    "line".format(line),
                )
                for value in ("examplepkg", SYNTHETIC_HASH, SECOND_HASH, "\\"):
                    self.assertNotIn(value, message)
        # Trailing spaces and tabs with no backslash before them are read by pip as well.
        for label, text in (
            (
                "E6 trailing space after the last hash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \n",
            ),
            (
                "E5 tab before the backslash and after the last hash",
                "examplepkg==1.0\t\\\n    " + SYNTHETIC_HASH_OPTION + "\t\n",
            ),
        ):
            with self.subTest(label):
                self.assertEqual(
                    checker.parse_hash_lock(text),
                    {"examplepkg": checker.LockedRequirement("1.0", (SYNTHETIC_HASH,))},
                )
        # Through the file check the refusal is the only error, with the line counted from the
        # top of the file.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_docs_inputs(
                root,
                "examplepkg==1.0\n",
                checker.LOCK_HEADER + "\nexamplepkg==1.0 \\ \n    " + SYNTHETIC_HASH_OPTION + "\n",
            )
            self.assertEqual(
                checker.validate_docs_dependencies(root),
                [
                    "docs/requirements.txt: line 3: a continuation backslash must be the last "
                    "character on its line"
                ],
            )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_docs_inputs(
                root,
                "examplepkg==1.0\n",
                checker.LOCK_HEADER + "\nexamplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \n",
            )
            self.assertEqual(checker.validate_docs_dependencies(root), [])

    def test_patterns_end_at_the_backslash_and_admit_trailing_blanks_only_without_one(
        self,
    ) -> None:
        # Checked on the patterns directly: the parse refuses a blank after a backslash earlier,
        # with its own message.
        checker = load_checker()
        start = checker.LOCK_START_PATTERN
        option = checker.HASH_PATTERN
        for trailing in (" ", "\t", " \t", "\t "):
            with self.subTest(trailing=ascii(trailing)):
                for separator in ("", " ", "\t"):
                    self.assertIsNone(
                        start.fullmatch("examplepkg==1.0" + separator + "\\" + trailing)
                    )
                    self.assertIsNone(
                        option.fullmatch(SYNTHETIC_HASH_OPTION + separator + "\\" + trailing)
                    )
                self.assertIsNotNone(start.fullmatch("examplepkg==1.0" + trailing))
                self.assertIsNotNone(option.fullmatch(SYNTHETIC_HASH_OPTION + trailing))
        # Indentation is never part of either pattern, and one backslash ends a line.
        self.assertIsNone(start.fullmatch(" examplepkg==1.0"))
        self.assertIsNone(option.fullmatch(" " + SYNTHETIC_HASH_OPTION))
        self.assertIsNone(start.fullmatch("examplepkg==1.0 \\\\"))
        self.assertIsNone(option.fullmatch(SYNTHETIC_HASH_OPTION + " \\\\"))

    def test_hashes_attach_only_through_a_continuation_backslash(self) -> None:
        # pip joins lines at a trailing backslash, not by indentation. This reader attached any
        # indented hash line to the requirement above it, so it counted hashes pip drops with a
        # warning ("has --hash but no requirement"), and it read a requirement line that pip
        # glues into the previous requirement's hash options as a requirement of its own.
        checker = load_checker()
        follow = (
            "line {}: a hash line must follow a line that ends with a continuation backslash"
        )
        for label, text, message in (
            (
                "F1 requirement line without a backslash",
                "examplepkg==1.0\n    " + SYNTHETIC_HASH_OPTION + "\n",
                follow.format(2),
            ),
            (
                "F2 blank line inside the continuation",
                "examplepkg==1.0 \\\n\n    " + SYNTHETIC_HASH_OPTION + "\n",
                follow.format(3),
            ),
            (
                "F3 comment line inside the continuation",
                "examplepkg==1.0 \\\n    # synthetic\n    " + SYNTHETIC_HASH_OPTION + "\n",
                follow.format(3),
            ),
            (
                "F5 hash line after a hash line without a backslash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + "\n    "
                + SECOND_HASH_OPTION + "\n",
                follow.format(3),
            ),
            (
                "F4 requirement line after a hash line's backslash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\notherpkg==2.0 \\\n    "
                + SECOND_HASH_OPTION + "\n",
                "line 3: a requirement line must not follow a line that ends with a "
                "continuation backslash",
            ),
        ):
            with self.subTest(label):
                with self.assertRaises(ValueError) as raised:
                    checker.parse_hash_lock(text)
                # Value-free: the line number and the rule, nothing from the file.
                self.assertEqual(str(raised.exception), message)
        # A blank or comment line after a hash line's backslash ends the continuation, and a
        # backslash on the last line continues nothing: pip reads all three alike.
        first = checker.LockedRequirement("1.0", (SYNTHETIC_HASH,))
        both = {"examplepkg": first, "otherpkg": checker.LockedRequirement("2.0", (SECOND_HASH,))}
        for label, text, expected in (
            (
                "F6 backslash on the last line",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\n",
                {"examplepkg": first},
            ),
            (
                "F7 blank line after a hash line's backslash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\n\notherpkg==2.0 \\\n    "
                + SECOND_HASH_OPTION + "\n",
                both,
            ),
            (
                "F8 comment line after a hash line's backslash",
                "examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + " \\\n    # synthetic\n"
                "otherpkg==2.0 \\\n    " + SECOND_HASH_OPTION + "\n",
                both,
            ),
        ):
            with self.subTest(label):
                self.assertEqual(checker.parse_hash_lock(text), expected)
        # An indented requirement line is refused although pip strips the indentation and
        # reads it (E7): stricter than pip, and uv never indents one.
        with self.assertRaisesRegex(ValueError, "continuation is malformed"):
            checker.parse_hash_lock(" examplepkg==1.0 \\\n    " + SYNTHETIC_HASH_OPTION + "\n")

    def test_missing_or_empty_lock_reports_every_pin_as_stale(self) -> None:
        # Only a lock that failed to parse skips the pin comparison. A missing or empty lock is
        # compared as an empty one, and for an empty file the stale errors are the only errors,
        # so nothing else would fail it.
        checker = load_checker()
        stale = "docs requirements top-level lock is stale"
        for label, lock, expected in (
            ("missing", None, ["docs/requirements.txt is missing", stale, stale]),
            ("empty", "", [stale, stale]),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                docs = Path(directory) / "docs"
                docs.mkdir()
                (docs / "requirements.in").write_bytes(b"examplepkg==1.0\notherpkg==2.0\n")
                if lock is not None:
                    (docs / "requirements.txt").write_bytes(lock.encode("utf-8"))

                self.assertEqual(checker.validate_docs_dependencies(Path(directory)), expected)


class DependabotPolicyTests(unittest.TestCase):
    def test_repository_dependabot_configuration_matches_policy(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_dependabot(REPO_ROOT), [])
        self.assertEqual(
            DEPENDABOT_PATH.read_text(encoding="utf-8"),
            checker.render_dependabot_policy(),
        )

        raw = DEPENDABOT_PATH.read_text(encoding="utf-8").lower()
        self.assertNotIn("auto-merge", raw)
        self.assertNotIn("automerge", raw)

    def test_missing_swift_root_manifests_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / ".github").mkdir()
            shutil.copyfile(DEPENDABOT_PATH, root / ".github" / "dependabot.yml")
            (root / "docs").mkdir()
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, root / "docs" / "requirements.txt")

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("Swift root manifest" in error for error in errors))

    def test_missing_docs_lock_blocks_pip_dependabot(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / ".github").mkdir()
            shutil.copyfile(DEPENDABOT_PATH, root / ".github" / "dependabot.yml")
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            (root / "Package.resolved").write_text("{}\n", encoding="utf-8")

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("docs dependency lock" in error for error in errors))

    def test_noncanonical_yaml_encodings_are_rejected_byte_for_byte(self) -> None:
        checker = load_checker()
        canonical = DEPENDABOT_PATH.read_text(encoding="utf-8")
        invalid_documents = (
            canonical.replace(
                'prefix: "build(actions)"',
                "prefix: 'build(''actions'')'",
                1,
            ),
            canonical.replace(
                'package-ecosystem: "github-actions"',
                "package-ecosystem: github-actions",
                1,
            ),
            canonical.replace("version: 2", "version: 2 # equivalent comment", 1),
        )

        for index, document in enumerate(invalid_documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                github = root / ".github"
                github.mkdir()
                (github / "dependabot.yml").write_text(document, encoding="utf-8")
                (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
                (root / "Package.resolved").write_text("{}\n", encoding="utf-8")
                docs = root / "docs"
                docs.mkdir()
                shutil.copyfile(REQUIREMENTS_IN_PATH, docs / "requirements.in")
                shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

                errors = checker.validate_dependabot(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(any("canonical" in error for error in errors))

    def test_rejects_symlinked_and_oversized_dependabot_policy(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            github = root / ".github"
            github.mkdir()
            target = root / "dependabot-source.yml"
            target.write_text(DEPENDABOT_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            (github / "dependabot.yml").symlink_to(target)

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("dependabot.yml" in error for error in errors))

            (github / "dependabot.yml").unlink()
            (github / "dependabot.yml").write_text(
                "#" * (checker.MAX_DEPENDABOT_BYTES + 1),
                encoding="utf-8",
            )
            errors = checker.validate_dependabot(root)
            self.assertTrue(any("dependabot.yml" in error for error in errors))

    def test_rejects_nonregular_dependabot_policy_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            github = root / ".github"
            github.mkdir()
            os.mkfifo(github / "dependabot.yml")
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            (root / "Package.resolved").write_text("{}\n", encoding="utf-8")
            docs = root / "docs"
            docs.mkdir()
            shutil.copyfile(REQUIREMENTS_IN_PATH, docs / "requirements.in")
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            )

            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
