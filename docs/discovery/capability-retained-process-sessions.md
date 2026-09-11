# Qualified capability process session

Status: specification for the retained-process implementation unit. Implementation and
production runtime qualification remain pending. This document specifies the
process unit of capability verification; claim binding/parsing, Bats distribution
and attestation, and LocalFileOwner recovery remain separate units. Complete
independent final review and the required distribution qualification before the
affected production execution.

## Evidence and remaining claim boundary

A reviewed prototype adapter has eight recorded passing native cases:
receipt absence, positive inherited-FD control, nonzero with a plausible artifact,
aggregate overflow, exited command with output held by its descendant, and
cancellation before spawn, after readiness and during cleanup. The first case
also brackets the worker prelaunch timestamp using the parent's shared clock.
The aggregate results and exact component identities are retained in private
verification records. Earlier failures remain evidence; the historical worker
refusal conjunct and group-signal error cause are not proved by later passes.

The adapter executed frozen qualification/capture/receipt/finalization primitives
and copied orchestration. It did not execute a production process package,
earliest-Git integration, arbitrary imported-caller ownership, hosted runtime, or
local script-owner recovery. Its explicit deadline checks and retained anchor
support this design; they do not prove hard wall-clock bounds for synchronous
filesystem, loader, native or spawn calls. The original successful fixed native
build and three same-process disposition/reset/waitability cases retain their
separate scopes. The production bootstrap must still exercise its actual shared
clock and full build/cleanup/artifact path.

## Scope and trust

Introduce one internal process package, provisionally
`scripts/ci/capability_process.py`, fixed native source
`scripts/ci/capability_process_native.c`, and a closed profile-data sibling
`scripts/ci/capability_process_profiles.json`. Keep command selection, public
diagnostics and evidence policy in `capability_policy.py`. Worker/bootstrap roles
belong to this same trusted package; do not add a generic external supervisor or
public executable override. A separate module is justified only by keeping the
trusted bootstrap import closure small, not by introducing another owner engine.

The initial target profile is standalone macOS arm64 CLT CPython. Its production
profile remains unqualified until the distribution records and actual package
acceptance below pass; prototype qualification does not enable a production row.
A version string, Python `getsignal`, `Popen.returncode is None`, or
current process-group lookup is insufficient. Reject unsupported runtime,
architecture or package identity before any subprocess. Hosted/Xcode rows remain
inactive until separately qualified after public visibility. Local synthetic
evidence cannot activate hosted support or collapse the existing separate hosted
build/Bats jobs.

The externally selected authority entry below supplies TrustedRunnerRoot; it is
not inferred from the candidate checkout or module location. Bind selected Git,
Swift, compiler and SDK/linker records as well as runtime/reset identity. Public
profiles contain canonical distribution/system paths and digests, never personal
or temporary paths. Unqualified mappings refuse before the affected subprocess.

Importing a parser has no signal or subprocess effect. Imported candidate APIs
require an explicit prepared session and never prepare one implicitly. Effectful
preparation is supported only through the trusted entry in a fresh, exclusively
controlled standalone process with no competing waiter or signal mutator.
Python-level thread/child counts cannot establish that guarantee. Tests may inject
an explicitly identified no-spawn backend; a forged Python object is not native
qualification.

This is lifecycle coordination for admitted trusted orchestration and reviewed
local candidates. It is not a same-user sandbox. Candidate code can inspect files,
signal processes and interfere with resources on that account. Private modes,
nonces, hashes and groups do not authenticate a receipt against that attacker.
Unreviewed local fork code with real HOME/TCC access remains inadmissible.

## External authority and trusted entry

Use an externally selected, reviewed standalone authority shim, separate from the
capability package. The shim belongs to the trusted orchestrator. This unit
introduces no installer or public authority configuration command. Independently reviewed invocation
records supply this boundary during qualification; distribution packaging must
provide the same boundary before production admission.

The shim contains three reviewed literals: canonical trusted package root,
expected SHA256 of the closed package-member manifest, and the admitted profile
identifier. Its own exact bytes/digest and the isolated Python executable are
pinned by the external invocation review/dispatch record. They are not learned
from candidate cwd, a candidate receipt, its own runtime self-hash, or a public
argument/environment override.

The externally reviewed invocation has this fixed shape, with canonical paths
and shim digest resolved before review rather than taken from the candidate:

```
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  <profile-pinned-absolute-CLT-python> -I -S -B \
  <externally-reviewed-authority-shim> <existing-check-or-compare-arguments>
```

The invocation exposes no new capability-policy authority option. Only the
existing candidate root/SHA operands vary within its admitted scope;
they are untrusted inputs and cannot replace the three authority literals.
No pre-session Git, xcrun, compiler/version query or installer discovers them.
The startup environment, argument shape and selected profile must all match the
admitted invocation; missing authority fails closed.

The closed package-member manifest binds the process/worker/policy modules and
other package import members, fixed native source and profile data. It excludes
its own bytes and the external authority shim. The shim is the externally trusted
root supplying the expected manifest digest; including its embedded digest in
that manifest would recreate a hash cycle. This does not leave an unreviewed
package launcher: every launcher supplied by the package is a manifest member.
The independently selected external shim is expressly outside that package and
has its own invocation pin. No production authority shim is qualified by this
specification.

The shim validates and captures the actual built-in shared-clock binding and
immediately takes started, setting D=started+58 before any charged package/profile/
runtime/member hashing. It verifies the closed members as bounded data before
loading/compiling their Python source in this same owned process, then hands the
captured clock and started/D onward without serialization or reset. Verification,
loading and preparation share one budget. The shim's minimal clock/manifest-loader
code is part of its external invocation review, not arbitrary candidate imports.
The complete runtime/reset/triple-image qualification stays at its accepted
pre-child position; these first clock reads do not confer ownership qualification.

Once modules are verified, the trusted entry checks context shape and invokes
preparation, which consumes its one preparation token. A second preparation or
reuse after failure refuses.
This is a lifecycle invariant, not protection against hostile Python running in
the same process. Tests may inject a fake context only through an explicit test
seam and must label that boundary. No serialized context ever becomes evidence.

Bound manifest size/member counts and no-follow regular member reads. Verify
exact relative membership, hashes and stable metadata before loading package
members, before each worker launch and after cleanup. Preparation checks consume
the original bootstrap budget; operational checks consume the corresponding
command budget. No pre-session process discovers or repairs authority.

## Session and policy interfaces

These are internal interfaces; public apple CLI arguments, JSON and stable failure
strings remain unchanged. Direct capability-policy check/compare fails closed as
specified below. No serialized context/request/result is accepted from a caller
as authority or capability evidence; Python naming/privacy does not authenticate
a caller in the same process.

| Interface | Required contract |
|---|---|
| `TrustedEntryContext` | Immutable in-memory `trusted_root`, `expected_manifest_sha256`, `profile_id` and the single bootstrap budget/clock token. No JSON/receipt deserializer or CLI/env factory. |
| `run_trusted(argv, *, context: TrustedEntryContext) -> int` | After closed-member verification, parses existing candidate operands and prepares once before the earliest candidate Git. Passes that session through check/compare. Missing/malformed context refuses without subprocesses. |
| `main(argv=None) -> int` | Direct `snapshot` retains pure parsing. Direct check/compare without trusted context uses fixed `process-session-unavailable` PolicyError behavior. Never derives authority from cwd or `__file__`. |
| `QualifiedProcessSession.prepare(trusted_root, profile_id)` | Called only through trusted entry. The trusted-root descriptor carries the already-started private bootstrap budget; preparation consumes it without resetting time. Returns ready only after closure/runtime/reset/clock qualification, native bootstrap cleanup and ABI/state validation. No old-helper fallback. |
| `session.clock` | Private qualified clock facade; callers form absolute deadlines from it. No stdlib monkeypatch and no exchanged process-relative timestamp. |
| `session.run(request)` | One synchronous command at a time; returns immutable `CommandResult` only after successful command, complete protocol/captures and owned cleanup. Failure raises a value-free `ProcessFailure`. |
| `CommandRequest` | Immutable role, absolute selected executable identity, argv tuple, canonical cwd, exact environment tuple, absolute deadline and aggregate output bound. Session/command correlation is added by the session, not supplied as authority by a caller. |
| `CommandResult` | Immutable stdout/stderr bytes, command_status zero and cleanup_complete true. Contains no PID, Popen object or transferable signal/wait capability. Existing policy wrapper exposes stdout only. |
| `ProcessFailure` | Closed reason, optional validated command status, cleanup disposition and session disposition. Carries no raw output, argv, filesystem error text or private path in its display string. |
| `session.state` | Exactly preparing, ready, command-active, poisoned or closed. Only the private prepare path enters preparing; run is forbidden there. No recovery transition from poisoned to ready. |
| `session.can_validate_final_checkout` | True only while ready and uncancelled. It grants no bypass: the subsequent run still performs ordinary identity/deadline/ownership checks. |
| `session.close()` | Idempotent, admits no new general command; finishes only already-owned safe cleanup and coordinates an already armed restricted owner, if any. Failure prevents success. |

Proposed exact `ProcessFailure.reason` values are `command-failed`,
`output-limit`, `deadline`, `cancelled`, `process-unavailable`, `ownership-lost`,
`protocol-invalid`, `identity-drift` and `cleanup-failed`. Native details stay
private and cannot replace these fixed display values. Failed group signaling,
unresolved reap and uncertain FD cleanup map to cleanup-failed; ECHILD and an
unexpected retained-worker exit map to ownership-lost. Preparation refusal maps
at the policy boundary to fixed `process-session-unavailable`.

The policy wrapper can retain `_run_bounded_command` as a small adapter with a
required `process_session` parameter and its existing command/cwd/environment/
timeout/maximum/failure/output_failure parameters. It constructs the request and
maps output-limit failure to `output_failure`, all other process failures to
`failure`. It contains no Popen, wait, poll, kill or alternate runner path.
Nonzero status can fail the candidate while leaving a safely cleaned session
ready; no nonzero capture becomes successful output.

Missing/wrong/closed sessions refuse before the first command. There is no global
session, silent default or requalification per command. Compare shares one
session across both candidates and final validation. Pure `snapshot --dump`,
claim validation, title decoding and receipt parsing need no session.

## Call topology to change

These functions in `scripts/ci/capability_policy.py` require explicit propagation.
Function names identify integration responsibilities; line numbers may change
as other capability-verification units land.

| Current site | Explicit propagation |
|---|---|
| `main` / `run_trusted` | Direct main permits pure snapshot and refuses unauthorised check/compare. Trusted entry consumes external context, prepares before candidate APIs, and owns final validation/session close before publishing the final decision. |
| `check_candidate`, `_checked_candidate_details`, `compare_candidates` | Require the same session. Establish operation-level finalization before the first acquisition; cover base/head acquisition failures as well as comparison. Do not start head if base poisoned the session. |
| `_capture_candidate` | Pass session through initial checkout, snapshot capture, runtime and gated final checkout. Establish its cleanup scope before acquisition; register a root for final validation after its initial checkout validation succeeds, even if snapshot acquisition later fails. Results remain provisional. |
| `_validate_checkout` | All top-level/HEAD/status Git calls use session. Structural path checks remain in-process. No first-Git exception. |
| `_run_git` / `_run_git_bytes` | Required session; retain fixed Git argv/config/env and per-call bounds. |
| `CommitSnapshot.capture` / `blob` | Snapshot retains the session for its lifetime. Tree and lazy blob Git reads use it; a cached blob does not reopen command authority. |
| `_materialized_snapshot` | Blob reads remain session-backed even when reached lazily during materialization. File-only cleanup does not imply permission to launch Git. |
| `_validate_origins` | Snapshot path naturally uses the stored session; retained path-based Git fallback requires explicit session too. No hidden test/convenience bypass. |
| `_default_runtime_runner` | All four current commands use session: Swift test, product build, bin-path query, fresh-binary help dump. Preserve actual runner/parser tests. |
| `_capture_candidate` and `compare_candidates` finalization | Replace unconditional Git with the state gate and failure-preserving logic below. Cover failures before the old try/finally positions; do not rely on CandidateDetails having been returned. |

Existing limits remain: Git10 seconds and its caller-selected output bound
(normally16 MiB, tree32 MiB, materialized blob up to64 MiB); Swift test/build/
bin-path30 minutes each with current64 MiB/4096-byte bounds; help dump60 seconds,
16 MiB. Deadline creation moves to the trusted request boundary before worker
spawn, so launch/preparation time consumes the allowance rather than creating a
new allowance after Popen returns. Session bootstrap has its own existing58+2
budget. Do not introduce a new overall check/compare timeout in this unit.
The future Bats caller must supply the remaining absolute30-minute phase
deadline; it cannot multiply that budget by file count.

## Qualification and bootstrap

1. In the externally selected authority shim, validate/capture the built-in time
   module and actual built-in `clock_gettime` identity/name/module/self binding,
   with exact integer `CLOCK_UPTIME_RAW == 8`. Immediately take the first shared
   reading `started` and fix bootstrap workdeadline `D = started + 58`, before
   charged package/profile/runtime hashing or qualification work. These early
   reads are nonmutating observations, not ownership qualification. Reject
   non-float, nonfinite, negative, backward or failing reads; no alternate clock,
   increased tolerance, later start or budget reset is permitted. Verify closed
   members before loading their code, then transfer this exact clock/started/D in
   the internal context to trusted entry; preparation consumes that token once.
2. Enter preparing and validate the externally selected closed package/profile
   and actual launcher, loaded main image, framework and reset implementation.
   Perform the qualified built-in SIGCHLD reset in this owned process before
   children. This pre-native step relies on that reviewed runtime/reset profile;
   Python `getsignal` is not a flags proof. Reject unqualified compiler/SDK/linker
   mapping before the first child. Verify and construct the finite build-input
   projection below. Hashing, copying and loading consume the original budget.
   Check that deadline after each synchronous observation; late returns consume
   the existing reserve.
3. Only this fresh preparing state may issue one private `compiler-bootstrap`
   request. Its worker uses the qualified runtime, shared clock and built-in reset
   without a native artifact dependency. It builds fixed trusted native source
   with profile-fixed compiler/SDK/argv, 1 MiB aggregate capture and the original
   D. Use the retained worker, noninherited receipt FD, signal-before-sole-wait
   and cleanup contract below. Before the artifact exists, this path retains the
   unpolled direct worker using the qualified built-in reset contract; it makes
   no native snapshot/wait observation call and does not depend on the future
   ABI. No Git, xcrun, quality runner, old helper, download
   or persistent cache may prepare this prerequisite. A failed compiler dominates
   a plausible artifact. No ordinary request can invoke this bootstrap path.
4. After owned cleanup and sole reap, independently validate the artifact from
   its fixed owned path (8 MiB maximum, regular no-follow identity/hash checks),
   then load the verified ABI and inspect actual SIGCHLD `(DFL, 0)`. All checks
   remain within the original D+2 final-validation boundary. Failure poisons
   preparation; no candidate Git has run. Ready is reachable only after this
   succeeds. Reuse one session artifact; never build one per command.
5. Every operational worker requires the accepted native artifact and rechecks
   closure, runtime, shared clock and artifact before its command. It performs
   its fresh pre-child reset and native zero-state check. A missing, changed or
   rejected operational artifact fails closed; it never retries bootstrap.
   Already-active controller state is inspected for drift, never repaired by
   repeating a process-wide reset while owned children exist.

Freeze production ABI version1 as these three exported C functions, with all
integer widths explicit and Python declarations using the matching ctypes scalar
and pointer types. C owns `sigaction`/`siginfo_t` layouts; Python never guesses
those structures:

- `uint32_t capability_process_abi_version(void)` returns exactly1.
- `int32_t capability_process_sigchld_snapshot(int32_t *handler_kind,
  uint32_t *flags)` returns zero or captured positive errno. On zero, kind0 means
  SIG_DFL, kind1 SIG_IGN, kind2 another handler; flags preserves all native bits.
  Qualification accepts only kind0/flags0. No handler address is exported.
- `int32_t capability_process_observe_child(int32_t child, int32_t *state,
  int32_t *observed_pid, int32_t *status_kind, int32_t *status_code)` performs
  `waitid(P_PID, child, ..., WNOWAIT|WNOHANG|WEXITED)` and returns zero or captured
  positive errno without fallback. Initialize outputs to zero. On successful
  live observation state0 keeps the other outputs zero; terminal state1 requires
  observed_pid==child and status_kind1/exited,2/killed,3/dumped with the matching
  exit/signal code. ECHILD is an errno outcome, never a live observation. Reject
  other outcome combinations. Require a positive representable child identity;
  pin/compile-check native scalar conversions and errno/status constants in the
  qualified profile. No signal, reap or PID discovery is exported.

Validate artifact identity and ABI version before state calls. Native functions
must preserve syscall errno before subsequent work and return fixed outputs on
error, never raw error text. Test-only disposition installers remain separate
fixture code and are not linked/exported as production operations. Distribution
qualification and actual production bootstrap tests remain outstanding evidence;
these signatures do not declare a new binary already qualified.

## Finite compiler, header and linker inputs

Use a **closed per-session build-input projection** populated from the
independently qualified distribution manifest. Do not hash or mirror the whole
SDK. The projection contains only the finite files/directories needed by the
exact fixed C translation unit, target, macros and selected compiler/linker.
All projected input paths and content digests are profile data reviewed before
admission. A missing entry is absent in the fresh projection; there is no fallback
to a host SDK/header search or opportunistic dependency discovery during prepare.

Apply the following input rules:

1. The profile supplies a sorted unique finite list of regular input members and
   directory entries. Each record binds source canonical path, size/digest, any
   admitted source alias resolution, and one normalized relative projection path.
   The list includes fixed C source, selected SDK/resource headers, required SDK
   stubs/startup/runtime link inputs and any enabled compiler configuration input.
   Bounds on member count, per-file bytes, aggregate bytes and topology are exact
   profile fields, checked before expansion/copy; qualification must establish
   their actual values and timing. No unbounded directory enumeration is admitted.
2. Prepare verifies each source member with the accepted no-follow/stable-identity
   checks and writes only those bytes to exclusive private files. Projection
   directories are initially private0700; completed input files become read-only
   and input directories nonwritable before compile. Output/capture directories
   are separate. Reject links, traversal, duplicate projection names and absolute
   or outside-projection references in the admitted projected search topology.
   Keep the original directory/file lifecycle and bounded cleanup requirements.
3. The fixed compiler profile must disable implicit/default header and module/PCH
   discovery and supply explicit SDK and resource/search roots inside that closed
   projection. No inherited header/config environment is accepted. The intended
   clang mechanisms are explicit sysroot/resource-dir, `-nostdinc`, explicit
   `-isystem` roots and disabled modules, qualified for this exact driver. The
   full concrete argv is a profile artifact to be reviewed before execution;
   this document does not claim these flags alone prove that no other inputs are
   consulted. An absolute/outside-root include, fallback or unrepresented config
   observed in qualification makes that profile inadmissible.
4. The exact selected linker executable is fixed independently of PATH. Its
   driver-selection mechanism and complete link argv are qualified and pinned;
   they cannot silently select another installed linker. Link inputs/search roots
   are explicit, with required stubs/reexports in the projection and no host SDK
   fallback. Any unavoidable tool runtime file remains a separately pinned member,
   not an implicit search result. The existing one-command worker model remains:
   clang may launch its qualified linker in the retained worker group; this does
   not add another controller command or deadline.
5. Hash-bind all non-system compiler/linker dylibs, configuration and other runtime
   files actually admitted by the fixed profile, including relative/rpath resolution
   and absence constraints. The observed CLT linker names libtapi, libcodedirectory,
   libLTO and libswiftDemangle; these are candidates for the record, not an already
   complete closure. No tool/helper is downloaded or cached as a new authority.
6. Recheck the admitted identities before affected launch and after owned cleanup,
   as required by the lifecycle contract. Post-cleanup artifact identity/load-command/
   ABI/state acceptance still completes by D+2. Do not reuse an unverified existing
   projection between sessions or enlarge the budget to fit a dependency set.

A closed projection resolves header negative lookups and shadowing by removing
unlisted files from the admitted search space. It does not prove that a compiler
obeys that space: fixed-argv dependency/search qualification and independently
reviewed trusted compiler/header behavior remain required. Candidate code cannot
supply the native source, projection members or compiler flags. This is not a
same-user filesystem sandbox or protection against concurrent same-account edits.

## Apple system runtime trust boundary

Treat the selected Apple OS installation and its system loader/dyld shared-cache
services as a trusted platform base under this profile. This includes the kernel,
libSystem and Apple system frameworks used by the admitted tools. Record the
supported OS build/architecture and relevant observed system image/cache identity
in qualification; refuse unsupported mappings. These observations identify the
platform, not independently attest every OS byte or authenticate the machine.

All non-system CLT tool binaries/dylibs, Python distribution images/extensions,
package members, headers and link-time stubs remain within the explicit file
identity records. System libraries supplied by dyld are not silently equated with
SDK text stubs or covered by the three-Python-image hashes. No entire-OS/shared-cache
hash sweep, new OS attestation service or same-user integrity claim is introduced.
The Apple base is an explicit trust assumption, alongside the exclusively
controlled standalone process and trusted orchestrator.
If that assumption is unacceptable for an intended environment, its profile
remains unsupported; the generic unit must not claim a stronger boundary.

## Offline qualification and production preparation

Offline qualification is a separate reviewed engineering activity. It may use
controlled compiler driver/dependency observations on fixed synthetic/native
source under the explicitly selected trusted Apple distribution. It does not
pretend to be an already qualified production session or use an operational
artifact that does not exist yet. Review each bounded fixture/invocation and its
initial trusted assumptions before execution. Profile rows remain inactive
until this qualification is complete.

The qualification deliverables are the finite projected member list/topology,
exact driver/header/linker search and argv selection, non-system loaded runtime
closure, Apple-base profile observations and measured shared-clock preparation
budget. A dependency report that excludes system headers is insufficient; even a
complete opened-header list alone does not establish negative searches or driver
config behavior. Inspect those explicitly and compare the projected fixed build
with the original fixed build for the required native ABI/state behavior. Reject
unrepresented inputs rather than allowing host fallback or silently copying a
larger tree. Header redistribution is unnecessary: production copies admitted
installed SDK members locally for its own session and publishes only profile
paths/hashes, subject to repository publication rules.

Production prepare performs no discovery. It consumes only the admitted finite
profile and projection, under the externally selected authority entry and the
original started/D. Missing or changed files, unsupported runtime or exhausted
budget refuse before/through the preparing-only bootstrap as appropriate. There
is still one native build per session, no operational fallback to bootstrap and
no installer/persistent qualification cache.

## Request, worker and receipt contract

Use one exclusive0700 directory per session and one exclusive0700 command child
directory. The session creates a canonical UTF-8 JSON request in an exclusive0600
regular file, then passes an already-open read-only descriptor at offset0. This
avoids a bounded request blocking on a pipe before the worker exists. The return
receipt uses a private nonblocking pipe. Only request and receipt descriptors
are passed to the worker; both become noninheritable before command spawn.
Standard input is `/dev/null`; worker's own stdout/stderr cannot leak diagnostic values.

Proposed request contract version1 has exact keys: version, role, session_id,
command_id, trusted_closure_sha256, profile_id, native_artifact_sha256, executable,
argv, cwd, environment, deadline, maximum_output_bytes. Operational role is exactly
`git`, `swift-test`, `swift-build`, `swift-bin-path` or `help-dump`; Bats admission
is later. `compiler-bootstrap` is rejected by this schema and by session.run.
Session_id is a fresh32-hex correlation nonce; command_id is a monotonic positive
integer no greater than2^53-1, with no reuse/wrap. Neither establishes same-user
authenticity. The executable record binds canonical path/hash/stat identity;
argv[0] must equal that path. Each role retains its policy-owned exact command
template and selected executable, rather than permit a worker command string.

The private preparing-only bootstrap schema instead has exact keys version,
role, session_id, command_id, trusted_closure_sha256, profile_id, compiler,
source, sdk, cwd, environment, deadline and maximum_output_bytes. Role is exactly
`compiler-bootstrap`. Compiler/source/SDK records are the selected closed-profile
identities; cwd is the session-owned build directory. Compiler argv is constructed
from its fixed profile template, with no caller argv field. There is deliberately
no native_artifact_sha256 field in this pre-artifact request. Deadline is the
already fixed bootstrap D and output limit exactly1 MiB. The same correlation,
size, parsing and FD rules apply. Only prepare creates and dispatches it once;
operational requests cannot obtain this privilege by omitting an artifact.

Before expansion or spawn, bound the complete request to64 KiB, argv to256
strings, environment to128 unique keys, each argument to4096 UTF-8 bytes,
each environment value to8192 bytes, and cwd to4096 bytes. NUL is forbidden;
environment keys use the owning role's allowlist. The aggregate bound is
independent. These limits cover the current fixed Git/Swift/dump call shapes;
production tests must verify every real constructed shape. Do not truncate.
Output limit is an exact integer0…64 MiB, deadline a finite shared-clock float
strictly in the future and within that role's current budget. Reject bool
substitutions, unknown keys, duplicate keys, unsupported version, wrong role,
source/profile/nonce mismatch or extra bytes before command launch.

The worker starts one command in its existing retained worker group; the command
must not create the worker's ownership group. Do not use `start_new_session` for
that inner command. The worker alone reaps the command; the controller alone
reaps the retained worker. Both stdout and stderr are drained fairly/nonblocking
with reads bounded by remaining aggregate budget plus one overflow-detection
byte. No unbounded read/communicate or serial drain. Write only bytes within the
cap to exclusive0600 captures, accounting for short writes. Keep fixed raw-byte
semantics and check deadline/cancellation after read/select/wait observations.

The bounded canonical receipt (4096 bytes maximum) has exact version, role,
session_id, command_id, trusted_closure_sha256, profile_id,
native_artifact_sha256, outcome, command_status, stdout_bytes, stderr_bytes,
stdout_sha256 and stderr_sha256 fields. Closed outcomes distinguish success,
command failure, output limit, deadline, launch failure and read failure.
Command status is an exact integer0…255 or a negative supported Darwin signal
number (profile-qualified range−31…−1), never bool; null is admitted only for
an outcome with no reaped command result. Success requires zero; command failure
requires nonzero. Lengths are exact nonnegative integers with aggregate at most
the request cap. An overflow outcome never treats truncated captures as evidence.
No worker PID, arbitrary error string or capture path appears in the receipt.

The bootstrap receipt uses those same exact keys except native_artifact_sha256,
which is absent. It reports only compiler outcome and captures; parent-side
post-cleanup inspection of the fixed output path establishes artifact identity.
A receipt never supplies authority to load an artifact or overrides compiler
failure. Its role must be compiler-bootstrap and its correlation must match the
one admitted preparing request. Operational receipts always require the artifact
field and cannot validate against the bootstrap schema.

Receipt send and receive are incremental/nonblocking, with at most4096 bytes
including one terminating LF and no additional frame/trailing bytes. Account for
short writes, interrupted operations and EAGAIN; bound each buffer/read by the
remaining frame allowance plus one rejection byte. Check cancellation and shared
deadline before and after select/read/write; EOF before a complete frame fails.
Do not use a blocking write-all/read-to-EOF path, let backpressure extend D, or
parse an incomplete prefix as success. The controller can receive the frame while
the worker remains live; capture/receipt acceptance waits until cleanup.

After closing command captures and sending its receipt, the worker remains a
strongly retained live anchor. Its post-report cooperative fallback uses the same
qualified clock and self-group SIGKILL no earlier than D+3. This leaves the
controller's D+2 cleanup reserve intact. It is a checkpoint loop, not an
independently armed timer: it does not interrupt synchronous import, loader,
filesystem, native or spawn stalls. Do not claim hard-wall protection, add a
second supervisor/timer, or extend/reset the parent deadline to accommodate it.
EOF, command exit or success receipt never authorizes early anchor reap.

Independently validate receipt/capture identities only after owned group cleanup
and the sole worker reap. Read captures from fixed owned paths with no-follow,
mode/owner/size/hash/stable metadata checks, bounded by the original caps. Complete
post-cleanup validation within D+2, checking before/after each synchronous read,
hash and native/artifact check; a late result cannot authorize success. No output
is returned on invalid/partial receipt, inconsistent capture or cleanup failure.

## Ownership, failure and finalization

Before spawn: validate request, cancellation, deadline and runtime/native state
under its admitted role. The preparing-only compiler exception uses the explicit
pre-native qualification above; it is not an operational state-check bypass.
Use nonraising cancellation latches so a signal around Popen return cannot lose
the newly created anchor. Store it first, then observe cancellation. Keep a
strong reference; no Popen context manager, poll, destructor or second waiter.

For a live retained anchor, completion, cancellation or failure starts immediate
owned-group SIGKILL before the sole reap, including successful/nonzero commands
whose descendants may remain. Do not introduce a TERM grace period. Let D be the
original workdeadline and W the shared-clock time when reap waiting starts. The
sole wait deadline is min(W+2, D+2), never a fresh two seconds beyond D+2 and never
permission to delay early-completion cleanup until D+2. Late synchronous returns
can exhaust this reserve and fail; they never reset it. Post-cleanup validation
must also fit D+2. Failed group signal, unresolved reap or ambiguous cleanup
prevents success even when command status is zero.

Unexpected terminal-anchor observation poisons the invocation and revokes the
live-anchor group-signal path. Retain only independently proven sole-reap
authority for that unreaped direct child; issue no later numeric group signal.
On ECHILD, revoke all signal/wait authority immediately and perform no explicit
wait. Never reconstruct authority with getpgid, process.kill, a receipt or PID
scan. The normal live-anchor path must still signal before its sole reap; tests
must distinguish that path from terminal/ECHILD refusal without dangerous real
post-reap signals.

| Event | Session disposition and outward result |
|---|---|
| Successful command, complete receipt/captures/FD cleanup and group cleanup | ready; return CommandResult only after all checks. |
| Ordinary nonzero or fully reported launch/read/output-limit failure, with positively completed protocol and all cleanup | ready is permitted; raise the mapped command failure. Candidate fails; final checkout remains possible. |
| Deadline exhausted or observed cancellation | poisoned; finish only already-owned cleanup. No subsequent command or final Git. |
| ECHILD, unexpected worker exit, failed group signal, unresolved reap, invalid/missing protocol, trusted identity drift or uncertain FD/capture cleanup | poisoned before returning failure. No retry, second candidate, version query or general cleanup command. |
| Pure schema/path/evidence validation failure while session remains ready | fail candidate; attempt ordinary gated final checkout. |
| Closed session | no command or implicit preparation. |

Operation-level finalization begins before acquiring either comparison candidate.
The current code acquires base and head before its comparison try/finally; that
placement must not survive this change. If head acquisition fails, already
acquired base state still receives its required gated final check. If base fails,
head acquisition never starts. A candidate's own cleanup scope also starts before
checkout/snapshot acquisition: once initial checkout validation succeeds, a later
snapshot or catalog failure cannot skip its final check merely because no
CandidateDetails was returned. Do not issue extra Git against an unvalidated root
or after session poison. Preserve the original acquisition error while completing
only eligible state-gated final validation and session close.

At each candidate's final validation, retain the primary failure. If session is
ready and uncancelled, perform the current checkout validation using it. If a
final check poisons the session, do not run remaining final checks (including
compare's other root). If unavailable, record a fixed private
`final_validation_unavailable` fact and fail unconditionally. Do not report a
clean checkout, overwrite an earlier failure with success, or issue Git from an
unconditional finally. If no primary diagnostic exists, the unavailable-final-
validation failure uses fixed PolicyError `final-checkout-unavailable`.
Existing failure codes otherwise win.

Only after required final checks, session close and output serialization succeed
may the driver publish success. Cancellation already latched before logical
finalization wins. The final result/exit decision is then immutable; later
cancellation cannot produce contradictory receipt/stdout/exit. Final output I/O
can still fail and never counts as a successful delivered result. This logical
boundary occurs once at the top-level operation, not after each command, so
between-command cancellation cannot be forgotten.

## Local-owner boundary, expressly deferred

Generic `session.run` always cleans its worker group before returning. It must
not be used as the lifetime wrapper for a LocalFileOwner that must survive Bats
cancellation. The local unit needs a separate fixed-purpose retained-actor path,
registered and armed before Bats, outside the generic command failure group.
It reuses this package's qualified runtime/native/clock and anchor primitives;
it does not become a replacement general session after poison.

`QualifiedRuntimeIdentity` names the immutable root/profile/native ABI/artifact/
clock descriptor shared with that future actor. The descriptor correlates
qualification and conveys no PID ownership. Module-internal retained-anchor
primitives remain nonpublic. This unit reserves only the boundary: close/poison
may coordinate an already armed, fixed-purpose recovery owner, never create one
or run arbitrary callbacks/commands. Exact leases, four AppleScript delivery
modes, direct helper coverage, owner deadline/reserve and app/fixture journal
belong to the separately authored local-owner protocol. Script-bearing local
files remain refused before execution until that unit is implemented and tested.

## Synthetic acceptance for the actual production package

Keep existing parser and actual-runtime-runner tests. Add focused process tests
that execute the implemented package rather than treating the prototype adapter's
copied orchestration as a substitute.

- Exercise direct main and trusted entry separately: snapshot remains pure;
  absent/malformed/candidate-supplied context cannot reach Git/compiler; verified
  members precede package execution; consumed/failed context cannot restart the
  bootstrap clock or repeat preparation.
- Reject extra/missing/shadowed projection members, outside links/searches and
  wrong compiler/linker/runtime identities before affected launch. Qualification
  must establish exact finite members/search/argv and measure their original-budget
  cost; pure fixtures or a successful old build cannot activate a profile.
- Inject failure during base acquisition, head acquisition, initial checkout,
  snapshot and final validation. Assert eligible roots are finalized even when
  acquisition fails before the old try/finally; no head after base failure, no Git
  after poison, no unvalidated-root query and no loss of the primary error.
- Prove the external manifest digest selects the trusted closed closure before
  candidate imports; reject candidate-selected manifests, extra/missing members,
  self-member recursion and changed profile/tool mappings before child launch.
  Verify the first clock reading precedes all charged package/runtime hash work.
- Exercise preparing-only compiler bootstrap without any native artifact, followed
  by artifact acceptance and ready transition. Missing operational artifact,
  forged compiler role, second bootstrap or failed preparation must never invoke
  compiler/Git as a recovery path. Test both exact request/receipt schemas and
  actual policy-owned command shapes, not only synthetic schema examples.
- Check incremental receipt short writes/EAGAIN, capacity+one overflow, partial
  EOF, extra frames and delayed observations. Prove immediate signal-before-wait,
  wait deadline min(W+2,D+2), post-cleanup validation cutoff and no deadline reset.
  Post-report fallback cannot fire before D+3; checkpoint-only limitations remain.
- Before touching ownership production code, use fake Popen/native/killpg/wait
  seams with no real spawn to demonstrate the current post-reap nonzero signal
  defect. A dangerous real post-reap signal is forbidden as a RED technique.
- Assert preparation before the earliest Git for check and compare; cover lazy
  blobs/materialization and path-origin fallback. Missing/poisoned session,
  unsupported profile and root/profile/worker/artifact drift invoke no Git or
  candidate code. Snapshot stays process-free. No competing hidden helper runs.
- Exercise real package bootstrap with fixed synthetic native source/compiler
  identity: nonzero plus plausible artifact, stdout/stderr overflow, missing/
  partial/wrong receipt, FD absence across descendants and the positive control.
  Native artifact is validated only after owned cleanup. Verify one native build
  per session rather than per command; no unqualified preparation subprocess.
- Execute actual package commands with self-expiring synthetic children for
  success/nonzero/launch/read/output/deadline cases; status and marker output are
  fixed. A command that exits while a descendant holds output must be stopped by
  group cleanup before fallback expiry. Require evidence distinguishing cleanup
  from natural exit, and no signal after sole reap. Repeat the eight supporting
  scenario classes at the production boundary; rerunning the prototype is not
  equivalent evidence.
- Inject ECHILD, terminal anchor, failed signal, wait expiry, short writes,
  descriptor-close failure and protocol drift through narrow no-spawn or recorded
  boundaries. Prove irreversible poisoning and zero queued Git/Popen calls after
  each poison cause; ordinary complete nonzero cleanup still permits final Git.
- Cover cancellation before/during spawn assignment, capture, receipt, cleanup,
  between commands, final Git and logical finalization. Repeated signals cannot
  interrupt already-owned cleanup or reset cancellation state.
- Prove shared origin and consumed preparation budget on actual main→worker and
  bootstrap paths. Expired/equal/late/missing/wrong-builtin/wrong-constant/read-
  error/nonfinite/backward controls fail closed. No old-domain comparison remains.
- Verify request/receipt bounds before expansion, exact signed status handling,
  source/native/capture drift, descriptor noninheritance and private-directory
  closure. Positive resource witnesses are required; absence assertions alone
  cannot establish that the fixture allocated the resource being checked.
- Preserve exact command argv/environment/stdin, aggregate output accounting,
  stable public diagnostics and no raw stderr in errors. Run final checkout only
  when safe, and withhold success if final validation or close fails.

All native tests require independent source/invocation review and an explicitly
authorized execution slot, closed stdin, finite work/cleanup/fallback budgets and
private captures.
No real Apple data, network package resolution or hosted actor is required for
the synthetic process unit. Actual full-candidate integration and canonical
gates follow implementation; this document supplies no such evidence.

## Remaining qualification and promotion requirements

The authority source, preparing-only bootstrap role, ABI signatures, frame limits,
cleanup reserve and cooperative fallback are fixed above. The remaining
implementation prerequisites require qualification evidence:

1. Supply the independently selected authority shim/invocation pin and populate
   the closed package manifest, runtime/reset/Git/Swift/compiler records, finite
   build-input projection and linker mappings. Keep the manifest outside its own
   membership and the external shim separately pinned. Qualify the explicit Apple
   platform-base mapping. Unqualified rows stay inactive; prototype evidence does
   not establish those production records or their timing.
2. Complete offline dependency/search qualification, then exercise the actual
   trusted-entry/package bootstrap and ABI with the shared clock and fixed compiler
   closure, including post-cleanup artifact/state validation. No installer
   or cache is needed: once per session without persistent cache remains fixed.
3. Verify all existing constructed policy requests against the exact role schemas,
   preserved argv/environment and public failure strings. Keep original primary
   PolicyError when final validation becomes unavailable; do not replace it with
   a cleanup/protocol diagnostic or success. Qualify the finite request/receipt
   bounds with boundary tests, not by loosening them after a fixture failure.
4. Independently review this revision and the local identity boundary, then promote
   the settled process spec through the normal tracked-spec gate before process
   RED/implementation. Hosted qualification stays after publication. Bats binding
   and local leases retain their separate admission and acceptance requirements.

No production qualification or integration result is supplied by this design.
The supporting eight-case record remains evidence for its frozen prototype
adapter, not a replacement for these production acceptance requirements. If the
finite closure or original-budget fit cannot be established, keep the profile
inactive and review that concrete constraint; do not silently broaden the input
set, reset time or introduce host fallback.
