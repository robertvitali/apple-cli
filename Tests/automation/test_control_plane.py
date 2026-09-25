"""Enforcement control plane: CODEOWNERS and the control-plane manifest (design section 10.5).

Checks, on the real tree:
  * .github/CODEOWNERS parses, uses only the anchored, glob-free pattern subset this file models,
    names exactly one distinct owner, and that owner is a single GitHub user (never a team, never
    an address);
  * every manifest path is effectively owned by that owner under GitHub's last-match-wins rule,
    as modelled here;
  * every tracked file under a deny-by-default tree is listed in the manifest (a new file there
    without a manifest entry is a red build, which is the friction the design asks for);
  * every tracked file a CODEOWNERS pattern claims is listed in the manifest (ownership asserted
    in CODEOWNERS is a claim that the path is control plane);
  * the governance documents and policy inputs outside the trees stay listed (they cannot be
    dropped from the manifest with a green suite);
  * every manifest path is a tracked file, and the manifest, CODEOWNERS and this test list
    themselves.
The owner's identifier is read from CODEOWNERS and never written in this file.

Residual, stated rather than implied: completeness is proven only for the four deny-by-default
trees, for CODEOWNERS-matched paths, and for the pinned non-tree set. A control-plane path outside
all three (a policy input a driver newly reads) can be omitted from the manifest without failing
here; section 10.5's rule that any data file an in-plane file reads as policy is in the plane is
carried by review, not by this file. GitHub also ignores a code owner without write access on the
repository; that is visible only through the code-owners errors API, which remains the authority
on whether the file takes effect.
"""
import json
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CODEOWNERS = ROOT / ".github" / "CODEOWNERS"
MANIFEST = ROOT / ".github" / "control-plane-manifest.json"
USER_OWNER_RE = re.compile(r"^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
DENY_BY_DEFAULT_TREES = (".github/", "scripts/", "Tests/automation/", "bats/helpers/")
# Non-tree control-plane paths that must stay in the manifest: governance documents and the
# policy inputs in-plane drivers read. Removing one is a policy change that must edit this test.
REQUIRED_NON_TREE_PATHS = (
    "AGENTS.md",
    "CLAUDE.md",
    "HUMAN-DECISIONS.md",
    "bats/tier-inventory.json",
    "docs/discovery/prelaunch-readiness-evidence.md",
    "docs/requirements.in",
    "docs/requirements.txt",
    "docs/superpowers/specs/2026-09-01-publication-automation-design.md",
    "mkdocs.yml",
)
SELF_REFERENTIAL_PATHS = (".github/CODEOWNERS", ".github/control-plane-manifest.json", "Tests/automation/test_control_plane.py")
UNSUPPORTED_PATTERN_CHARS = set("*?[]!\\")


def tracked_files():
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, text=True, check=True).stdout
    return sorted(f for f in out.split("\0") if f)


def parse_codeowners(text):
    rules = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            raise ValueError(f"line {lineno}: pattern without an owner")
        rules.append((lineno, parts[0], tuple(parts[1:])))
    return rules


def pattern_is_supported(pattern):
    """The subset this file models: anchored ('/'-prefixed), glob-free, no negation or escapes."""
    return pattern.startswith("/") and not (set(pattern) & UNSUPPORTED_PATTERN_CHARS)


def pattern_matches(pattern, path):
    """Anchored, glob-free CODEOWNERS matching.

    '/dir/' matches every path beneath dir; '/path' matches that exact path or, when the tree has
    it as a directory, everything beneath it. Patterns outside this subset are refused by
    test_codeowners_uses_only_the_modelled_pattern_subset, so no glob semantics are modelled here.
    """
    if not pattern_is_supported(pattern):
        raise ValueError(f"unsupported CODEOWNERS pattern: {pattern}")
    pat = pattern.lstrip("/")
    if pat.endswith("/"):
        return path.startswith(pat)
    return path == pat or path.startswith(pat + "/")


def effective_owners(rules, path):
    owners = ()
    for _, pattern, rule_owners in rules:
        if pattern_matches(pattern, path):
            owners = rule_owners  # last match wins
    return owners


class ControlPlaneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = parse_codeowners(CODEOWNERS.read_text(encoding="utf-8"))
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.tracked = tracked_files()

    def test_codeowners_uses_only_the_modelled_pattern_subset(self):
        bad = [(lineno, pattern) for lineno, pattern, _ in self.rules if not pattern_is_supported(pattern)]
        self.assertEqual(bad, [], f"CODEOWNERS patterns outside the anchored, glob-free subset this test models: {bad}")

    def test_codeowners_names_exactly_one_user_owner(self):
        owners = {o for _, _, rule_owners in self.rules for o in rule_owners}
        self.assertEqual(len(owners), 1, f"CODEOWNERS must name exactly one owner, found {len(owners)}")
        (owner,) = owners
        self.assertRegex(owner, USER_OWNER_RE, "the owner must be a single GitHub user, not a team or an address")

    def test_every_rule_names_the_same_single_owner(self):
        owner_sets = {rule_owners for _, _, rule_owners in self.rules}
        self.assertEqual(len(owner_sets), 1, "every rule must name the same single owner, so a later rule can never change ownership")
        for lineno, pattern, rule_owners in self.rules:
            self.assertEqual(len(rule_owners), 1, f"CODEOWNERS line {lineno} ({pattern}) names {len(rule_owners)} owners")

    def test_no_alternate_codeowners_location_exists(self):
        # GitHub reads .github/CODEOWNERS first; a root or docs/ copy would be inert but confusing.
        for alt in ("CODEOWNERS", "docs/CODEOWNERS"):
            self.assertNotIn(alt, self.tracked, f"{alt} must not exist alongside .github/CODEOWNERS")

    def test_manifest_shape(self):
        self.assertEqual(self.manifest["schema"], 1)
        trees = tuple(self.manifest["deny_by_default_trees"])
        self.assertEqual(trees, DENY_BY_DEFAULT_TREES)
        for tree in trees:
            self.assertTrue(tree.endswith("/"), f"deny-by-default tree {tree!r} must end with '/' so it cannot match a sibling prefix")
        paths = self.manifest["paths"]
        self.assertEqual(paths, sorted(set(paths)), "manifest paths must be sorted and unique")
        for required in SELF_REFERENTIAL_PATHS:
            self.assertIn(required, paths)

    def test_manifest_lists_every_required_non_tree_path(self):
        missing = [p for p in REQUIRED_NON_TREE_PATHS if p not in self.manifest["paths"]]
        self.assertEqual(missing, [], f"control-plane paths removed from the manifest: {missing}")

    def test_every_manifest_path_is_tracked(self):
        tracked = set(self.tracked)
        missing = [p for p in self.manifest["paths"] if p not in tracked]
        self.assertEqual(missing, [], f"manifest lists untracked paths: {missing}")

    def test_every_tracked_file_under_a_deny_by_default_tree_is_listed(self):
        listed = set(self.manifest["paths"])
        unlisted = [f for f in self.tracked if f.startswith(DENY_BY_DEFAULT_TREES) and f not in listed]
        self.assertEqual(unlisted, [], "new control-plane files need a manifest entry in the same change: " + ", ".join(unlisted))

    def test_every_codeowners_matched_tracked_file_is_in_the_manifest(self):
        # Ownership asserted in CODEOWNERS is a claim that the path is control plane, so the
        # manifest must list it. Catches growth under /docs/runbooks/ and /docs/superpowers/specs/,
        # which no deny-by-default tree covers.
        listed = set(self.manifest["paths"])
        claimed = [f for f in self.tracked if effective_owners(self.rules, f) and f not in listed]
        self.assertEqual(claimed, [], f"CODEOWNERS owns paths the manifest omits: {claimed}")

    def test_every_manifest_path_is_effectively_owned_by_the_single_owner(self):
        (owner,) = {o for _, _, rule_owners in self.rules for o in rule_owners}
        unowned = [p for p in self.manifest["paths"] if effective_owners(self.rules, p) != (owner,)]
        self.assertEqual(unowned, [], f"manifest paths without the operator as effective owner: {unowned}")


class CodeownersModelTests(unittest.TestCase):
    """Hermetic cases for the parser and the matcher: each refused shape must fail on its own."""

    def test_rule_without_an_owner_is_refused_at_parse_time(self):
        with self.assertRaises(ValueError):
            parse_codeowners("/scripts/ @alice\n/scripts/ci/\n")

    def test_two_owners_on_one_rule_break_the_single_owner_invariant(self):
        rules = parse_codeowners("/scripts/ @alice @bob\n")
        owner_sets = {rule_owners for _, _, rule_owners in rules}
        self.assertNotEqual(len(next(iter(owner_sets))), 1)

    def test_team_and_address_owners_are_not_single_users(self):
        for owner in ("@example-org/platform", "alice@example.com", "@", "@-alice"):
            self.assertIsNone(USER_OWNER_RE.match(owner), owner)
        self.assertIsNotNone(USER_OWNER_RE.match("@alice-1"))

    def test_last_match_wins_and_a_later_different_owner_changes_ownership(self):
        rules = parse_codeowners("/scripts/ @alice\n/scripts/ci/ @bob\n")
        self.assertEqual(effective_owners(rules, "scripts/ci/x.py"), ("@bob",))
        self.assertEqual(effective_owners(rules, "scripts/x.py"), ("@alice",))
        self.assertEqual(len({o for _, _, ro in rules for o in ro}), 2)

    def test_unsupported_pattern_shapes_are_refused(self):
        for pattern in ("scripts/", "*.py", "/scripts/*", "/docs/[r]eadme.md", "!/scripts/", "/scripts/**", "/a\\ b"):
            self.assertFalse(pattern_is_supported(pattern), pattern)
            with self.assertRaises(ValueError):
                pattern_matches(pattern, "scripts/x.py")

    def test_supported_pattern_shapes_match_as_github_does(self):
        self.assertTrue(pattern_matches("/scripts/", "scripts/ci/x.py"))
        self.assertFalse(pattern_matches("/scripts/", "Tests/scripts/x.py"))
        self.assertFalse(pattern_matches("/scripts/", "scripts-old/x.py"))
        self.assertTrue(pattern_matches("/AGENTS.md", "AGENTS.md"))
        self.assertFalse(pattern_matches("/AGENTS.md", "docs/AGENTS.md"))
        self.assertTrue(pattern_matches("/docs/runbooks", "docs/runbooks/x.md"))
        self.assertFalse(pattern_matches("/docs/runbooks", "docs/runbooks-old/x.md"))


if __name__ == "__main__":
    unittest.main()
