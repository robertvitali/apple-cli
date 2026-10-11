#!/usr/bin/env python3
"""Read-only release-artifact rehearsal (design sections 14.1, 15.1 and 18 step 15).

The second half of the exact-SHA release rehearsal. `scripts/ci/release_prep.py` renders the
two predicted release files (the version constant and `CHANGELOG.md`) into a scratch
directory; this script builds the release binary from one exact candidate commit plus those
two files, packages it with the urgent-release runbook's recipe, and verifies the OUTCOME
(HUMAN-DECISIONS.md D18 step (4): a verified outcome, not a flag list). It uploads nothing,
creates no ref, and never prints or records anything that carries the predicted version.

    python3 -I -S -B scripts/ci/release_artifact.py --candidate-root <clean clone> \\
        --candidate-sha <40-hex> --overlay <release_prep scratch dir> --work <new dir> \\
        [--report <path.json>]

Exit status: 0 pass; 1 a checked condition failed (including a tool, git, filesystem or
timeout failure, or the wrong platform); 2 the request was refused before any work (argument
shape, path locations, an existing report). Every file this script writes is created new
(O_EXCL, no symlink follow) except the two overlay copies, which replace the content of the
already tracked, regular files of the private source clone under `--work`.

WHERE IT RUNS. The hosted `release-prep-rehearsal` job of `.github/workflows/docs.yml` is its
routine run. The job runs it only when release preparation rendered the two files, so the
release commit itself (nothing to release) is never built there. Running it on the operator's
Mac is a native release build and needs an operator grant (HUMAN-DECISIONS D23); it is not a
"runs freely" rehearsal. The recipe (the runbook's `-Xswiftc -gnone`; no strip, no re-sign,
no prefix maps), the linkage rule and the path-prefix classes below are the project's
PROVISIONAL definitions pending HUMAN-DECISIONS D51.

WHAT IT WRITES. Its outputs (the source clone, the build tree, SwiftPM's cache, configuration
and fingerprint store, the pinned binary, the archive and the checksum file) all go under
`--work`; `prepare_work` creates `--work` and any missing parent directories of it, and if the
run is refused afterwards it removes only the `--work` directory it created, leaving those
parent directories in place. What can still be written outside it: whatever the toolchain itself
writes under HOME, which is passed through and never isolated (Xcode 26 mounts its Metal
toolchain disk image under an isolated HOME and a later recursive delete then fails; see
scripts/ci/quality.py, remove_temporary_root), and the toolchain's transient files under TMPDIR,
which is the caller's own (SwiftPM's manifest sandbox and every hosted build so far run with the
system temporary directory, so it is not redirected). On a hosted runner the machine is
discarded.

Steps, in order. Each fails closed, and a failed step leaves every later check `not-run`:

1.  Request checks (exit 2): `--candidate-sha` is a full lowercase SHA; `--candidate-root` is
    a directory; `--overlay` is a real directory; `--work` is not a symlink, is either absent
    (created 0700, with any missing parents) or an empty directory not writable by group or
    other; containment is compared by file identity wherever the path exists (by spelling only
    for a part that does not exist yet): none of `--work`, the candidate root and the overlay
    lies inside another, and `--report` (release preparation's rule: not a symlink, not
    existing yet) lies outside the candidate, `--work` and the overlay, the `--work` case
    checked again once `--work` exists.
2.  `checkout`: the candidate root is a clean checkout whose HEAD is `--candidate-sha`
    (release preparation's hardened git runner and check).
3.  `overlay`: walked with `lstat`, never following a link, the overlay holds exactly the two
    allowlisted files as regular files and only the directories that hold them; its version
    constant is exactly one strict MAJOR.MINOR.PATCH (kept in memory only), and release
    preparation's drift gate holds on the two rendered texts. The bytes validated here are the
    bytes step 6 writes; the overlay is not read a second time.
4.  `platform`: Darwin on arm64.
5.  `no-write-path` (below).
6.  `change-set`: the candidate is cloned into `<work>/src` and checked out detached at the
    SHA, the two overlay files replace their tracked counterparts, and `git status` must then
    list exactly those two paths as modified, once each, and nothing else: the rendered
    change set is exactly the two allowlisted files and both differ from HEAD. Residual: this
    does not show that generated documentation needs no change (design section 14.2's third
    file class).
7.  `deployment-minimum`: exactly one `.macOS(.vNN)` / `.macOS(.vNN_M)` inside the
    `platforms:` argument of `Package.swift` names the expected deployment minimum.
8.  `build`: `/usr/bin/swift build -c release --disable-automatic-resolution -Xswiftc -gnone`
    with SwiftPM's `--cache-path`, `--config-path` and `--security-path` under `<work>/swiftpm`
    and `--disable-netrc` and `--disable-keychain`, then the identical flags plus
    `--show-bin-path`; `.build` must be a real directory and the binary a regular file inside
    it. The build's process group is then killed and the binary's bytes are pinned to
    `<work>/verify/apple` (0755); every later check, the packaging included, works on that
    pinned copy.
9.  Binary checks, all run before the group can fail: `version` (the binary run with an
    empty environment prints exactly the predicted version and a line feed); `macho` (a pure
    Python Mach-O reader walks the file without finding a malformation, and the load commands
    fill `sizeofcmds` exactly); `architecture` (a thin 64-bit little-endian arm64 MH_EXECUTE
    with CPU_SUBTYPE_ARM64_ALL, and `lipo -archs` agrees); `deployment-target` (one
    LC_BUILD_VERSION, platform macOS, minos equal to step 7, no LC_VERSION_MIN_MACOSX);
    `linkage` (below; `otool -L`'s list must pass the same dylib-name rule and equal the
    reader's, in order); `debug-map` (no N_OSO entry, and `nm -ap`, read to the end, agrees);
    `signature` (an LC_CODE_SIGNATURE and `codesign --verify` exit 0); `paths` (none of the
    path-prefix classes below in the bytes).
10. `package`: the runbook's tar line (`--uid 0 --gid 0 --uname '' --gname '' --no-xattrs
    --no-acls --no-fflags`, COPYFILE_DISABLE=1) run on `<work>/verify` into `<work>/out`;
    afterwards the pinned copy must still hold the bytes the reader saw.
11. Archive checks, all run: `archive-stream` (exactly one complete gzip member, capped
    decompressed size); `archive-members` (one regular member `apple`, mode 0755, uid 0, gid
    0, empty owner names, no link name, no PAX key but `mtime`, no global PAX header; and a
    raw walk of the 512-byte records: at most one per-file PAX header, holding at least one
    record, its records well formed (a length of at most 20 digits) and naming only `mtime`
    with a decimal value, its padding zero, then one regular-file header named `apple`, its
    data and zero padding, at least two zero records and only zero bytes to the end, every
    header checksum verified, offset and size agreeing with tarfile's); `archive-roundtrip`
    (the member's bytes equal the pinned binary); `paths` again over the compressed and
    decompressed bytes (with no decompressed stream, `paths` records only a hit and otherwise
    stays `not-run`).
12. `checksum`: `shasum -a 256` writes the checksum file, which must be exactly one line of
    64 lowercase hex digits, two spaces, the archive name and a line feed, matching an
    independent digest; `shasum -a 256 -c` must accept it.
13. `candidate-untouched`: step 2's check again.

NO-WRITE-PATH. What the check covers, exactly: the process environment carries none of
GITHUB_TOKEN, GH_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN, GITHUB_PAT,
ACTIONS_RUNTIME_TOKEN, ACTIONS_ID_TOKEN_REQUEST_TOKEN, ACTIONS_ID_TOKEN_REQUEST_URL, and no
GIT_CONFIG_COUNT, GIT_CONFIG_KEY_<n>, GIT_CONFIG_VALUE_<n> or GIT_CONFIG_PARAMETERS; and the git
configuration (the `--local` scope, plus the worktree configuration file whenever one exists,
whatever `extensions.worktreeConfig` says, includes followed per file) of the candidate, and of
every repository that a `remote.*.url` or `remote.*.pushurl` value names when that value is a
local directory (in CI the checkout in GITHUB_WORKSPACE), holds no `http.(*.)extraheader`,
`credential.*`, `core.askpass` or `core.sshcommand` key and no key or value with URL userinfo
(`scheme://...@`). Values are read but never printed. A local remote path that does not exist is
skipped (nothing there can carry a credential); one that exists but cannot be read fails closed.
Remote values are classified as written: `url.<base>.insteadOf` and `url.<base>.pushInsteadOf`
rewrites are not applied, so a network URL that such a rewrite would turn into a local path is
not inspected. The build itself runs with GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1 and
GIT_TERMINAL_PROMPT=0, so SwiftPM's dependency fetch cannot use a credential helper, an
insteadOf rewrite or a global hook, and SwiftPM itself runs with `--disable-netrc` and
`--disable-keychain`; HOME is passed through, so git's own fetch can still read `~/.netrc` and
`~/.ssh`. The build performs no push. The report's `outward_writes: []` records that THIS SCRIPT
performs no outward write; the actual bound on outward writes is the workflow (`contents: read`,
`persist-credentials: false`, no secrets, the static workflow scan of
scripts/ci/workflow_policy.py). This tool does not by itself satisfy design step 15's "refusal
of any outward-write step" (HUMAN-DECISIONS D51).

LINKAGE. Design section 15.1 asks that "checksum, architecture, linkage, and runtime version
agree" without defining linkage. This script is the project's provisional DEFINITION of it
(HUMAN-DECISIONS D51): every dylib load command (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB) names an absolute path that
starts with `/usr/lib/` or `/System/Library/`, none starts with `@` and none contains `/../`;
at least one dylib is linked; the dynamic linker is exactly `/usr/lib/dyld`; there is no
LC_DYLD_ENVIRONMENT; and every LC_RPATH path is exactly `@loader_path` or `@executable_path`,
or an absolute path with no `..` segment under `/usr/lib/`, `/System/Library/`,
`/Library/Developer/CommandLineTools/` or `/Applications/Xcode*.app/Contents/Developer/`. The
dylib-name rule is applied twice, independently: to the Mach-O reader's list and to
`otool -L`'s list. Those LC_RPATH entries are permitted because SwiftPM adds `@loader_path`
and toolchain paths to every executable, and because no load command may name an `@rpath/`
path, dyld never consults them for the binary's own dependencies. Residual, stated rather than
implied: dyld also consults the main executable's LC_RPATH entries for an `@rpath/` dependency
of ANY image loaded into the process (a library's own `@rpath/` dependency, or a runtime
`dlopen`), not only for the binary's own; the product's sources make no `dlopen` call (checked
2026-10-10), and this check does not prove that for future code. The
`/Applications/Xcode*.app` root is writable by the admin group, unlike the other permitted
roots. An rpath under a home or temporary prefix fails this rule (it is outside the
permitted set); one under a prefix `paths` scans for also fails that check, independently.

PATHS. The provisional path-prefix classes (HUMAN-DECISIONS D51) are `/Users/`,
`/private/tmp/`, `/var/folders/`, `/home/` and `/var/tmp/`, scanned in the binary, the
compressed archive and the decompressed tar stream. `/Volumes/` and a bare `/tmp/` are
deliberately absent: the product's own help text contains `/Volumes/`, and its Messages
attachment guard compares paths against the literal `/tmp/`. The hosted `paths` check is
neither D18 step (4)'s check on the published artifact nor D34's operator-local denylist scan.

NEVER PRINTED OR RECORDED: the predicted version, the archive name (it embeds the version), any
digest of the binary, the archive or the checksum file, and any byte size (design section 14.1:
a digest over a handful of candidate versions is reversed by enumeration; provisional,
HUMAN-DECISIONS D51). Failure messages name the check and a value-free reason; the path scan
names the prefix class, a count and the Mach-O section holding each hit, never the bytes that
matched; a linkage failure names a dylib or rpath only when it fully matches a safe shape
(`@rpath/<name>.dylib`, or a path under `/usr/`, `/System/`, `/Library/Developer/` or
`/Applications/Xcode` spelled with `[A-Za-z0-9_.+/-]` only, with no `.` or `..` segment, no `//`
and no path-prefix class) and otherwise counts it. An argument the parser rejects is reported as
one fixed line, never echoed. Every line written to stderr passes one redactor: the predicted
version, every run of 40 or more hex digits, the work, candidate and overlay paths (and their
`/private` forms, matched case-insensitively), HOME (case-insensitively and only at a path
boundary) and then the name after any remaining `/Users/` or `/home/` (in any case) are
replaced, and control characters are escaped. The report is the pass result, the candidate SHA,
the allowlist and one status per check. THE WORK DIRECTORY HOLDS THE BINARY, THE ARCHIVE AND THE
CHECKSUM FILE, WHICH CARRY THE VERSION: it is working material, never an artifact, never
evidence, never uploaded.

BUILD-LOG RELAY. On a build failure no free text from the build log is printed. At most the
last 256 KiB is read (a partial first line is dropped) and split on line feeds and carriage
returns. A compiler diagnostic `<path>:<line>:<col>: error:` whose path lies inside
`<work>/src`, both as spelled and once symlinks are resolved, and whose path relative to it is
spelled with `[A-Za-z0-9_.+-]` segments with, after normalisation, no `.` or `..` segment (a raw
`..` is never printed), is printed as `release-artifact: build | <relative path>:<line>:<col>:
error` (the message dropped), at most the last 20 distinct ones; every other line containing
`error:` is only counted, in one line, by a class decided by keyword (dependency fetch or
resolution, linker, manifest, other) and never echoed. Every printed line still passes the
redactor, so the top claim above holds for everything this script prints. On a pull request
the proposal could print anything through its own copy of this script anyway.

What this cannot prove: the toolchain itself (`swift`, the linker, `tar`, `shasum`, the xcrun
shims behind `lipo`, `otool` and `nm`) runs with the caller's privileges, and the build fetches
the pinned dependency over the network; the checks bind the outcome, not the tools. On a pull
request the proposal's own copy of this script runs, so it is a smoke check there.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import platform as _platform
import re
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import zlib
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional, Sequence, TextIO, Tuple
from urllib.parse import unquote, urlsplit

_SPEC = importlib.util.spec_from_file_location("release_prep", Path(__file__).with_name("release_prep.py"))
_RELEASE_PREP = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(_RELEASE_PREP)

# Reused from release preparation, never copied: the error classes, the hardened git runner,
# the checkout check, the drift gate, the path and report helpers, and the allowlist and its
# patterns.
PolicyError = _RELEASE_PREP.PolicyError
AssertionFailure = _RELEASE_PREP.AssertionFailure
GitError = _RELEASE_PREP.GitError
run_git = _RELEASE_PREP.run_git
full_sha = _RELEASE_PREP.full_sha
validate_checkout = _RELEASE_PREP.validate_checkout
drift_gate = _RELEASE_PREP.drift_gate
resolve_outside = _RELEASE_PREP.resolve_outside
write_report = _RELEASE_PREP.write_report
POLICY_ROOT = _RELEASE_PREP.POLICY_ROOT
FULL_SHA_RE = _RELEASE_PREP.FULL_SHA_RE
VERSION_RE = _RELEASE_PREP.VERSION_RE
CONSTANT_RE = _RELEASE_PREP.CONSTANT_RE
CONSTANT_PATH = _RELEASE_PREP.CONSTANT_PATH
CHANGELOG_PATH = _RELEASE_PREP.CHANGELOG_PATH
ALLOWLIST = _RELEASE_PREP.ALLOWLIST
POLICY_FAILURE_STATUS = _RELEASE_PREP.POLICY_FAILURE_STATUS
ASSERTION_FAILURE_STATUS = _RELEASE_PREP.ASSERTION_FAILURE_STATUS

GitRunner = Callable[[Sequence[str], Path], str]
Failure = Tuple[str, str]  # (value-free reason, failure class)

REPORT_SCHEMA_VERSION = 1
PASS = "pass"
FAIL = "fail"
NOT_RUN = "not-run"

# Every check the report carries, in the order the rehearsal runs them.
CHECK_NAMES: Tuple[str, ...] = (
    "checkout",
    "overlay",
    "platform",
    "no-write-path",
    "change-set",
    "deployment-minimum",
    "build",
    "version",
    "macho",
    "architecture",
    "deployment-target",
    "linkage",
    "debug-map",
    "signature",
    "paths",
    "package",
    "archive-stream",
    "archive-members",
    "archive-roundtrip",
    "checksum",
    "candidate-untouched",
)
BINARY_CHECKS: Tuple[str, ...] = (
    "version", "macho", "architecture", "deployment-target", "linkage", "debug-map", "signature",
)
ARCHIVE_CHECKS: Tuple[str, ...] = ("archive-stream", "archive-members", "archive-roundtrip")

IO = "io"
GIT = "git"
PLATFORM = "platform"
ASSERTION = "assertion"
TIMEOUT = "timeout"
TOOL = "tool"
FAILURE_CLASSES: Tuple[str, ...] = (IO, GIT, PLATFORM, ASSERTION, TIMEOUT, TOOL)

REPORT_NOTE = (
    "digests, sizes and the archive name are withheld because the binary embeds the unassigned "
    "version (design section 14.1: a digest over a handful of candidate versions is reversed by "
    "enumeration; provisional, HUMAN-DECISIONS D51); the binary, archive and checksum file exist "
    "only under the work directory, "
    "and nothing was uploaded; outward_writes records that this script performs no outward "
    "write, while the bound on outward writes is the workflow (contents: read, "
    "persist-credentials: false, no secrets, the static workflow scan)"
)

TOKEN_VARIABLES: Tuple[str, ...] = (
    "GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GITHUB_PAT",
    "ACTIONS_RUNTIME_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
)
GIT_CONFIG_VARIABLE_RE = re.compile(r"^GIT_CONFIG_(?:COUNT|PARAMETERS|KEY_.*|VALUE_.*)$", re.S)
CREDENTIAL_KEY_RES = (
    re.compile(r"^http\.(?:.*\.)?extraheader$", re.I | re.S),
    re.compile(r"^credential\.", re.I),
    re.compile(r"^core\.askpass$", re.I),
    re.compile(r"^core\.sshcommand$", re.I),
)
USERINFO_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^/?#\s@]*@")
REMOTE_URL_KEY_RE = re.compile(r"^remote\..+\.(?:url|pushurl)$", re.I | re.S)

SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
PASSTHROUGH_VARIABLES: Tuple[str, ...] = ("HOME", "TMPDIR", "DEVELOPER_DIR")
SWIFT = "/usr/bin/swift"
LIPO = "/usr/bin/lipo"
OTOOL = "/usr/bin/otool"
NM = "/usr/bin/nm"
CODESIGN = "/usr/bin/codesign"
TAR = "/usr/bin/tar"
SHASUM = "/usr/bin/shasum"
BUILD_ARGUMENTS: Tuple[str, ...] = ("build", "-c", "release", "--disable-automatic-resolution", "-Xswiftc", "-gnone")
SWIFTPM_CREDENTIAL_FLAGS: Tuple[str, ...] = ("--disable-netrc", "--disable-keychain")
TAR_FLAGS: Tuple[str, ...] = ("--uid", "0", "--gid", "0", "--uname", "", "--gname", "", "--no-xattrs", "--no-acls",
                              "--no-fflags")
BINARY_NAME = "apple"
BINARY_MODE = 0o755
BUILD_TIMEOUT_SECONDS = 1800
SHOW_BIN_PATH_TIMEOUT_SECONDS = 120
VERSION_TIMEOUT_SECONDS = 30
TOOL_TIMEOUT_SECONDS = 120
PACKAGE_TIMEOUT_SECONDS = 120

MAX_OVERLAY_ENTRIES = 64
MAX_TEXT_BYTES = 16 * 1024 * 1024
MAX_BINARY_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_DECOMPRESSED_BYTES = 512 * 1024 * 1024
MAX_CHECKSUM_FILE_BYTES = 4096
BUILD_LOG_TAIL_BYTES = 256 * 1024
BUILD_LOG_MAX_LINES = 20

PATH_PREFIXES: Tuple[bytes, ...] = (b"/Users/", b"/private/tmp/", b"/var/folders/", b"/home/", b"/var/tmp/")

PLATFORMS_LIST_RE = re.compile(r"platforms\s*:\s*\[([^\]]*)\]")
MACOS_ENTRY_RE = re.compile(r"\.macOS\(")
MACOS_STRICT_RE = re.compile(r"\.macOS\(\s*\.v([1-9][0-9]*)(?:_([0-9]+))?\s*\)")
OTOOL_LINE_RE = re.compile(r"\t(.+) \(compatibility version [^()]*\)")

HEX_RUN_RE = re.compile(r"[0-9A-Fa-f]{40,}")
USERS_NAME_RE = re.compile(r"/(Users|home)/[^/\s]+", re.IGNORECASE)
PAX_LENGTH_RE = re.compile(rb"[1-9][0-9]{0,19}")
PAX_MTIME_RE = re.compile(rb"-?[0-9]{1,20}(?:\.[0-9]{1,9})?")
HOME_BOUNDARY = r"(?=/|$|[^A-Za-z0-9._-])"
COMPILER_ERROR_RE = re.compile(r"^(?P<path>[^:\n]+):(?P<line>[0-9]{1,7}):(?P<col>[0-9]{1,7}): error:")
SAFE_RELATIVE_PATH_RE = re.compile(r"[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*")
MAX_RELATIVE_PATH_LENGTH = 255
# Fixed classes for build-log error lines that are counted, never echoed; decided by keyword only.
ERROR_LINE_CLASSES: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    ("dependency fetch or resolution", ("fetch", "resolv", "clone", "repository", "package.resolved")),
    ("linker", ("linker command failed",)),
    ("manifest", ("package.swift", "manifest")),
)
OTHER_ERROR_LINE_CLASS = "other"
# The linker's own `ld:` prefix, as a word: a substring test would also class `build:` as linker.
LINKER_PREFIX_RE = re.compile(r"(?<![a-z0-9_.-])ld:")
CONTROL_CHARACTER_RE = re.compile("[\x00-\x1f\x7f-\x9f\u2028\u2029]")

SAFE_RPATH_DYLIB_RE = re.compile(r"@rpath/[A-Za-z0-9_.+-]+\.dylib")
SAFE_PATH_RE = re.compile(r"[A-Za-z0-9_.+/-]{1,256}")
SAFE_PATH_PREFIXES = ("/usr/", "/System/", "/Library/Developer/", "/Applications/Xcode")
SAFE_SECTION_NAME_RE = re.compile(r"[A-Za-z0-9_.$]{1,16}")

# Mach-O constants (mach-o/loader.h, mach-o/fat.h, mach-o/stab.h).
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MAGICS_32 = (0xFEEDFACE, 0xCEFAEDFE)
FAT_MAGICS = (0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA)
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_ARM64_ALL = 0
MH_EXECUTE = 2
MACH_HEADER_64_SIZE = 32
LC_SYMTAB = 0x02
LC_LOAD_DYLIB = 0x0C
LC_LOAD_DYLINKER = 0x0E
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LAZY_LOAD_DYLIB = 0x20
LC_VERSION_MIN_MACOSX = 0x24
LC_DYLD_ENVIRONMENT = 0x27
LC_BUILD_VERSION = 0x32
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001C
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB)
SEGMENT_COMMAND_64_SIZE = 72
SECTION_64_SIZE = 80
ZEROFILL_SECTION_TYPES = (0x01, 0x0C, 0x12)  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
PLATFORM_MACOS = 1
NLIST_64_SIZE = 16
N_OSO = 0x66
SYSTEM_DYLIB_PREFIXES = ("/usr/lib/", "/System/Library/")
DYLINKER = "/usr/lib/dyld"
# Run-path entries an executable may carry: exactly one of these tokens, or an absolute path
# with no `..` segment under one of these roots (provisional, HUMAN-DECISIONS D51).
PERMITTED_RPATH_TOKENS = ("@loader_path", "@executable_path")
PERMITTED_RPATH_ROOTS = ("/usr/lib/", "/System/Library/", "/Library/Developer/CommandLineTools/")
XCODE_RPATH_RE = re.compile(r"/Applications/Xcode[^/]*\.app/Contents/Developer/")

TAR_BLOCK_SIZE = 512
ZERO_BLOCK = b"\0" * TAR_BLOCK_SIZE


class StepFailure(Exception):
    """A checked condition that failed; names the check, a value-free reason and a class."""

    def __init__(self, check: str, reason: str, failure_class: str = ASSERTION) -> None:
        super().__init__(reason)
        self.check = check
        self.reason = reason
        self.failure_class = failure_class


class Request:
    """A request that passed every step-1 check; every path is resolved."""

    def __init__(self, candidate_root: Path, candidate_sha: str, overlay: Path, work: Path,
                 report_path: Optional[Path] = None) -> None:
        self.candidate_root = candidate_root
        self.candidate_sha = candidate_sha
        self.overlay = overlay
        self.work = work
        self.report_path = report_path


class Ledger:
    """One status per check name; reasons and failure classes for the failed ones. A failed
    check never moves back to pass."""

    def __init__(self) -> None:
        self.status: Dict[str, str] = {name: NOT_RUN for name in CHECK_NAMES}
        self.reasons: Dict[str, List[str]] = {}
        self.classes: Dict[str, str] = {}

    def record(self, name: str, failures: Optional[Sequence[Failure]]) -> None:
        """None leaves the check as it is; an empty list passes it unless it already failed;
        anything else fails it."""
        if name not in self.status:
            raise KeyError(name)
        if failures is None:
            return
        if not failures:
            if self.status[name] != FAIL:
                self.status[name] = PASS
            return
        self.status[name] = FAIL
        self.reasons.setdefault(name, []).extend(reason for reason, _ in failures)
        self.classes.setdefault(name, failures[0][1])

    def passed(self, name: str) -> None:
        self.record(name, [])

    def fail(self, name: str, reason: str, failure_class: str) -> None:
        self.record(name, [(reason, failure_class)])

    def any_failed(self, names: Sequence[str]) -> bool:
        return any(self.status[name] == FAIL for name in names)

    def all_passed(self) -> bool:
        return all(status == PASS for status in self.status.values())

    def failure_class(self) -> str:
        for name in CHECK_NAMES:
            if self.status[name] == FAIL:
                return self.classes.get(name, ASSERTION)
        return ASSERTION


# --- redaction -------------------------------------------------------------------------------

def escape_controls(text: str) -> str:
    """Escape C0 controls (tab included), DEL, C1 controls (U+0085 included), U+2028, U+2029."""
    def replace(match: "re.Match[str]") -> str:
        code = ord(match.group(0))
        return "\\u{:04x}".format(code) if code > 0xFF else "\\x{:02x}".format(code)
    return CONTROL_CHARACTER_RE.sub(replace, text)


def _path_forms(path: str) -> List[str]:
    forms = [path]
    if path.startswith("/private/"):
        forms.append(path[len("/private"):])
    elif path.startswith("/"):
        forms.append("/private" + path)
    return forms


class Redactor:
    """The one redactor every human-facing line passes through. `version` is set once the
    overlay has been read. Path spellings are matched case-insensitively, HOME only at a path
    boundary, longest first; the name after any remaining `/Users/` or `/home/` (in any case)
    is then replaced."""

    def __init__(self, paths: Optional[Mapping[str, Path]] = None, home: Optional[str] = None) -> None:
        self.version: Optional[str] = None
        self._patterns: List[Tuple[int, "re.Pattern[str]", str]] = []
        for placeholder, path in (paths or {}).items():
            for form in _path_forms(str(path)):
                self._add(form, placeholder, "")
        if home is not None:
            stripped = home.rstrip("/")
            if len(stripped) > 1:
                for form in _path_forms(stripped):
                    self._add(form, "~", HOME_BOUNDARY)

    def _add(self, needle: str, replacement: str, suffix: str) -> None:
        if needle:
            self._patterns.append((len(needle), re.compile(re.escape(needle) + suffix, re.IGNORECASE), replacement))

    def redact(self, text: str) -> str:
        patterns = list(self._patterns)
        if self.version:
            patterns.append((len(self.version), re.compile(re.escape(self.version)), "<predicted version>"))
        for _length, pattern, replacement in sorted(patterns, key=lambda item: item[0], reverse=True):
            text = pattern.sub(lambda _match, value=replacement: value, text)
        text = HEX_RUN_RE.sub("<hex>", text)
        return USERS_NAME_RE.sub(
            lambda match: "/Users/<user>" if match.group(1).lower() == "users" else "/home/<user>", text)

    def __call__(self, text: str) -> str:
        return escape_controls(self.redact(text))


# --- external programs -----------------------------------------------------------------------

class ProcessResult:
    """What a child process did. `returncode` is None when it could not be started."""

    def __init__(self, returncode: Optional[int], stdout: bytes = b"", stderr: bytes = b"",
                 timed_out: bool = False, spawn_error: Optional[str] = None) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.timed_out = timed_out
        self.spawn_error = spawn_error


def _create_log(path: Path) -> int:
    return os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)


def _kill_group(process: "subprocess.Popen[bytes]") -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:  # ESRCH: the group is already gone
        pass


def run_process(command: Sequence[str], cwd: Path, environment: Mapping[str, str], timeout: float,
                output_log: Optional[Path] = None, error_log: Optional[Path] = None,
                merge_error: bool = False, kill_group_after: bool = False) -> ProcessResult:
    """Run `command` with stdin from /dev/null in its own process group.

    stdout goes to `output_log` (created new) or is captured; stderr goes to `error_log`, to the
    same place as stdout (`merge_error`), or is captured. On timeout the WHOLE group is killed
    and the result says so; with `kill_group_after` any straggler of the group is also killed
    after a normal exit."""
    descriptors: List[int] = []
    try:
        stdout_target = subprocess.PIPE  # type: object
        stderr_target = subprocess.PIPE  # type: object
        if output_log is not None:
            descriptors.append(_create_log(output_log))
            stdout_target = descriptors[-1]
        if merge_error:
            stderr_target = subprocess.STDOUT
        elif error_log is not None:
            descriptors.append(_create_log(error_log))
            stderr_target = descriptors[-1]
        process = subprocess.Popen(
            list(command),
            cwd=str(cwd),
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=stdout_target,
            stderr=stderr_target,
            start_new_session=True,
        )
    except OSError as error:
        return ProcessResult(None, spawn_error=error.__class__.__name__)
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            # A descendant left the group and holds a pipe open: stop reading and reap the child.
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
            process.wait()
            stdout, stderr = b"", b""
        return ProcessResult(process.returncode, stdout or b"", stderr or b"", timed_out=True)
    if kill_group_after:
        _kill_group(process)
    return ProcessResult(process.returncode, stdout or b"", stderr or b"")


def swiftpm_arguments(work: Path) -> List[str]:
    """The release build's flags; show-bin-path must use the identical set."""
    state = work / "swiftpm"
    return [*BUILD_ARGUMENTS, "--cache-path", str(state / "cache"), "--config-path", str(state / "config"),
            "--security-path", str(state / "security"), *SWIFTPM_CREDENTIAL_FLAGS]


class Tools:
    """Every external program and every host fact the rehearsal consults.

    The CLI builds this real one (absolute paths under /usr/bin); tests subclass it and
    override methods, so the orchestration can run end to end with fakes. There is no CLI flag
    that swaps tools."""

    def __init__(self, environ: Optional[Mapping[str, str]] = None,
                 build_timeout: float = BUILD_TIMEOUT_SECONDS,
                 show_bin_path_timeout: float = SHOW_BIN_PATH_TIMEOUT_SECONDS,
                 version_timeout: float = VERSION_TIMEOUT_SECONDS,
                 tool_timeout: float = TOOL_TIMEOUT_SECONDS,
                 package_timeout: float = PACKAGE_TIMEOUT_SECONDS) -> None:
        self.environ: Dict[str, str] = dict(os.environ if environ is None else environ)
        self.build_timeout = build_timeout
        self.show_bin_path_timeout = show_bin_path_timeout
        self.version_timeout = version_timeout
        self.tool_timeout = tool_timeout
        self.package_timeout = package_timeout

    # host facts
    def host(self) -> Tuple[str, str]:
        return _platform.system(), os.uname().machine

    def environment(self) -> Dict[str, str]:
        return dict(self.environ)

    def build_environment(self) -> Dict[str, str]:
        # HOME and TMPDIR are passed through, never isolated (see the module docstring). Git
        # configuration outside the repository is shut off so SwiftPM's dependency fetch cannot
        # use a credential helper, an insteadOf rewrite or a global hook.
        environment = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}
        for name in PASSTHROUGH_VARIABLES:
            if name in self.environ:
                environment[name] = self.environ[name]
        return environment

    # programs
    def swift_build(self, source: Path, work: Path, log_path: Path) -> ProcessResult:
        return run_process([SWIFT, *swiftpm_arguments(work)], source, self.build_environment(), self.build_timeout,
                           output_log=log_path, merge_error=True, kill_group_after=True)

    def show_bin_path(self, source: Path, work: Path, log_path: Path) -> ProcessResult:
        return run_process([SWIFT, *swiftpm_arguments(work), "--show-bin-path"], source, self.build_environment(),
                           self.show_bin_path_timeout, error_log=log_path, kill_group_after=True)

    def run_version(self, binary: Path, cwd: Path) -> ProcessResult:
        return run_process([str(binary), "--version"], cwd, {}, self.version_timeout, kill_group_after=True)

    def lipo_archs(self, binary: Path) -> ProcessResult:
        return run_process([LIPO, "-archs", str(binary)], binary.parent, self.build_environment(), self.tool_timeout)

    def otool_libraries(self, binary: Path) -> ProcessResult:
        return run_process([OTOOL, "-L", str(binary)], binary.parent, self.build_environment(), self.tool_timeout)

    def nm_symbols(self, binary: Path) -> ProcessResult:
        # Captured whole, never through an early-exit pipe (Tests/automation/
        # test_urgent_release_runbook.py, RecordedPackagingCheckReadsToTheEnd).
        return run_process([NM, "-ap", str(binary)], binary.parent, self.build_environment(), self.tool_timeout)

    def codesign_verify(self, binary: Path) -> ProcessResult:
        return run_process([CODESIGN, "--verify", str(binary)], binary.parent, self.build_environment(),
                           self.tool_timeout)

    def package(self, bindir: Path, archive: Path) -> ProcessResult:
        command = [TAR, *TAR_FLAGS, "-C", str(bindir), "-czf", str(archive), BINARY_NAME]
        environment = {"COPYFILE_DISABLE": "1", "PATH": SYSTEM_PATH, "LC_ALL": "C"}
        return run_process(command, archive.parent, environment, self.package_timeout)

    def checksum(self, out: Path, name: str) -> ProcessResult:
        return run_process([SHASUM, "-a", "256", name], out, {"PATH": SYSTEM_PATH, "LC_ALL": "C"},
                           self.tool_timeout)

    def checksum_verify(self, out: Path, checksum_name: str) -> ProcessResult:
        return run_process([SHASUM, "-a", "256", "-c", checksum_name], out, {"PATH": SYSTEM_PATH, "LC_ALL": "C"},
                           self.tool_timeout)


def process_failure(result: ProcessResult, label: str, verdict: bool = False) -> Optional[Failure]:
    """A value-free failure for a process that did not exit 0, or None. With `verdict`, a
    non-zero exit is the check's own negative answer (an assertion), not a tool failure."""
    if result.spawn_error is not None or result.returncode is None:
        return ("{} could not be started".format(label), TOOL)
    if result.timed_out:
        return ("{} did not finish in time and was killed".format(label), TIMEOUT)
    if result.returncode != 0:
        return ("{} exited {}".format(label, result.returncode), ASSERTION if verdict else TOOL)
    return None


# --- filesystem helpers ----------------------------------------------------------------------

def inside(path: Path, root: Path) -> bool:
    """True when `path`, or one of its existing ancestors, IS `root` by file identity (device
    and inode), so a case-varied spelling on a case-insensitive volume or a symlinked alias is
    still caught wherever the path exists. When `root` does not exist, nothing can be inside it
    except its own spelling."""
    try:
        root_info = os.stat(str(root))
    except OSError:
        return path == root or root in path.parents
    for step in (path,) + tuple(path.parents):
        try:
            step_info = os.stat(str(step))
        except OSError:
            continue  # a part that does not exist yet
        if os.path.samestat(step_info, root_info):
            return True
    return False


def read_regular(path: Path, cap: int, check: str) -> bytes:
    """Read a regular file without following a final symlink; refuse one larger than `cap`."""
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise StepFailure(check, "an input is not a regular file")
        data = handle.read(cap + 1)
    if len(data) > cap:
        raise StepFailure(check, "an input is larger than the recorded cap")
    return data


def create_bytes(path: Path, data: bytes, mode: Optional[int] = None) -> None:
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
        if mode is not None:
            os.fchmod(handle.fileno(), mode)


def prepare_work(work: Path) -> bool:
    """Require an empty, private directory; create it (0700), and any missing parent
    directories, only when absent. Returns whether this call created it."""
    if os.path.lexists(str(work)):
        info = os.lstat(str(work))
        if not stat.S_ISDIR(info.st_mode):
            raise PolicyError("--work must be a real directory")
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise PolicyError("--work must not be group- or world-writable")
        if os.listdir(str(work)):
            raise PolicyError("--work must be empty")
        return False
    work.mkdir(parents=True, mode=0o700)
    return True


# --- step 1: request -------------------------------------------------------------------------

def resolve_request(candidate_root_arg: Path, candidate_sha_arg: Optional[str], overlay_arg: Path,
                    work_arg: Path, report_arg: Optional[Path]) -> Request:
    candidate_sha = full_sha(candidate_sha_arg, "--candidate-sha")
    candidate_root = candidate_root_arg.expanduser().resolve()
    if not candidate_root.is_dir():
        raise PolicyError("--candidate-root must be a directory")
    overlay_path = overlay_arg.expanduser()
    if overlay_path.is_symlink() or not overlay_path.is_dir():
        raise PolicyError("--overlay must be a real directory, not a symlink")
    overlay = overlay_path.resolve()
    if inside(overlay, candidate_root):
        raise PolicyError("--overlay must lie outside the candidate root")
    if inside(candidate_root, overlay):
        raise PolicyError("the candidate root must not lie inside --overlay")
    work_path = work_arg.expanduser()
    if work_path.is_symlink():
        raise PolicyError("--work must not be a symlink")
    work = work_path.resolve()
    for label, other in (("the candidate root", candidate_root), ("the overlay", overlay)):
        if inside(work, other):
            raise PolicyError("--work must lie outside {}".format(label))
        if inside(other, work):
            raise PolicyError("{} must not lie inside --work".format(label))
    report_path = None
    if report_arg is not None:
        report_path = resolve_outside(report_arg, candidate_root, "--report")
        if inside(report_path, candidate_root):
            raise PolicyError("--report must lie outside the candidate root")
        if inside(report_path, work) or inside(report_path, overlay):
            raise PolicyError("--report must lie outside --work and the overlay")
        if report_path.exists() or report_path.is_symlink():
            raise PolicyError("--report must name a file that does not exist yet")
    created = prepare_work(work)
    if report_path is not None and inside(report_path, work):
        # Before --work existed only its spelling could be compared; now its identity can.
        if created:
            try:
                os.rmdir(str(work))  # removes it only while it is still empty
            except OSError:
                pass
        raise PolicyError("--report must lie outside --work and the overlay")
    return Request(candidate_root, candidate_sha, overlay, work, report_path)


# --- steps 2 to 7 ----------------------------------------------------------------------------

def check_checkout(root: Path, candidate_sha: str, git: GitRunner, check: str) -> None:
    """release_prep.validate_checkout, reported under `check` (a wrong root is a failed check
    here, not a refusal: the request was already accepted)."""
    try:
        validate_checkout(root, candidate_sha, git)
    except (AssertionFailure, PolicyError) as error:
        raise StepFailure(check, str(error)) from error


def expected_overlay() -> Dict[str, str]:
    entries: Dict[str, str] = {}
    for path in ALLOWLIST:
        for parent in reversed(list(path.parents)[:-1]):  # Path.parents slicing needs 3.10
            entries[parent.as_posix()] = "dir"
        entries[path.as_posix()] = "file"
    return entries


def overlay_entries(root: Path) -> Dict[str, str]:
    found: Dict[str, str] = {}
    pending = [""]
    while pending:
        relative = pending.pop()
        directory = os.path.join(str(root), relative) if relative else str(root)
        for name in sorted(os.listdir(directory)):
            child = name if not relative else relative + "/" + name
            mode = os.lstat(os.path.join(str(root), child)).st_mode
            if stat.S_ISDIR(mode):
                found[child] = "dir"
                pending.append(child)
            elif stat.S_ISREG(mode):
                found[child] = "file"
            else:
                found[child] = "other"
            if len(found) > MAX_OVERLAY_ENTRIES:
                raise StepFailure("overlay", "the overlay holds more entries than the allowlist could explain")
    return found


def _decode(data: bytes, check: str, label: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise StepFailure(check, "the {} is not UTF-8".format(label)) from error


def _read_text(path: Path, check: str, label: str) -> str:
    return _decode(read_regular(path, MAX_TEXT_BYTES, check), check, label)


def read_overlay(overlay: Path) -> Tuple[str, Dict[Path, bytes]]:
    """Check the overlay's shape and drift gate. Returns its version (in memory, never printed)
    and the two validated byte strings, which are what `assemble_source` writes."""
    expected = expected_overlay()
    found = overlay_entries(overlay)
    missing = sorted(name for name in expected if name not in found)
    unexpected = [name for name in found if name not in expected]
    wrong_kind = [name for name in expected if name in found and found[name] != expected[name]]
    reasons = []
    if missing:
        reasons.append("{} allowlisted entr{} missing ({})".format(
            len(missing), "y is" if len(missing) == 1 else "ies are", ", ".join(missing)))
    if unexpected:
        reasons.append("{} entr{} outside the allowlist".format(len(unexpected), "y" if len(unexpected) == 1 else "ies"))
    if wrong_kind:
        reasons.append("{} allowlisted entr{} not a regular file or directory as expected".format(
            len(wrong_kind), "y is" if len(wrong_kind) == 1 else "ies are"))
    if reasons:
        raise StepFailure("overlay", "; ".join(reasons))
    constant_bytes = read_regular(overlay / CONSTANT_PATH, MAX_TEXT_BYTES, "overlay")
    changelog_bytes = read_regular(overlay / CHANGELOG_PATH, MAX_TEXT_BYTES, "overlay")
    source = _decode(constant_bytes, "overlay", "overlay version constant file")
    matches = list(CONSTANT_RE.finditer(source))
    if len(matches) != 1:
        raise StepFailure("overlay", "expected exactly one version constant in the overlay, found {}".format(len(matches)))
    version = matches[0].group(2)
    if VERSION_RE.fullmatch(version) is None:
        raise StepFailure("overlay", "the overlay version constant is not strict MAJOR.MINOR.PATCH")
    changelog = _decode(changelog_bytes, "overlay", "overlay CHANGELOG")
    try:
        drift_gate(source, changelog, version)
    except AssertionFailure as error:
        raise StepFailure("overlay", str(error)) from error
    return version, {CONSTANT_PATH: constant_bytes, CHANGELOG_PATH: changelog_bytes}


def check_platform(tools: Tools) -> None:
    system, machine = tools.host()
    if system != "Darwin" or machine != "arm64":
        raise StepFailure("platform", "the release binary is built only on Darwin arm64", PLATFORM)


def _config_listing(git: GitRunner, root: Path, *scope: str) -> List[Tuple[str, str]]:
    output = git(["config", *scope, "--includes", "--null", "--list"], root)
    entries = []
    for record in output.split("\0"):
        if record:
            key, _, value = record.partition("\n")
            entries.append((key, value))
    return entries


def config_entries(git: GitRunner, root: Path) -> List[Tuple[str, str]]:
    """`root`'s `--local` git configuration, includes followed, as (key, value) pairs, united
    with its worktree configuration file (`config.worktree`, located with `git rev-parse
    --git-path`) whenever that file exists, whatever `extensions.worktreeConfig` says. Git reads
    the file only when the extension is on, by its own boolean rules; reading it regardless can
    only add entries, never hide one. The file is listed with `git config --file`, which also
    works in a repository with linked worktrees, where `git config --worktree` is refused while
    the extension is off. Includes are followed per file, as listed. Any git failure is raised."""
    local = _config_listing(git, root, "--local")
    location = git(["rev-parse", "--git-path", "config.worktree"], root).strip()
    path = Path(location) if os.path.isabs(location) else root / location
    worktree: List[Tuple[str, str]] = []
    if os.path.lexists(str(path)):
        try:
            worktree = _config_listing(git, root, "--file", str(path))
        except GitError as error:  # the message would otherwise carry the file's path
            raise GitError("git config --file <worktree configuration> failed") from error
    entries: List[Tuple[str, str]] = []
    for entry in local + worktree:
        if entry not in entries:
            entries.append(entry)
    return entries


def credential_hits(entries: Sequence[Tuple[str, str]]) -> int:
    hits = 0
    for key, value in entries:
        if any(pattern.match(key) for pattern in CREDENTIAL_KEY_RES) or USERINFO_RE.search(key) or USERINFO_RE.search(value):
            hits += 1
    return hits


def local_directory(url: str, candidate_root: Path) -> Optional[Path]:
    """The local directory a remote URL names, or None for a remote that is not a local path
    (a network URL or an scp-like `host:path`)."""
    if not url:
        return None
    if "://" in url:
        parts = urlsplit(url)
        if parts.scheme.lower() != "file" or parts.netloc not in ("", "localhost"):
            return None
        return Path(unquote(parts.path))
    if url.startswith("/"):
        return Path(url)
    colon, slash = url.find(":"), url.find("/")
    if colon > 0 and (slash < 0 or colon < slash):
        return None  # scp-like syntax
    return candidate_root / url


def local_remote_directories(entries: Sequence[Tuple[str, str]], candidate_root: Path) -> List[Path]:
    """Every local directory a `remote.*.url` or `remote.*.pushurl` value names, in order."""
    directories: List[Path] = []
    for key, value in entries:
        if REMOTE_URL_KEY_RE.match(key):
            directory = local_directory(value, candidate_root)
            if directory is not None and directory not in directories:
                directories.append(directory)
    return directories


def check_no_write_path(environment: Mapping[str, str], candidate_root: Path, git: GitRunner) -> None:
    present = sorted(name for name in environment if name in TOKEN_VARIABLES or GIT_CONFIG_VARIABLE_RE.match(name))
    if present:
        raise StepFailure("no-write-path", "the environment carries {}".format(", ".join(present)))
    entries = config_entries(git, candidate_root)
    reasons = []
    hits = credential_hits(entries)
    if hits:
        reasons.append("the candidate's local git configuration carries {} credential-bearing entr{}".format(
            hits, "y" if hits == 1 else "ies"))
    remote_hits = 0
    for directory in local_remote_directories(entries, candidate_root):
        try:
            directory_info = os.stat(str(directory))
        except FileNotFoundError:
            continue  # a local remote path that does not exist cannot carry a credential
        except OSError as error:
            raise StepFailure("no-write-path", "a local remote's directory cannot be read") from error
        if not stat.S_ISDIR(directory_info.st_mode):
            raise StepFailure("no-write-path", "a local remote is not a directory")
        try:
            remote_hits += credential_hits(config_entries(git, directory))
        except GitError as error:
            raise StepFailure("no-write-path", "the git configuration of a local remote cannot be read") from error
    if remote_hits:
        reasons.append("the local remotes' git configuration carries {} credential-bearing entr{}".format(
            remote_hits, "y" if remote_hits == 1 else "ies"))
    if reasons:
        raise StepFailure("no-write-path", "; ".join(reasons))


def _require_real_directories(source: Path, relative: Path) -> None:
    current = source
    for part in relative.parent.parts:
        current = current / part
        try:
            mode = os.lstat(str(current)).st_mode
        except FileNotFoundError as error:
            raise StepFailure("change-set", "a predicted file has no tracked counterpart in the candidate") from error
        if not stat.S_ISDIR(mode):
            raise StepFailure("change-set", "a directory on a predicted file's path is not a real directory")


def copy_overlay_file(data: bytes, source: Path, relative: Path) -> None:
    _require_real_directories(source, relative)
    target = source / relative
    try:
        mode = os.lstat(str(target)).st_mode
    except FileNotFoundError as error:
        raise StepFailure("change-set", "a predicted file has no tracked counterpart in the candidate") from error
    if not stat.S_ISREG(mode):
        raise StepFailure("change-set", "a predicted file's counterpart in the candidate is not a regular file")
    descriptor = os.open(str(target), os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def assemble_source(candidate_root: Path, candidate_sha: str, overlay_files: Mapping[Path, bytes], work: Path,
                    git: GitRunner) -> Path:
    source = work / "src"
    git(["clone", "--quiet", "--no-hardlinks", "--no-checkout", "--", str(candidate_root), str(source)], work)
    git(["checkout", "--quiet", "--detach", candidate_sha], source)
    if git(["rev-parse", "HEAD"], source).strip() != candidate_sha:
        raise StepFailure("change-set", "the source clone's HEAD does not equal --candidate-sha")
    for relative in ALLOWLIST:
        copy_overlay_file(overlay_files[relative], source, relative)
    status = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], source)
    entries = [entry for entry in status.split("\0") if entry]
    expected = [" M " + path.as_posix() for path in ALLOWLIST]
    unchanged = [entry for entry in expected if entry not in entries]
    unexpected = [entry for entry in entries if entry not in expected]
    reasons = []
    if unchanged:
        reasons.append("{} predicted file{} unchanged".format(len(unchanged), " is" if len(unchanged) == 1 else "s are"))
    if unexpected:
        reasons.append("{} status entr{} outside the predicted change set".format(
            len(unexpected), "y" if len(unexpected) == 1 else "ies"))
    if len(entries) != len(set(entries)):
        reasons.append("a status entry is listed more than once")
    if reasons:
        raise StepFailure("change-set", "; ".join(reasons))
    return source


def expected_minimum(package_swift: str) -> Tuple[int, int, int]:
    """The deployment minimum named by the one `.macOS(...)` inside `platforms: [...]`."""
    bodies = [match.group(1) for match in PLATFORMS_LIST_RE.finditer(package_swift)]
    entries = sum(len(MACOS_ENTRY_RE.findall(body)) for body in bodies)
    if entries != 1:
        raise StepFailure("deployment-minimum",
                          "expected exactly one .macOS(...) inside platforms:, found {}".format(entries))
    strict = [match for body in bodies for match in MACOS_STRICT_RE.finditer(body)]
    if len(strict) != 1:
        raise StepFailure("deployment-minimum", "the .macOS(...) entry is not of the form .vNN or .vNN_M")
    major = int(strict[0].group(1))
    minor = int(strict[0].group(2)) if strict[0].group(2) is not None else 0
    return major, minor, 0


# --- step 8: build ---------------------------------------------------------------------------

def source_relative_path(raw: str, source: Path) -> Optional[str]:
    """A compiler-reported path, relative to the source clone, when it lies inside it (as spelled
    and once symlinks are resolved) and is spelled safely; None otherwise (the line is then only
    counted)."""
    if ".." in raw.split("/"):
        return None
    normalized = os.path.normpath(raw if raw.startswith("/") else os.path.join(str(source), raw))
    for base in _path_forms(str(source)):
        prefix = base.rstrip("/") + "/"
        if normalized.startswith(prefix):
            relative = normalized[len(prefix):]
            break
    else:
        return None
    if len(relative) > MAX_RELATIVE_PATH_LENGTH or SAFE_RELATIVE_PATH_RE.fullmatch(relative) is None:
        return None
    if any(segment in (".", "..") for segment in relative.split("/")):
        return None
    # The lexical checks above do not see symlinks: a link inside the clone may point outside it.
    if not os.path.realpath(normalized).startswith(os.path.realpath(str(source)).rstrip("/") + "/"):
        return None
    return relative


def classify_error_line(line: str) -> str:
    lowered = line.lower()
    for name, keywords in ERROR_LINE_CLASSES:
        if any(keyword in lowered for keyword in keywords) or (name == "linker" and LINKER_PREFIX_RE.search(lowered)):
            return name
    return OTHER_ERROR_LINE_CLASS


def build_error_lines(path: Path, source: Path) -> List[str]:
    """A value-free classification of a failed build log (module docstring, BUILD-LOG RELAY):
    safe compiler locations, then one line of counts by class. No free text is echoed."""
    try:
        descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return ["release-artifact: build | the build log could not be read"]
    with os.fdopen(descriptor, "rb") as handle:
        size = os.fstat(handle.fileno()).st_size
        start = max(0, size - BUILD_LOG_TAIL_BYTES)
        handle.seek(start)
        text = handle.read(BUILD_LOG_TAIL_BYTES).decode("utf-8", "replace")
    lines = re.split(r"[\r\n]", text)
    if start > 0 and lines:
        lines = lines[1:]  # the read began inside a line
    located: List[str] = []
    counts = {name: 0 for name, _ in ERROR_LINE_CLASSES}
    counts[OTHER_ERROR_LINE_CLASS] = 0
    for line in lines:
        match = COMPILER_ERROR_RE.match(line)
        if match is not None:
            relative = source_relative_path(match.group("path"), source)
            if relative is not None:
                entry = "{}:{}:{}: error".format(relative, match.group("line"), match.group("col"))
                if entry in located:
                    located.remove(entry)
                located.append(entry)
                continue
        if "error:" in line:
            counts[classify_error_line(line)] += 1
    output = ["release-artifact: build | " + entry for entry in located[-BUILD_LOG_MAX_LINES:]]
    if any(counts.values()):
        output.append("release-artifact: build | other error lines by class: " + ", ".join(
            "{} {}".format(name, counts[name]) for name in list(counts)))
    if not output:
        return ["release-artifact: build | no compiler error line was found in the build log"]
    return output


def build_binary(tools: Tools, source: Path, work: Path, emit: Callable[[str], None]) -> Path:
    """Build, locate and return the binary inside the source clone's build tree."""
    for directory in (work / "logs", work / "swiftpm", work / "swiftpm" / "cache", work / "swiftpm" / "config",
                      work / "swiftpm" / "security"):
        directory.mkdir(mode=0o700)
    build_log = work / "logs" / "swift-build.log"
    emit("release-artifact: building the release binary; output goes to <work>/logs/swift-build.log")
    failure = process_failure(tools.swift_build(source, work, build_log), "swift build")
    if failure is not None:
        for line in build_error_lines(build_log, source):
            emit(line)
        raise StepFailure("build", failure[0], failure[1])
    bin_log = work / "logs" / "swift-show-bin-path.log"
    result = tools.show_bin_path(source, work, bin_log)
    failure = process_failure(result, "swift build --show-bin-path")
    if failure is not None:
        for line in build_error_lines(bin_log, source):
            emit(line)
        raise StepFailure("build", failure[0], failure[1])
    try:
        text = result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise StepFailure("build", "--show-bin-path printed something other than one path") from error
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != 1 or not lines[0].startswith("/"):
        raise StepFailure("build", "--show-bin-path printed something other than one absolute path")
    try:
        build_mode = os.lstat(str(source / ".build")).st_mode
    except FileNotFoundError as error:
        raise StepFailure("build", "the source clone has no .build directory") from error
    if not stat.S_ISDIR(build_mode):
        raise StepFailure("build", "the source clone's .build is not a real directory")
    binary = Path(lines[0]) / BINARY_NAME
    try:
        mode = os.lstat(str(binary)).st_mode
    except FileNotFoundError as error:
        raise StepFailure("build", "the build produced no binary at the reported path") from error
    if not stat.S_ISREG(mode):
        raise StepFailure("build", "the built binary is not a regular file")
    real = Path(os.path.realpath(str(binary)))
    build_root = Path(os.path.realpath(str(source))) / ".build"
    if build_root not in real.parents:
        raise StepFailure("build", "the built binary lies outside the source clone's .build tree")
    return real


def pin_binary(binary: Path, work: Path) -> Tuple[Path, bytes]:
    """Copy the built bytes to `<work>/verify/apple` (0755); every later check uses the copy."""
    data = read_regular(binary, MAX_BINARY_BYTES, "build")
    verify = work / "verify"
    verify.mkdir(mode=0o700)
    pinned = verify / BINARY_NAME
    create_bytes(pinned, data, BINARY_MODE)
    return pinned, data


# --- step 9: Mach-O reader and binary checks -------------------------------------------------

class MachOError(Exception):
    """A malformation found while walking a thin 64-bit Mach-O."""


class MachOInfo:
    """What the reader learned. `walked` is false when the header is not a thin 64-bit
    little-endian Mach-O (nothing further can be read); `malformed` names a malformation."""

    def __init__(self) -> None:
        self.header_reasons: List[str] = []
        self.arch_ok = False
        self.walked = False
        self.malformed: Optional[str] = None
        self.build_versions: List[Tuple[int, Tuple[int, int, int]]] = []
        self.version_min_count = 0
        self.dylibs: List[str] = []
        self.rpaths: List[str] = []
        self.dyld_environment_count = 0
        self.dylinkers: List[str] = []
        self.symtab_count = 0
        self.oso_count = 0
        self.code_signature = False
        self.sections: List[Tuple[str, int, int]] = []  # (label, file offset, size)


def _need(command: bytes, size: int, label: str) -> None:
    if len(command) < size:
        raise MachOError("{} is shorter than its fixed fields".format(label))


def _lc_str(command: bytes, field: int, minimum: int, label: str) -> str:
    (offset,) = struct.unpack_from("<I", command, field)
    if offset < minimum or offset >= len(command):
        raise MachOError("{} string offset is out of bounds".format(label))
    end = command.find(b"\0", offset)
    if end < 0:
        raise MachOError("{} string is not terminated inside its command".format(label))
    return command[offset:end].decode("utf-8", "surrogateescape")


def _section_label(segment: bytes, section: bytes) -> str:
    names = [raw.split(b"\0", 1)[0].decode("ascii", "replace") for raw in (segment, section)]
    if all(SAFE_SECTION_NAME_RE.fullmatch(name) for name in names):
        return "{},{}".format(*names)
    return "an unnamed section"


def _read_segment(data: bytes, command: bytes, info: MachOInfo) -> None:
    _need(command, SEGMENT_COMMAND_64_SIZE, "LC_SEGMENT_64")
    (nsects,) = struct.unpack_from("<I", command, 64)
    if SEGMENT_COMMAND_64_SIZE + nsects * SECTION_64_SIZE > len(command):
        raise MachOError("LC_SEGMENT_64 section list runs past its command")
    for index in range(nsects):
        base = SEGMENT_COMMAND_64_SIZE + index * SECTION_64_SIZE
        sectname, segname = command[base:base + 16], command[base + 16:base + 32]
        (size,) = struct.unpack_from("<Q", command, base + 40)
        (offset,) = struct.unpack_from("<I", command, base + 48)
        (flags,) = struct.unpack_from("<I", command, base + 64)
        if flags & 0xFF in ZEROFILL_SECTION_TYPES or offset == 0:
            continue  # no file content
        if offset + size > len(data):
            raise MachOError("a section runs past the end of the file")
        info.sections.append((_section_label(segname, sectname), offset, size))


def _read_command(data: bytes, cmd: int, command: bytes, info: MachOInfo) -> None:
    if cmd == LC_BUILD_VERSION:
        _need(command, 24, "LC_BUILD_VERSION")
        platform_id, minos, _sdk, ntools = struct.unpack_from("<IIII", command, 8)
        if 24 + ntools * 8 > len(command):
            raise MachOError("LC_BUILD_VERSION tool list runs past its command")
        info.build_versions.append((platform_id, (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)))
    elif cmd == LC_VERSION_MIN_MACOSX:
        _need(command, 16, "LC_VERSION_MIN_MACOSX")
        info.version_min_count += 1
    elif cmd in DYLIB_COMMANDS:
        _need(command, 24, "a dylib command")
        info.dylibs.append(_lc_str(command, 8, 24, "a dylib command"))
    elif cmd == LC_RPATH:
        _need(command, 12, "LC_RPATH")
        info.rpaths.append(_lc_str(command, 8, 12, "LC_RPATH"))
    elif cmd == LC_DYLD_ENVIRONMENT:
        _need(command, 12, "LC_DYLD_ENVIRONMENT")
        _lc_str(command, 8, 12, "LC_DYLD_ENVIRONMENT")
        info.dyld_environment_count += 1
    elif cmd == LC_LOAD_DYLINKER:
        _need(command, 12, "LC_LOAD_DYLINKER")
        info.dylinkers.append(_lc_str(command, 8, 12, "LC_LOAD_DYLINKER"))
    elif cmd == LC_SEGMENT_64:
        _read_segment(data, command, info)
    elif cmd == LC_SYMTAB:
        _need(command, 24, "LC_SYMTAB")
        symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", command, 8)
        info.symtab_count += 1
        if info.symtab_count > 1:
            raise MachOError("more than one LC_SYMTAB")
        if symoff + nsyms * NLIST_64_SIZE > len(data):
            raise MachOError("the symbol table runs past the end of the file")
        if stroff + strsize > len(data):
            raise MachOError("the string table runs past the end of the file")
        # n_type is the byte at offset 4 of each 16-byte nlist_64 entry.
        info.oso_count = data[symoff + 4: symoff + nsyms * NLIST_64_SIZE: NLIST_64_SIZE].count(N_OSO)
    elif cmd == LC_CODE_SIGNATURE:
        _need(command, 16, "LC_CODE_SIGNATURE")
        dataoff, datasize = struct.unpack_from("<II", command, 8)
        if dataoff + datasize > len(data):
            raise MachOError("the code signature runs past the end of the file")
        info.code_signature = True


def _walk(data: bytes, info: MachOInfo) -> None:
    _magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from("<IIIIIIII", data, 0)
    if cputype != CPU_TYPE_ARM64:
        info.header_reasons.append("the CPU type is not arm64")
    elif cpusubtype & CPU_SUBTYPE_MASK != CPU_SUBTYPE_ARM64_ALL:
        info.header_reasons.append("the CPU subtype is not CPU_SUBTYPE_ARM64_ALL")
    else:
        info.arch_ok = True
    if filetype != MH_EXECUTE:
        info.header_reasons.append("the file type is not an executable (MH_EXECUTE)")
    end = MACH_HEADER_64_SIZE + sizeofcmds
    if end > len(data):
        raise MachOError("the load commands run past the end of the file")
    offset = MACH_HEADER_64_SIZE
    for index in range(ncmds):
        if offset + 8 > end:
            raise MachOError("load command {} starts past sizeofcmds".format(index))
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or cmdsize % 8:
            raise MachOError("load command {} has an invalid cmdsize".format(index))
        if offset + cmdsize > end:
            raise MachOError("load command {} runs past sizeofcmds".format(index))
        _read_command(data, cmd, data[offset:offset + cmdsize], info)
        offset += cmdsize
    if offset != end:
        raise MachOError("the load commands do not fill sizeofcmds exactly")


def read_macho(data: bytes) -> MachOInfo:
    """Read a Mach-O image. Never raises: a malformation is recorded, not thrown."""
    info = MachOInfo()
    if len(data) < 4:
        info.header_reasons.append("the file is too short to be a Mach-O file")
        return info
    (magic,) = struct.unpack_from("<I", data, 0)
    if magic in FAT_MAGICS:
        info.header_reasons.append("a universal (FAT) binary, not a thin arm64 Mach-O")
        return info
    if magic in MAGICS_32:
        info.header_reasons.append("a 32-bit Mach-O, not a 64-bit one")
        return info
    if magic == MH_CIGAM_64:
        info.header_reasons.append("a big-endian Mach-O, not a little-endian one")
        return info
    if magic != MH_MAGIC_64:
        info.header_reasons.append("not a Mach-O file")
        return info
    info.walked = True
    if len(data) < MACH_HEADER_64_SIZE:
        info.header_reasons.append("the Mach-O header is truncated")
        info.malformed = "the Mach-O header is truncated"
        return info
    try:
        _walk(data, info)
    except MachOError as error:
        info.malformed = str(error)
    except (struct.error, IndexError, ValueError, OverflowError) as error:  # bounds are checked first
        info.malformed = "the Mach-O reader could not read the file ({})".format(error.__class__.__name__)
    return info


def printable_name(name: str) -> bool:
    """A dylib or rpath name that may be printed: it fully matches a safe shape and holds no
    `.` or `..` segment, no `//` and no path-prefix class."""
    segments = name.split("/")
    if "//" in name or "." in segments or ".." in segments:
        return False
    if any(prefix.decode("ascii").lower() in name.lower() for prefix in PATH_PREFIXES):
        return False
    if SAFE_RPATH_DYLIB_RE.fullmatch(name):
        return True
    return name.startswith(SAFE_PATH_PREFIXES) and SAFE_PATH_RE.fullmatch(name) is not None


def describe_names(names: Sequence[str]) -> str:
    shown = [name for name in names if printable_name(name)][:5]
    hidden = len(names) - len(shown)
    parts = shown + (["{} other(s) not shown".format(hidden)] if hidden else [])
    return " ({})".format(", ".join(parts)) if parts else ""


def dylib_name_failures(names: Sequence[str], source: str) -> List[Failure]:
    """The dylib-name half of the linkage DEFINITION, applied to one reader's list."""
    failures: List[Failure] = []
    if not names:
        failures.append(("{}: no dylib is linked".format(source), ASSERTION))
    outside = [name for name in names if not name.startswith(SYSTEM_DYLIB_PREFIXES)]
    at_paths = [name for name in names if name.startswith("@")]
    parents = [name for name in names if "/../" in name]
    if outside:
        failures.append(("{}: {} dylib(s) outside /usr/lib/ and /System/Library/{}".format(
            source, len(outside), describe_names(outside)), ASSERTION))
    if at_paths:
        failures.append(("{}: {} dylib(s) named through an @ path{}".format(
            source, len(at_paths), describe_names(at_paths)), ASSERTION))
    if parents:
        failures.append(("{}: {} dylib(s) with /../ in the path{}".format(
            source, len(parents), describe_names(parents)), ASSERTION))
    return failures


def rpath_permitted(path: str) -> bool:
    """Exactly @loader_path or @executable_path, or an absolute path with no `..` segment
    under a permitted root."""
    if path in PERMITTED_RPATH_TOKENS:
        return True
    if not path.startswith("/") or ".." in path.split("/"):
        return False
    return path.startswith(PERMITTED_RPATH_ROOTS) or XCODE_RPATH_RE.match(path) is not None


def macho_findings(info: MachOInfo, expected_minos: Tuple[int, int, int]) -> Dict[str, Optional[List[Failure]]]:
    """The reader's own verdicts; None marks a check the reader could not evaluate."""
    findings: Dict[str, Optional[List[Failure]]] = {}
    architecture = [(reason, ASSERTION) for reason in info.header_reasons]
    if not info.arch_ok and not architecture:
        architecture.append(("the Mach-O header could not be read", ASSERTION))
    findings["architecture"] = architecture
    for name in ("macho", "deployment-target", "linkage", "debug-map"):
        findings[name] = None
    if not info.walked:
        return findings
    if info.malformed is not None:
        findings["macho"] = [(info.malformed, ASSERTION)]
        return findings
    findings["macho"] = []

    target: List[Failure] = []
    if len(info.build_versions) != 1:
        target.append(("expected exactly one LC_BUILD_VERSION, found {}".format(len(info.build_versions)), ASSERTION))
    else:
        platform_id, minos = info.build_versions[0]
        if platform_id != PLATFORM_MACOS:
            target.append(("the build platform is not macOS", ASSERTION))
        if minos != expected_minos:
            target.append(("minos {}.{}.{} does not equal the Package.swift minimum {}.{}.{}".format(
                *(minos + expected_minos)), ASSERTION))
    if info.version_min_count:
        target.append(("LC_VERSION_MIN_MACOSX is present", ASSERTION))
    findings["deployment-target"] = target

    linkage = dylib_name_failures(info.dylibs, "the Mach-O reader")
    loose = [path for path in info.rpaths if not rpath_permitted(path)]
    if loose:
        linkage.append(("{} LC_RPATH entr{} outside the permitted set{}".format(
            len(loose), "y" if len(loose) == 1 else "ies", describe_names(loose)), ASSERTION))
    if info.dyld_environment_count:
        linkage.append(("{} LC_DYLD_ENVIRONMENT entr{}".format(
            info.dyld_environment_count, "y" if info.dyld_environment_count == 1 else "ies"), ASSERTION))
    if info.dylinkers != [DYLINKER]:
        linkage.append(("the dynamic linker is not exactly {} ({} LC_LOAD_DYLINKER)".format(
            DYLINKER, len(info.dylinkers)), ASSERTION))
    findings["linkage"] = linkage

    findings["debug-map"] = (
        [("{} debug-map (N_OSO) entr{}".format(info.oso_count, "y" if info.oso_count == 1 else "ies"), ASSERTION)]
        if info.oso_count else []
    )
    return findings


def parse_otool(output: bytes, binary: Path) -> Optional[List[str]]:
    lines = output.decode("utf-8", "surrogateescape").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0] != str(binary) + ":":
        return None
    names = []
    for line in lines[1:]:
        if line == "":
            continue
        match = OTOOL_LINE_RE.fullmatch(line)
        if match is None:
            return None
        names.append(match.group(1))
    return names


def count_oso_lines(output: bytes) -> int:
    return sum(1 for line in output.split(b"\n") if b" OSO " in line)


def check_version(tools: Tools, binary: Path, cwd: Path, version: str) -> List[Failure]:
    result = tools.run_version(binary, cwd)
    if result.spawn_error is not None or result.returncode is None:
        return [("the binary could not be started", TOOL)]
    if result.timed_out:
        return [("the binary's --version did not finish in time and was killed", TIMEOUT)]
    failures: List[Failure] = []
    if result.returncode != 0:
        failures.append(("the binary's --version exited {}".format(result.returncode), ASSERTION))
    if result.stdout != (version + "\n").encode("ascii"):
        failures.append(("the binary's --version output is not the predicted version and one line feed", ASSERTION))
    if result.stderr:
        failures.append(("the binary's --version wrote to stderr", ASSERTION))
    return failures


def binary_checks(tools: Tools, binary: Path, data: bytes, cwd: Path, version: str,
                  expected_minos: Tuple[int, int, int],
                  info: Optional[MachOInfo] = None) -> Dict[str, Optional[List[Failure]]]:
    """Every step-9 check except `paths`: the reader's verdicts plus independent tools, each
    of which must pass and agree with the reader."""
    results: Dict[str, Optional[List[Failure]]] = {"version": check_version(tools, binary, cwd, version)}
    if info is None:
        info = read_macho(data)
    findings = macho_findings(info, expected_minos)
    results.update(findings)

    architecture = list(findings["architecture"] or [])
    lipo = tools.lipo_archs(binary)
    failure = process_failure(lipo, "lipo -archs")
    if failure is not None:
        architecture.append(failure)
    else:
        lipo_ok = lipo.stdout.decode("ascii", "replace").split() == ["arm64"]
        if not lipo_ok:
            architecture.append(("lipo -archs does not report exactly arm64", ASSERTION))
        if lipo_ok != info.arch_ok:
            architecture.append(("lipo and the Mach-O reader disagree on the architecture", ASSERTION))
    results["architecture"] = architecture

    linkage = findings["linkage"]
    if linkage is not None:
        linkage = list(linkage)
        otool = tools.otool_libraries(binary)
        failure = process_failure(otool, "otool -L")
        if failure is not None:
            linkage.append(failure)
        else:
            listed = parse_otool(otool.stdout, binary)
            if listed is None:
                linkage.append(("otool -L output is unparseable", ASSERTION))
            else:
                linkage.extend(dylib_name_failures(listed, "otool -L"))
                if listed != info.dylibs:
                    linkage.append(("otool -L and the Mach-O reader list different dylibs", ASSERTION))
        results["linkage"] = linkage

    debug_map = findings["debug-map"]
    if debug_map is not None:
        debug_map = list(debug_map)
        nm = tools.nm_symbols(binary)
        failure = process_failure(nm, "nm -ap")
        if failure is not None:
            debug_map.append(failure)
        else:
            count = count_oso_lines(nm.stdout)
            if count:
                debug_map.append(("nm -ap reports {} debug-map (N_OSO) entr{}".format(count, "y" if count == 1 else "ies"),
                                  ASSERTION))
            if count != info.oso_count:
                debug_map.append(("nm -ap and the Mach-O reader disagree on the debug-map count", ASSERTION))
        results["debug-map"] = debug_map

    signature: List[Failure] = []
    if info.walked and info.malformed is None and not info.code_signature:
        signature.append(("no LC_CODE_SIGNATURE load command", ASSERTION))
    failure = process_failure(tools.codesign_verify(binary), "codesign --verify", verdict=True)
    if failure is not None:
        signature.append(failure)
    results["signature"] = signature
    return results


def _occurrences(data: bytes, needle: bytes) -> List[int]:
    found = []
    position = data.find(needle)
    while position >= 0:
        found.append(position)
        position = data.find(needle, position + len(needle))
    return found


def path_hits(surfaces: Sequence[Tuple[str, bytes]],
              sections: Optional[Sequence[Tuple[str, int, int]]] = None) -> List[str]:
    """One value-free reason per surface and prefix class found: a count and, for the surface
    labelled `binary`, the Mach-O section holding each hit. Never the matched bytes."""
    reasons = []
    for label, data in surfaces:
        for prefix in PATH_PREFIXES:
            offsets = _occurrences(data, prefix)
            if not offsets:
                continue
            detail = ""
            if label == "binary":
                places: Dict[str, int] = {}
                for offset in offsets:
                    place = "outside any section"
                    for name, start, size in sections or ():
                        if start <= offset < start + size:
                            place = name
                            break
                    places[place] = places.get(place, 0) + 1
                detail = " ({})".format("; ".join("{}: {}".format(place, count) for place, count in places.items()))
            reasons.append("{}: {} occurrence(s) of the {} prefix class{}".format(
                label, len(offsets), prefix.decode("ascii"), detail))
    return reasons


# --- steps 10 to 12: package, archive, checksum ----------------------------------------------

def archive_name(version: str) -> str:
    return "apple-v{}-macos-arm64.tar.gz".format(version)


def package_binary(tools: Tools, pinned: Path, pinned_bytes: bytes, work: Path, version: str) -> Tuple[Path, str, bytes]:
    out = work / "out"
    out.mkdir(mode=0o700)
    name = archive_name(version)
    archive = out / name
    failure = process_failure(tools.package(pinned.parent, archive), "tar")
    if failure is not None:
        raise StepFailure("package", failure[0], failure[1])
    if read_regular(pinned, MAX_BINARY_BYTES, "package") != pinned_bytes:
        raise StepFailure("package", "the pinned binary changed during packaging")
    try:
        mode = os.lstat(str(archive)).st_mode
    except FileNotFoundError as error:
        raise StepFailure("package", "tar produced no archive") from error
    if not stat.S_ISREG(mode):
        raise StepFailure("package", "the archive is not a regular file")
    return out, name, read_regular(archive, MAX_ARCHIVE_BYTES, "package")


def decompress_single_member(data: bytes) -> Tuple[Optional[bytes], List[Failure]]:
    """Decompress exactly one gzip member, refusing output past MAX_DECOMPRESSED_BYTES. Returns
    the member's bytes (None when it is not one complete member) and the failures."""
    cap = MAX_DECOMPRESSED_BYTES
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    output = bytearray()
    pending = data
    try:
        while True:
            chunk = decompressor.decompress(pending, cap + 1 - len(output))
            output += chunk
            if len(output) > cap:
                return None, [("the archive decompresses past the recorded size cap", ASSERTION)]
            pending = decompressor.unconsumed_tail
            if decompressor.eof:
                break
            if not chunk and not pending:
                break
    except zlib.error:
        return None, [("the archive is not a valid gzip stream", ASSERTION)]
    if not decompressor.eof:
        return None, [("the gzip stream is truncated", ASSERTION)]
    if decompressor.unused_data:
        return bytes(output), [("bytes follow the first gzip member", ASSERTION)]
    return bytes(output), []


def _tar_octal(field: bytes) -> Optional[int]:
    text = field.split(b"\0", 1)[0].strip(b" ")
    if not text:
        return 0
    if re.fullmatch(rb"[0-7]+", text) is None:
        return None
    return int(text, 8)


def _typeflag_label(typeflag: bytes) -> str:
    if len(typeflag) == 1 and 0x21 <= typeflag[0] <= 0x7E:
        return "'{}'".format(typeflag.decode("ascii"))
    return "0x{:02x}".format(typeflag[0]) if typeflag else "missing"


def pax_records(data: bytes) -> Optional[List[Tuple[str, bytes]]]:
    """The (key, value) pairs of a PAX header's `<decimal length> <key>=<value>\n` records, or
    None when a length field is not 1 to 20 digits without a leading zero, a record's length
    does not match its bytes, or the records do not exactly fill the data."""
    records: List[Tuple[str, bytes]] = []
    position = 0
    while position < len(data):
        space = data.find(b" ", position)
        if space < 0 or PAX_LENGTH_RE.fullmatch(data[position:space]) is None:
            return None
        end = position + int(data[position:space])
        if end > len(data) or end <= space + 1 or data[end - 1:end] != b"\n":
            return None
        key, separator, value = data[space + 1:end - 1].partition(b"=")
        if not separator or not key:
            return None
        records.append((key.decode("utf-8", "replace"), value))
        position = end
    return records


def raw_tar_walk(stream: bytes) -> Tuple[List[Failure], Optional[Tuple[int, int]]]:
    """Walk the tar stream as raw 512-byte records: at most one per-file PAX header (at least
    one record, records well formed, key `mtime` only with a decimal value, zero padding), one
    regular-file header named `apple` with its
    data and zero padding, at least two zero records and only zero bytes to the end. Returns the
    failures and the member's (data offset, size)."""
    position = 0
    member: Optional[Tuple[int, int]] = None
    failures: List[Failure] = []
    pax_headers = 0
    while member is None:
        if position + TAR_BLOCK_SIZE > len(stream):
            return [("the tar stream ends inside a header record", ASSERTION)], None
        block = stream[position:position + TAR_BLOCK_SIZE]
        if block == ZERO_BLOCK:
            return [("the tar stream reaches an end record before its member", ASSERTION)], None
        stored = _tar_octal(block[148:156])
        unsigned = sum(block[:148]) + 8 * 0x20 + sum(block[156:])
        signed = sum(byte - 256 if byte > 127 else byte for byte in block[:148] + block[156:]) + 8 * 0x20
        if stored is None or stored not in (unsigned, signed):
            return [("a tar header checksum does not verify", ASSERTION)], None
        size = _tar_octal(block[124:136])
        if size is None:
            return [("a tar header size field is not octal", ASSERTION)], None
        data_end = position + TAR_BLOCK_SIZE + (size + TAR_BLOCK_SIZE - 1) // TAR_BLOCK_SIZE * TAR_BLOCK_SIZE
        if data_end > len(stream):
            return [("a tar record's data runs past the end of the stream", ASSERTION)], None
        typeflag = block[156:157]
        data_start = position + TAR_BLOCK_SIZE
        if typeflag == b"x":
            pax_headers += 1
            if pax_headers > 1:
                return [("more than one per-file PAX header precedes the member", ASSERTION)], None
            if stream[data_start + size:data_end].strip(b"\0"):
                return [("non-zero padding follows a PAX header's data", ASSERTION)], None
            records = pax_records(stream[data_start:data_start + size])
            if records is None:
                return [("a PAX header record is malformed", ASSERTION)], None
            if not records:
                return [("a PAX header holds no record", ASSERTION)], None
            if {key for key, _ in records} - {"mtime"}:
                return [("a PAX header carries a key other than mtime", ASSERTION)], None
            if any(PAX_MTIME_RE.fullmatch(value) is None for _, value in records):
                return [("a PAX mtime value is not a decimal number", ASSERTION)], None
            position = data_end
            continue
        if typeflag not in (b"0", b"\0"):
            return [("a tar record of type {} is present".format(_typeflag_label(typeflag)), ASSERTION)], None
        name = block[0:100].split(b"\0", 1)[0]
        prefix = block[345:500].split(b"\0", 1)[0] if block[257:262] == b"ustar" else b""
        if name != BINARY_NAME.encode("ascii") or prefix:
            failures.append(("the raw member header does not name apple", ASSERTION))
        if stream[data_start + size:data_end].strip(b"\0"):
            failures.append(("non-zero padding follows the member's data", ASSERTION))
        member = (data_start, size)
        position = data_end
    trailer = stream[position:]
    if len(trailer) < 2 * TAR_BLOCK_SIZE or trailer[:2 * TAR_BLOCK_SIZE] != ZERO_BLOCK * 2:
        failures.append(("the member is not followed by two zero records", ASSERTION))
    if trailer.strip(b"\0"):
        failures.append(("non-zero bytes follow the member", ASSERTION))
    return failures, member


def archive_member_checks(stream: bytes, binary: bytes) -> Tuple[List[Failure], Optional[List[Failure]],
                                                                 Optional[Tuple[int, int]]]:
    """(archive-members, archive-roundtrip, tarfile's (data offset, size) of the member). Any
    tarfile error fails closed."""
    try:
        with tarfile.open(fileobj=io.BytesIO(stream), mode="r:") as archive:
            members = archive.getmembers()
            global_headers = dict(archive.pax_headers)
            failures: List[Failure] = []
            if global_headers:
                failures.append(("the archive carries a global PAX header", ASSERTION))
            if len(members) != 1:
                failures.append(("{} members, expected 1".format(len(members)), ASSERTION))
                return failures, None, None
            member = members[0]
            if member.name != BINARY_NAME:
                failures.append(("the member is not named apple", ASSERTION))
            if not member.isreg() or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                failures.append(("the member is not a regular file", ASSERTION))
            if member.mode & 0o7777 != BINARY_MODE:
                failures.append(("the member's mode is not 0755", ASSERTION))
            if member.uid != 0 or member.gid != 0:
                failures.append(("the member is not owned by uid 0 and gid 0", ASSERTION))
            if member.uname != "" or member.gname != "":
                failures.append(("the member carries an owner or group name", ASSERTION))
            if member.linkname:
                failures.append(("the member carries a link name", ASSERTION))
            extra = set(member.pax_headers) - {"mtime"}
            if extra:
                failures.append(("the member carries {} PAX key(s) other than mtime".format(len(extra)), ASSERTION))
            placement = (member.offset_data, member.size)
            if not member.isreg():
                return failures, None, placement
            handle = archive.extractfile(member)
            if handle is None:
                return failures, [("the member cannot be read back", ASSERTION)], placement
            content = handle.read()
    except Exception:  # noqa: BLE001 - every tarfile error, of whatever class, fails closed
        return [("the tar stream does not parse", ASSERTION)], None, None
    roundtrip = [] if content == binary else [("the member's bytes differ from the built binary", ASSERTION)]
    return failures, roundtrip, placement


def archive_checks(archive: bytes, binary: bytes) -> Tuple[Dict[str, Optional[List[Failure]]], Optional[bytes]]:
    stream, stream_failures = decompress_single_member(archive)
    results: Dict[str, Optional[List[Failure]]] = {
        "archive-stream": stream_failures, "archive-members": None, "archive-roundtrip": None,
    }
    if stream is not None:
        members, roundtrip, placement = archive_member_checks(stream, binary)
        raw_failures, raw_member = raw_tar_walk(stream)
        members = members + raw_failures
        if raw_member is not None and placement is not None and raw_member != placement:
            members.append(("the raw record walk and tarfile disagree on the member's offset or size", ASSERTION))
        results["archive-members"], results["archive-roundtrip"] = members, roundtrip
    return results, stream


def check_checksum(tools: Tools, out: Path, name: str, archive: bytes) -> List[Failure]:
    checksum_name = name + ".sha256"
    result = tools.checksum(out, name)
    failure = process_failure(result, "shasum -a 256")
    if failure is not None:
        return [failure]
    create_bytes(out / checksum_name, result.stdout)
    content = read_regular(out / checksum_name, MAX_CHECKSUM_FILE_BYTES, "checksum")
    failures: List[Failure] = []
    match = re.fullmatch(rb"([0-9a-f]{64})  " + re.escape(name.encode("ascii")) + rb"\n", content)
    if match is None:
        failures.append(("the checksum file is not exactly one line of 64 lowercase hex digits, two spaces, "
                         "the archive name and a line feed", ASSERTION))
    elif match.group(1).decode("ascii") != hashlib.sha256(archive).hexdigest():
        failures.append(("the recorded checksum does not match an independent digest of the archive", ASSERTION))
    failure = process_failure(tools.checksum_verify(out, checksum_name), "shasum -a 256 -c", verdict=True)
    if failure is not None:
        failures.append(failure)
    return failures


# --- orchestration ---------------------------------------------------------------------------

def rehearse_artifact(request: Request, tools: Tools, git: GitRunner = run_git,
                      emit: Optional[Callable[[str], None]] = None,
                      redactor: Optional[Redactor] = None) -> Ledger:
    """Run steps 2 to 13 and return the ledger. Never raises: a checked condition is a failed
    check, and an unexpected exception is an `internal error` against the current stage."""
    redactor = redactor or Redactor()
    say = emit or (lambda message: print(redactor(message), file=sys.stderr))
    ledger = Ledger()
    stage = "checkout"
    try:
        check_checkout(request.candidate_root, request.candidate_sha, git, "checkout")
        ledger.passed("checkout")
        stage = "overlay"
        version, overlay_files = read_overlay(request.overlay)
        redactor.version = version
        ledger.passed("overlay")
        stage = "platform"
        check_platform(tools)
        ledger.passed("platform")
        stage = "no-write-path"
        check_no_write_path(tools.environment(), request.candidate_root, git)
        ledger.passed("no-write-path")
        stage = "change-set"
        source = assemble_source(request.candidate_root, request.candidate_sha, overlay_files, request.work, git)
        ledger.passed("change-set")
        stage = "deployment-minimum"
        expected = expected_minimum(_read_text(source / "Package.swift", "deployment-minimum", "Package.swift"))
        ledger.passed("deployment-minimum")
        stage = "build"
        built = build_binary(tools, source, request.work, say)
        pinned, binary_bytes = pin_binary(built, request.work)
        ledger.passed("build")

        stage = "macho"
        info = read_macho(binary_bytes)
        results = binary_checks(tools, pinned, binary_bytes, request.work, version, expected, info)
        for name, failures in results.items():
            ledger.record(name, failures)
        binary_hits = path_hits([("binary", binary_bytes)], info.sections)
        if binary_hits:
            ledger.record("paths", [(reason, ASSERTION) for reason in binary_hits])
        if ledger.any_failed(BINARY_CHECKS + ("paths",)) or any(ledger.status[name] != PASS for name in BINARY_CHECKS):
            return ledger

        stage = "package"
        out, name, archive_bytes = package_binary(tools, pinned, binary_bytes, request.work, version)
        ledger.passed("package")

        stage = "archive-stream"
        archive_results, stream = archive_checks(archive_bytes, binary_bytes)
        for check, failures in archive_results.items():
            ledger.record(check, failures)
        surfaces = [("archive (compressed)", archive_bytes)]
        if stream is not None:
            surfaces.append(("archive (decompressed)", stream))
        archive_hits = [(reason, ASSERTION) for reason in path_hits(surfaces)]
        if stream is not None or archive_hits:
            ledger.record("paths", archive_hits)  # with no decompressed stream, never a pass
        if ledger.any_failed(ARCHIVE_CHECKS + ("paths",)) or any(ledger.status[check] != PASS for check in ARCHIVE_CHECKS):
            return ledger

        stage = "checksum"
        ledger.record("checksum", check_checksum(tools, out, name, archive_bytes))
        if ledger.status["checksum"] != PASS:
            return ledger

        stage = "candidate-untouched"
        check_checkout(request.candidate_root, request.candidate_sha, git, "candidate-untouched")
        ledger.passed("candidate-untouched")
    except StepFailure as failure:
        ledger.fail(failure.check, failure.reason, failure.failure_class)
    except GitError as error:
        ledger.fail(stage, redactor.redact(str(error)), GIT)
    except OSError as error:
        # strerror only: a file name could be the archive's, which carries the version.
        ledger.fail(stage, error.strerror or error.__class__.__name__, IO)
    except Exception as error:  # noqa: BLE001 - a traceback could print values; name the class only
        ledger.fail(stage, "internal error ({})".format(error.__class__.__name__), ASSERTION)
    return ledger


def build_report(candidate_sha: str, ledger: Ledger, failure_class: Optional[str] = None) -> Dict[str, object]:
    passed = failure_class is None and ledger.all_passed()
    report: Dict[str, object] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "pass": passed,
        "candidate_sha": candidate_sha,
        "change_set": sorted(path.as_posix() for path in ALLOWLIST),
        "checks": {name: ledger.status[name] for name in CHECK_NAMES},
        "outward_writes": [],
        "note": REPORT_NOTE,
    }
    if not passed:
        report["failure_class"] = failure_class or ledger.failure_class()
    return report


def execute(request: Request, tools: Tools, git: GitRunner, stdout: TextIO, stderr: TextIO) -> int:
    """Run the rehearsal, print the outcome and write the report; returns the exit status."""
    redactor = Redactor({"<work>": request.work, "<candidate>": request.candidate_root, "<overlay>": request.overlay},
                        tools.environment().get("HOME"))

    def emit(message: str) -> None:
        print(redactor(message), file=stderr)

    forced: Optional[str] = None
    try:
        ledger = rehearse_artifact(request, tools, git, emit, redactor)
    except Exception as error:  # noqa: BLE001 - backstop; rehearse_artifact already catches
        emit("release-artifact: FAIL: internal error ({})".format(error.__class__.__name__))
        ledger = Ledger()
        forced = ASSERTION
    report = build_report(request.candidate_sha, ledger, forced)
    for name in CHECK_NAMES:
        status = ledger.status[name]
        if status == FAIL:
            for reason in ledger.reasons.get(name, []):
                emit("release-artifact: FAIL: {}: {}".format(name, reason))
        else:
            emit("release-artifact: {}: {}".format(name, status))
    if request.report_path is not None:
        try:
            write_report(request.report_path, report)
        except OSError as error:
            emit("release-artifact: FAIL: the report could not be written ({})".format(
                error.strerror or error.__class__.__name__))
            return ASSERTION_FAILURE_STATUS
    if not report["pass"]:
        return ASSERTION_FAILURE_STATUS
    print(json.dumps(report, sort_keys=True), file=stdout)
    return 0


class QuietArgumentParser(argparse.ArgumentParser):
    """An argument parser that never echoes an argument value: any rejection is one fixed line
    on stderr and exit status 2."""

    def error(self, message: str):  # type: ignore[override]
        sys.stderr.write("release-artifact: policy: invalid arguments (see --help)\n")
        raise SystemExit(POLICY_FAILURE_STATUS)


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = QuietArgumentParser(description="Read-only release-artifact rehearsal.")
    parser.add_argument("--candidate-root", type=Path, default=POLICY_ROOT)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--overlay", type=Path, required=True, help="release_prep.py's scratch directory")
    parser.add_argument("--work", type=Path, required=True, help="absent or empty private directory")
    parser.add_argument("--report", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        request = resolve_request(args.candidate_root, args.candidate_sha, args.overlay, args.work, args.report)
    except PolicyError as error:
        print("release-artifact: policy: {}".format(escape_controls(str(error))), file=sys.stderr)
        return POLICY_FAILURE_STATUS
    except RuntimeError:  # Path.resolve on a symlink loop (before 3.13), or expanduser with an unknown ~user
        print("release-artifact: policy: a path could not be resolved", file=sys.stderr)
        return POLICY_FAILURE_STATUS
    except OSError as error:
        print("release-artifact: policy: {}".format(error.strerror or error.__class__.__name__), file=sys.stderr)
        return POLICY_FAILURE_STATUS
    return execute(request, Tools(), run_git, sys.stdout, sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
