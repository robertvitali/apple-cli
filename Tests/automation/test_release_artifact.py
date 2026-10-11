"""Tests for scripts/ci/release_artifact.py - the read-only release-artifact rehearsal.

Everything except the last class runs anywhere (hosted Ubuntu included): the Mach-O reader is fed
synthetic images built here with `struct`, archives are built with `tarfile` and `gzip`, and the
orchestration runs end to end with a fake `Tools` whose build writes a synthetic binary. The last
class compiles tiny C programs and runs the real macOS tools; nothing here ever runs `swift`.
"""
from __future__ import annotations

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
import platform
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import zlib
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "release_artifact.py"
RUNBOOK = REPO_ROOT / "docs" / "runbooks" / "urgent-release.md"
CONSTANT_REL = Path("Sources/AppleKit/CommandSupport.swift")
CHANGELOG_REL = Path("CHANGELOG.md")
OLD_VERSION = "26.0.0"
NEW_VERSION = "26.7.13"  # distinctive, so a leak of it into any output is unambiguous
ARCHIVE_NAME = "apple-v{}-macos-arm64.tar.gz".format(NEW_VERSION)
BUILD_MARKER = "BUILD-OUTPUT-MARKER-QX"
HEX64_RE = re.compile(r"[0-9a-f]{64}")
RAW_CONTROL_RE = re.compile("[\x00-\x09\x0b-\x1f\x7f-\x9f\u2028\u2029]")
EXPECTED_MINOS = (14, 0, 0)
# Scratch repositories are built with no global or system git configuration and a synthetic identity.
GIT_TEST_ENVIRONMENT = dict(
    os.environ,
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_NOSYSTEM="1",
    GIT_AUTHOR_NAME="Automation Example",
    GIT_AUTHOR_EMAIL="automation@example.com",
    GIT_COMMITTER_NAME="Automation Example",
    GIT_COMMITTER_EMAIL="automation@example.com",
)


def load_module():
    spec = importlib.util.spec_from_file_location("release_artifact", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


artifact = load_module()


def git(args, cwd):
    completed = subprocess.run(
        ["git", *args], cwd=str(cwd), env=GIT_TEST_ENVIRONMENT, check=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return completed.stdout


CONSTANT_SOURCE = (
    "import Foundation\n\n"
    "public enum AppleVersion {\n"
    "    public static let current = \"26.0.0\" // workflow-owned\n"
    "}\n"
)
CHANGELOG_SOURCE = (
    "# Changelog\n\n"
    "## [Unreleased]\n\n"
    "### Added\n\n"
    "- Something callers can see.\n\n"
    "## [26.0.0] - 2026-08-30\n\n"
    "- First release.\n"
)
PACKAGE_SWIFT = (
    "// swift-tools-version: 6.0\n"
    "import PackageDescription\n\n"
    "let package = Package(\n"
    "    name: \"example\",\n"
    "    platforms: [.macOS(.v14)], // the floor\n"
    "    targets: [.target(name: \"Example\", swiftSettings: [.define(\"X\", .when(platforms: [.macOS]))])]\n"
    ")\n"
)


def seed_repo(path: Path, package: bool = True, changelog: bool = True) -> str:
    path.mkdir(parents=True, exist_ok=True)
    git(["init", "-q"], path)
    git(["config", "commit.gpgsign", "false"], path)
    (path / CONSTANT_REL).parent.mkdir(parents=True)
    (path / CONSTANT_REL).write_text(CONSTANT_SOURCE, encoding="utf-8")
    if changelog:
        (path / CHANGELOG_REL).write_text(CHANGELOG_SOURCE, encoding="utf-8")
    if package:
        (path / "Package.swift").write_text(PACKAGE_SWIFT, encoding="utf-8")
    git(["add", "-A"], path)
    git(["commit", "-q", "-m", "chore(release): v26.0.0"], path)
    return git(["rev-parse", "HEAD"], path).strip()


def make_overlay(root: Path, version: str = NEW_VERSION, heading_version: Optional[str] = None) -> Path:
    (root / CONSTANT_REL).parent.mkdir(parents=True)
    (root / CONSTANT_REL).write_text(CONSTANT_SOURCE.replace('"26.0.0"', '"{}"'.format(version)), encoding="utf-8")
    (root / CHANGELOG_REL).write_text(
        CHANGELOG_SOURCE.replace("## [Unreleased]\n\n", "## [Unreleased]\n\n## [{}] - 2026-10-07\n\n".format(
            heading_version or version), 1),
        encoding="utf-8")
    return root


# --- synthetic Mach-O images -------------------------------------------------------------------

GOOD_DYLIBS = ("/usr/lib/libSystem.B.dylib", "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation")
N_SECT_EXT = 0x0F
CLT_RPATH = "/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx"
XCODE_RPATH = "/Applications/Xcode_26.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"


def align8(value: int) -> int:
    return (value + 7) & ~7


def encode_version(version: Tuple[int, int, int]) -> int:
    return (version[0] << 16) | (version[1] << 8) | version[2]


def build_version_cmd(platform_id: int = 1, minos: Tuple[int, int, int] = EXPECTED_MINOS) -> bytes:
    return struct.pack("<IIIIII", 0x32, 24, platform_id, encode_version(minos), encode_version((26, 0, 0)), 0)


def string_cmd(cmd: int, text: str, fixed: int = 12, fields: bytes = b"", offset: Optional[int] = None) -> bytes:
    name = text.encode("ascii") + b"\0"
    size = align8(fixed + len(name))
    head = struct.pack("<III", cmd, size, fixed if offset is None else offset) + fields
    return (head + name).ljust(size, b"\0")


def dylib_cmd(text: str, cmd: int = 0x0C, offset: Optional[int] = None) -> bytes:
    return string_cmd(cmd, text, fixed=24, fields=struct.pack("<III", 2, 0x10000, 0x10000), offset=offset)


def dylinker_cmd(text: str = "/usr/lib/dyld") -> bytes:
    return string_cmd(0x0E, text)


def rpath_cmd(text: str = "@loader_path") -> bytes:
    return string_cmd(0x8000001C, text)


def dyld_environment_cmd(text: str = "DYLD_LIBRARY_PATH=/opt") -> bytes:
    return string_cmd(0x27, text)


def version_min_cmd() -> bytes:
    return struct.pack("<IIII", 0x24, 16, encode_version(EXPECTED_MINOS), encode_version((26, 0, 0)))


def default_commands() -> List[bytes]:
    return [build_version_cmd(), dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0]), dylib_cmd(GOOD_DYLIBS[1], cmd=0x80000018)]


def macho(commands: Optional[Sequence[bytes]] = None, *, magic: int = 0xFEEDFACF, cputype: int = 0x0100000C,
          cpusubtype: int = 0, filetype: int = 2, symbols: Sequence[int] = (N_SECT_EXT, N_SECT_EXT, 0x0E),
          signature: bool = True, symtab: Optional[Tuple[int, int, int, int]] = None, tail: bytes = b"",
          slack: int = 0, tail_section: Optional[Tuple[bytes, bytes]] = None,
          section_size: Optional[int] = None) -> bytes:
    """A thin Mach-O image: header, load commands (plus `slack` unparsed bytes counted in
    sizeofcmds), then the nlist_64 table, the string table, a stand-in code-signature blob and
    `tail`, optionally covered by one LC_SEGMENT_64 section named by `tail_section`."""
    commands = list(default_commands() if commands is None else commands)
    segment_size = 72 + 80 if tail_section is not None else 0
    sizeofcmds = sum(len(command) for command in commands) + 24 + (16 if signature else 0) + segment_size + slack
    ncmds = len(commands) + 1 + (1 if signature else 0) + (1 if tail_section is not None else 0)
    symoff = align8(32 + sizeofcmds)
    strtab = b"\0_main\0_padding\0"
    stroff = symoff + 16 * len(symbols)
    sigoff = align8(stroff + len(strtab))
    blob = b"\xfa\xde\x0c\xc0" + b"\0" * 12
    tail_offset = sigoff + len(blob)
    fields = symtab if symtab is not None else (symoff, len(symbols), stroff, len(strtab))
    commands.append(struct.pack("<IIIIII", 0x02, 24, *fields))
    if signature:
        commands.append(struct.pack("<IIII", 0x1D, 16, sigoff, len(blob)))
    if tail_section is not None:
        segname, sectname = tail_section
        size = len(tail) if section_size is None else section_size
        section = (sectname.ljust(16, b"\0") + segname.ljust(16, b"\0")
                   + struct.pack("<QQIIIIIIII", 0x100004000, size, tail_offset, 0, 0, 0, 0, 0, 0, 0))
        commands.append(struct.pack("<II", 0x19, 152) + segname.ljust(16, b"\0")
                        + struct.pack("<QQQQiiII", 0x100000000, 0x4000, 0, tail_offset + len(tail), 5, 5, 1, 0) + section)
    image = (struct.pack("<IIIIIIII", magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, 0, 0)
             + b"".join(commands) + b"\0" * slack)
    image = image.ljust(symoff, b"\0")
    image += b"".join(struct.pack("<IBBHQ", 1, n_type, 1, 0, 0x100000000 + index) for index, n_type in enumerate(symbols))
    image = (image + strtab).ljust(sigoff, b"\0") + blob
    return image + tail


def verdicts(data: bytes, expected=EXPECTED_MINOS) -> Tuple[Dict[str, str], Dict[str, List[str]]]:
    findings = artifact.macho_findings(artifact.read_macho(data), expected)
    statuses = {name: ("not-run" if found is None else ("pass" if not found else "fail")) for name, found in findings.items()}
    reasons = {name: [reason for reason, _ in (found or [])] for name, found in findings.items()}
    return statuses, reasons


# --- tar helpers -------------------------------------------------------------------------------

def ustar_member(name: str = "apple", data: bytes = b"", **fields) -> Tuple[tarfile.TarInfo, bytes]:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o755
    info.mtime = 1700000000
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    for key, value in fields.items():
        setattr(info, key, value)
    return info, data


def tar_bytes(members, fmt: int = tarfile.USTAR_FORMAT, global_headers: Optional[Dict[str, str]] = None) -> bytes:
    buffer = io.BytesIO()
    options = {"format": fmt}
    if global_headers is not None:
        options["pax_headers"] = global_headers
    with tarfile.open(fileobj=buffer, mode="w", **options) as archive:
        for info, data in members:
            archive.addfile(info, io.BytesIO(data) if info.isreg() else None)
    return buffer.getvalue()


def raw_header(name: str, typeflag: bytes, size: int = 0, checksum_ok: bool = True) -> bytes:
    """One hand-built USTAR header record."""
    block = bytearray(512)
    block[0:len(name)] = name.encode("ascii")
    block[100:108] = b"0000755\0"
    block[108:116] = b"0000000\0"
    block[116:124] = b"0000000\0"
    block[124:136] = "{:011o}\0".format(size).encode("ascii")
    block[136:148] = "{:011o}\0".format(1700000000).encode("ascii")
    block[156:157] = typeflag
    block[257:263] = b"ustar\0"
    block[263:265] = b"00"
    block[148:156] = b" " * 8
    block[148:156] = "{:06o}\0 ".format(sum(block)).encode("ascii")
    if not checksum_ok:
        block[1] ^= 0x01
    return bytes(block)


def padded(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 512)


MTIME_RECORD = b"20 mtime=1700000000\n"  # a 20-byte PAX record: the length counts itself and the line feed


def pax_header(records: bytes, padding: Optional[bytes] = None) -> bytes:
    """One per-file PAX header record (`x`) and its data, zero-padded unless `padding` is given."""
    tail = b"\0" * (-len(records) % 512) if padding is None else padding
    return raw_header("././@PaxHeader", b"x", len(records)) + records + tail


def pax_record(key: bytes, value: bytes) -> bytes:
    """One well-formed PAX record: its decimal length counts its own digits, the space, the key,
    '=', the value and the line feed."""
    body = b" " + key + b"=" + value + b"\n"
    for digits in range(1, 4):
        if len(str(digits + len(body))) == digits:
            return str(digits + len(body)).encode("ascii") + body
    raise AssertionError("a record too long for this helper")


def gzip_with_name(payload: bytes, name: bytes) -> bytes:
    """A single gzip member whose header carries an FNAME field (raw deflate body)."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    body = compressor.compress(payload) + compressor.flush()
    header = b"\x1f\x8b\x08\x08" + struct.pack("<I", 0) + b"\x00\x03" + name + b"\0"
    return header + body + struct.pack("<II", zlib.crc32(payload) & 0xFFFFFFFF, len(payload) & 0xFFFFFFFF)


# --- fakes -------------------------------------------------------------------------------------

def result(returncode: Optional[int] = 0, stdout: bytes = b"", stderr: bytes = b"", timed_out: bool = False):
    return artifact.ProcessResult(returncode, stdout, stderr, timed_out=timed_out)


def otool_listing(binary: Path, names: Sequence[str] = GOOD_DYLIBS) -> bytes:
    lines = [str(binary) + ":"] + ["\t{} (compatibility version 1.0.0, current version 1.0.0)".format(name) for name in names]
    return ("\n".join(lines) + "\n").encode("ascii")


class FakeTools(artifact.Tools):
    """A Tools whose every program is a stand-in; `overrides` replaces a result by method name."""

    def __init__(self, version: str = NEW_VERSION, binary: Optional[bytes] = None,
                 host: Tuple[str, str] = ("Darwin", "arm64"), environ: Optional[Dict[str, str]] = None,
                 archive_transform: Optional[Callable[[bytes, bytes], bytes]] = None, **overrides) -> None:
        super().__init__(environ={} if environ is None else environ)
        self.version = version
        self.binary = macho() if binary is None else binary
        self.host_value = host
        self.archive_transform = archive_transform
        self.overrides = overrides
        self.calls: List[str] = []
        self.paths: Dict[str, Path] = {}

    def _answer(self, name: str, default: Callable[[], artifact.ProcessResult], *args) -> artifact.ProcessResult:
        self.calls.append(name)
        if args:
            self.paths[name] = args[0]
        if name in self.overrides:
            value = self.overrides[name]
            return value(*args) if callable(value) else value
        return default()

    def host(self):
        self.calls.append("host")
        return self.host_value

    def swift_build(self, source, work, log_path):
        def build():
            log_path.write_text("Compiling example\n{}\n".format(BUILD_MARKER), encoding="utf-8")
            binary = source / ".build" / "arm64-apple-macosx" / "release" / "apple"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(self.binary)
            binary.chmod(0o755)
            return result(0)
        return self._answer("swift_build", build, source, work, log_path)

    def show_bin_path(self, source, work, log_path):
        return self._answer("show_bin_path", lambda: result(0, (str(source / ".build" / "arm64-apple-macosx" / "release") + "\n").encode()),
                            source, work, log_path)

    def run_version(self, binary, cwd):
        return self._answer("run_version", lambda: result(0, (self.version + "\n").encode()), binary, cwd)

    def lipo_archs(self, binary):
        return self._answer("lipo_archs", lambda: result(0, b"arm64\n"), binary)

    def otool_libraries(self, binary):
        return self._answer("otool_libraries", lambda: result(0, otool_listing(binary)), binary)

    def nm_symbols(self, binary):
        return self._answer("nm_symbols", lambda: result(0, b"00000001000000a0 T __mh_execute_header\n000000010000032c T _main\n"),
                            binary)

    def codesign_verify(self, binary):
        return self._answer("codesign_verify", lambda: result(0), binary)

    def package(self, bindir, archive):
        def pack():
            data = (bindir / "apple").read_bytes()
            raw = tar_bytes([ustar_member("apple", data)])
            packed = gzip.compress(raw, mtime=0)
            if self.archive_transform is not None:
                packed = self.archive_transform(raw, packed)
            archive.write_bytes(packed)
            return result(0)
        return self._answer("package", pack, bindir, archive)

    def checksum(self, out, name):
        return self._answer("checksum", lambda: result(0, "{}  {}\n".format(
            hashlib.sha256((out / name).read_bytes()).hexdigest(), name).encode("ascii")), out, name)

    def checksum_verify(self, out, checksum_name):
        def verify():
            line = (out / checksum_name).read_text(encoding="ascii")
            digest, name = line.rstrip("\n").split("  ", 1)
            return result(0 if hashlib.sha256((out / name).read_bytes()).hexdigest() == digest else 1)
        return self._answer("checksum_verify", verify, out, checksum_name)


class TempCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="release-artifact-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()


# --- Mach-O reader -----------------------------------------------------------------------------

class MachOReaderTests(unittest.TestCase):
    READER_CHECKS = ("macho", "architecture", "deployment-target", "linkage", "debug-map")

    def assert_fails_only(self, data: bytes, check: str, reason: Optional[str] = None) -> Dict[str, str]:
        statuses, reasons = verdicts(data)
        self.assertEqual({name for name, status in statuses.items() if status == "fail"}, {check}, statuses)
        if reason is not None:
            self.assertTrue(any(reason in text for text in reasons[check]), reasons[check])
        return statuses

    def test_good_thin_arm64_executable_passes_every_reader_check(self) -> None:
        data = macho()
        info = artifact.read_macho(data)
        statuses, _ = verdicts(data)
        self.assertEqual(statuses, {name: "pass" for name in self.READER_CHECKS})
        self.assertEqual(info.dylibs, list(GOOD_DYLIBS))
        self.assertEqual(info.dylinkers, ["/usr/lib/dyld"])
        self.assertEqual(info.build_versions, [(1, EXPECTED_MINOS)])
        self.assertEqual((info.rpaths, info.dyld_environment_count, info.oso_count), ([], 0, 0))
        self.assertTrue(info.code_signature)

    def test_universal_magics_fail_architecture_and_stop_the_reader(self) -> None:
        for magic in (0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA):
            with self.subTest(magic=hex(magic)):
                statuses = self.assert_fails_only(macho(magic=magic), "architecture", "universal")
                for name in ("macho", "deployment-target", "linkage", "debug-map"):
                    self.assertEqual(statuses[name], "not-run")

    def test_32_bit_and_big_endian_magics_fail_architecture(self) -> None:
        self.assert_fails_only(macho(magic=0xFEEDFACE), "architecture", "32-bit")
        self.assert_fails_only(macho(magic=0xCEFAEDFE), "architecture", "32-bit")
        self.assert_fails_only(macho(magic=0xCFFAEDFE), "architecture", "big-endian")
        self.assert_fails_only(b"\x7fELF" + b"\0" * 60, "architecture", "not a Mach-O")
        self.assert_fails_only(b"\0\0", "architecture", "too short")

    def test_x86_64_cputype_fails_architecture_only(self) -> None:
        statuses = self.assert_fails_only(macho(cputype=0x01000007), "architecture", "not arm64")
        self.assertEqual(statuses["linkage"], "pass")

    def test_arm64e_subtype_fails_architecture_only(self) -> None:
        self.assert_fails_only(macho(cpusubtype=2), "architecture", "CPU_SUBTYPE_ARM64_ALL")
        self.assert_fails_only(macho(cpusubtype=0x80000002), "architecture", "CPU_SUBTYPE_ARM64_ALL")
        statuses, _ = verdicts(macho(cpusubtype=0x80000000))  # capability bits only: still ARM64_ALL
        self.assertEqual(statuses["architecture"], "pass")
        self.assertFalse(artifact.read_macho(macho(cpusubtype=2)).arch_ok)

    def test_dylib_filetype_fails_architecture_only(self) -> None:
        self.assert_fails_only(macho(filetype=6), "architecture", "MH_EXECUTE")

    def test_deployment_target_refusals(self) -> None:
        dylibs = [dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]
        cases = {
            "minos 15.0": ([build_version_cmd(minos=(15, 0, 0))] + dylibs, "minos 15.0.0"),
            "platform iOS": ([build_version_cmd(platform_id=2)] + dylibs, "not macOS"),
            "missing LC_BUILD_VERSION": (dylibs, "found 0"),
            "two LC_BUILD_VERSION": ([build_version_cmd(), build_version_cmd()] + dylibs, "found 2"),
            "LC_VERSION_MIN_MACOSX": ([build_version_cmd(), version_min_cmd()] + dylibs, "LC_VERSION_MIN_MACOSX"),
        }
        for label, (commands, reason) in cases.items():
            with self.subTest(case=label):
                self.assert_fails_only(macho(commands), "deployment-target", reason)

    def test_minor_minimum_is_decoded(self) -> None:
        commands = [build_version_cmd(minos=(14, 4, 0)), dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]
        statuses, _ = verdicts(macho(commands), expected=(14, 4, 0))
        self.assertEqual(statuses["deployment-target"], "pass")
        self.assert_fails_only(macho(commands), "deployment-target", "minos 14.4.0")

    def test_linkage_refusals(self) -> None:
        base = [build_version_cmd(), dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]
        cases = {
            "@rpath dylib": (base + [dylib_cmd("@rpath/x.dylib")], "named through an @ path (@rpath/x.dylib)"),
            "/usr/local dylib": (base + [dylib_cmd("/usr/local/lib/x.dylib")], "outside /usr/lib/"),
            "parent segment": (base + [dylib_cmd("/usr/lib/../local/x.dylib")], "/../"),
            "relative rpath": (base + [rpath_cmd("lib/swift")], "outside the permitted set"),
            "rpath above the loader": (base + [rpath_cmd("@loader_path/../x")], "outside the permitted set"),
            "rpath above the executable": (base + [rpath_cmd("@executable_path/../Frameworks")],
                                           "outside the permitted set"),
            "@rpath-prefixed rpath": (base + [rpath_cmd("@rpath/lib")], "outside the permitted set"),
            "bare @rpath rpath": (base + [rpath_cmd("@rpath")], "outside the permitted set"),
            "empty rpath": (base + [rpath_cmd("")], "outside the permitted set"),
            "temporary rpath": (base + [rpath_cmd("/tmp/x")], "outside the permitted set"),
            "/usr/local rpath": (base + [rpath_cmd("/usr/local/lib")], "outside the permitted set (/usr/local/lib)"),
            "Homebrew rpath": (base + [rpath_cmd("/opt/homebrew/lib")], "outside the permitted set"),
            "other application rpath": (base + [rpath_cmd("/Applications/Other.app/lib")], "outside the permitted set"),
            "rpath climbing out of a root": (base + [rpath_cmd("/usr/lib/../../tmp")], "outside the permitted set"),
            "one bad rpath among good ones": (base + [rpath_cmd("/usr/lib/swift"), rpath_cmd("@loader_path"),
                                                      rpath_cmd("Frameworks")], "1 LC_RPATH entry outside"),
            "@rpath dylib despite a matching rpath": (base + [rpath_cmd("@loader_path"), dylib_cmd("@rpath/x.dylib")],
                                                      "named through an @ path"),
            "LC_DYLD_ENVIRONMENT": (base + [dyld_environment_cmd()], "LC_DYLD_ENVIRONMENT"),
            "wrong dylinker": ([build_version_cmd(), dylinker_cmd("/usr/lib/dyld2"), dylib_cmd(GOOD_DYLIBS[0])],
                               "dynamic linker"),
            "no dylinker": ([build_version_cmd(), dylib_cmd(GOOD_DYLIBS[0])], "dynamic linker"),
            "two dylinkers": (base + [dylinker_cmd()], "dynamic linker"),
            "no dylib": ([build_version_cmd(), dylinker_cmd()], "no dylib"),
            "weak @executable_path dylib": (base + [dylib_cmd("@executable_path/x.dylib", cmd=0x80000018)], "@ path"),
            "reexport outside": (base + [dylib_cmd("/opt/x.dylib", cmd=0x8000001F)], "outside"),
            "lazy outside": (base + [dylib_cmd("/opt/x.dylib", cmd=0x20)], "outside"),
            "upward outside": (base + [dylib_cmd("/opt/x.dylib", cmd=0x80000023)], "outside"),
        }
        for label, (commands, reason) in cases.items():
            with self.subTest(case=label):
                self.assert_fails_only(macho(commands), "linkage", reason)

    def test_unsafe_names_are_counted_not_printed(self) -> None:
        base = [build_version_cmd(), dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]
        _, reasons = verdicts(macho(base + [dylib_cmd("/opt/vendor-QZMARK/x.dylib"), rpath_cmd("/opt/QZMARK-rpath")]))
        text = " ".join(reasons["linkage"])
        self.assertNotIn("QZMARK", text)
        self.assertIn("1 dylib(s) outside /usr/lib/ and /System/Library/ (1 other(s) not shown)", text)
        self.assertIn("1 LC_RPATH entry outside the permitted set (1 other(s) not shown)", text)
        self.assertTrue(artifact.printable_name("@rpath/libx.dylib"))
        self.assertTrue(artifact.printable_name(XCODE_RPATH))
        for name in ("@rpath/x/y.dylib", "/opt/x.dylib", "/usr/lib/x y.dylib", "/usr/lib/x\u00e9.dylib", "@loader_path/x"):
            self.assertFalse(artifact.printable_name(name), name)
        # Dot segments, doubled slashes and any path-prefix class (spelled at run time, in any case).
        users, private_tmp = "/" + "Users" + "/", "/" + "private" + "/tmp/"
        for name in ("/usr/.." + users + "x/y.dylib", "/Library/Developer/../.." + private_tmp + "x.dylib",
                     "/usr//lib/x.dylib", "/usr/./lib/x.dylib", "/usr/lib/..", "/Library/Developer" + users + "x.dylib",
                     "/Library/Developer" + users.upper() + "x.dylib", "/System/Library/x/../y.dylib"):
            self.assertFalse(artifact.printable_name(name), name)
        self.assertTrue(artifact.printable_name("/usr/lib/libSystem.B.dylib"))
        self.assertTrue(artifact.printable_name(CLT_RPATH))

    def test_permitted_rpaths_pass_linkage(self) -> None:
        base = [build_version_cmd(), dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]
        for paths in (["/usr/lib/swift"], ["@loader_path"], ["@executable_path"], [CLT_RPATH], [XCODE_RPATH],
                      ["/usr/lib/swift", "@loader_path", XCODE_RPATH]):  # the shape SwiftPM gives an executable
            with self.subTest(rpaths=paths):
                data = macho(base + [rpath_cmd(path) for path in paths])
                statuses, reasons = verdicts(data)
                self.assertEqual(statuses, {name: "pass" for name in self.READER_CHECKS}, reasons)
                self.assertEqual(artifact.read_macho(data).rpaths, paths)

    def test_rpath_rule_unit(self) -> None:
        for path in ("/usr/lib/swift", "/System/Library/Frameworks", CLT_RPATH, XCODE_RPATH,
                     "/Applications/Xcode.app/Contents/Developer/x", "@loader_path", "@executable_path"):
            self.assertTrue(artifact.rpath_permitted(path), path)
        for path in ("", "lib", "./lib", "@loader_path/../x", "@loader_path/", "@executable_path/lib", "@rpath",
                     "@rpath/x", " /usr/lib", "@LOADER_PATH", "/tmp/x", "/var/tmp/x", "/usr/local/lib",
                     "/opt/homebrew/lib", "/Applications/Other.app/lib", "/usr/lib/../../tmp", "/usr/lib/..", "/usr/lib",
                     "/Applications/Xcode.app/Contents/Developer", "/Applications/XcodeX/Contents/Developer/x", "/"):
            self.assertFalse(artifact.rpath_permitted(path), path)

    def test_dylib_order_is_kept(self) -> None:
        names = ["/usr/lib/libb.dylib", "/usr/lib/liba.dylib", "/System/Library/Frameworks/C.framework/C"]
        commands = [build_version_cmd(), dylinker_cmd()] + [dylib_cmd(name) for name in names]
        self.assertEqual(artifact.read_macho(macho(commands)).dylibs, names)

    def test_a_debug_map_entry_as_the_last_symbol_fails_debug_map(self) -> None:
        statuses = self.assert_fails_only(macho(symbols=(N_SECT_EXT,) * 500 + (0x66,)), "debug-map", "1 debug-map")
        self.assertEqual(statuses["macho"], "pass")
        self.assertEqual(artifact.read_macho(macho(symbols=(0x66, 0x24, 0x66))).oso_count, 2)

    def test_sections_are_recorded_with_safe_names(self) -> None:
        data = macho(tail=b"payload!", tail_section=(b"__TEXT", b"__cstring"))
        info = artifact.read_macho(data)
        self.assertIsNone(info.malformed)
        self.assertEqual(info.sections, [("__TEXT,__cstring", len(data) - 8, 8)])
        odd = artifact.read_macho(macho(tail=b"payload!", tail_section=(b"__TEXT", b"bad name")))
        self.assertEqual(odd.sections[0][0], "an unnamed section")

    def malformed(self, data: bytes, reason: str) -> None:
        try:
            statuses, reasons = verdicts(data)
        except Exception as error:  # noqa: BLE001 - the reader must never raise
            self.fail("the reader raised {}".format(error.__class__.__name__))
        self.assertEqual(statuses["macho"], "fail", statuses)
        self.assertTrue(any(reason in text for text in reasons["macho"]), reasons["macho"])
        for name in ("deployment-target", "linkage", "debug-map"):
            self.assertEqual(statuses[name], "not-run")

    def test_malformations_fail_closed_and_never_raise(self) -> None:
        good = macho()
        self.malformed(good[:32 + 20], "past the end of the file")
        self.malformed(good[:20], "truncated")
        zero = bytearray(good)
        struct.pack_into("<I", zero, 32 + 4, 0)
        self.malformed(bytes(zero), "invalid cmdsize")
        odd = bytearray(good)
        struct.pack_into("<I", odd, 32 + 4, 28)
        self.malformed(bytes(odd), "invalid cmdsize")
        short = bytearray(good)
        (sizeofcmds,) = struct.unpack_from("<I", short, 20)
        struct.pack_into("<I", short, 20, sizeofcmds - 8)
        self.malformed(bytes(short), "runs past sizeofcmds")
        many = bytearray(good)
        (ncmds,) = struct.unpack_from("<I", many, 16)
        struct.pack_into("<I", many, 16, ncmds + 1)
        self.malformed(bytes(many), "starts past sizeofcmds")
        huge = bytearray(good)
        struct.pack_into("<I", huge, 20, 0xFFFFFFF0)
        self.malformed(bytes(huge), "past the end of the file")
        self.malformed(macho(slack=8), "do not fill sizeofcmds exactly")
        self.malformed(macho(default_commands() + [struct.pack("<IIIIII", 0x02, 24, 0, 0, 0, 0)]), "more than one LC_SYMTAB")
        base = [build_version_cmd(), dylinker_cmd()]
        self.malformed(macho(base + [dylib_cmd(GOOD_DYLIBS[0], offset=4096)]), "string offset is out of bounds")
        self.malformed(macho(base + [dylib_cmd(GOOD_DYLIBS[0], offset=8)]), "string offset is out of bounds")
        unterminated = struct.pack("<IIIIII", 0x0C, 32, 24, 2, 0, 0) + b"/usr/lib/libunterminated"[:8]
        self.malformed(macho(base + [unterminated]), "not terminated")
        self.malformed(macho(symtab=(len(good) + 64, 4, 0, 0)), "symbol table runs past")
        self.malformed(macho(symtab=(64, 0xFFFFFFF, 0, 0)), "symbol table runs past")
        self.malformed(macho(symtab=(0, 0, len(good) + 64, 16)), "string table runs past")
        short_build = struct.pack("<IIII", 0x32, 16, 1, encode_version(EXPECTED_MINOS))
        self.malformed(macho([short_build, dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]), "shorter than its fixed fields")
        tools = struct.pack("<IIIIII", 0x32, 24, 1, encode_version(EXPECTED_MINOS), 0, 9)
        self.malformed(macho([tools, dylinker_cmd(), dylib_cmd(GOOD_DYLIBS[0])]), "tool list runs past")
        bad_signature = bytearray(good)
        offset = 32 + sum(len(command) for command in default_commands()) + 24
        struct.pack_into("<I", bad_signature, offset + 8, len(good))
        self.malformed(bytes(bad_signature), "code signature runs past")
        self.malformed(macho(tail=b"x" * 8, tail_section=(b"__TEXT", b"__cstring"), section_size=4096),
                       "a section runs past the end of the file")
        segment = struct.pack("<II", 0x19, 72) + b"__TEXT".ljust(16, b"\0") + struct.pack("<QQQQiiII", 0, 0, 0, 0, 5, 5, 3, 0)
        self.malformed(macho(default_commands() + [segment]), "section list runs past")

    def test_random_truncations_never_raise(self) -> None:
        good = macho(tail=b"x" * 16, tail_section=(b"__TEXT", b"__cstring"))
        for length in range(0, len(good), 7):
            with self.subTest(length=length):
                artifact.macho_findings(artifact.read_macho(good[:length]), EXPECTED_MINOS)


# --- binary checks with fake tools -----------------------------------------------------------

class BinaryCrossCheckTests(TempCase):
    def run_checks(self, data: Optional[bytes] = None, **overrides):
        data = macho() if data is None else data
        binary = self.tmp / "bin-{}".format(len(list(self.tmp.iterdir()))) / "apple"
        binary.parent.mkdir()
        binary.write_bytes(data)
        tools = FakeTools(**overrides)
        results = artifact.binary_checks(tools, binary, data, self.tmp, NEW_VERSION, EXPECTED_MINOS)
        statuses = {name: ("not-run" if found is None else ("pass" if not found else "fail")) for name, found in results.items()}
        reasons = {name: [reason for reason, _ in (found or [])] for name, found in results.items()}
        classes = {name: [cls for _, cls in (found or [])] for name, found in results.items()}
        return statuses, reasons, classes

    def assert_only(self, statuses, check):
        self.assertEqual({name for name, status in statuses.items() if status == "fail"}, {check}, statuses)

    def test_agreeing_tools_pass_every_check(self) -> None:
        statuses, _, _ = self.run_checks()
        self.assertEqual(statuses, {name: "pass" for name in artifact.BINARY_CHECKS})

    def test_lipo_answers(self) -> None:
        statuses, _, _ = self.run_checks(lipo_archs=result(0, b"arm64 "))
        self.assertEqual(statuses["architecture"], "pass")
        for label, answer, reason in (
            ("two architectures", result(0, b"x86_64 arm64\n"), "exactly arm64"),
            ("empty", result(0, b""), "exactly arm64"),
            ("arm64e", result(0, b"arm64e\n"), "exactly arm64"),
            ("non-zero exit", result(1, b"arm64\n"), "lipo -archs exited 1"),
            ("timeout", result(-9, b"", timed_out=True), "did not finish"),
        ):
            with self.subTest(case=label):
                statuses, reasons, _ = self.run_checks(lipo_archs=answer)
                self.assert_only(statuses, "architecture")
                self.assertTrue(any(reason in text for text in reasons["architecture"]), reasons)

    def test_lipo_disagreeing_with_the_reader_fails(self) -> None:
        for data in (macho(cputype=0x01000007), macho(cpusubtype=2)):
            statuses, reasons, _ = self.run_checks(data, lipo_archs=result(0, b"arm64\n"))
            self.assertIn("lipo and the Mach-O reader disagree on the architecture", reasons["architecture"])

    def test_otool_answers(self) -> None:
        def listing(names):
            return lambda binary: result(0, otool_listing(binary, names))
        cases = {
            "different list": (listing(GOOD_DYLIBS[:1]), "list different dylibs"),
            "different order": (listing(tuple(reversed(GOOD_DYLIBS))), "list different dylibs"),
            "unparseable line": (lambda binary: result(0, otool_listing(binary) + b"\tgarbage\n"), "unparseable"),
            "wrong first line": (lambda binary: result(0, otool_listing(binary).replace(b":\n", b" (architecture arm64):\n", 1)),
                                 "unparseable"),
            "empty output": (result(0, b""), "unparseable"),
            "non-zero exit": (result(2), "otool -L exited 2"),
        }
        for label, (answer, reason) in cases.items():
            with self.subTest(case=label):
                statuses, reasons, _ = self.run_checks(otool_libraries=answer)
                self.assert_only(statuses, "linkage")
                self.assertTrue(any(reason in text for text in reasons["linkage"]), reasons["linkage"])

    def test_otool_list_is_judged_by_the_same_name_rule(self) -> None:
        # The reader sees only system dylibs, but otool lists an @rpath one: the name rule applied
        # to otool's own list must fail on its own, not only through the disagreement.
        def listing(binary):
            return result(0, otool_listing(binary, (GOOD_DYLIBS[0], "@rpath/x.dylib")))
        statuses, reasons, _ = self.run_checks(otool_libraries=listing)
        self.assert_only(statuses, "linkage")
        self.assertIn("otool -L: 1 dylib(s) outside /usr/lib/ and /System/Library/ (@rpath/x.dylib)", reasons["linkage"])
        self.assertIn("otool -L: 1 dylib(s) named through an @ path (@rpath/x.dylib)", reasons["linkage"])
        self.assertIn("otool -L and the Mach-O reader list different dylibs", reasons["linkage"])
        for name in ("/usr/lib/../local/x.dylib", "/opt/x.dylib"):
            with self.subTest(name=name):
                statuses, reasons, _ = self.run_checks(
                    otool_libraries=lambda binary, n=name: result(0, otool_listing(binary, (GOOD_DYLIBS[0], n))))
                self.assertTrue(any(reason.startswith("otool -L: ") for reason in reasons["linkage"]), reasons)
        statuses, reasons, _ = self.run_checks(otool_libraries=lambda binary: result(0, otool_listing(binary, ())))
        self.assertIn("otool -L: no dylib is linked", reasons["linkage"])

    def test_otool_weak_suffix_parses(self) -> None:
        def weak(binary):
            text = otool_listing(binary).decode().replace("current version 1.0.0)", "current version 1.0.0, weak)")
            return result(0, text.encode())
        statuses, _, _ = self.run_checks(otool_libraries=weak)
        self.assertEqual(statuses["linkage"], "pass")

    def test_nm_is_read_to_the_end(self) -> None:
        padding = b"0000000100003f90 T _symbol_padding_line\n" * 2000
        self.assertGreater(len(padding), 64 * 1024)
        statuses, reasons, _ = self.run_checks(nm_symbols=result(0, padding + b"00000000000000a0 - 00 0001    OSO /x/y.o\n"))
        self.assert_only(statuses, "debug-map")
        self.assertIn("nm -ap reports 1 debug-map (N_OSO) entry", reasons["debug-map"])
        self.assertIn("nm -ap and the Mach-O reader disagree on the debug-map count", reasons["debug-map"])

    def test_nm_failure_and_disagreement(self) -> None:
        statuses, reasons, classes = self.run_checks(nm_symbols=result(1))
        self.assert_only(statuses, "debug-map")
        self.assertEqual(classes["debug-map"], ["tool"])
        statuses, reasons, _ = self.run_checks(macho(symbols=(0x66,)))
        self.assertIn("nm -ap and the Mach-O reader disagree on the debug-map count", reasons["debug-map"])

    def test_codesign_failure_fails_signature(self) -> None:
        statuses, reasons, classes = self.run_checks(codesign_verify=result(1))
        self.assert_only(statuses, "signature")
        self.assertEqual(classes["signature"], ["assertion"])

    def test_missing_code_signature_command_fails_signature(self) -> None:
        statuses, reasons, _ = self.run_checks(macho(signature=False))
        self.assert_only(statuses, "signature")
        self.assertIn("no LC_CODE_SIGNATURE load command", reasons["signature"])

    def test_universal_binary_skips_reader_dependent_tools(self) -> None:
        statuses, _, _ = self.run_checks(macho(magic=0xCAFEBABE), lipo_archs=result(0, b"x86_64 arm64\n"))
        self.assertEqual(statuses["architecture"], "fail")
        for name in ("macho", "deployment-target", "linkage", "debug-map"):
            self.assertEqual(statuses[name], "not-run")


# --- version check (real Tools.run_version, stand-in executables) ------------------------------

class VersionCheckTests(TempCase):
    def check(self, body: str, timeout: float = 30):
        script = self.tmp / "apple-{}".format(len(list(self.tmp.iterdir())))
        script.write_text("#!/bin/sh\n" + body, encoding="ascii")
        script.chmod(0o755)
        tools = artifact.Tools(environ={}, version_timeout=timeout)
        return artifact.check_version(tools, script, self.tmp, NEW_VERSION)

    def test_exact_output_passes(self) -> None:
        self.assertEqual(self.check("printf '%s\\n' {}\n".format(NEW_VERSION)), [])

    def test_refusals(self) -> None:
        cases = {
            "wrong version": ("printf '%s\\n' 26.7.14\n", "not the predicted version"),
            "trailing text": ("printf '%s extra\\n' {}\n".format(NEW_VERSION), "not the predicted version"),
            "extra newline": ("printf '%s\\n\\n' {}\n".format(NEW_VERSION), "not the predicted version"),
            "no newline": ("printf '%s' {}\n".format(NEW_VERSION), "not the predicted version"),
            "non-zero exit": ("printf '%s\\n' {}\nexit 3\n".format(NEW_VERSION), "exited 3"),
            "stderr text": ("printf '%s\\n' {}\nprintf 'note\\n' >&2\n".format(NEW_VERSION), "wrote to stderr"),
        }
        for label, (body, reason) in cases.items():
            with self.subTest(case=label):
                failures = self.check(body)
                self.assertTrue(failures)
                self.assertTrue(any(reason in text for text, _ in failures), failures)
                for text, _ in failures:
                    self.assertNotIn(NEW_VERSION, text)

    def test_runs_with_an_empty_environment(self) -> None:
        body = 'if [ -n "${RELEASE_ARTIFACT_PROBE+x}" ]; then exit 9; fi\nprintf \'%s\\n\' ' + NEW_VERSION + "\n"
        with mock.patch.dict(os.environ, {"RELEASE_ARTIFACT_PROBE": "1"}):
            self.assertEqual(self.check(body), [])

    def test_a_hang_is_killed_at_the_timeout(self) -> None:
        started = time.monotonic()
        failures = self.check("/bin/sleep 30\n", timeout=1)
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual(failures, [("the binary's --version did not finish in time and was killed", "timeout")])

    def test_the_whole_process_group_is_killed(self) -> None:
        marker = self.tmp / "late"
        script = self.tmp / "spawner"
        script.write_text("#!/bin/sh\n( /bin/sleep 2; : > '{}' ) &\n/bin/sleep 30\n".format(marker), encoding="ascii")
        script.chmod(0o755)
        outcome = artifact.run_process([str(script)], self.tmp, {}, 1)
        self.assertTrue(outcome.timed_out)
        time.sleep(3)
        self.assertFalse(marker.exists(), "a member of the process group survived the timeout")

    def test_stragglers_are_killed_after_a_normal_exit_when_asked(self) -> None:
        marker = self.tmp / "straggler"
        script = self.tmp / "detacher"
        script.write_text("#!/bin/sh\n( /bin/sleep 2; : > '{}' ) </dev/null >/dev/null 2>&1 &\nexit 0\n".format(marker),
                          encoding="ascii")
        script.chmod(0o755)
        outcome = artifact.run_process([str(script)], self.tmp, {}, 10, kill_group_after=True)
        self.assertEqual((outcome.returncode, outcome.timed_out), (0, False))
        time.sleep(3)
        self.assertFalse(marker.exists(), "a straggler of the build's process group survived")

    def test_an_unstartable_binary_is_a_tool_failure(self) -> None:
        tools = artifact.Tools(environ={})
        failures = artifact.check_version(tools, self.tmp / "missing", self.tmp, NEW_VERSION)
        self.assertEqual(failures, [("the binary could not be started", "tool")])


# --- SwiftPM invocation ------------------------------------------------------------------------

class SwiftInvocationTests(TempCase):
    def test_both_swift_invocations_share_the_redirected_state_and_a_shut_git_config(self) -> None:
        captured = []

        def fake_run(command, cwd, environment, timeout, **options):
            captured.append((list(command), dict(environment), options))
            return artifact.ProcessResult(0)

        work = self.tmp / "work"
        tools = artifact.Tools(environ={"HOME": "/h", "PATH": "/x", "GIT_CONFIG_GLOBAL": "/etc/other", "TMPDIR": "/t"})
        with mock.patch.object(artifact, "run_process", fake_run):
            tools.swift_build(self.tmp / "src", work, self.tmp / "a.log")
            tools.show_bin_path(self.tmp / "src", work, self.tmp / "b.log")
            tools.run_version(self.tmp / "apple", self.tmp)
        (build, build_env, build_options), (show, show_env, show_options), (_, version_env, version_options) = captured
        self.assertEqual(show, build + ["--show-bin-path"])
        self.assertEqual(build[:7], ["/usr/bin/swift", "build", "-c", "release", "--disable-automatic-resolution", "-Xswiftc", "-gnone"])
        for flag, leaf in (("--cache-path", "cache"), ("--config-path", "config"), ("--security-path", "security")):
            self.assertEqual(build[build.index(flag) + 1], str(work / "swiftpm" / leaf))
        for command in (build, show):
            self.assertEqual(command.count("--disable-netrc"), 1)
            self.assertEqual(command.count("--disable-keychain"), 1)
        for environment in (build_env, show_env):
            self.assertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
            self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
            self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
            # The runner's TMPDIR passes through, untouched (never redirected into the work directory).
            self.assertEqual(environment["TMPDIR"], "/t")
            self.assertEqual(environment["HOME"], "/h")
            self.assertEqual(environment["PATH"], artifact.SYSTEM_PATH)
        for options in (build_options, show_options, version_options):
            self.assertIs(options.get("kill_group_after"), True)
        self.assertEqual(version_env, {})


# --- archive checks ----------------------------------------------------------------------------

class ArchiveTests(unittest.TestCase):
    BINARY = macho()

    def statuses(self, archive: bytes, binary: Optional[bytes] = None):
        results, stream = artifact.archive_checks(archive, self.BINARY if binary is None else binary)
        statuses = {name: ("not-run" if found is None else ("pass" if not found else "fail")) for name, found in results.items()}
        reasons = {name: [reason for reason, _ in (found or [])] for name, found in results.items()}
        return statuses, reasons, stream

    def good(self, fmt: int = tarfile.USTAR_FORMAT, **fields) -> bytes:
        return tar_bytes([ustar_member("apple", self.BINARY, **fields)], fmt=fmt)

    def assert_members_fail(self, raw: bytes, reason: str) -> None:
        statuses, reasons, _ = self.statuses(gzip.compress(raw, mtime=0))
        self.assertEqual(statuses["archive-stream"], "pass")
        self.assertEqual(statuses["archive-members"], "fail", statuses)
        self.assertTrue(any(reason in text for text in reasons["archive-members"]), reasons["archive-members"])

    def test_good_ustar_and_pax_archives_pass(self) -> None:
        for label, raw in (("ustar", self.good()), ("pax with mtime only", self.good(tarfile.PAX_FORMAT, mtime=1700000000.5))):
            with self.subTest(case=label):
                statuses, _, stream = self.statuses(gzip.compress(raw, mtime=0))
                self.assertEqual(statuses, {name: "pass" for name in artifact.ARCHIVE_CHECKS})
                self.assertEqual(stream, raw)
                failures, member = artifact.raw_tar_walk(raw)
                self.assertEqual(failures, [])
                with tarfile.open(fileobj=io.BytesIO(raw)) as handle:
                    parsed = handle.getmembers()[0]
                self.assertEqual(member, (parsed.offset_data, parsed.size))

    def test_member_refusals(self) -> None:
        link = ustar_member("apple", b"", type=tarfile.SYMTYPE, linkname="/bin/sh")
        cases = {
            "two members": (tar_bytes([ustar_member("apple", self.BINARY), ustar_member("other", b"x")]), "2 members"),
            "AppleDouble beside apple": (tar_bytes([ustar_member("._apple", b"\0\5\26\7"), ustar_member("apple", self.BINARY)]),
                                         "2 members"),
            "uid 501": (self.good(uid=501), "uid 0 and gid 0"),
            "gid 20": (self.good(gid=20), "uid 0 and gid 0"),
            "uname set": (self.good(uname="builder"), "owner or group name"),
            "gname set": (self.good(gname="staff"), "owner or group name"),
            "setuid mode": (self.good(mode=0o4755), "mode is not 0755"),
            "0644 mode": (self.good(mode=0o644), "mode is not 0755"),
            "symlink member": (tar_bytes([link]), "not a regular file"),
            "parent path": (tar_bytes([ustar_member("../apple", self.BINARY)]), "not named apple"),
            "absolute path": (tar_bytes([ustar_member("/apple", self.BINARY)]), "not named apple"),
            "global PAX header": (tar_bytes([ustar_member("apple", self.BINARY)], fmt=tarfile.PAX_FORMAT,
                                            global_headers={"comment": "x"}), "global PAX header"),
            "extra PAX key": (self.good(tarfile.PAX_FORMAT, pax_headers={"SCHILY.xattr.x": "1"}), "PAX key(s) other than mtime"),
            "no members": (tar_bytes([]), "0 members"),
        }
        for label, (raw, reason) in cases.items():
            with self.subTest(case=label):
                self.assert_members_fail(raw, reason)

    def test_link_name_on_a_regular_member_is_refused(self) -> None:
        self.assert_members_fail(self.good(linkname="elsewhere"), "link name")

    def test_raw_record_refusals_that_tarfile_alone_misses(self) -> None:
        good = self.good()
        member = raw_header("apple", b"0", len(self.BINARY)) + padded(self.BINARY)
        cases = {
            "a second archive after the first terminator": (good + tar_bytes([ustar_member("other", b"x")]),
                                                            "non-zero bytes follow the member"),
            "an empty global PAX header": (raw_header("pax_global_header", b"g", 0) + good, "type 'g'"),
            "a garbage record after the member, then a valid header": (
                member + b"\xff" * 512 + raw_header("other", b"0", 1) + padded(b"x") + b"\0" * 1024,
                "not followed by two zero records"),
            "one non-zero byte in the end padding": (good[:-1] + b"\x01", "non-zero bytes follow the member"),
            "a single end record": (member + b"\0" * 512, "not followed by two zero records"),
            "two chained per-file PAX headers": (pax_header(MTIME_RECORD) + pax_header(MTIME_RECORD) + member + b"\0" * 1024,
                                                 "more than one per-file PAX header"),
        }
        for label, (raw, reason) in cases.items():
            with self.subTest(case=label):
                members, roundtrip, _ = artifact.archive_member_checks(raw, self.BINARY)
                self.assertEqual((members, roundtrip), ([], []), "tarfile alone accepts this stream")
                self.assert_members_fail(raw, reason)

    def test_one_well_formed_pax_header_passes_the_raw_walk(self) -> None:
        raw = pax_header(MTIME_RECORD) + raw_header("apple", b"0", len(self.BINARY)) + padded(self.BINARY) + b"\0" * 1024
        self.assertEqual(artifact.raw_tar_walk(raw), ([], (1536, len(self.BINARY))))
        statuses, _, _ = self.statuses(gzip.compress(raw, mtime=0))
        self.assertEqual(statuses, {name: "pass" for name in artifact.ARCHIVE_CHECKS})

    def test_pax_header_refusals(self) -> None:
        member = raw_header("apple", b"0", len(self.BINARY)) + padded(self.BINARY) + b"\0" * 1024
        cases = {
            "an extra key": (pax_header(MTIME_RECORD + b"11 uid=501\n"), "a key other than mtime"),
            "a length longer than the record": (pax_header(b"21 mtime=1700000000\n"), "record is malformed"),
            "a length shorter than the record": (pax_header(b"19 mtime=1700000000\n"), "record is malformed"),
            "a record not ending in a line feed": (pax_header(b"20 mtime=1700000000x"), "record is malformed"),
            "records that do not fill the size": (pax_header(MTIME_RECORD + b"x"), "record is malformed"),
            "a record without a key": (pax_header(b"9 =value\n"), "record is malformed"),
            "a record without '='": (pax_header(b"11 mtime 1\n"), "record is malformed"),
            "a length with a leading zero": (pax_header(b"020 mtime=170000000\n"), "record is malformed"),
            "non-zero padding after the data": (pax_header(MTIME_RECORD, b"\0" * 491 + b"\x01"), "non-zero padding follows a PAX"),
        }
        for label, (header, reason) in cases.items():
            with self.subTest(case=label):
                failures, placement = artifact.raw_tar_walk(header + member)
                self.assertIsNone(placement)
                self.assertTrue(any(reason in text for text, _ in failures), failures)
        self.assertEqual(artifact.pax_records(MTIME_RECORD + b"18 path=x/y/zzzzz\n"),
                         [("mtime", b"1700000000"), ("path", b"x/y/zzzzz")])
        self.assertEqual(artifact.pax_records(b""), [])

    def test_pax_length_and_mtime_shapes(self) -> None:
        member = raw_header("apple", b"0", len(self.BINARY)) + padded(self.BINARY) + b"\0" * 1024
        long_length = b"1" + b"0" * 20  # 21 digits, built at run time
        twenty_one_digits = b"1" * 21
        cases = {
            "a length field longer than 20 digits": (pax_header(long_length + b" mtime=1\n"), "record is malformed"),
            "no record at all": (pax_header(b""), "holds no record"),
            "an mtime that is not a number": (pax_header(pax_record(b"mtime", b"soon")), "not a decimal number"),
            "an mtime in exponent form": (pax_header(pax_record(b"mtime", b"1e9")), "not a decimal number"),
            "an empty mtime": (pax_header(pax_record(b"mtime", b"")), "not a decimal number"),
            "an mtime with ten fraction digits": (pax_header(pax_record(b"mtime", b"1." + b"5" * 10)),
                                                  "not a decimal number"),
            "an mtime of 21 digits": (pax_header(pax_record(b"mtime", twenty_one_digits)), "not a decimal number"),
            "an mtime with a trailing space": (pax_header(pax_record(b"mtime", b"1 ")), "not a decimal number"),
        }
        for label, (header, reason) in cases.items():
            with self.subTest(case=label):
                failures, placement = artifact.raw_tar_walk(header + member)
                self.assertIsNone(placement)
                self.assertTrue(any(reason in text for text, _ in failures), failures)
        for value in (b"0", b"-1", b"1700000000", b"1700000000.5", b"1." + b"5" * 9, b"9" * 20):
            with self.subTest(value=value):
                failures, placement = artifact.raw_tar_walk(pax_header(pax_record(b"mtime", value)) + member)
                self.assertEqual((failures, placement), ([], (1536, len(self.BINARY))))
        self.assertIsNone(artifact.pax_records(long_length + b" x=1\n"))
        # A huge length field is refused by its shape, before int() could be asked to parse it.
        self.assertIsNone(artifact.pax_records(b"1" * 5000 + b" x=1\n"))
        self.assertEqual(pax_record(b"mtime", b"1700000000"), MTIME_RECORD)

    def test_non_zero_padding_after_the_member_is_refused(self) -> None:
        data = b"m" * 45  # short, so the member's record carries padding
        raw = raw_header("apple", b"0", len(data)) + data + b"\x01" + b"\0" * 466 + b"\0" * 1024
        members, roundtrip, _ = artifact.archive_member_checks(raw, data)
        self.assertEqual((members, roundtrip), ([], []), "tarfile alone accepts this stream")
        failures, placement = artifact.raw_tar_walk(raw)
        self.assertEqual(failures, [("non-zero padding follows the member's data", "assertion")])
        self.assertEqual(placement, (512, 45))

    def test_raw_record_refusals(self) -> None:
        cases = {
            "a bad header checksum": (raw_header("apple", b"0", len(self.BINARY), checksum_ok=False) + padded(self.BINARY)
                                      + b"\0" * 1024, "checksum does not verify"),
            "a CONTTYPE member": (tar_bytes([ustar_member("apple", self.BINARY, type=tarfile.CONTTYPE)]), "type '7'"),
            "a GNU long-name record": (raw_header("././@LongLink", b"L", 6) + padded(b"apple\0") + self.good(), "type 'L'"),
            "a hard-link record": (raw_header("apple", b"1", 0) + b"\0" * 1024, "type '1'"),
            "a directory record": (raw_header("dir/", b"5", 0) + self.good(), "type '5'"),
            "a member named otherwise in the raw header": (raw_header("apple2", b"0", 1) + padded(b"x") + b"\0" * 1024,
                                                           "does not name apple"),
            "a non-octal size": (raw_header("apple", b"0", 0)[:124] + b"zzzzzzzzzzz\0" + raw_header("apple", b"0", 0)[136:],
                                 "checksum does not verify"),
            "a stream ending inside a header": (b"\x01" * 100, "ends inside a header record"),
            "an end record before any member": (b"\0" * 1024, "end record before its member"),
            "data running past the stream": (raw_header("apple", b"0", 4096) + b"x" * 512, "runs past the end"),
        }
        for label, (raw, reason) in cases.items():
            with self.subTest(case=label):
                failures, _ = artifact.raw_tar_walk(raw)
                self.assertTrue(any(reason in text for text, _ in failures), failures)

    def test_the_raw_walk_and_tarfile_must_agree_on_the_member(self) -> None:
        # No real stream makes only this cross-check disagree (every such stream also fails another
        # check), so the walker's answer is replaced to show the agreement guard on its own.
        archive = gzip.compress(self.good(), mtime=0)
        with mock.patch.object(artifact, "raw_tar_walk", lambda stream: ([], (0, 1))):
            statuses, reasons, _ = self.statuses(archive)
        self.assertEqual(statuses["archive-members"], "fail")
        self.assertEqual(reasons["archive-members"],
                         ["the raw record walk and tarfile disagree on the member's offset or size"])

    def test_member_bytes_must_equal_the_binary(self) -> None:
        statuses, reasons, _ = self.statuses(gzip.compress(self.good(), mtime=0), binary=self.BINARY + b"\0")
        self.assertEqual(statuses["archive-members"], "pass")
        self.assertEqual(statuses["archive-roundtrip"], "fail")
        self.assertIn("the member's bytes differ from the built binary", reasons["archive-roundtrip"])

    def test_stream_refusals(self) -> None:
        good = gzip.compress(self.good(), mtime=0)
        cases = {
            "trailing bytes": (good + b"\0junk", "bytes follow the first gzip member"),
            "two gzip members": (good + gzip.compress(b"more", mtime=0), "bytes follow the first gzip member"),
            "not gzip": (self.good(), "not a valid gzip stream"),
            "truncated": (good[:len(good) // 2], "truncated"),
            "empty": (b"", "truncated"),
        }
        for label, (archive, reason) in cases.items():
            with self.subTest(case=label):
                statuses, reasons, _ = self.statuses(archive)
                self.assertEqual(statuses["archive-stream"], "fail")
                self.assertTrue(any(reason in text for text in reasons["archive-stream"]), reasons)

    def test_a_decompression_bomb_is_refused_at_the_cap(self) -> None:
        bomb = gzip.compress(b"\0" * 8192, mtime=0)
        with mock.patch.object(artifact, "MAX_DECOMPRESSED_BYTES", 4096):
            statuses, reasons, stream = self.statuses(bomb)
        self.assertIsNone(stream)
        self.assertEqual(statuses["archive-stream"], "fail")
        self.assertIn("the archive decompresses past the recorded size cap", reasons["archive-stream"])
        with mock.patch.object(artifact, "MAX_DECOMPRESSED_BYTES", 8192):
            stream, failures = artifact.decompress_single_member(bomb)
        self.assertEqual((len(stream), failures), (8192, []))

    def test_a_large_member_decompresses_in_chunks(self) -> None:
        payload = os.urandom(300000) + b"\0" * 2000000
        stream, failures = artifact.decompress_single_member(gzip.compress(payload, mtime=0))
        self.assertEqual((stream, failures), (payload, []))


# --- checksum ----------------------------------------------------------------------------------

class ChecksumTests(TempCase):
    ARCHIVE = b"archive bytes for the checksum tests"

    def check(self, stdout: Optional[bytes] = None, verify=None, checksum=None):
        out = self.tmp / "out-{}".format(len(list(self.tmp.iterdir())))
        out.mkdir()
        (out / ARCHIVE_NAME).write_bytes(self.ARCHIVE)
        overrides = {}
        if stdout is not None:
            overrides["checksum"] = result(0, stdout)
        if checksum is not None:
            overrides["checksum"] = checksum
        if verify is not None:
            overrides["checksum_verify"] = verify
        return artifact.check_checksum(FakeTools(**overrides), out, ARCHIVE_NAME, self.ARCHIVE), out

    def line(self, digest: Optional[str] = None, name: str = ARCHIVE_NAME, sep: str = "  ", end: str = "\n") -> bytes:
        return ((digest or hashlib.sha256(self.ARCHIVE).hexdigest()) + sep + name + end).encode("ascii")

    def test_good_checksum_passes_and_is_written_verbatim(self) -> None:
        failures, out = self.check()
        self.assertEqual(failures, [])
        self.assertEqual((out / (ARCHIVE_NAME + ".sha256")).read_bytes(), self.line())

    def test_refusals(self) -> None:
        digest = hashlib.sha256(self.ARCHIVE).hexdigest()
        cases = {
            "second line": (self.line() + b"extra\n", "not exactly one line"),
            "single space": (self.line(sep=" "), "not exactly one line"),
            "binary-mode marker": (self.line(sep=" *"), "not exactly one line"),
            "uppercase hex": (self.line(digest=digest.upper()), "not exactly one line"),
            "wrong name": (self.line(name="apple-macos-arm64.tar.gz"), "not exactly one line"),
            "missing final newline": (self.line(end=""), "not exactly one line"),
            "CRLF": (self.line(end="\r\n"), "not exactly one line"),
            "wrong digest": (self.line(digest=hashlib.sha256(b"other").hexdigest()), "does not match"),
        }
        for label, (stdout, reason) in cases.items():
            with self.subTest(case=label):
                failures, _ = self.check(stdout, verify=result(0))
                self.assertTrue(any(reason in text for text, _ in failures), failures)
                for text, _ in failures:
                    self.assertNotIn(NEW_VERSION, text)
                    self.assertIsNone(HEX64_RE.search(text))

    def test_shasum_check_failure_fails(self) -> None:
        failures, _ = self.check(verify=result(1))
        self.assertEqual(failures, [("shasum -a 256 -c exited 1", "assertion")])

    def test_shasum_failure_is_a_tool_failure(self) -> None:
        failures, out = self.check(checksum=result(2))
        self.assertEqual(failures, [("shasum -a 256 exited 2", "tool")])
        self.assertFalse((out / (ARCHIVE_NAME + ".sha256")).exists())


# --- paths -------------------------------------------------------------------------------------

class PathScanTests(unittest.TestCase):
    def test_each_prefix_is_counted_and_never_quoted(self) -> None:
        for prefix in artifact.PATH_PREFIXES:
            with self.subTest(prefix=prefix):
                reasons = artifact.path_hits([("binary", b"x" + prefix + b"MARKERQZX\0" + prefix + b"MARKERQZX")])
                self.assertIn("binary: 2 occurrence(s) of the {} prefix class (outside any section: 2)".format(prefix.decode()),
                              reasons)
                for reason in reasons:  # only classes the inserted prefix itself contains
                    named = reason.split(" of the ", 1)[1].split(" prefix class", 1)[0]
                    self.assertIn(named.encode(), prefix)
                self.assertNotIn("MARKERQZX", " ".join(reasons))
        self.assertEqual(artifact.path_hits([("binary", b"/usr/lib/libSystem.B.dylib ~/x /var/log /Volumes/x /tmpx")]), [])
        self.assertIn(b"/var/tmp/", artifact.PATH_PREFIXES)
        self.assertNotIn(b"/Volumes/", artifact.PATH_PREFIXES)
        # The product's Messages attachment guard holds the literal "/tmp/" (ChatDB.swift), so a
        # bare /tmp/ class would fail every real build; /private/tmp/ covers the resolved form.
        self.assertNotIn(b"/tmp/", artifact.PATH_PREFIXES)
        self.assertEqual(artifact.path_hits([("binary", b"\0/tmp\0/tmp/\0/private/tmp\0")]), [])

    def test_hits_name_the_section_holding_them(self) -> None:
        prefix = artifact.PATH_PREFIXES[0]
        data = macho(tail=prefix + b"MARKERQZX", tail_section=(b"__TEXT", b"__cstring"))
        info = artifact.read_macho(data)
        reasons = artifact.path_hits([("binary", data)], info.sections)
        self.assertEqual(reasons, ["binary: 1 occurrence(s) of the {} prefix class (__TEXT,__cstring: 1)".format(prefix.decode())])
        outside = macho(tail=prefix + b"MARKERQZX")
        self.assertEqual(artifact.path_hits([("binary", outside)], artifact.read_macho(outside).sections),
                         ["binary: 1 occurrence(s) of the {} prefix class (outside any section: 1)".format(prefix.decode())])
        self.assertEqual(artifact.path_hits([("archive (compressed)", prefix)]),
                         ["archive (compressed): 1 occurrence(s) of the {} prefix class".format(prefix.decode())])


# --- redaction ---------------------------------------------------------------------------------

class RedactionTests(TempCase):
    def test_redactor_replaces_values_paths_home_and_escapes_controls(self) -> None:
        work = self.tmp / "work"
        redactor = artifact.Redactor({"<work>": work, "<candidate>": self.tmp / "candidate"}, str(self.tmp / "home"))
        redactor.version = NEW_VERSION
        alias = str(work)[len("/private"):] if str(work).startswith("/private/") else "/private" + str(work)
        text = "v{} {} {}/x {}/src {}/.cache \x07 \u2028 \x85".format(
            NEW_VERSION, "ab" * 32, work, alias, self.tmp / "home")
        cleaned = redactor(text)
        self.assertEqual(cleaned, "v<predicted version> <hex> <work>/x <work>/src ~/.cache \\x07 \\u2028 \\x85")
        self.assertEqual(artifact.Redactor(home="/").redact("/usr"), "/usr")

    def test_redactor_replaces_home_only_at_a_path_boundary(self) -> None:
        users = "/" + "Users" + "/"  # built at run time: no home-path literal in tracked text
        redactor = artifact.Redactor(home=users + "x")
        self.assertEqual(redactor.redact(users + "xy/f"), users + "<user>/f")
        self.assertEqual(redactor.redact(users + "x/f"), "~/f")
        self.assertEqual(redactor.redact("at " + users + "x"), "at ~")
        self.assertEqual(redactor.redact(users + "x:1"), "~:1")
        self.assertEqual(redactor.redact(users + "x.y/f " + users + "x-y"), users + "<user>/f " + users + "<user>")
        self.assertEqual(redactor.redact(users + "someone"), users + "<user>")
        self.assertEqual(artifact.Redactor().redact(users + "a/b " + users + "<user>"), users + "<user>/b " + users + "<user>")

    def test_redactor_replaces_users_and_home_names_in_any_case(self) -> None:
        users, home = "/" + "Users" + "/", "/" + "home" + "/"  # built at run time
        redactor = artifact.Redactor()
        self.assertEqual(redactor.redact(home + "alice/x"), home + "<user>/x")
        self.assertEqual(redactor.redact(home.upper() + "alice"), home + "<user>")
        self.assertEqual(redactor.redact(users.lower() + "bob/y " + users.upper() + "carol"),
                         users + "<user>/y " + users + "<user>")
        self.assertEqual(redactor.redact("x" + home + "dave z"), "x" + home + "<user> z")
        self.assertEqual(redactor.redact("/homestead/x /Usersx/y"), "/homestead/x /Usersx/y")

    def test_redactor_matches_path_spellings_case_insensitively(self) -> None:
        work = self.tmp / "WorkDir"
        home = self.tmp / "HomeDir"
        redactor = artifact.Redactor({"<work>": work}, str(home))
        self.assertEqual(redactor.redact(str(work).upper() + "/x " + str(home).lower() + "/y"), "<work>/x ~/y")
        self.assertNotIn("~", redactor.redact(str(home).swapcase() + "z/y"))  # no path boundary after HOME

    def test_build_error_lines_print_only_safe_locations_and_class_counts(self) -> None:
        source = self.tmp / "work" / "src"
        log = self.tmp / "build.log"
        lines = ["note: {}".format(BUILD_MARKER)] + [
            "{}/Sources/F{:02d}.swift:1:{}: error: {}".format(source, index, index + 1, BUILD_MARKER) for index in range(30)
        ] + [
            "{}/Sources/F29.swift:1:30: error: the same location again".format(source),
            "Sources/Rel/Z.swift:3:9: error: relative to the source clone",
            "{}/Sources/./Dot.swift:4:4: error: a dot segment normalises away".format(source),
            "{}/Sources/../../escape.swift:1:1: error: dotdot".format(source),
            "{}/elsewhere/W.swift:2:2: error: outside".format(self.tmp),
            "{}/Sources/{}bidi.swift:5:5: error: an unsafe character".format(source, chr(0x202E)),
            "{}/Sources/sp ace.swift:6:6: error: a space".format(source),
            "x.swift:99999999:1: error: an eight-digit line number",
            "error: failed to fetch https://example.com/x.git",
            "error: Package.resolved is out of date",
            "error: could not clone the dependency",
            "ld: error: library not found",
            "error: linker command failed with exit code 1",
            "error: the Package.swift manifest does not parse",
            "error: something else entirely",
            "error: build: a stage failed",
            "warning: not an error line",
        ]
        log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        relayed = artifact.build_error_lines(log, source)
        # 32 distinct locations (F00-F29, Z, Dot; the repeated F29 collapses): the last 20 are kept.
        located = ["release-artifact: build | Sources/F{:02d}.swift:1:{}: error".format(index, index + 1)
                   for index in range(12, 29)]
        self.assertEqual(relayed, located + [
            "release-artifact: build | Sources/F29.swift:1:30: error",
            "release-artifact: build | Sources/Rel/Z.swift:3:9: error",
            "release-artifact: build | Sources/Dot.swift:4:4: error",
            "release-artifact: build | other error lines by class: dependency fetch or resolution 3, linker 2, "
            "manifest 1, other 7",
        ])

    def test_compiler_paths_resolve_against_the_source_clone(self) -> None:
        source = self.tmp / "work" / "src"
        self.assertEqual(artifact.source_relative_path(str(source) + "/Sources/A.swift", source), "Sources/A.swift")
        self.assertEqual(artifact.source_relative_path("Sources/A.swift", source), "Sources/A.swift")
        alias = str(source)[len("/private"):] if str(source).startswith("/private/") else "/private" + str(source)
        if os.path.realpath(alias) == os.path.realpath(str(source)):  # macOS: /var and /tmp link into /private
            self.assertEqual(artifact.source_relative_path(alias + "/Sources/A.swift", source), "Sources/A.swift")
        else:  # elsewhere the /private spelling names another place
            self.assertIsNone(artifact.source_relative_path(alias + "/Sources/A.swift", source))
        for raw in (str(source) + "/../src/Sources/A.swift", str(source) + "x/Sources/A.swift", str(source),
                    str(source) + "/Sources/" + "a" * 300 + ".swift", "/elsewhere/Sources/A.swift",
                    str(source) + "/Sources/A" + chr(0x200B) + ".swift", "../src/A.swift"):
            with self.subTest(raw=raw):
                self.assertIsNone(artifact.source_relative_path(raw, source))

    def test_a_symlink_inside_the_clone_pointing_outside_is_counted_not_printed(self) -> None:
        source = self.tmp / "work" / "src"
        (source / "Sources").mkdir(parents=True)
        outside = self.tmp / "outside"
        outside.mkdir()
        os.symlink(str(outside), str(source / "Linked"))
        log = self.tmp / "linked.log"
        log.write_text("{0}/Linked/X.swift:1:1: error: {1}\n{0}/Sources/Y.swift:2:2: error: {1}\n".format(
            source, BUILD_MARKER), encoding="utf-8")
        self.assertIsNone(artifact.source_relative_path(str(source / "Linked" / "X.swift"), source))
        self.assertIsNone(artifact.source_relative_path("Linked/X.swift", source))
        self.assertEqual(artifact.build_error_lines(log, source), [
            "release-artifact: build | Sources/Y.swift:2:2: error",
            "release-artifact: build | other error lines by class: dependency fetch or resolution 0, linker 0, "
            "manifest 0, other 1",
        ])
        os.symlink(str(source / "Sources"), str(source / "Inner"))  # a link that stays inside is fine
        self.assertEqual(artifact.source_relative_path(str(source / "Inner" / "Z.swift"), source), "Inner/Z.swift")

    def test_no_error_line_and_partial_first_line(self) -> None:
        source = self.tmp / "work" / "src"
        log = self.tmp / "quiet.log"
        log.write_text("compiling\nlinking\n", encoding="utf-8")
        self.assertEqual(artifact.build_error_lines(log, source),
                         ["release-artifact: build | no compiler error line was found in the build log"])
        self.assertEqual(artifact.build_error_lines(self.tmp / "absent.log", source),
                         ["release-artifact: build | the build log could not be read"])
        big = self.tmp / "big.log"
        # Read whole, this relative compiler line would print; its tail alone would print too
        # (as "DDD.../STRADDLE.swift"), so only dropping the partial first line keeps it out.
        straddle = "Sources/" + "D" * 60 + "/STRADDLE.swift:1:1: error: x\n"
        tail = "x\n" * ((artifact.BUILD_LOG_TAIL_BYTES - (len(straddle) - 50)) // 2)
        big.write_text("h\n" * 1000 + straddle + tail, encoding="utf-8")
        cut = big.stat().st_size - artifact.BUILD_LOG_TAIL_BYTES
        self.assertTrue(2000 + 8 < cut < 2000 + 68, cut)  # the read starts inside the run of D's
        self.assertEqual(artifact.build_error_lines(big, source),
                         ["release-artifact: build | no compiler error line was found in the build log"])


# --- overlay -----------------------------------------------------------------------------------

class OverlayTests(TempCase):
    def overlay(self, **options) -> Path:
        return make_overlay(self.tmp / "overlay-{}".format(len(list(self.tmp.iterdir()))), **options)

    def refuse(self, overlay: Path, reason: str) -> None:
        with self.assertRaises(artifact.StepFailure) as caught:
            artifact.read_overlay(overlay)
        self.assertEqual(caught.exception.check, "overlay")
        self.assertIn(reason, caught.exception.reason)
        self.assertNotIn(NEW_VERSION, caught.exception.reason)

    def test_good_overlay_yields_the_version_and_the_validated_bytes(self) -> None:
        overlay = self.overlay()
        version, files = artifact.read_overlay(overlay)
        self.assertEqual(version, NEW_VERSION)
        self.assertEqual(files, {rel: (overlay / rel).read_bytes() for rel in (CONSTANT_REL, CHANGELOG_REL)})

    def test_missing_file(self) -> None:
        overlay = self.overlay()
        (overlay / CHANGELOG_REL).unlink()
        self.refuse(overlay, "missing (CHANGELOG.md)")

    def test_third_file(self) -> None:
        overlay = self.overlay()
        (overlay / "Sources" / "extra.swift").write_text("x\n", encoding="utf-8")
        self.refuse(overlay, "outside the allowlist")

    def test_symlink_in_place_of_a_file(self) -> None:
        overlay = self.overlay()
        real = self.tmp / "real-changelog.md"
        (overlay / CHANGELOG_REL).rename(real)
        os.symlink(real, overlay / CHANGELOG_REL)
        self.refuse(overlay, "not a regular file or directory as expected")

    def test_symlinked_directory(self) -> None:
        overlay = self.overlay()
        moved = self.tmp / "moved-sources"
        (overlay / "Sources").rename(moved)
        os.symlink(moved, overlay / "Sources")
        self.refuse(overlay, "allowlisted entr")

    def test_extra_empty_directory(self) -> None:
        overlay = self.overlay()
        (overlay / "empty").mkdir()
        self.refuse(overlay, "1 entry outside the allowlist")

    def test_constant_count_and_shape(self) -> None:
        for label, text, reason in (
            ("zero constants", "public enum AppleVersion {}\n", "found 0"),
            ("two constants", CONSTANT_SOURCE.replace('"26.0.0"', '"{}"'.format(NEW_VERSION)) * 2, "found 2"),
            ("leading zero", CONSTANT_SOURCE.replace('"26.0.0"', '"26.07.13"'), "not strict"),
            ("v prefix", CONSTANT_SOURCE.replace('"26.0.0"', '"v26.7.13"'), "not strict"),
            ("pre-release", CONSTANT_SOURCE.replace('"26.0.0"', '"26.7.13-rc1"'), "not strict"),
        ):
            with self.subTest(case=label):
                overlay = self.overlay()
                (overlay / CONSTANT_REL).write_text(text, encoding="utf-8")
                self.refuse(overlay, reason)

    def test_non_utf8_constant(self) -> None:
        overlay = self.overlay()
        (overlay / CONSTANT_REL).write_bytes(b"\xff\xfe")
        self.refuse(overlay, "not UTF-8")

    def test_changelog_heading_must_match_the_constant(self) -> None:
        self.refuse(self.overlay(heading_version="26.7.14"), "drift gate")
        overlay = self.overlay()
        (overlay / CHANGELOG_REL).write_text(CHANGELOG_SOURCE, encoding="utf-8")
        self.refuse(overlay, "drift gate")


# --- change set, deployment minimum, no-write-path ---------------------------------------------

class ChangeSetTests(TempCase):
    def setUp(self) -> None:
        super().setUp()
        self.candidate = self.tmp / "candidate"
        self.sha = seed_repo(self.candidate)
        self.work = self.tmp / "work"
        self.work.mkdir(mode=0o700)

    def assemble(self, overlay: Path, candidate: Optional[Path] = None, sha: Optional[str] = None,
                 git_runner=artifact.run_git) -> Path:
        files = {rel: (overlay / rel).read_bytes() for rel in artifact.ALLOWLIST}
        return artifact.assemble_source(candidate or self.candidate, sha or self.sha, files, self.work, git_runner)

    def refuse(self, overlay: Path, reason: str, **options) -> None:
        with self.assertRaises(artifact.StepFailure) as caught:
            self.assemble(overlay, **options)
        self.assertEqual(caught.exception.check, "change-set")
        self.assertIn(reason, caught.exception.reason)

    def test_both_files_changed_passes(self) -> None:
        overlay = make_overlay(self.tmp / "overlay")
        source = self.assemble(overlay)
        self.assertEqual(source, self.work / "src")
        for rel in (CONSTANT_REL, CHANGELOG_REL):
            self.assertEqual((source / rel).read_bytes(), (overlay / rel).read_bytes())
        self.assertEqual(git(["status", "--porcelain"], self.candidate), "")

    def test_a_predicted_file_equal_to_head_fails(self) -> None:
        overlay = make_overlay(self.tmp / "overlay")
        (overlay / CHANGELOG_REL).write_text(CHANGELOG_SOURCE, encoding="utf-8")
        self.refuse(overlay, "1 predicted file is unchanged")

    def test_an_extra_status_entry_fails(self) -> None:
        def stray(args, cwd):
            output = artifact.run_git(args, cwd)
            return output + "?? stray\0" if args[0] == "status" else output
        self.refuse(make_overlay(self.tmp / "overlay"), "1 status entry outside the predicted change set", git_runner=stray)

    def test_a_duplicated_status_entry_fails(self) -> None:
        def doubled(args, cwd):
            output = artifact.run_git(args, cwd)
            return output + output.split("\0")[0] + "\0" if args[0] == "status" else output
        self.refuse(make_overlay(self.tmp / "overlay"), "listed more than once", git_runner=doubled)

    def test_a_source_clone_at_another_head_fails(self) -> None:
        def elsewhere(args, cwd):
            if list(args) == ["rev-parse", "HEAD"] and Path(cwd).name == "src":
                return "f" * 40 + "\n"
            return artifact.run_git(args, cwd)
        self.refuse(make_overlay(self.tmp / "overlay"), "the source clone's HEAD does not equal", git_runner=elsewhere)

    def test_an_overlay_that_would_add_an_untracked_file_fails(self) -> None:
        candidate = self.tmp / "no-changelog"
        sha = seed_repo(candidate, changelog=False)
        overlay = make_overlay(self.tmp / "overlay")
        self.refuse(overlay, "no tracked counterpart", candidate=candidate, sha=sha)
        self.assertFalse((self.work / "src" / CHANGELOG_REL).exists())

    def test_a_symlinked_directory_on_the_path_is_refused(self) -> None:
        candidate = self.tmp / "linked"
        candidate.mkdir()
        git(["init", "-q"], candidate)
        git(["config", "commit.gpgsign", "false"], candidate)
        elsewhere = self.tmp / "elsewhere" / "AppleKit"
        elsewhere.mkdir(parents=True)
        (elsewhere / "CommandSupport.swift").write_text(CONSTANT_SOURCE, encoding="utf-8")
        os.symlink(str(self.tmp / "elsewhere"), str(candidate / "Sources"))
        (candidate / CHANGELOG_REL).write_text(CHANGELOG_SOURCE, encoding="utf-8")
        git(["add", "-A"], candidate)
        git(["commit", "-q", "-m", "chore: linked"], candidate)
        sha = git(["rev-parse", "HEAD"], candidate).strip()
        overlay = make_overlay(self.tmp / "overlay")
        self.refuse(overlay, "not a real directory", candidate=candidate, sha=sha)
        self.assertEqual((elsewhere / "CommandSupport.swift").read_text(encoding="utf-8"), CONSTANT_SOURCE)


class DeploymentMinimumTests(unittest.TestCase):
    def test_parses_the_platforms_argument(self) -> None:
        self.assertEqual(artifact.expected_minimum(PACKAGE_SWIFT), (14, 0, 0))
        self.assertEqual(artifact.expected_minimum("platforms: [.macOS(.v14_4)]"), (14, 4, 0))
        self.assertEqual(artifact.expected_minimum("platforms: [ .macOS( .v10_15 ), .iOS(.v17) ]"), (10, 15, 0))
        self.assertEqual(artifact.expected_minimum("platforms: [.macOS(.v26)]"), (26, 0, 0))

    def test_zero_or_several_or_loose_entries_fail(self) -> None:
        for label, text in (
            ("no platforms", "let package = Package(name: \"x\")"),
            ("no macOS", "platforms: [.iOS(.v17)]"),
            ("two macOS", "platforms: [.macOS(.v14), .macOS(.v15)]"),
            ("two lists", "platforms: [.macOS(.v14)]\nplatforms: [.macOS(.v15)]"),
            ("string form", "platforms: [.macOS(\"14.0\")]"),
            ("leading zero", "platforms: [.macOS(.v014)]"),
        ):
            with self.subTest(case=label):
                with self.assertRaises(artifact.StepFailure) as caught:
                    artifact.expected_minimum(text)
                self.assertEqual(caught.exception.check, "deployment-minimum")


class NoWritePathTests(TempCase):
    def setUp(self) -> None:
        super().setUp()
        self.candidate = self.tmp / "candidate"
        seed_repo(self.candidate)

    def refuse(self, candidate: Path, reason: str, environment: Optional[Dict[str, str]] = None) -> str:
        with self.assertRaises(artifact.StepFailure) as caught:
            artifact.check_no_write_path(environment or {}, candidate, artifact.run_git)
        self.assertEqual(caught.exception.check, "no-write-path")
        self.assertIn(reason, caught.exception.reason)
        return caught.exception.reason

    def test_clean_environment_and_config_pass(self) -> None:
        artifact.check_no_write_path({"HOME": "/nonexistent", "PATH": "/usr/bin"}, self.candidate, artifact.run_git)

    def test_each_variable_fails_and_is_named(self) -> None:
        for name in ("GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GITHUB_PAT",
                     "ACTIONS_RUNTIME_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
                     "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS"):
            with self.subTest(variable=name):
                reason = self.refuse(self.candidate, name, {name: "VALUEMARKERQZ"})
                self.assertNotIn("VALUEMARKERQZ", reason)
        artifact.check_no_write_path({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}, self.candidate,
                                     artifact.run_git)

    def test_credential_bearing_local_keys_fail(self) -> None:
        for key, value in (("http.https://example.com/.extraheader", "AUTHORIZATION: basic eA=="),
                           ("http.extraheader", "AUTHORIZATION: basic eA=="),
                           ("credential.helper", "store"),
                           ("credential.https://example.com.username", "example"),
                           ("core.askPass", "/bin/echo"),
                           ("core.sshCommand", "ssh -i key"),
                           ("url.https://user:eA==@example.com/.insteadOf", "https://example.com/"),
                           ("remote.origin.url", "https://user:eA==@example.com/x.git")):
            with self.subTest(key=key):
                git(["config", "--local", key, value], self.candidate)
                try:
                    reason = self.refuse(self.candidate, "the candidate's local git configuration carries 1")
                    self.assertNotIn("eA==", reason)
                finally:
                    git(["config", "--local", "--unset-all", key], self.candidate)
        artifact.check_no_write_path({}, self.candidate, artifact.run_git)

    def test_an_extraheader_reached_only_through_an_include_fails(self) -> None:
        included = self.tmp / "included.cfg"
        included.write_text("[http \"https://example.com/\"]\n\textraheader = AUTHORIZATION: basic eA==\n", encoding="ascii")
        git(["config", "--local", "include.path", str(included)], self.candidate)
        self.refuse(self.candidate, "carries 1 credential-bearing entry")

    def origin_and_clone(self) -> Tuple[Path, Path]:
        origin = self.tmp / "origin"
        seed_repo(origin)
        clone = self.tmp / "clone"
        git(["clone", "-q", str(origin), str(clone)], self.tmp)
        return origin, clone

    def test_a_credential_in_the_origin_repository_fails(self) -> None:
        origin, clone = self.origin_and_clone()
        artifact.check_no_write_path({}, clone, artifact.run_git)
        git(["config", "--local", "credential.helper", "store"], origin)
        self.refuse(clone, "the local remotes' git configuration carries 1")

    def test_a_file_url_origin_is_inspected_too(self) -> None:
        origin, clone = self.origin_and_clone()
        git(["config", "--local", "remote.origin.url", "file://" + str(origin)], clone)
        git(["config", "--local", "http.extraheader", "AUTHORIZATION: basic eA=="], origin)
        self.refuse(clone, "the local remotes' git configuration carries 1")

    def test_every_url_and_pushurl_value_is_inspected(self) -> None:
        # Not only the last remote.origin.url: a second url value and a pushurl, on any remote.
        origin, clone = self.origin_and_clone()
        second = self.tmp / "second"
        seed_repo(second)
        git(["config", "--local", "http.extraheader", "AUTHORIZATION: basic eA=="], second)
        git(["config", "--local", "--add", "remote.origin.url", str(second)], clone)
        git(["config", "--local", "--add", "remote.origin.url", "https://example.com/x.git"], clone)
        reason = self.refuse(clone, "the local remotes' git configuration carries 1")
        self.assertNotIn("eA==", reason)
        git(["config", "--local", "--replace-all", "remote.origin.url", str(origin)], clone)
        artifact.check_no_write_path({}, clone, artifact.run_git)
        git(["config", "--local", "remote.mirror.pushurl", str(second)], clone)
        self.refuse(clone, "the local remotes' git configuration carries 1")
        self.assertEqual(
            artifact.local_remote_directories(
                [("remote.a.url", str(origin)), ("Remote.B.PushURL", "../up"), ("remote.a.url", str(origin)),
                 ("remote.c.url", "https://example.com/x.git"), ("remote.d.fetch", str(second))], clone),
            [origin, clone / "../up"])

    def test_the_worktree_configuration_scope_is_read_too(self) -> None:
        git(["config", "--local", "extensions.worktreeConfig", "true"], self.candidate)
        # Enabled with no config.worktree file: nothing to read there, so nothing to refuse.
        artifact.check_no_write_path({}, self.candidate, artifact.run_git)
        git(["config", "--worktree", "http.extraheader", "AUTHORIZATION: basic eA=="], self.candidate)
        self.assertNotIn("extraheader", git(["config", "--local", "--list"], self.candidate))
        self.refuse(self.candidate, "the candidate's local git configuration carries 1")

    def test_a_worktree_file_is_read_whatever_the_extension_says(self) -> None:
        # Git reads config.worktree only with extensions.worktreeConfig on, by its own boolean
        # rules ("2" counts as true); the scan reads the file whenever it exists, so no spelling
        # of the setting can hide a credential there.
        location = git(["rev-parse", "--git-path", "config.worktree"], self.candidate).strip()
        path = Path(location) if os.path.isabs(location) else self.candidate / location
        path.write_text("[http]\n\textraheader = AUTHORIZATION: basic eA==\n", encoding="utf-8")
        for setting in (None, "2", "false"):
            with self.subTest(setting=setting):
                if setting is not None:
                    git(["config", "--local", "--replace-all", "extensions.worktreeConfig", setting], self.candidate)
                self.refuse(self.candidate, "the candidate's local git configuration carries 1")

    def test_a_linked_worktrees_own_worktree_file_is_read_from_that_worktree(self) -> None:
        linked = self.tmp / "linked-with-file"
        git(["worktree", "add", "--detach", str(linked)], self.candidate)
        location = git(["rev-parse", "--git-path", "config.worktree"], linked).strip()
        path = Path(location) if os.path.isabs(location) else linked / location
        self.assertNotEqual(path.resolve(), (self.candidate / ".git" / "config.worktree").resolve())
        path.write_text("[http]\n\textraheader = AUTHORIZATION: basic eA==\n", encoding="utf-8")
        self.refuse(linked, "the candidate's local git configuration carries 1")
        artifact.check_no_write_path({}, self.candidate, artifact.run_git)

    def test_a_worktree_file_read_failure_names_no_path(self) -> None:
        location = git(["rev-parse", "--git-path", "config.worktree"], self.candidate).strip()
        path = Path(location) if os.path.isabs(location) else self.candidate / location
        path.write_text("[core]\n\tbare = false\n", encoding="utf-8")

        def file_fails(args, cwd):
            if "--file" in args:
                raise artifact.GitError("git config --file {} exited 1".format(args[args.index("--file") + 1]))
            return artifact.run_git(args, cwd)
        with self.assertRaises(artifact.GitError) as caught:
            artifact.config_entries(file_fails, self.candidate)
        self.assertEqual(str(caught.exception), "git config --file <worktree configuration> failed")

    def test_a_repository_with_a_linked_worktree_and_no_extension_passes(self) -> None:
        # Git refuses `config --worktree` once a linked worktree exists, so the scan never asks
        # for that scope; it lists a worktree file, when one exists, with `config --file`.
        linked = self.tmp / "linked-worktree"
        git(["worktree", "add", "--detach", str(linked)], self.candidate)
        calls: List[List[str]] = []

        def recording(args, cwd):
            calls.append(list(args))
            return artifact.run_git(args, cwd)
        for root in (self.candidate, linked):
            with self.subTest(root=root.name):
                artifact.check_no_write_path({}, root, recording)
        self.assertTrue(calls)
        self.assertFalse(any("--worktree" in call for call in calls), calls)

    def test_a_worktree_scope_failure_with_the_file_present_is_not_a_pass(self) -> None:
        git(["config", "--local", "extensions.worktreeConfig", "true"], self.candidate)
        git(["config", "--worktree", "core.bare", "false"], self.candidate)

        def worktree_fails(args, cwd):
            if "--file" in args:
                raise artifact.GitError("git config --file exited 1")
            return artifact.run_git(args, cwd)
        with self.assertRaises(artifact.GitError):
            artifact.check_no_write_path({}, self.candidate, worktree_fails)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads a mode-000 directory")
    def test_an_unreadable_origin_directory_fails_closed(self) -> None:
        origin, clone = self.origin_and_clone()
        os.chmod(str(origin), 0)
        try:
            self.refuse(clone, "the git configuration of a local remote cannot be read")
        finally:
            os.chmod(str(origin), 0o755)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can stat under a mode-000 directory")
    def test_an_origin_that_cannot_be_examined_fails_closed(self) -> None:
        locked = self.tmp / "locked"
        locked.mkdir()
        origin = locked / "origin"
        seed_repo(origin)
        clone = self.tmp / "clone-of-locked"
        git(["clone", "-q", str(origin), str(clone)], self.tmp)
        os.chmod(str(locked), 0)
        try:
            self.refuse(clone, "a local remote's directory cannot be read")
        finally:
            os.chmod(str(locked), 0o755)

    def test_a_local_remote_that_is_not_a_directory_fails(self) -> None:
        plain = self.tmp / "plain-file"
        plain.write_text("x\n", encoding="ascii")
        git(["config", "--local", "remote.origin.url", str(plain)], self.candidate)
        self.refuse(self.candidate, "a local remote is not a directory")

    def test_network_and_missing_origins_are_not_inspected(self) -> None:
        for url in ("https://example.com/x.git", "git@example.com:x/y.git", str(self.tmp / "absent")):
            with self.subTest(url=url):
                git(["config", "--local", "remote.origin.url", url], self.candidate)
                artifact.check_no_write_path({}, self.candidate, artifact.run_git)
        self.assertEqual(artifact.local_directory("../up", self.candidate), self.candidate / "../up")

    def test_names_match_case_insensitively(self) -> None:
        for name in ("HTTP.https://example.com/.ExtraHeader", "Credential.Helper", "CORE.ASKPASS", "core.SSHCommand"):
            with self.subTest(name=name):
                with self.assertRaises(artifact.StepFailure):
                    artifact.check_no_write_path({}, self.candidate, lambda args, cwd, n=name: "core.bare\nfalse\0" + n + "\nx\0")

    def test_a_git_failure_is_not_a_pass(self) -> None:
        def broken(args, cwd):
            raise artifact.GitError("git config exited 1")
        with self.assertRaises(artifact.GitError):
            artifact.check_no_write_path({}, self.candidate, broken)


# --- orchestration end to end with fakes -------------------------------------------------------

class EndToEndTests(TempCase):
    def setUp(self) -> None:
        super().setUp()
        self.candidate = self.tmp / "candidate"
        self.sha = seed_repo(self.candidate)
        self.overlay = make_overlay(self.tmp / "overlay")
        self.runs = 0
        self.work_parent = self.tmp / "WORKMARKERQZ"
        self.work_parent.mkdir()

    def work(self) -> Path:
        return self.work_parent / "work-{}".format(self.runs)

    def run_rehearsal(self, tools: FakeTools, candidate: Optional[Path] = None, sha: Optional[str] = None,
                      git_runner=artifact.run_git):
        self.runs += 1
        report_path = self.tmp / "reports" / "report-{}.json".format(self.runs)
        report_path.parent.mkdir(exist_ok=True)
        request = artifact.resolve_request(candidate or self.candidate, sha or self.sha, self.overlay, self.work(), report_path)
        stdout, stderr = io.StringIO(), io.StringIO()
        status = artifact.execute(request, tools, git_runner, stdout, stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        return status, report, stdout.getvalue(), stderr.getvalue(), report_path.read_text(encoding="utf-8")

    def assert_value_free(self, *texts: str) -> None:
        for text in texts:
            self.assertNotIn(NEW_VERSION, text)
            self.assertNotIn(ARCHIVE_NAME, text)
            self.assertNotIn("WORKMARKERQZ", text)
            self.assertIsNone(HEX64_RE.search(text))

    def test_full_pass_with_fakes(self) -> None:
        tools = FakeTools()
        status, report, stdout, stderr, raw = self.run_rehearsal(tools)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(report["checks"], {name: "pass" for name in artifact.CHECK_NAMES})
        self.assertIs(report["pass"], True)
        self.assertNotIn("failure_class", report)
        self.assertEqual(report["candidate_sha"], self.sha)
        self.assertEqual(report["change_set"], ["CHANGELOG.md", "Sources/AppleKit/CommandSupport.swift"])
        self.assertEqual(report["outward_writes"], [])
        self.assertEqual(report["schema_version"], 1)
        self.assertIn("withheld", report["note"])
        self.assertIn("provisional, HUMAN-DECISIONS D51", report["note"])
        self.assertIn("the bound on outward writes is the workflow", report["note"])
        self.assertEqual(sorted(report), ["candidate_sha", "change_set", "checks", "note", "outward_writes", "pass",
                                          "schema_version"])
        self.assertEqual(json.loads(stdout), report)
        self.assert_value_free(stdout, stderr, raw)
        self.assertNotIn(BUILD_MARKER, stdout + stderr)
        self.assertIn("output goes to <work>/logs/swift-build.log", stderr)
        self.assertEqual(git(["status", "--porcelain"], self.candidate), "")
        work = self.work()
        self.assertTrue((work / "out" / ARCHIVE_NAME).is_file())
        self.assertTrue((work / "out" / (ARCHIVE_NAME + ".sha256")).is_file())
        self.assertEqual(tools.calls.count("swift_build"), 1)

    def test_every_check_runs_on_the_pinned_copy(self) -> None:
        tools = FakeTools()
        status, _, _, stderr, _ = self.run_rehearsal(tools)
        self.assertEqual(status, 0, stderr)
        work = self.work()
        pinned = work / "verify" / "apple"
        for name in ("run_version", "lipo_archs", "otool_libraries", "nm_symbols", "codesign_verify"):
            self.assertEqual(tools.paths[name], pinned, name)
        self.assertEqual(tools.paths["package"], work / "verify")
        self.assertEqual(pinned.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(pinned.read_bytes(), tools.binary)
        self.assertEqual(tools.paths["swift_build"], work / "src")
        for leaf in ("swiftpm/cache", "swiftpm/config", "swiftpm/security"):
            self.assertTrue((work / leaf).is_dir(), leaf)

    def test_the_overlay_is_read_once_and_its_validated_bytes_are_written(self) -> None:
        original = artifact.read_overlay
        overlay = self.overlay

        def read_then_change(path):
            answer = original(path)
            (overlay / CONSTANT_REL).write_text(CONSTANT_SOURCE.replace('"26.0.0"', '"26.7.14"'), encoding="utf-8")
            return answer
        with mock.patch.object(artifact, "read_overlay", read_then_change):
            status, report, _, stderr, _ = self.run_rehearsal(FakeTools())
        self.assertEqual(status, 0, stderr)
        written = (self.work() / "src" / CONSTANT_REL).read_text(encoding="utf-8")
        self.assertIn('"{}"'.format(NEW_VERSION), written)
        self.assertNotIn("26.7.14", written)

    def test_paths_without_a_decompressed_stream_is_never_a_pass(self) -> None:
        # A stream that does not decompress leaves `paths` not-run unless a hit was found.
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools(archive_transform=lambda raw, packed: b"not gzip"))
        self.assertEqual(status, 1)
        self.assertEqual((report["checks"]["archive-stream"], report["checks"]["paths"]), ("fail", "not-run"))
        prefix = artifact.PATH_PREFIXES[0]
        status, report, _, stderr, _ = self.run_rehearsal(
            FakeTools(archive_transform=lambda raw, packed: b"not gzip " + prefix + b"MARKERQZX"))
        self.assertEqual((report["checks"]["archive-stream"], report["checks"]["paths"]), ("fail", "fail"))
        self.assertNotIn("MARKERQZX", stderr)

    def test_a_pinned_copy_changed_during_packaging_fails(self) -> None:
        def tamper(bindir, archive):
            archive.write_bytes(gzip.compress(tar_bytes([ustar_member("apple", (bindir / "apple").read_bytes())]), mtime=0))
            with open(str(bindir / "apple"), "ab") as handle:
                handle.write(b"\0")
            return result(0)
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools(package=tamper))
        self.assertEqual((status, report["checks"]["package"]), (1, "fail"))
        self.assertIn("the pinned binary changed during packaging", stderr)

    def test_one_failed_binary_check_still_reports_the_others(self) -> None:
        status, report, stdout, stderr, raw = self.run_rehearsal(
            FakeTools(codesign_verify=result(1), run_version=result(0, b"26.7.14\n")))
        self.assertEqual(status, 1)
        checks = report["checks"]
        self.assertEqual((checks["signature"], checks["version"]), ("fail", "fail"))
        for name in ("macho", "architecture", "deployment-target", "linkage", "debug-map"):
            self.assertEqual(checks[name], "pass")
        for name in ("paths", "package", "archive-stream", "archive-members", "archive-roundtrip", "checksum",
                     "candidate-untouched"):
            self.assertEqual(checks[name], "not-run")
        self.assertEqual(report["failure_class"], "assertion")
        self.assertIn("release-artifact: FAIL: signature: codesign --verify exited 1", stderr)
        self.assertEqual(stdout, "")
        self.assert_value_free(stdout, stderr, raw)

    def test_paths_are_refused_wherever_they_appear(self) -> None:
        marker = b"MARKERQZX"

        def in_stream(prefix):
            return lambda raw, packed: gzip.compress(raw + prefix + marker, mtime=0)

        def in_compressed(prefix):
            return lambda raw, packed: gzip_with_name(raw, prefix + marker)

        for prefix in artifact.PATH_PREFIXES:
            for surface in ("binary", "archive (decompressed)", "archive (compressed)"):
                with self.subTest(prefix=prefix, surface=surface):
                    if surface == "binary":
                        tools = FakeTools(binary=macho(tail=prefix + marker))
                    elif surface == "archive (decompressed)":
                        tools = FakeTools(archive_transform=in_stream(prefix))
                    else:
                        tools = FakeTools(archive_transform=in_compressed(prefix))
                    status, report, stdout, stderr, raw = self.run_rehearsal(tools)
                    self.assertEqual(status, 1, stderr)
                    self.assertEqual(report["checks"]["paths"], "fail")
                    detail = " (outside any section: 1)" if surface == "binary" else ""
                    expected = "release-artifact: FAIL: paths: {}: 1 occurrence(s) of the {} prefix class{}".format(
                        surface, prefix.decode(), detail)
                    self.assertIn(expected, stderr)
                    for line in stderr.splitlines():
                        if "FAIL: paths:" in line:
                            self.assertTrue(line.startswith("release-artifact: FAIL: paths: {}:".format(surface)), line)
                    self.assertNotIn(marker.decode(), stderr + stdout + raw)
                    if surface == "archive (compressed)":
                        for name in artifact.ARCHIVE_CHECKS:
                            self.assertEqual(report["checks"][name], "pass")
                        self.assertEqual(report["checks"]["checksum"], "not-run")

    def test_build_failure_prints_only_safe_locations_and_class_counts(self) -> None:
        home = self.tmp / "HOMEMARKERQZ"
        digest = "ab" * 32
        bidi, zero_width = chr(0x202E), chr(0x200B)

        def failing(source, work, log_path):
            lines = ["line {}".format(index) for index in range(100)] + [
                "{} note".format(BUILD_MARKER),
                "{}/Sources/X/Y.swift:12:5: error: {} near {} in {}".format(source, BUILD_MARKER, NEW_VERSION, work),
                "error: digest " + digest[:24] + "\x1b[0m" + digest[24:],
                "error: wrote 4194304 bytes to " + ARCHIVE_NAME,
                "error: ##[add-mask]x",
                "error: from {}/.cache\r::error::x".format(home),
                "error: hidden" + bidi + "text" + zero_width,
                "{}/../escape.swift:1:1: error: {}".format(source, BUILD_MARKER),
                "{}/elsewhere/W.swift:2:2: error: {}".format(self.tmp, BUILD_MARKER),
            ]
            log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return result(1)
        status, report, stdout, stderr, raw = self.run_rehearsal(FakeTools(swift_build=failing, environ={"HOME": str(home)}))
        self.assertEqual(status, 1)
        self.assertEqual(report["checks"]["build"], "fail")
        self.assertEqual(report["failure_class"], "tool")
        build_lines = [line for line in stderr.splitlines() if line.startswith("release-artifact: build | ")]
        self.assertEqual(build_lines, [
            "release-artifact: build | Sources/X/Y.swift:12:5: error",
            "release-artifact: build | other error lines by class: dependency fetch or resolution 0, linker 0, "
            "manifest 0, other 8",
        ])
        for leaked in (BUILD_MARKER, digest[:24], digest[24:], "4194304", ARCHIVE_NAME, "##[", "::", "add-mask",
                       "HOMEMARKERQZ", "escape.swift", "W.swift", "line 99", bidi, zero_width):
            self.assertNotIn(leaked, stderr)
        for line in stderr.splitlines():
            self.assertIsNone(RAW_CONTROL_RE.search(line), line)
        self.assert_value_free(stdout, stderr, raw)

    def test_a_git_failure_message_is_redacted(self) -> None:
        def failing_clone(args, cwd):
            if args[0] == "clone":
                raise artifact.GitError("git {} exited 128".format(" ".join(args)))
            return artifact.run_git(args, cwd)
        status, report, stdout, stderr, raw = self.run_rehearsal(FakeTools(), git_runner=failing_clone)
        self.assertEqual((status, report["checks"]["change-set"], report["failure_class"]), (1, "fail", "git"))
        self.assertIn("<work>/src exited 128", stderr)
        self.assertIn("<candidate>", stderr)
        self.assert_value_free(stdout, stderr, raw)

    def test_git_failure_text_is_redacted_before_it_is_recorded(self) -> None:
        # The ledger itself holds the redacted text, independently of the printing layer.
        def failing_clone(args, cwd):
            if args[0] == "clone":
                raise artifact.GitError("git {} exited 128".format(" ".join(args)))
            return artifact.run_git(args, cwd)
        self.runs += 1
        request = artifact.resolve_request(self.candidate, self.sha, self.overlay, self.work(), None)
        redactor = artifact.Redactor({"<work>": request.work, "<candidate>": request.candidate_root})
        printed: List[str] = []
        ledger = artifact.rehearse_artifact(request, FakeTools(), failing_clone, printed.append, redactor)
        self.assertEqual(ledger.status["change-set"], "fail")
        self.assertTrue(any("<work>/src exited 128" in reason for reason in ledger.reasons["change-set"]))
        self.assertNotIn("WORKMARKERQZ", " ".join(ledger.reasons["change-set"]))

    def test_every_stderr_line_passes_the_redactor_whatever_its_origin(self) -> None:
        # A reason that reaches the printer unredacted is still redacted on the way out.
        class LeakyTools(FakeTools):
            def swift_build(self, source, work, log_path):
                raise artifact.StepFailure("build", "stand-in failure under {} with \x07 bell".format(work), "tool")

        status, report, stdout, stderr, raw = self.run_rehearsal(LeakyTools())
        self.assertEqual(report["checks"]["build"], "fail")
        self.assertIn("release-artifact: FAIL: build: stand-in failure under <work> with \\x07 bell", stderr)
        self.assert_value_free(stdout, stderr, raw)
        for line in stderr.splitlines():
            self.assertIsNone(RAW_CONTROL_RE.search(line), line)

    def test_build_timeout_is_classed(self) -> None:
        def hung(source, work, log_path):
            log_path.write_text("", encoding="utf-8")
            return result(-9, timed_out=True)
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools(swift_build=hung))
        self.assertEqual((status, report["checks"]["build"], report["failure_class"]), (1, "fail", "timeout"))
        self.assertIn("no compiler error line was found in the build log", stderr)

    def test_binary_outside_the_build_tree_is_refused(self) -> None:
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "apple").write_bytes(macho())
        status, report, _, stderr, _ = self.run_rehearsal(
            FakeTools(show_bin_path=result(0, (str(outside) + "\n").encode())))
        self.assertEqual(report["checks"]["build"], "fail")
        self.assertIn("outside the source clone's .build tree", stderr)

    def test_symlinked_binary_is_refused(self) -> None:
        def build(source, work, log_path):
            log_path.write_text("", encoding="utf-8")
            target = source / ".build" / "real-apple"
            target.parent.mkdir(parents=True)
            target.write_bytes(macho())
            release = source / ".build" / "arm64-apple-macosx" / "release"
            release.mkdir(parents=True)
            os.symlink(str(target), str(release / "apple"))
            return result(0)
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools(swift_build=build))
        self.assertEqual(report["checks"]["build"], "fail")
        self.assertIn("the built binary is not a regular file", stderr)

    def test_a_symlinked_build_directory_is_refused(self) -> None:
        elsewhere = self.tmp / "elsewhere-build"

        def build(source, work, log_path):
            log_path.write_text("", encoding="utf-8")
            release = elsewhere / "arm64-apple-macosx" / "release"
            release.mkdir(parents=True)
            (release / "apple").write_bytes(macho())
            os.symlink(str(elsewhere), str(source / ".build"))
            return result(0)
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools(swift_build=build))
        self.assertEqual(report["checks"]["build"], "fail")
        self.assertIn("the source clone's .build is not a real directory", stderr)

    def test_show_bin_path_must_be_one_absolute_path(self) -> None:
        for stdout in (b"relative/path\n", b"/a\n/b\n", b""):
            with self.subTest(stdout=stdout):
                status, report, _, _, _ = self.run_rehearsal(FakeTools(show_bin_path=result(0, stdout)))
                self.assertEqual(report["checks"]["build"], "fail")

    def test_package_and_checksum_failures(self) -> None:
        status, report, _, _, _ = self.run_rehearsal(FakeTools(package=result(1)))
        self.assertEqual((report["checks"]["package"], report["failure_class"]), ("fail", "tool"))
        status, report, _, _, _ = self.run_rehearsal(FakeTools(checksum_verify=result(1)))
        self.assertEqual(report["checks"]["checksum"], "fail")
        self.assertEqual(report["checks"]["candidate-untouched"], "not-run")

    def test_a_candidate_dirtied_during_the_run_fails_candidate_untouched(self) -> None:
        candidate = self.candidate

        class DirtyingTools(FakeTools):
            def swift_build(self, source, work, log_path):
                (candidate / "stray-during-build.txt").write_text("x\n", encoding="utf-8")
                return super().swift_build(source, work, log_path)

        status, report, _, stderr, _ = self.run_rehearsal(DirtyingTools())
        self.assertEqual(status, 1)
        checks = report["checks"]
        self.assertEqual(checks["candidate-untouched"], "fail")
        for name in ("build", "package", "checksum", "archive-members"):
            self.assertEqual(checks[name], "pass")
        self.assertIn("release-artifact: FAIL: candidate-untouched: candidate worktree is not clean", stderr)

    def test_dirty_candidate_or_other_head_fails_the_checkout_check(self) -> None:
        (self.candidate / "stray.txt").write_text("x\n", encoding="utf-8")
        tools = FakeTools()
        status, report, _, stderr, _ = self.run_rehearsal(tools)
        self.assertEqual((status, report["checks"]["checkout"]), (1, "fail"))
        self.assertIn("not clean", stderr)
        self.assertNotIn("swift_build", tools.calls)
        (self.candidate / "stray.txt").unlink()
        (self.candidate / "note.txt").write_text("x\n", encoding="utf-8")
        git(["add", "note.txt"], self.candidate)
        git(["commit", "-q", "-m", "fix: later"], self.candidate)
        status, report, _, stderr, _ = self.run_rehearsal(FakeTools())
        self.assertEqual(report["checks"]["checkout"], "fail")
        self.assertIn("HEAD does not equal", stderr)

    def test_missing_package_swift_fails_closed_before_the_build(self) -> None:
        candidate = self.tmp / "no-package"
        sha = seed_repo(candidate, package=False)
        tools = FakeTools()
        status, report, _, _, _ = self.run_rehearsal(tools, candidate, sha)
        self.assertEqual((report["checks"]["deployment-minimum"], report["failure_class"]), ("fail", "io"))
        self.assertNotIn("swift_build", tools.calls)

    def test_injected_platforms_fail_before_any_build(self) -> None:
        for host in (("Linux", "x86_64"), ("Darwin", "x86_64"), ("Linux", "arm64")):
            with self.subTest(host=host):
                tools = FakeTools(host=host)
                status, report, _, _, _ = self.run_rehearsal(tools)
                self.assertEqual(status, 1)
                self.assertEqual(report["failure_class"], "platform")
                self.assertEqual(report["checks"]["platform"], "fail")
                self.assertEqual(report["checks"]["no-write-path"], "not-run")
                self.assertNotIn("swift_build", tools.calls)
                self.assertFalse((self.work() / "src").exists())

    def test_token_in_environment_stops_before_the_clone(self) -> None:
        tools = FakeTools(environ={"GH_TOKEN": "x"})
        status, report, _, _, _ = self.run_rehearsal(tools)
        self.assertEqual(report["checks"]["no-write-path"], "fail")
        self.assertFalse((self.work() / "src").exists())

    def test_internal_errors_keep_the_partial_ledger(self) -> None:
        def explode(binary, cwd):
            raise KeyError(ARCHIVE_NAME)
        status, report, stdout, stderr, raw = self.run_rehearsal(FakeTools(run_version=explode))
        self.assertEqual((status, report["pass"], report["failure_class"]), (1, False, "assertion"))
        for name in ("checkout", "overlay", "platform", "no-write-path", "change-set", "deployment-minimum", "build"):
            self.assertEqual(report["checks"][name], "pass", name)
        self.assertEqual(report["checks"]["macho"], "fail")
        self.assertIn("release-artifact: FAIL: macho: internal error (KeyError)", stderr)
        self.assertNotIn("Traceback", stderr)
        self.assert_value_free(stdout, stderr, raw)

    def test_report_names_every_check_and_class(self) -> None:
        self.assertEqual(len(set(artifact.CHECK_NAMES)), len(artifact.CHECK_NAMES))
        self.assertEqual(set(artifact.FAILURE_CLASSES), {"io", "git", "platform", "assertion", "timeout", "tool"})
        for phrase in ("DEFINITION", "HUMAN-DECISIONS D51", "HUMAN-DECISIONS D23", "does not by itself satisfy",
                       "provisional,\nHUMAN-DECISIONS D51", "of ANY image loaded into the process",
                       "writable by the admin group",
                       "neither D18 step (4)'s check on the published artifact nor D34's operator-local denylist scan",
                       "the toolchain's transient files under TMPDIR", "`--disable-keychain`; HOME is passed through",
                       "`url.<base>.pushInsteadOf` rewrites are not applied", "after normalisation, no `.` or `..` segment",
                       "removes only the `--work` directory it created",
                       "plus the worktree configuration file whenever one exists"):
            # Compared with whitespace collapsed, so reflowing the prose cannot break a phrase.
            self.assertIn(" ".join(phrase.split()), " ".join(artifact.__doc__.split()))
        self.assertNotIn("<work>/tmp", artifact.__doc__)


class LedgerTests(unittest.TestCase):
    def test_a_failed_check_never_moves_back_to_pass(self) -> None:
        ledger = artifact.Ledger()
        ledger.fail("paths", "binary: 1 occurrence(s)", "assertion")
        ledger.record("paths", [])
        ledger.passed("paths")
        ledger.record("paths", None)
        self.assertEqual(ledger.status["paths"], "fail")
        self.assertEqual(ledger.reasons["paths"], ["binary: 1 occurrence(s)"])
        ledger.record("checksum", [])
        self.assertEqual(ledger.status["checksum"], "pass")
        with self.assertRaises(KeyError):
            ledger.record("no-such-check", [])


class ContainmentTests(TempCase):
    def test_inside_compares_by_file_identity(self) -> None:
        real = self.tmp / "real"
        (real / "sub").mkdir(parents=True)
        alias = self.tmp / "alias"
        os.symlink(str(real), str(alias))
        self.assertTrue(artifact.inside(alias / "sub" / "new", real))  # a spelling comparison says no
        self.assertTrue(artifact.inside(real, real))
        self.assertFalse(artifact.inside(self.tmp / "other", real))
        self.assertFalse(artifact.inside(real, self.tmp / "missing"))
        self.assertTrue(artifact.inside(self.tmp / "missing" / "x", self.tmp / "missing"))

    def test_a_case_varied_spelling_on_a_case_insensitive_volume(self) -> None:
        probe = self.tmp / "CaseProbe"
        probe.mkdir()
        if not os.path.exists(str(self.tmp / "caseprobe")):
            self.skipTest("this volume is case-sensitive")
        self.assertTrue(artifact.inside(self.tmp / "CASEPROBE" / "work", probe))


class RunbookParityTests(unittest.TestCase):
    """The script's build and tar recipe must not drift from the urgent-release runbook's."""

    def restored_workflow(self) -> str:
        text = RUNBOOK.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^<!-- restored-workflow: \S+ -->\n(.*?)^<!-- restored-workflow: end -->$", text)
        self.assertIsNotNone(match)
        return match.group(1)

    def test_tar_flags_match_the_runbook(self) -> None:
        lines = self.restored_workflow().split("\n")
        index = next(i for i, line in enumerate(lines) if " tar --uid" in line)
        joined = lines[index].rstrip("\\") + " " + lines[index + 1] if lines[index].rstrip().endswith("\\") else lines[index]
        tokens = shlex.split(joined)
        self.assertEqual(tokens[0], "COPYFILE_DISABLE=1")
        start = tokens.index("tar") + 1
        self.assertEqual(tuple(tokens[start:tokens.index("-C")]), artifact.TAR_FLAGS)
        self.assertIn("-czf", tokens)

    def test_runbook_build_flags_are_in_the_script_build(self) -> None:
        block = self.restored_workflow()
        build_lines = [line.strip() for line in block.split("\n")
                       if line.strip().startswith("swift build ") and "--show-bin-path" not in line]
        self.assertEqual(len(build_lines), 1, build_lines)
        flags = shlex.split(build_lines[0])[2:]
        self.assertEqual(flags, ["-c", "release", "-Xswiftc", "-gnone"])
        pairs = list(zip(artifact.BUILD_ARGUMENTS, artifact.BUILD_ARGUMENTS[1:]))
        for pair in zip(flags[0::2], flags[1::2]):
            self.assertIn(pair, pairs)


# --- CLI ---------------------------------------------------------------------------------------

def run_script(*args: str, cwd: Path):
    return subprocess.run(
        [sys.executable, "-I", "-S", "-B", str(SCRIPT), *args], cwd=str(cwd), stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )


class CliTests(TempCase):
    def setUp(self) -> None:
        super().setUp()
        self.candidate = self.tmp / "candidate"
        # No Package.swift: even a CLI run that got past every earlier check on a Darwin arm64 host
        # would stop at deployment-minimum, so no test here can ever start a real build.
        self.sha = seed_repo(self.candidate, package=False)
        self.overlay = make_overlay(self.tmp / "overlay")
        self.work = self.tmp / "work"

    def invoke(self, *extra: str, sha: Optional[str] = None, overlay: Optional[Path] = None, work: Optional[Path] = None,
               candidate: Optional[Path] = None):
        return run_script("--candidate-root", str(candidate or self.candidate), "--candidate-sha", sha or self.sha,
                          "--overlay", str(overlay or self.overlay), "--work", str(work or self.work), *extra,
                          cwd=self.tmp)

    def refused(self, outcome, message: str) -> None:
        self.assertEqual(outcome.returncode, 2, outcome.stderr)
        self.assertIn(message, outcome.stderr)
        self.assertEqual(outcome.stdout, "")
        self.assertNotIn("Traceback", outcome.stderr)

    def test_bad_sha_is_refused(self) -> None:
        for sha in ("abc123", self.sha.upper(), self.sha + "0"):
            with self.subTest(sha=sha):
                self.refused(self.invoke(sha=sha), "full 40-hex SHA")
        self.assertFalse(self.work.exists())

    def test_missing_candidate_root_is_refused(self) -> None:
        self.refused(self.invoke(candidate=self.tmp / "absent"), "--candidate-root must be a directory")

    def test_a_symlink_loop_is_refused_without_a_traceback(self) -> None:
        os.symlink(str(self.tmp / "loop-b"), str(self.tmp / "loop-a"))
        os.symlink(str(self.tmp / "loop-a"), str(self.tmp / "loop-b"))
        outcome = self.invoke(candidate=self.tmp / "loop-a" / "x")
        self.refused(outcome, "release-artifact: policy:")

    def test_work_inside_candidate_is_refused_without_creating_it(self) -> None:
        for work in (self.candidate / "work", self.candidate / "deep" / "work", self.candidate):
            with self.subTest(work=work):
                self.refused(self.invoke(work=work), "--work must lie outside the candidate root")
        self.assertFalse((self.candidate / "work").exists())
        self.assertFalse((self.candidate / "deep").exists())
        self.assertEqual(git(["status", "--porcelain"], self.candidate), "")

    def test_case_varied_work_inside_candidate_is_refused(self) -> None:
        if not os.path.exists(str(self.tmp / "CANDIDATE")):
            self.skipTest("this volume is case-sensitive")
        self.refused(self.invoke(work=self.tmp / "CANDIDATE" / "work"), "--work must lie outside the candidate root")
        self.assertFalse((self.candidate / "work").exists())

    def test_work_inside_overlay_is_refused(self) -> None:
        self.refused(self.invoke(work=self.overlay / "work"), "--work must lie outside the overlay")
        self.assertFalse((self.overlay / "work").exists())

    def test_candidate_or_overlay_inside_work_is_refused(self) -> None:
        self.refused(self.invoke(work=self.tmp), "the candidate root must not lie inside --work")
        nested = self.tmp / "holder"
        overlay = make_overlay(nested / "overlay")
        self.refused(self.invoke(work=nested, overlay=overlay), "the overlay must not lie inside --work")

    def test_non_empty_work_is_refused(self) -> None:
        self.work.mkdir(mode=0o700)
        (self.work / "old").write_text("x", encoding="utf-8")
        self.refused(self.invoke(), "--work must be empty")

    def test_writable_work_is_refused(self) -> None:
        self.work.mkdir(mode=0o700)
        os.chmod(str(self.work), 0o770)
        self.refused(self.invoke(), "--work must not be group- or world-writable")

    def test_work_that_is_a_file_or_symlink_is_refused(self) -> None:
        self.work.write_text("x", encoding="utf-8")
        self.refused(self.invoke(), "--work must be a real directory")
        target = self.tmp / "target"
        target.mkdir(mode=0o700)
        link = self.tmp / "link"
        os.symlink(str(target), str(link))
        self.refused(self.invoke(work=link), "--work must not be a symlink")

    def test_overlay_symlink_or_missing_is_refused(self) -> None:
        link = self.tmp / "overlay-link"
        os.symlink(str(self.overlay), str(link))
        self.refused(self.invoke(overlay=link), "--overlay must be a real directory, not a symlink")
        self.refused(self.invoke(overlay=self.tmp / "absent"), "--overlay must be a real directory")
        self.assertFalse(self.work.exists())

    def test_report_refusals(self) -> None:
        existing = self.tmp / "existing.json"
        existing.write_text("{}\n", encoding="utf-8")
        self.refused(self.invoke("--report", str(existing)), "does not exist yet")
        self.assertEqual(existing.read_text(encoding="utf-8"), "{}\n")
        link = self.tmp / "report-link.json"
        os.symlink(str(self.tmp / "elsewhere.json"), str(link))
        self.refused(self.invoke("--report", str(link)), "must not be a symlink")
        self.refused(self.invoke("--report", str(self.candidate / "report.json")), "--report must lie outside")
        self.assertFalse(self.work.exists())

    def test_report_inside_work_or_overlay_is_refused(self) -> None:
        self.refused(self.invoke("--report", str(self.work / "report.json")), "--report must lie outside --work and the overlay")
        self.assertFalse(self.work.exists())
        self.refused(self.invoke("--report", str(self.overlay / "report.json")),
                     "--report must lie outside --work and the overlay")
        self.assertFalse((self.overlay / "report.json").exists())

    def test_a_case_varied_report_inside_the_new_work_is_refused_and_work_removed(self) -> None:
        probe = self.tmp / "CaseProbe"
        probe.mkdir()
        if not os.path.exists(str(self.tmp / "caseprobe")):
            self.skipTest("this volume is case-sensitive")
        work = self.tmp / "fresh" / "work"
        report = self.tmp / "FRESH" / "WORK" / "report.json"
        # Before --work exists only spellings can be compared, and these differ; once it exists,
        # file identity catches it, and the directory this run created is removed again.
        self.refused(self.invoke("--report", str(report), work=work), "--report must lie outside --work and the overlay")
        self.assertFalse(work.exists())
        self.assertFalse(report.exists())

    def test_a_report_reached_through_a_link_made_after_creation_is_refused(self) -> None:
        # Portable (no case-insensitive volume needed): a link to --work appears only once --work
        # exists, so only the post-creation identity check can see the report now lies inside it.
        alias = self.tmp / "alias"
        original = artifact.prepare_work

        def create_then_link(work):
            created = original(work)
            os.symlink(str(work), str(alias))
            return created
        stderr = io.StringIO()
        with mock.patch.object(artifact, "prepare_work", create_then_link), contextlib.redirect_stderr(stderr):
            status = artifact.main(["--candidate-root", str(self.candidate), "--candidate-sha", self.sha,
                                    "--overlay", str(self.overlay), "--work", str(self.work),
                                    "--report", str(alias / "report.json")])
        self.assertEqual(status, 2)
        self.assertEqual(stderr.getvalue(), "release-artifact: policy: --report must lie outside --work and the overlay\n")
        self.assertFalse(self.work.exists())
        self.assertTrue(alias.is_symlink())
        self.assertFalse(os.path.lexists(str(self.work / "report.json")))

    def test_overlay_and_candidate_must_not_nest(self) -> None:
        inner = make_overlay(self.tmp / "inner-overlay")
        shutil.move(str(inner), str(self.candidate / "inner-overlay"))
        self.refused(self.invoke(overlay=self.candidate / "inner-overlay"), "--overlay must lie outside the candidate root")
        self.assertFalse(self.work.exists())
        holder = self.tmp / "holder"
        candidate = holder / "candidate"
        sha = seed_repo(candidate, package=False)
        make_overlay(holder)
        self.refused(self.invoke(candidate=candidate, sha=sha, overlay=holder),
                     "the candidate root must not lie inside --overlay")
        self.assertFalse(self.work.exists())

    def test_a_path_resolution_error_names_no_cause(self) -> None:
        stderr = io.StringIO()
        failing = mock.patch.object(artifact, "resolve_request", side_effect=RuntimeError("loop at CAUSEMARKERQZ"))
        with failing, contextlib.redirect_stderr(stderr):
            status = artifact.main(["--candidate-root", str(self.candidate), "--candidate-sha", self.sha,
                                    "--overlay", str(self.overlay), "--work", str(self.work)])
        self.assertEqual(status, 2)
        self.assertEqual(stderr.getvalue(), "release-artifact: policy: a path could not be resolved\n")

    def test_an_invalid_argument_is_never_echoed(self) -> None:
        outcome = self.invoke("--bogus-ARGMARKERQZ=" + NEW_VERSION)
        self.assertEqual(outcome.returncode, 2)
        self.assertEqual(outcome.stdout, "")
        self.assertEqual(outcome.stderr, "release-artifact: policy: invalid arguments (see --help)\n")
        outcome = run_script("--candidate-sha", "ARGMARKERQZ", cwd=self.tmp)  # required arguments missing
        self.assertEqual((outcome.returncode, outcome.stdout), (2, ""))
        self.assertEqual(outcome.stderr, "release-artifact: policy: invalid arguments (see --help)\n")
        self.assertFalse(self.work.exists())

    @unittest.skipIf(platform.system() == "Darwin" and os.uname().machine == "arm64",
                     "on Darwin arm64 the platform check passes; the injected-platform test covers it")
    def test_this_host_fails_the_platform_check_before_any_build(self) -> None:
        report = self.tmp / "report.json"
        outcome = self.invoke("--report", str(report))
        self.assertEqual(outcome.returncode, 1, outcome.stderr)
        document = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual((document["pass"], document["failure_class"]), (False, "platform"))
        self.assertEqual((document["checks"]["checkout"], document["checks"]["overlay"], document["checks"]["platform"]),
                         ("pass", "pass", "fail"))
        self.assertFalse((self.work / "src").exists())
        self.assertNotIn(NEW_VERSION, outcome.stdout + outcome.stderr)


# --- release preparation's real output, end to end --------------------------------------------

class ReleasePrepIntegrationTests(TempCase):
    """The real scripts/ci/release_prep.py renders the overlay; the artifact rehearsal then runs on
    it with the fake build and tools, whose binary prints the version the overlay holds."""

    def test_real_release_prep_output_passes_every_check(self) -> None:
        candidate = self.tmp / "candidate"
        candidate.mkdir()
        git(["init", "-q"], candidate)
        git(["config", "commit.gpgsign", "false"], candidate)
        git(["config", "tag.gpgsign", "false"], candidate)
        (candidate / CONSTANT_REL).parent.mkdir(parents=True)
        (candidate / CONSTANT_REL).write_text(CONSTANT_SOURCE, encoding="utf-8")
        (candidate / CHANGELOG_REL).write_text(
            "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- **Something callers can see.** Manual: "
            "https://github.com/example-owner/example-cli/blob/main/docs/manual/README.md\n\n"
            "## [26.0.0] - 2026-08-30\n\n### Added\n\n- First release.\n", encoding="utf-8")
        (candidate / "Package.swift").write_text(PACKAGE_SWIFT, encoding="utf-8")
        git(["add", "-A"], candidate)
        git(["commit", "-q", "-m", "chore(release): v26.0.0"], candidate)
        git(["tag", "-a", "v26.0.0", "-m", "v26.0.0"], candidate)
        (candidate / "note.txt").write_text("x\n", encoding="utf-8")
        git(["add", "note.txt"], candidate)
        git(["commit", "-q", "-m", "feat: add a caller-visible thing"], candidate)
        sha = git(["rev-parse", "HEAD"], candidate).strip()
        scratch = self.tmp / "scratch"
        prepared = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(SCRIPT.with_name("release_prep.py")), "--candidate-root", str(candidate),
             "--candidate-sha", sha, "--repository", "example-owner/example-cli", "--scratch", str(scratch),
             "--date", "2026-10-10"],
            cwd=str(self.tmp), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            check=False)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        match = re.search(r'current = "([0-9]+\.[0-9]+\.[0-9]+)"', (scratch / CONSTANT_REL).read_text(encoding="utf-8"))
        self.assertIsNotNone(match)
        version = match.group(1)
        self.assertNotEqual(version, OLD_VERSION)
        work = self.tmp / "work"
        report_path = self.tmp / "report.json"
        request = artifact.resolve_request(candidate, sha, scratch, work, report_path)
        stdout, stderr = io.StringIO(), io.StringIO()
        status = artifact.execute(request, FakeTools(version=version), artifact.run_git, stdout, stderr)
        self.assertEqual(status, 0, stderr.getvalue())
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["checks"], {name: "pass" for name in artifact.CHECK_NAMES})
        for text in (stdout.getvalue(), stderr.getvalue(), report_path.read_text(encoding="utf-8")):
            self.assertNotIn(version, text)
            self.assertNotIn(artifact.archive_name(version), text)
            self.assertIsNone(HEX64_RE.search(text))
        self.assertTrue((work / "out" / artifact.archive_name(version)).is_file())
        self.assertEqual(git(["status", "--porcelain"], candidate), "")


# --- macOS: real tools on tiny compiled programs ------------------------------------------------

MACOS_TOOLS = ("/usr/bin/lipo", "/usr/bin/otool", "/usr/bin/nm", "/usr/bin/codesign", "/usr/bin/tar", "/usr/bin/shasum")
C_PROGRAM = (
    "#include <stdio.h>\n#include <string.h>\n"
    "int main(int argc, char **argv) {{\n"
    "  if (argc == 2 && strcmp(argv[1], \"--version\") == 0) {{ puts(\"{}\"); }}\n"
    "  return 0;\n}}\n"
).format(NEW_VERSION)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("cc") and all(os.path.exists(tool) for tool in MACOS_TOOLS),
                     "runs only where cc and Apple's tools exist (an operator's Mac); no CI job runs it")
class RealToolTests(TempCase):
    def setUp(self) -> None:
        super().setUp()
        (self.tmp / "main.c").write_text(C_PROGRAM, encoding="ascii")
        self.tools = artifact.Tools()

    def compile(self, label: str, *flags: str, debug_object: bool = False) -> Path:
        target = self.tmp / label / "apple"
        target.parent.mkdir()
        common = ["cc", "-arch", "arm64", "-mmacosx-version-min=14.0"]
        if debug_object:
            obj = self.tmp / (label + ".o")
            subprocess.run(common + ["-g", "-c", str(self.tmp / "main.c"), "-o", str(obj)], check=True, capture_output=True)
            subprocess.run(common + [str(obj), "-o", str(target)], check=True, capture_output=True)
        else:
            subprocess.run(common + list(flags) + [str(self.tmp / "main.c"), "-o", str(target)], check=True, capture_output=True)
        return target

    def checks(self, binary: Path):
        data = binary.read_bytes()
        results = artifact.binary_checks(self.tools, binary, data, self.tmp, NEW_VERSION, EXPECTED_MINOS)
        return data, {name: ("not-run" if found is None else ("pass" if not found else "fail")) for name, found in results.items()}

    def test_a_plain_thin_binary_passes_and_the_readers_agree(self) -> None:
        binary = self.compile("plain")
        data, statuses = self.checks(binary)
        self.assertEqual(statuses, {name: "pass" for name in artifact.BINARY_CHECKS})
        info = artifact.read_macho(data)
        self.assertEqual(artifact.parse_otool(self.tools.otool_libraries(binary).stdout, binary), info.dylibs)
        self.assertEqual(self.tools.lipo_archs(binary).stdout.split(), [b"arm64"])
        self.assertEqual(artifact.count_oso_lines(self.tools.nm_symbols(binary).stdout), info.oso_count)
        self.assertEqual(info.oso_count, 0)
        self.assertTrue(info.code_signature)
        self.assertTrue(any(name.startswith("__TEXT,") for name, _, _ in info.sections))
        self.assertEqual(artifact.path_hits([("binary", data)], info.sections), [])

    def test_a_debug_object_keeps_the_debug_map_in_both_readers(self) -> None:
        binary = self.compile("debug", debug_object=True)
        data, statuses = self.checks(binary)
        self.assertEqual(statuses["debug-map"], "fail")
        self.assertGreater(artifact.read_macho(data).oso_count, 0)
        self.assertGreater(artifact.count_oso_lines(self.tools.nm_symbols(binary).stdout), 0)

    def test_a_universal_binary_fails_architecture_in_both_readers(self) -> None:
        binary = self.compile("universal", "-arch", "x86_64")
        data, statuses = self.checks(binary)
        self.assertEqual(statuses["architecture"], "fail")
        self.assertIn("a universal (FAT) binary, not a thin arm64 Mach-O", artifact.read_macho(data).header_reasons)
        self.assertNotEqual(self.tools.lipo_archs(binary).stdout.split(), [b"arm64"])

    def test_a_loader_path_rpath_passes_linkage(self) -> None:
        binary = self.compile("rpath", "-Wl,-rpath,@loader_path")
        data, statuses = self.checks(binary)
        self.assertEqual(statuses["linkage"], "pass")
        self.assertEqual(artifact.read_macho(data).rpaths, ["@loader_path"])

    def test_an_rpath_dylib_fails_linkage_in_the_reader_and_in_otool(self) -> None:
        library_dir = self.tmp / "rpathlib"
        library_dir.mkdir()
        (self.tmp / "x.c").write_text("int x_value(void) { return 7; }\n", encoding="ascii")
        (self.tmp / "uses_x.c").write_text(
            "int x_value(void);\nint main(void) { return x_value() == 7 ? 0 : 1; }\n", encoding="ascii")
        common = ["cc", "-arch", "arm64", "-mmacosx-version-min=14.0"]
        subprocess.run(common + ["-dynamiclib", "-install_name", "@rpath/libx.dylib", str(self.tmp / "x.c"),
                                 "-o", str(library_dir / "libx.dylib")], check=True, capture_output=True)
        binary = library_dir / "apple"
        subprocess.run(common + [str(self.tmp / "uses_x.c"), "-L" + str(library_dir), "-lx", "-Wl,-rpath,@loader_path",
                                 "-o", str(binary)], check=True, capture_output=True)
        data = binary.read_bytes()
        info = artifact.read_macho(data)
        self.assertIn("@rpath/libx.dylib", info.dylibs)
        self.assertEqual(info.rpaths, ["@loader_path"])
        reader_only = [reason for reason, _ in artifact.macho_findings(info, EXPECTED_MINOS)["linkage"]]
        self.assertIn("the Mach-O reader: 1 dylib(s) named through an @ path (@rpath/libx.dylib)", reader_only)
        listed = artifact.parse_otool(self.tools.otool_libraries(binary).stdout, binary)
        self.assertEqual(listed, info.dylibs)
        results = artifact.binary_checks(self.tools, binary, data, self.tmp, NEW_VERSION, EXPECTED_MINOS)
        reasons = [reason for reason, _ in results["linkage"]]
        self.assertIn("the Mach-O reader: 1 dylib(s) named through an @ path (@rpath/libx.dylib)", reasons)
        self.assertIn("otool -L: 1 dylib(s) named through an @ path (@rpath/libx.dylib)", reasons)

    def test_real_packaging_and_checksum_pass_every_archive_check(self) -> None:
        binary = self.compile("packaged")
        os.chmod(str(binary), 0o755)
        data = binary.read_bytes()
        out = self.tmp / "out"
        out.mkdir(mode=0o700)
        packaged = self.tools.package(binary.parent, out / ARCHIVE_NAME)
        self.assertEqual(packaged.returncode, 0, packaged.stderr)
        archive = (out / ARCHIVE_NAME).read_bytes()
        results, stream = artifact.archive_checks(archive, data)
        self.assertEqual(results, {name: [] for name in artifact.ARCHIVE_CHECKS})
        self.assertEqual(artifact.path_hits([("archive (compressed)", archive), ("archive (decompressed)", stream)]), [])
        self.assertEqual(artifact.check_checksum(self.tools, out, ARCHIVE_NAME, archive), [])


if __name__ == "__main__":
    unittest.main()
