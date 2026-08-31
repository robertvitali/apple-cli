#!/usr/bin/env python3
"""Generate the `apple` command manual from the binary's own help dump.

The binary is the single source of truth: every command page, flag, and abstract
here comes from `apple --experimental-dump-help`, so the manual cannot drift from
what the CLI actually accepts. Hand-written prose (examples, extended notes) lives
in a sidecar keyed by command path and is merged in, so curation survives
regeneration.

    scripts/gen-manual.py                 # regenerate docs/manual/
    scripts/gen-manual.py --check         # fail if regenerating would change anything

`--check` is the CI gate: it makes "the docs match the binary" a testable claim
rather than a promise.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "manual"
SIDECAR = REPO / "docs" / "manual-prose.json"

# ---------------------------------------------------------------- help dump


def dump_help(binary: str) -> dict:
    proc = subprocess.run(
        [binary, "--experimental-dump-help"], capture_output=True, check=False
    )
    if proc.returncode != 0 or not proc.stdout:
        sys.exit(
            f"error: `{binary} --experimental-dump-help` failed "
            f"(exit {proc.returncode}). Build the binary first."
        )
    return json.loads(proc.stdout)["command"]


def walk(node: dict, path: tuple[str, ...] = ()):
    here = path + (node["commandName"],)
    yield here, node
    for sub in node.get("subcommands") or []:
        yield from walk(sub, here)


# ---------------------------------------------------------------- rendering


def flag_signature(arg: dict) -> str:
    """`-s`, `--long <value>` — the conventional CLI options rendering."""
    names = []
    for n in arg.get("names") or []:
        names.append(("-" if n["kind"] == "short" else "--") + n["name"])
    if not names:
        # positional
        return f"`<{arg.get('valueName', 'arg')}>`"
    sig = ", ".join(f"`{n}`" for n in names)
    if arg["kind"] == "option":
        sig += f" `<{arg.get('valueName', 'value')}>`"
    if arg.get("isRepeating"):
        sig += " *(repeatable)*"
    return sig


def usage_line(path: tuple[str, ...], node: dict, inherited: set[str]) -> str:
    parts = list(path)
    positionals = [
        a
        for a in node.get("arguments") or []
        if a["kind"] == "positional" and a.get("shouldDisplay", True)
    ]
    for p in positionals:
        name = p.get("valueName", "arg")
        token = f"<{name}>"
        if p.get("isRepeating"):
            token = f"<{name}>..."
        parts.append(token if not p.get("isOptional") else f"[{token}]")
    own = [
        a
        for a in node.get("arguments") or []
        if a["kind"] != "positional"
        and a.get("shouldDisplay", True)
        and key_of(a) not in inherited
    ]
    if own:
        parts.append("[flags]")
    return " ".join(parts)


def key_of(arg: dict) -> str:
    pref = arg.get("preferredName") or {}
    return f"{pref.get('kind', '')}:{pref.get('name', '')}"


def options_table(args: list[dict]) -> list[str]:
    out: list[str] = []
    for a in sorted(args, key=lambda x: (x.get("preferredName") or {}).get("name", "")):
        abstract = a.get("abstract", "").strip()
        out.append(f"- {flag_signature(a)}")
        if abstract:
            out.append(f"  <br>{abstract}")
    return out


def page_path(path: tuple[str, ...], has_children: bool) -> str:
    """Where a command's page lives, relative to docs_dir.

    A command WITH subcommands becomes `<dir>/index.md`, not `<dir>.md`. Emitting
    both `mail.md` and `mail/` makes MkDocs render two top-level nav entries for one
    domain -- the six apps came out as twelve tabs before this. Folding the parent
    into the directory's index gives exactly one tab per app.
    """
    if len(path) == 1:
        return "index.md"
    tail = "/".join(path[1:])
    return f"{tail}/index.md" if has_children else f"{tail}.md"


def rel_link(frm: str, to: str) -> str:
    """Relative link between two pages, both given as docs_dir-relative paths."""
    import posixpath
    rel = posixpath.relpath(to, posixpath.dirname(frm) or ".")
    return rel if rel.startswith(".") else f"./{rel}"


def render(path: tuple[str, ...], node: dict, inherited_keys: set[str],
           inherited_args: list[dict], prose: dict, tree: dict) -> str:
    name = " ".join(path)
    subs = [s for s in (node.get("subcommands") or []) if s.get("shouldDisplay", True)]
    args = [a for a in (node.get("arguments") or []) if a.get("shouldDisplay", True)]
    own = [a for a in args if key_of(a) not in inherited_keys]
    extra = prose.get(name, {})

    def has_kids(p: tuple[str, ...]) -> bool:
        return bool(tree.get(p))

    self_page = page_path(path, has_kids(path))

    # Nav label: the H1 is the full command ("apple mail"), which reads badly as a tab.
    # A short front-matter title gives MkDocs "Mail" while the page keeps its real name.
    L: list[str] = []
    if len(path) == 1:
        L += ["---", "title: Home", "---", ""]
    elif len(path) == 2:
        # Every top-level entry gets a short tab label, leaf or not — otherwise a
        # childless one like `version` renders as the tab "apple version" next to
        # siblings reading "Mail"/"Notes".
        L += ["---", f"title: {path[1].capitalize()}", "---", ""]

    # The root page is the site landing page, not a command reference page, so its
    # heading reads "Home" rather than the bare binary name — the site header already
    # carries the branding.
    L += ["# Home" if len(path) == 1 else f"# {name}", ""]
    if node.get("abstract"):
        L += [node["abstract"], ""]

    L += ["## Synopsis", "", "```", usage_line(path, node, inherited_keys), "```", ""]

    if extra.get("description"):
        L += ["## Description", "", extra["description"].strip(), ""]

    # List only children we actually EMIT a page for. Reading node["subcommands"]
    # directly would link to filtered-out commands (`help`), producing dead links.
    emitted = {c for c in tree.get(path, [])}
    children = [s for s in subs if (path + (s["commandName"],)) in emitted]
    if children:
        L += ["## Subcommands", ""]
        for s in sorted(children, key=lambda x: x["commandName"]):
            child = path + (s["commandName"],)
            target = page_path(child, has_kids(child))
            L.append(
                f"- [`{s['commandName']}`]({rel_link(self_page, target)}) — "
                f"{s.get('abstract', '').strip()}"
            )
        L.append("")

    if own:
        L += ["## Options", ""] + options_table(own) + [""]

    # Only list inherited options THIS command actually declares. The global list is
    # a >=90% threshold, so up to 10% of commands don't take them -- emitting it
    # unconditionally documented flags the binary rejects (`apple version --text`) on
    # 21 pages, which falsifies the whole "generated, therefore accurate" premise.
    # Take the arg objects from THIS node, not from a representative leaf. Sourcing
    # them from one sample leaf couples every page to that leaf: because
    # inherited_keys is a >=90% threshold, a key can be inherited yet absent from the
    # sample, in which case it is stripped from `own` on every page AND missing here,
    # so the flag is documented nowhere -- and --check stays green, because generator
    # and tree agree on the same wrong output.
    shown_inherited = [a for a in args if key_of(a) in inherited_keys]
    if shown_inherited:
        # The root command has no "inherited" anything -- its own flags ARE the
        # globals, so listing them under that heading would be wrong (and omitting
        # them entirely, as this did, left `apple --help`/`--version` undocumented).
        heading = "## Options" if len(path) == 1 else "## Inherited options"
        L += [heading, ""] + options_table(shown_inherited) + [""]

    if extra.get("examples"):
        L += ["## Examples", ""]
        for ex in extra["examples"]:
            if ex.get("title"):
                L.append(f"{ex['title']}")
                L.append("")
            L += ["```console", ex["command"].strip(), "```", ""]

    if extra.get("notes"):
        L += ["## Notes", "", extra["notes"].strip(), ""]

    jc = rel_link(self_page, "reference/json-contract.md")
    ec = rel_link(self_page, "reference/exit-codes.md")
    L += ["## Output", "",
          "`stdout` carries the JSON envelope; `stderr` carries human text. "
          f"See [the JSON contract]({jc}) and [exit codes]({ec}).", ""]

    # See also links the PARENT only. Listing every sibling buries the useful link
    # under 40 entries on a domain like mail; the parent page already indexes them.
    if len(path) > 1:
        parent = path[:-1]
        L += ["## See also", "",
              f"- [`{' '.join(parent)}`]"
              f"({rel_link(self_page, page_path(parent, True))})", ""]

    return "\n".join(L).rstrip() + "\n"


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", default=None, help="path to the apple binary")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if regenerating would change the tree")
    a = ap.parse_args()

    binary = a.binary
    if not binary:
        for cand in (REPO / ".build/release/apple", REPO / ".build/debug/apple"):
            if cand.exists():
                binary = str(cand)
                break
    if not binary:
        sys.exit("error: no apple binary found; run `swift build` first")

    root = dump_help(binary)
    nodes = [(p, n) for p, n in walk(root) if n.get("shouldDisplay", True)]
    nodes = [(p, n) for p, n in nodes if "help" not in p]

    leaves = [(p, n) for p, n in nodes if not (n.get("subcommands") or [])]
    # Inherited = options carried by nearly every leaf. Computed rather than
    # hardcoded, so a new global flag is picked up automatically. A strict
    # intersection is wrong here: outliers like `apple version` do not take the
    # global options and would collapse the set to just --help/--version.
    counts: dict[str, int] = {}
    for _, n in leaves:
        for x in n.get("arguments") or []:
            if x.get("shouldDisplay", True) and x["kind"] != "positional":
                counts[key_of(x)] = counts.get(key_of(x), 0) + 1
    threshold = 0.9 * len(leaves)
    inherited_keys = {k for k, c in counts.items() if c >= threshold}
    inherited_args = [
        x for x in (leaves[0][1].get("arguments") or [])
        if key_of(x) in inherited_keys
    ] if leaves else []

    tree: dict[tuple, list[tuple]] = {}
    for p, _ in nodes:
        tree.setdefault(p[:-1], []).append(p)

    prose = json.loads(SIDECAR.read_text()) if SIDECAR.exists() else {}

    staging = OUT.parent / (".manual-staging" if a.check else "manual")
    if a.check and staging.exists():
        shutil.rmtree(staging)
    elif not a.check and OUT.exists():
        shutil.rmtree(OUT)
    target = staging if a.check else OUT

    written = 0
    for p, n in nodes:
        page = render(p, n, inherited_keys, inherited_args, prose, tree)
        dest = target / page_path(p, bool(tree.get(p)))
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(page)
        written += 1

    # Hand-written standalone pages (getting started, the JSON contract, exit codes)
    # live OUTSIDE the generated tree and are copied in, because this script wipes
    # docs/manual/ on every run and would otherwise delete them.
    static = REPO / "docs" / "manual-static"
    copied = 0
    if static.exists():
        # Copy every file, not just markdown — the theme logo and any other assets
        # live here too, and the generated tree is wiped on each run.
        for src in sorted(p for p in static.rglob("*") if p.is_file()):
            dest = target / src.relative_to(static)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            copied += 1

    # Validate every relative link we just emitted. These are generated, so a dangling
    # one is a generator bug and should fail here rather than in a reader's browser.
    import re as _re
    broken: list[str] = []
    for md in sorted(target.rglob("*.md")):
        for m in _re.finditer(r"\]\((?!https?:)([^)#]+)\)", md.read_text()):
            if not (md.parent / m.group(1)).resolve().exists():
                broken.append(f"{md.relative_to(target)} -> {m.group(1)}")
    if broken:
        print(f"error: {len(broken)} dangling link(s) in the generated manual:")
        for b in broken[:20]:
            print(f"  {b}")
        if a.check:
            shutil.rmtree(target)
        return 2

    if a.check:
        diff = subprocess.run(
            ["diff", "-r", "-q", str(OUT), str(target)],
            capture_output=True, text=True,
        )
        shutil.rmtree(target)
        if diff.returncode != 0:
            print("manual is STALE — regenerate with scripts/gen-manual.py:\n")
            print(diff.stdout or diff.stderr)
            return 1
        print(f"manual up to date ({written} pages)")
        return 0

    print(f"wrote {written} pages to {OUT.relative_to(REPO)}")
    print(f"inherited options detected: "
          f"{sorted(k.split(':')[1] for k in inherited_keys)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
