# Local capability owner protocol

Specification for the per-file `LocalFileOwner` that retains ownership of Bats
and script process groups across cancellation and drives prearmed fixture/app
recovery. Implementation and runtime qualification remain pending. This unit
follows the independently deliverable claim/parser and qualified process units;
their completion does not qualify this local protocol.

## Evidence and remaining claim boundary

No implementation, prototype adapter or native case exists for this unit; it has
no recorded passing evidence of any kind. The retained-process unit's prototype
results and the claim/parser unit's acceptance bind only their own scopes and are
not LocalFileOwner evidence. Every interface named below as proposed is
unwritten. The proposed test order in the final section is the first deliverable,
not a record of work performed.

## Scope and dependency boundary

Implement one `LocalFileOwner` per admitted full local Bats file. It survives
Bats, CLI and intermediate wrapper exit, cancellation and SIGKILL while the owner
and its controller remain operational. It also initiates bounded recovery when
its controller channel closes. Owner SIGKILL, host/kernel failure, external
reaping, uninterruptible termination and arbitrary escaping descendants remain
outside successful recovery claims. Known AppleKit and direct-helper separate
groups are explicitly inside scope.

Use the process package's `TrustedRunnerRoot`, its proposed
`QualifiedRuntimeIdentity` descriptor (reserved by the retained-process unit; not
yet implemented), the native retained-anchor primitive and the shared
`CLOCK_UPTIME_RAW` facade. The identity descriptor binds trusted
package/profile/native ABI/clock inputs; possession is not kernel ownership. The
owner is created through a separate fixed-purpose retained-actor entry,
registered before Bats admission. It is NOT the command of
`QualifiedProcessSession.run`: that API cleans its worker group before every
return and would kill recovery prematurely. Do not add a general recovery
callback or arbitrary persistent-command API to that session. Poison/close can
notify and await only this already-armed actor under its reserved deadline.

The local adapter performs the following sequence: verify exact
source/binary/full-file/helper closure and supported fixture plan; prepare the
trusted owner; obtain a validated `armed` response covering recovery manifest and
snapshot; request the single frozen Bats plan; await its complete file result and
recovery receipt; validate the still-safe candidate and produce evidence only
when every prerequisite succeeds. A poisoned general session never runs final
Git, another file or a replacement session. Record final checkout validation as
unavailable and fail even if restricted recovery succeeds.

The owner itself belongs outside every Bats, CLI, helper and per-script failure
group. It owns a live Bats anchor and all script anchors, and is their exclusive
observer/waiter. The controller does not hold their PIDs or signal them. Any
lower-level supervision of the owner itself has a distinct final deadline after
all reserved recovery phases, and cannot interpret owner termination as proof of
script/app restoration.

### Design choices pending operator ratification

Three choices below are stated in this document as design intent only. None is
ratified, and none is required for the grant-free test increments (acceptance
items 1, 2 and 7):

1. **Real HOME under a surviving owner.** Running an owner that outlives SIGKILL
   with real HOME and live TCC is a safety-posture choice touching agent conduct,
   not a spec detail; it is NOT yet ratified.
2. **Initial trust root.** Treating reviewed local source plus the selected local
   runner installation as the initial profile's entire trust root is NOT yet
   ratified.
3. **Direct-helper backend replacement.** Replacing the direct helper's
   communicate-then-signal backend with a lease backend under validated local
   context changes every local Bats file's helper path and is NOT yet ratified.

Live local admission of any Bats file under this protocol is refused until all
three are ratified and recorded in HUMAN-DECISIONS.md.

## Internal interfaces and topology

Proposed Python owner module: `scripts/ci/capability_local_owner.py`, loaded only
from the bound trusted package. Admitting this module makes the closed package
nine members; it requires a manifest re-freeze and re-pinning of the shim, native
artifact and dispatch record in the sibling unit's acyclic order. No local-owner
code is loadable until that re-freeze is reviewed. Reuse the process package's
proposed native anchor implementation through a typed fixed-role entry rather
than copying bootstrap logic. Proposed Swift implementation:
`Sources/AppleKit/LocalScriptLease.swift`, with a narrowly refactored internal
process-lifetime boundary in `OwnedScriptProcess.swift`. `ScriptLaunching`,
`ScriptInvocation`, `ScriptOutcome`, the four `ScriptDelivery` modes (`inline`,
`timed`, `stdin`, `timedStdin`), AppleScriptRunner public methods and output-limit
markers remain the semantic interface.

The process-lifetime interface uses an opaque sum type for a locally owned child
or a remote script lease. Operations are `start`, `observeCommand`,
`finishClient`, `cancel` and `close`. A remote lease never implements
`ScriptProcessChildren` by inventing a pid_t, pretending to waitpid, or accepting
a remote numeric group. Keep the existing local backend and its kernel authority
tests intact. Client I/O remains in `OwnedScriptProcess`: its nonblocking input,
fair output reads, combined optional byte budget and fixed-size pread capture
snapshots remain local operations. This avoids moving Swift errors or Apple
payloads through a second result serializer.

For a script lease, the owner starts a trusted live anchor in a fresh group
before command execution. The anchor spawns the fixed `/usr/bin/osascript` in
that SAME group, applies the existing script child mask/disposition/descriptor
policy, and closes its copies of all script descriptors immediately after spawn.
It alone waits for its command, reporting the command status separately. After
command completion it remains alive until owner cleanup, without holding script
stdin/stdout/stderr. Its private control channel is never inherited by osascript.
The owner holds exclusive wait authority over the anchor and the anchor reserves
the group's identity.

The trusted anchor remains live through the owner's TERM grace; its own narrowly
installed cancellation handling must not leak ignored dispositions or masks into
the script. The command child must match the existing launcher policy: empty
signal mask, reset dispositions, explicit stdio and close-on-exec default. The
script must not request its own new group in this path. This is a separate native
spawn mode requiring tests; blindly calling the existing SETPGROUP child-spawn
function would break ownership.

Normal zero and nonzero command completion can return to the client while the
live anchor remains owned until file cleanup. This preserves successful
background work during the file; it does not promise that background work
survives the enclosing attested file. A timeout, output overflow, delivery/read
failure or client EOF cancels its lease promptly. File teardown drains even
successful leases before fixture/app recovery. The non-profile CLI retains its
existing background behavior.

## Context admission and descriptor transport

Use a private AF_UNIX SOCK_STREAM endpoint owned by LocalFileOwner under a
physical 0700 run directory. A runner-established internal context identifies
endpoint, protocol version, run, file and the exact expected CLI/helper identity.
The child environment receives only those internal context fields, not arbitrary
executable/receipt/profile paths. The initial profile trusts reviewed local
source and the selected local runner installation. Verify endpoint filesystem
type/owner, LOCAL_PEERCRED and LOCAL_PEERPID, bounded proc_pidpath resolution
with stable process start-time identity checks around image-file hash validation
performed through a single O_NOFOLLOW descriptor whose st_dev/st_ino/st_size are
confirmed identical before and after the hash; never re-open the resolved path to
hash it. Admission binds only the peer as observed at that instant; a later exec
by the peer is outside the check. Verify exact run/file/package/binary bindings.
The installed Darwin headers are expected to expose these peer/process inspection
APIs; availability is itself an item-2 preflight assertion, and their integrated
behavior still requires synthetic qualification. The peer PID is only an identity
cross-check and never signal authority. Bind Swift clients to the exact built CLI
image; bind direct Python helpers to the qualified interpreter plus frozen helper
closure and inherited runner context. This latter source association relies on
reviewed local inputs and is not a native proof of which Python source is
executing. A nonce and private directory prevent accidental cross-run confusion;
they do not create isolation from malicious same-user code. Do not claim that
arbitrary descendant code is authenticated simply because it inherited a context.
Unsupported peer/image verification fails admission; no weaker fallback is
silently substituted.

The local context is carried entirely in the child environment under the single
reserved prefix `APPLE_CLI_LOCAL_OWNER_`. This is the frozen field set for
implementation; exact keys:

| Variable | Type and bound | Meaning |
|---|---|---|
| `APPLE_CLI_LOCAL_OWNER_PROTOCOL` | exact ASCII `1` | Context/protocol version |
| `APPLE_CLI_LOCAL_OWNER_ENDPOINT` | absolute path, 1..103 bytes, no NUL | AF_UNIX endpoint below the owner's 0700 root |
| `APPLE_CLI_LOCAL_OWNER_RUN_ID` | exactly 32 lowercase hex | Run scope identity |
| `APPLE_CLI_LOCAL_OWNER_FILE_ID` | exactly 32 lowercase hex | Admitted-file scope identity |
| `APPLE_CLI_LOCAL_OWNER_CONNECTION_SCOPE` | exact token, one of `cli`, `helper`, `file-lifecycle` | Declared peer role scope; the single source-bound Bats file lifecycle peer presents `file-lifecycle` |
| `APPLE_CLI_LOCAL_OWNER_IMAGE_SHA256` | exactly 64 lowercase hex | Expected CLI/helper image identity digest |
| `APPLE_CLI_LOCAL_OWNER_NONCE` | exactly 64 lowercase hex | Per-file admission nonce |

All seven fields are required together. Any nonempty subset present without ALL
seven refuses before any Apple script launch; the empty set is the ordinary
no-context launch below. Any variable beginning `APPLE_CLI_LOCAL_OWNER_` that is
not one of the seven refuses, as does a value violating its stated type, length
or character bound, a `CONNECTION_SCOPE` outside the three exact tokens, an
empty value, or a duplicate-cased spelling. The owner
strips every `APPLE_CLI_LOCAL_OWNER_` variable from script children.

Without any local context, ordinary CLI launch uses `OsascriptLauncher`. A
partially present, malformed, stale, mismatched or disconnected requested context
refuses before any Apple script launch. No fallback to unowned spawn. No public
command-line executable override is introduced. A synthetic endpoint/executable
override exists only through internal test injection and cannot be enabled by
production environment fields.

Control framing is a four-byte big-endian length followed by strict UTF-8 JSON.
Maximum frame 32 KiB; reject duplicate keys, unknown fields, wrong types,
nonfinite numbers and extra bytes. Every request carries protocol=1, run ID, file
ID, connection ID and monotonically increasing request sequence. Replies echo
them and carry an owner-created opaque lease ID where applicable. IDs are bounded
ASCII tokens, never numeric process IDs. Repeat/out-of-order requests fail the
connection and poison the file rather than being treated as a second spawn.
Terminal release acknowledgment is distinct from group-cleanup acknowledgment.

All accepted sockets, anchor channels and controller IPC use nonblocking
incremental reads AND writes under a poll-driven owner loop. No
recvmsg/sendmsg, accept, reply flush or per-client wait may monopolize that loop.
Service cancellation, controller EOF and already-owned cleanup before admitting
new work; then service at most one bounded chunk per ready connection per turn,
checking deadlines between clients. Apply the same rule to partial ancillary
delivery and native-anchor ACK/status channels. Suspend ordinary admission while
draining, without suspending existing ownership cleanup.

Before accepting a connection reserve one of 64 connection slots; at most 32 may
await hello, and at most 32 spawn requests may be inflight. Cap total accepted
connections at 8192 per file, pending received descriptors at 128 globally (four
per inflight spawn), released from the budget at close rather than at frame
acceptance, so a rejected batch cannot wedge reservation, and queued reply bytes
at 1 MiB globally and 64 KiB per connection. Reserve queue/FD capacity before
accepting the corresponding operation; overflow closes the offending connection,
closes all its untransferred received FDs, fails the file and initiates recovery.
On accept failure with EMFILE/ENFILE/ENOMEM, stop polling the listener for the
remainder of the turn and continue servicing existing connections and cleanup;
never retry accept in a tight loop. Reserve a spare descriptor at startup for
graceful close. Listener readiness at capacity cannot starve recovery. The owner
never allocates storage based on an unchecked advertised length.

Hello must finish within five seconds of accept. Each subsequent complete frame
and queued reply has a fixed five-second absolute deadline from its first
byte/enqueue, capped by the current work/phase deadline; progress does not extend
it. A successfully submitted spawn may await the native ACK only within its
separately reserved fixed phase deadline, still with nonblocking servicing of all
other channels. Protocol silence while a command runs is not a five-second
command timeout: no frame is inflight, the owner already holds the anchor and its
command/file deadlines. Waiting clients poll nonblockingly under their existing
command deadline. An expired partial frame or blocked reply causes the same
failed-file cleanup; it cannot prevent detection of controller EOF or draining
another lease. Native spawn and filesystem syscalls retain the stated checkpoint
limitation; this contract does not claim they are asynchronously interruptible.

Use sendmsg/recvmsg with SCM_RIGHTS for spawn descriptors. All receive operations
capable of consuming frame bytes must also collect ancillary data; never mix
plain recv with an outstanding FD-bearing frame. Ancillary data belongs only to
the first byte of the spawn frame. Reject truncated/unknown ancillary data,
unexpected or duplicate descriptor batches and counts other than exactly four.
Close every received descriptor on any rejected or incomplete frame, including
EOF mid-frame. Mark each accepted FD close-on-exec immediately and relocate 0/1/2
before other work. The four roles are argv metadata, child stdin, child stdout
and child stderr. Fstat each stdio role and reject anything other than a pipe or
regular file. The three stdio descriptors are chosen by the client and are not a
privilege boundary; the owner's guarantee is descriptor hygiene and closure, not
the destination's safety. The stdout/stderr roles may intentionally refer to the
same pipe for direct-helper merged capture; duplicated received descriptors still
have distinct close obligations.

Argv metadata is an owner-bounded snapshot from a private regular unlinked FD,
read with pread, at most 4 MiB, containing only the exact UTF-8 string array.
Before reading, fstat the metadata descriptor and reject anything that is not a
regular file with st_nlink == 0 and st_size <= 4 MiB; reject a descriptor on
which pread returns ESPIPE. Reject NUL, wrong shape and
growth/truncation/change during the snapshot. Copy the complete validated array
before native spawn; do not pass an attacker-editable filename to the anchor.
This limit is a local attestation resource limit, not a new public output policy.
Stdin script bodies stream over their existing pipe and do not enter control
frames or logs. Inline source remains exactly in argv. No shell eval or generic
command string exists.

The owner/native boundary receives the three stdio FDs, exact argv, fixed
osascript role and frozen environment identity; no client-provided executable,
cwd or arbitrary environment is accepted. Profile environment copies the
previously reviewed CLI execution environment needed for current behavior,
including real HOME; it removes internal transport fields from script children.
Preserve rather than globally override test-mode, dry-run and output-limit
configuration. This profile neither sets nor clears
APPLE_TEST_MODE/APPLE_DRY_RUN; an admitted file carries its own posture, and the
profile must never supply one the file did not declare. Environment closure is
captured before Bats and per-invocation allowed changes are enumerated in the
full-file plan; unapproved changes refuse local admission.

## Lease protocol, ownership and FD ledger

Wire-protocol operations (distinct from the Swift process-lifetime operations
above) are `hello`, `spawnScript`, `observeCommand`, `finishClient`, and
`cancelLease` for clients; controller-only operations are `startFrozenFile`,
`beginRecovery`, `queryRecovery` and `closeOwner`. The single source-bound Bats
file lifecycle peer may additionally submit `sealFileAdmissions`, exactly once at
the normal teardown_file boundary; it cannot request recovery commands or inspect
another lease. No operation accepts an arbitrary command, target PID, signal
number, filesystem deletion path or alternate recovery manifest. Direct
fixture/app operations are fixed owner-internal transitions, not client methods.

Owner lease states are `reserved -> spawning -> active -> commandTerminal ->
clientFinished -> draining -> reaped`, with terminal `failedDrained`, terminal
`failedResolved` and terminal `failedUnresolved`. `cancelLease`, timeout,
output overflow, delivery failure, unexpected client EOF, controller EOF, an
expired deadline and a protocol error move any of
`spawning`/`active`/`commandTerminal` directly to `draining` once ownership
exists; the same events on a lease that holds no anchor yet move it to
`failedResolved`, because there is nothing to drain. A lease that fails BEFORE
ownership exists (a native spawn error, refused descriptors, or an admission
refusal raised after reservation) moves `reserved`/`spawning` to
`failedResolved`, with no anchor created and nothing to reap.

`draining` has exactly three exits. A lease moves from `draining` to
`failedDrained` when the lease failed for any of the causes listed above and its
owned anchor was then signalled and confirmed reaped by this owner's sole reap.
A lease moves from `draining` to `reaped` only when its command completed
without any lease failure and its anchor was then confirmed reaped by that same
sole reap. A lease moves from `draining` to `failedUnresolved` on an unresolved
reap or on lost authority. `failedUnresolved` is otherwise reserved for lost
authority after ownership existed.

`reaped` remains the terminal-success state and requires an actual sole reap of
an anchor this owner owned under a lease that never failed; `failedDrained`,
`failedResolved` and `failedUnresolved` are the terminal-failure states. There
are exactly four terminal states, no other state is terminal, and no transition
leaves any of the four. `failedDrained`, `failedResolved` and
`failedUnresolved` leases alike still count against the total lease budget
(retained and failed alike) and appear in the receipt with their primary code.

Spawn admission reserves a lease before any native call and journals the request
identity as a pre-spawn admission record. The write order is fixed in three
steps: the pre-spawn admission record is journaled BEFORE the native spawn call;
the live in-memory ownership ledger entry is installed immediately after
successful native spawn and before any post-spawn journal update or ACK; the
post-spawn journal update follows that ledger install. Ownership starts at
successful native spawn, before any client reply. Client disappearance before
ACK therefore cannot strand an unregistered child. A native spawn error leaves
no anchor and closes all received descriptors; a failure after anchor creation
drains that owned anchor even if no lease ID reached the client. Observe/reply
errors never relaunch.

`spawnScript` acknowledges only after the anchor has reported actual command
spawn success or its exact errno. The anchor records actual successful
command-spawn time in the shared clock and includes it in the acknowledgment. A
timed remote lease uses that timestamp plus the original duration; it must not
start a fresh full timeout on receipt. Use the same qualified clock in the Swift
remote path rather than assuming DispatchTime has the same epoch. Existing
no-context timing stays unchanged. Remote scheduling and transport latency are
also bounded by the prearmed file deadline; never reset either absolute deadline
at acknowledgment. This profile adds launch transport overhead but cannot turn a
late file response into valid evidence. `observeCommand` is bounded and checks
the same absolute file deadline after native/transport observations. Existing
client deadline checks remain after its observation/read calls, including
equal/late completion refusal.

`finishClient` completion means all client-side capture reads and raw
`ScriptOutcome` assembly are complete. `result(of:)` nonzero conversion and
stdout trimming happen afterwards in the client and do not affect owner state,
so the proposed Swift lease seam must expose the raw outcome before that
conversion; that seam is proposed internal structure, not implemented.
`finishClient` closes the client's lease connection and owner request metadata;
it does not reap or signal the retained successful anchor. The owner records the
command status plus client completion, retaining only the bounded lease/anchor
control state. A connection must not signal EOF as successful release until that
acknowledgment is validated. Unexpected EOF at any earlier phase cancels the
lease. A lost release ACK may cause cleanup and fail the file; it must not create
a false pass.

FD obligations:

| Holder | Descriptors kept | Release |
|---|---|---|
| Swift client | Existing input writer/output readers, or capture FDs; lease channel | Existing I/O policy and all error exits; raw error saved before cleanup |
| Owner | Accepted FDs only through anchor spawn; anchor control and journal | Close stdio/metadata duplicates immediately after verified transfer; control after final signal/reap |
| Anchor | Private owner channel; temporary child endpoints | Child endpoints closed immediately after command spawn; private channel never inherited |
| Script | Exactly stdin/stdout/stderr and explicitly established runtime descriptors | Ordinary command lifetime; no owner/journal/receipt/control descriptor |

Descriptor delivery does not transfer the client's original close obligation. A
missing ACK never makes the sender assume the recipient closed its copies. Both
maintain independent ledgers. Test shared-open-file-description capture behavior
explicitly: no seek on a shared capture; snapshots use fixed-length pread while
the live anchor preserves group authority. Owner/client read failure cannot be
excused by a successful command status.

### Frozen request and reply schemas (protocol 1)

Every frame carries the common envelope below in addition to the
operation-specific keys that follow. Every value is a bounded ASCII token, an
integer, a boolean, a fixed enum or, in the single `closeOwner` case below, one
nested object of frozen keys; no free text, no script content, no payload
bytes and no filesystem path appears in any frame. Every ID is exactly 32
lowercase hex, including `lease_id`, which is the owner-created opaque token
described above and is never a numeric process ID. Timestamps are shared
`CLOCK_UPTIME_RAW` seconds values encoded as decimal strings with exactly nine
fractional digits. Exact envelope keys:

| Key | Direction | Type and bound | Meaning |
|---|---|---|---|
| `protocol` | both | integer, exactly 1 | Frozen protocol version |
| `op` | request | fixed enum of the operation names below | Requested operation |
| `run_id` | both | 32 lowercase hex | Run scope identity |
| `file_id` | both | 32 lowercase hex | Admitted-file scope identity |
| `connection_id` | both | 32 lowercase hex, client-created, unique per connection | Connection identity; the reply echoes it |
| `sequence` | both | monotonic positive integer, no reuse | Request sequence; the reply echoes its request's value |
| `ok` | reply | boolean | Whether the requested operation succeeded |
| `code` | reply | fixed refusal code or null | Exactly one fixed code when `ok` is false; null when `ok` is true |
| `lease_id` | both | 32 lowercase hex or null | Non-null on every operation naming a lease; null otherwise |

A failure reply carries `ok` false and exactly one fixed refusal code from the
vocabulary below. A success reply carries `ok` true and a null `code`. An
unknown key, a missing key, a wrong type or an out-of-bound value in any frame
refuses the connection with `protocol-frame`, closes every descriptor received
with that frame and fails the file.

The failure reply shape is uniform across every operation and is stated once
here rather than per row: a failure reply for any operation carries the common
envelope, `ok` false, exactly one fixed refusal code in `code`, and EVERY
operation-specific reply key listed for that operation below, each present with
a null value. Key presence is therefore identical between an operation's
success and failure replies; only the values differ, and every non-null
constraint stated in a reply row below (`released` exactly true, for example)
is a success-path constraint that the failure shape overrides. For `closeOwner`
the nested `notice` object is itself null on failure rather than present with
null members. Exact per-operation keys, all additional to the envelope:

| Operation | Request keys | Reply keys |
|---|---|---|
| `hello` | `connection_scope` (fixed enum `cli`, `helper`, `file-lifecycle`), `image_sha256` (64 lowercase hex), `nonce` (64 lowercase hex) | `accepted_scope` (echoes the admitted enum) |
| `spawnScript` | `delivery_mode` (fixed enum `inline`, `timed`, `stdin`, `timedStdin`), `timeout_ms` (bounded integer, non-null exactly for `timed` and `timedStdin`, else null), `argv_bytes` (bounded integer, 0..4194304, the advertised metadata length); carries exactly four SCM_RIGHTS descriptors on the frame's first byte, and argv content travels through the metadata descriptor, never in the frame | `lease_id` (envelope, non-null on success), `spawned_at` (decimal string, non-null on success, else null), `spawn_errno` (bounded integer, non-null only with code `spawn-failed`, else null) |
| `observeCommand` | none; `lease_id` names the lease | `command_terminal` (boolean), `command_status` (bounded integer, non-null exactly when `command_terminal` is true), `command_terminal_at` (decimal string, non-null exactly when `command_terminal` is true) |
| `finishClient` | `client_capture_complete` (boolean, exactly true) | release ACK: `released` (boolean, exactly true), `client_finished_at` (decimal string), `lease_state` (fixed enum, exactly `clientFinished` on success) |
| `cancelLease` | none; `lease_id` names the lease | `lease_state` (fixed enum, `draining` when the lease holds an anchor, `failedResolved` when it holds none) |
| `startFrozenFile` | controller-only: `manifest_sha256` (64 lowercase hex) | `armed` (boolean, exactly true on success), `manifest_sha256` (echo), `snapshot_complete` (boolean), `deadline_total` (decimal string) |
| `sealFileAdmissions` | file-lifecycle peer only, exactly once; none beyond the envelope | seal ACK: `sealed` (boolean, exactly true), `sealed_at` (decimal string); no restoration field exists on this reply |
| `beginRecovery` | controller-only: `reason` (fixed enum `cancelled`, `deadline`, `controller-directed`) | `recovery_started` (boolean), `phase` (fixed enum `script-drain`, `fixture`, `app`) |
| `queryRecovery` | controller-only; none beyond the envelope | `phase` (fixed enum `script-drain`, `fixture`, `app`, `complete`), `last_journal_sequence` (monotonic positive integer), `unresolved_obligations` (bounded integer count) |
| `closeOwner` | controller-only; none beyond the envelope | `notice` (object, non-null on success, null on failure) whose own exact keys are the completion notice's frozen key list, unchanged: `version` (integer, exactly 1), `run_id` (32 lowercase hex), `file_id` (32 lowercase hex), `manifest_sha256` (64 lowercase hex), `receipt_bytes` (bounded integer), `receipt_sha256` (64 lowercase hex) and `outcome` (fixed enum) |

`spawnScript` acknowledges only after the anchor reports actual command-spawn
success or its exact errno, so its reply is the acknowledgment the timing rules
above describe. `observeCommand` reports command status and terminal flag only;
it never reaps. `finishClient`'s reply is the release acknowledgment that a
connection must validate before treating EOF as successful release.
`sealFileAdmissions`'s reply is the seal acknowledgment and reports no
restoration success. `closeOwner` is controller-only, and its reply carries the
common envelope plus `ok`, `code` and the single nested `notice` object; the
nested object's exact key list is the completion notice's frozen key list under
"Receipt and evidence" and is closed in the same way. The nested notice's
`run_id` and `file_id` MUST equal the enclosing envelope's `run_id` and
`file_id`; any inequality refuses the connection with `protocol-frame` and fails
the file.

### Fixed refusal codes and failure precedence

Owner and anchor refusals carry exactly one of these fixed bounded kebab-case
codes; no arbitrary exception text, script content or private path appears in a
code or its display form. Exact values:

`context-missing`, `context-malformed`, `context-mismatch`, `protocol-frame`,
`protocol-sequence`, `ancillary-invalid`, `descriptor-invalid`, `argv-invalid`,
`limit-exhausted`, `deadline`, `cancelled`, `spawn-failed`, `ownership-lost`,
`cleanup-failed`, `journal-failed`, `receipt-failed`, `manifest-invalid`,
`owner-unexpected-exit` and `anchor-unexpected-exit`.

`manifest-invalid` names a manifest, original-snapshot, journal, receipt or
completion-notice artifact that fails its schema or identity validation,
including an unknown key, a missing key, a duplicate key, a `version` other than
1 and a binding digest that does not match. It is distinct from `journal-failed`
and `receipt-failed`, which name write or publish failures of an otherwise valid
artifact.

`descriptor-invalid` names a received stdio or metadata descriptor that fails
its fstat/type rule; `argv-invalid` names a metadata snapshot that fails its
shape, NUL, size or stability rule. Refusals raised before the owner accepts a
file plan, such as an unapproved environment change, an after-seal script trap
or a second live owner for the run directory, are plan-admission refusals
outside this vocabulary; a duplicate seal or a post-seal admission is
`protocol-sequence`.

`owner-unexpected-exit` is controller-emitted, never owner-emitted. An owner
cannot journal its own unexpected exit, so no owner journal record, receipt or
control frame ever carries this code. Its sole carrier is the controller
terminal record specified under "Receipt and evidence", written by the
controller when it observes the owner's own exit without a valid final receipt.
Its position in the frozen same-turn order below is retained for vocabulary
completeness only: journal-sequence precedence and same-turn arbitration apply
solely to owner-written records.

`spawn-failed` carries the native errno separately as a bounded integer field; no
other code carries a numeric detail. Precedence is by time, not severity: the
earliest failure observed for a lease or file, ordered by journal sequence,
becomes its primary code, and every later failure is recorded as an additional fixed code that never
replaces the primary. Concretely, an observed `cancelled` or `deadline` that
precedes a protocol or ownership event stays primary; a `protocol-frame` or
`protocol-sequence` observed before ownership loss stays primary over a
subsequent `ownership-lost`; and `cleanup-failed` never becomes primary while any
earlier code exists. Cleanup uncertainty is reported separately from the primary
code and independently prevents success, so a file can fail with a primary
`cancelled` and a recorded `cleanup-failed` at once.

Failures that become observable within one poll turn are not separable in time
and are recorded under one journal sequence; they are arbitrated by this frozen
same-turn order rather than by the order the owner loop happens to inspect its
channels. Exact order: `cancelled` (including controller EOF, which is recorded
as `cancelled` with `controller_eof` true), `deadline`, `ownership-lost`,
`anchor-unexpected-exit`, `owner-unexpected-exit`, `protocol-sequence`,
`protocol-frame`, `ancillary-invalid`, `descriptor-invalid`, `argv-invalid`,
`context-missing`, `context-malformed`, `context-mismatch`, `limit-exhausted`,
`journal-failed`, `receipt-failed`, `cleanup-failed`. Any vocabulary code not
named in that order sorts after every named code, in the order the vocabulary
lists it. Primary codes therefore never depend on iteration order.

## Error and result compatibility

No Swift `Error` is serialized. Input/output/capture allocation, read, delivery
and output-limit errors are created in the existing client operations. Save the
original error before requesting owned cleanup, then rethrow that same error
after the bounded lease cleanup attempt; report cleanup uncertainty separately to
the owner/file result. Preserve marked configuration/overflow errors, unmarked
identical-text controls, raw capture NSError family and the existing
script-status conversion. Transport failures are ordinary fixed
`RunError.launchFailed` failures and an unconditional attestation refusal; they
never impersonate `ScriptOutputLimitExceeded` or an AppleError policy marker.

Native command spawn failure carries only its numeric errno and fixed stage; the
client builds the same POSIX error at the existing launchFailed conversion
boundary. Anchor/protocol failures carry the fixed codes enumerated above, not
arbitrary exception text or script contents. `ScriptOutcome` remains exact
status/stdout/stderr bytes; `result(of:)` still performs nonzero conversion and
stdout trimming once. Confirm error equality at the actual conversion boundary
rather than claiming universal localized Foundation message parity.

For direct `/usr/bin/osascript` callers in `bats/helpers/bounded_exec.py`, add a
source-bound lease backend selected only under validated local context, retaining
merged stdout/stderr at the OS pipe, closed stdin, ordinary shell status
conversion, timeout 124, cancellation 128+signal and cancellation output discard.
Do not route direct reachability probes through the CLI under test. Version 1 of
this protocol admits only the fixed `/usr/bin/osascript` spawn role. A local Bats
file whose frozen plan contains any other separate-group wrapper command,
including `$BIN` wrappers that today rely on `start_new_session=True`, is REFUSED
before execution with its catalog declarations intact, until a separately
reviewed typed wrapper-plan lease is specified and added to this document as a
later version. No wrapper may retain `start_new_session=True` under a validated
local context. The inventory of every reachable separate-group callsite,
including helper-internal ones, is a pre-admission deliverable, and any
unadapted callsite refuses the file. The old communicate-then-signal
implementation is not a supported ownership backend.

## Bounds and cleanup authority

Pin protocol resource limits in the trusted local profile: 32 simultaneous
spawning/active commands, 4096 total retained leases per file, 32 KiB per control
frame, 4 MiB argv metadata per spawn. Preflight planned bounds before Bats where
knowable, count incrementally at admission, and refuse before spawn at
exhaustion. Never reap a successful anchor early to reclaim a slot and later
signal its recycled group. Complete successful leases still consume the total
retained-lease budget. Limits are explicit local evidence support constraints; no
unlimited public output default changes.

The file plan includes one absolute work deadline and separately reserved
script-drain, fixture and app-recovery phases, all within a fixed owner lifetime.
Each admitted file's total owner lifetime is drawn from the single remaining
absolute phase deadline the caller supplies, as the sibling process unit fixes
it; that budget is never multiplied per file, so expanding file by file consumes
one shared remaining allowance rather than granting a fresh lifetime to each
file. Use shared CLOCK_UPTIME_RAW for exchanged timestamps. Preserve each
existing local wrapper's configured work/grace duration and the existing app
setup/teardown 120-second bounds; do not silently shorten a command's existing
bound to obtain coverage. The profile computes a sufficient total deadline from
the exact plan before admission, within that single remaining allowance. Reject
an impossible reservation before Bats. Every owner loop checks phase and total
deadlines before and after native/read/write/select/file operations; synchronous
kernel calls remain checkpoint-bounded, not hard real-time.

On cancellation, protocol error, controller EOF or file work expiry: stop all
admissions; latch file failure; start owned Bats-group TERM while draining inner
leases; finish bounded Bats escalation and reap without killing the owner; signal
each still-owned live script-anchor group with TERM, wait its configured grace,
then KILL, then perform its sole selective anchor reap. No signal follows reap.
An unexpected anchor exit, ECHILD, failed required signal or unresolved reap
fails cleanup. ECHILD revokes signal and wait authority first. Do not forgive
EPERM based on a terminal-only group or infer group emptiness. Do not make new
targets from the journal.

Anchors arm a finite fallback before accepting command execution. A fallback that
self-terminates its own still-live, verified group is distinct from a stale PID
watchdog. It is not successful owner cleanup; its occurrence fails the file.
Normal recovery must be observed before fallback could explain cessation. If an
anchor exits unexpectedly, retain only valid wait authority for bounded reaping
and record descendant cleanup as unresolved; do not try to repair lost
live-anchor authority with getpgid or terminal-only signaling. Eventual reap
transfer, if needed, grants only exclusive reaping with no I/O descriptors or
signal capability and blocks success.

## Prearmed recovery manifest and app progress

Before Bats begins, the owner privately freezes a schema-versioned manifest
containing run/file/source/binary identities, original six-app snapshot/preserve
flag, exact admitted fixture obligations, fixed recovery command templates,
profile resource/deadline limits and private directory identities. Store outside
Bats-owned deletion paths using exclusive 0600 regular files below the owner's
0700 root. Create the 0700 root with mkdir failing on an existing path, verify
every component's owner and mode, and record its st_dev/st_ino in the manifest;
the AF_UNIX endpoint's protection derives from that directory, not from the
socket's bind mode. Reject links, wrong ownership/mode, extra members and drift.
A mutable progress journal is a different artifact: monotonically sequenced
transitions linked to that immutable manifest, written atomically with
complete-write/flush handling before an effectful attempt. No repository or
public receipt includes live IDs, paths, output or account structure.

The manifest, the journal and the final receipt each carry an integer `version`
whose only admitted value is 1. Each artifact's key set is closed: an unknown
key, a missing key, a duplicate key or a `version` other than 1 refuses the
artifact and fails the file; no partial or forward-compatible acceptance exists.

Manifest contract version 1 has exact keys: version, run_id, file_id,
source_sha256, binary_sha256, package_closure_sha256, profile_id, app_snapshot,
app_preserve, fixture_obligations, recovery_templates, resource_limits,
deadline_plan, private_root_identity and endpoint_identity.

Journal contract version 1 has exact keys: version, manifest_sha256, run_id,
file_id, sequence, transition, subject_kind, subject_key, subject_identity,
attempt_state, observed_outcome and recorded_at. subject_identity carries the
bounded observed identity triple for an app subject (ASN, PID and stable
check-in token) and is absent-valued for other subject kinds. Sequence is a
monotonic positive integer with no reuse or wrap; every record binds the same
manifest_sha256.

Nested records inside those artifacts are closed in exactly the same way: an
unknown key, a missing key or a duplicate key inside a nested record refuses the
artifact and fails the file, precisely as a top-level violation does, and is
reported as `manifest-invalid`. Only the per-lease and app-progress records are
frozen in this version; every other nested record's exact key list is a
pre-implementation deliverable that must be added here before the artifact is
admitted.

The app-progress record, which appears in the journal under an app-subject
transition and in the receipt's app_restoration, has exact keys: app_key,
original_running, preserve, subject_identity, attempt_state, observed_outcome,
escalation and processed_sequence. subject_identity carries the bounded observed
identity triple and no other field; app_key is one of the six fixed app keys.
Every exact key is always PRESENT here too: the record is state-dependent
through nullability, never through key presence. subject_identity is null for a
non-app subject and for an app subject not yet observed; escalation is null
until escalation is attempted; observed_outcome is null while attempt_state is
`attempted` and no outcome has been observed; app_key, original_running,
preserve, attempt_state and processed_sequence are always non-null. A
null where the record's state requires a non-null, or a non-null where it
requires a null, refuses the artifact as `manifest-invalid`.

The fixed value sets used by those nested records are frozen here.
`attempt_state` is exactly one of `pending`, `attempted` and `resolved`.
`observed_outcome` is exactly one of `stopped`, `escalated`, `still-running`,
`changed`, `reappeared` and `unknown`. `escalation` is exactly one of `none` and `hard-kill`, and is
null until escalation is attempted, as the nullability rule above states.
`descriptor_closure`, wherever it appears in the receipt as a top-level key or
inside a per-lease record, is exactly one of `complete`, `incomplete` and
`unknown`. A value outside the stated set refuses the artifact as
`manifest-invalid`.

Two bounds apply wherever this document calls a value bounded without stating a
tighter bound of its own. A bounded integer is non-negative and strictly less
than 2^31. A bounded timestamp is a shared `CLOCK_UPTIME_RAW` seconds value
encoded as a decimal string with exactly nine fractional digits. A tighter
stated bound, such as `argv_bytes` at 0..4194304, governs over the general one.

Final receipt contract version 1 has exact keys: version, protocol, profile_id,
package_closure_sha256, native_artifact_sha256, clock_id, run_id, file_id,
binary_sha256, manifest_sha256, file_process_status, lease_counts,
stage_outcomes, last_journal_sequence, bats_anchor_state, script_anchor_states,
descriptor_closure, fixture_restoration, app_restoration,
unavailable_final_checks, unresolved_obligations and lease_records. Lease records
carry only bounded lease identity, fixed state and fixed stage codes.

The receipt's per-lease record has exact keys: lease_id, connection_scope, state,
primary_code, additional_codes, command_status, spawn_errno, spawned_at,
command_terminal_at, client_finished_at, anchor_signal_state, anchor_reap_state,
descriptor_closure and controller_eof. Every exact key is always PRESENT: the
record is state-dependent through nullability, never through key presence, so a
success record and a failure record have identical key sets. lease_id,
connection_scope, state and descriptor_closure are always non-null. The
remaining keys — primary_code, additional_codes, command_status, spawn_errno,
controller_eof, spawned_at, command_terminal_at, client_finished_at,
anchor_signal_state and anchor_reap_state — are nullable, and additional_codes
additionally admits the empty list. state is one of the lease states above, and
because the receipt is written after cleanup it is always one of the four
terminal states; primary_code and every member of additional_codes is a fixed
refusal code; spawn_errno is the bounded integer errno; command_status is the
bounded integer command status; spawned_at, command_terminal_at and
client_finished_at are shared-clock timestamps; controller_eof is a boolean.

Nullability constraints are keyed on `state`. For `reaped`: primary_code is
null, additional_codes is the empty list, spawn_errno is null, controller_eof is
null, command_status is an integer, spawned_at, command_terminal_at and
client_finished_at are all non-null, and anchor_signal_state and
anchor_reap_state each carry a value from their fixed sets. For
`failedResolved`: primary_code is non-null, spawned_at is null,
anchor_signal_state and anchor_reap_state are both null, and spawn_errno is
non-null only when primary_code is `spawn-failed` and null otherwise. For
`failedDrained`: primary_code is non-null, spawned_at is non-null because
ownership existed, command_status is nullable because the lease may have failed
before any command status was observed, anchor_signal_state is one of
`term-sent`, `kill-sent` and `signal-failed`, and anchor_reap_state is `reaped`
because the anchor was confirmed reaped by the sole reap; controller_eof is
non-null exactly when the recorded cause was controller EOF, which is the
`cancelled` case of the general controller_eof rule below. For
`failedUnresolved`: primary_code is non-null, spawned_at is non-null, and
anchor_reap_state is `unresolved`. In every state controller_eof is non-null
only when primary_code is `cancelled`. anchor_signal_state has the fixed value
set `none`, `term-sent`, `kill-sent` and `signal-failed`; anchor_reap_state has
the fixed value set `none`, `reaped` and `unresolved`. A null where that state
requires a non-null, or a non-null where that state requires a null, refuses the
artifact as `manifest-invalid`.

Normal completion uses a two-phase handoff; it must never wait for app
restoration inside a still-running Bats teardown_file. After all per-test
teardown hooks have finished, the source-bound file lifecycle hook sends
`sealFileAdmissions`. The owner durably records the seal, rejects new script
admissions, and ACKs only that seal; the hook then returns immediately. It does
not await script drain, fixture cleanup, app restoration or the final owner
receipt. A missing/rejected ACK returns a teardown failure and latches
failed-file recovery. An ACK reports no restoration success. A peer seal cannot
substitute for the anchor's actual Bats command completion status.

The normal owner path waits for actual natural Bats command completion under the
existing work deadline, preserves its exact status and complete output, then
cleans the retained Bats anchor/group and all script anchors before starting
fixture/app restoration. If Bats does not finish after sealing,
timeout/cancellation takes the forced recovery path; normal seal does not extend
the file deadline. Forced recovery stops admission and terminates the active Bats
group without waiting for a seal or a cooperative hook. Both paths converge only
after Bats/script quiescence at the same owner-controlled fixture/app lifecycle
state machine. The external final owner receipt, not teardown_file's return or
TAP alone, gates file acceptance. Nonzero Bats status remains failure even if
restoration succeeds; failed restoration refuses evidence even if Bats returned
zero.

Existing per-test fixture cleanup stays before the seal. In particular Mail's
teardown() best-effort template deletion still runs while ordinary script
admissions are open, and preserves its existing handling of the test status; do
not replace a failed test with cleanup success or expose discarded output. Bind
the exact fixture store to admitted scratch and arm owner recovery before any
test creates it, so outer death does not rely on the shell variable surviving.
The normal hook does not add a second cleanup invocation. Freeze and review all
EXIT/signal traps and post-teardown_file paths: no path requiring a new script
lease may run after seal. Bats-internal bookkeeping/temp cleanup may finish
normally. A file with an unadapted after-seal script trap is refused before
execution; do not silently suppress it. Ordinary non-profile lifecycle hooks keep
their existing behavior.

Reuse the exact parsers in `bats/helpers/app_lifecycle.py` and the lifecycle
algorithm in `bats/helpers/app_lifecycle.bash` by moving its operation dispatch
behind the owner; do not maintain divergent termination rules. Normal file
sealing and owner recovery are exclusive state transitions, not a stale
filesystem lock that a second actor may break. Only the owner runs the eventual
termination loop, so a shell hook and recovery actor cannot compete. Two
LocalFileOwners never contend for the same run directory because concurrent local
Bats files are unsupported: AGENTS.md already states that recursive Bats is
sequential and that parallel local-file execution is unsupported. This protocol
relies on that existing constraint and introduces no cross-file lock of its own;
an observed second live owner for the same run directory is a refusal, not a
condition to arbitrate.

For each of the six fixed app keys, journal original running state and, when an
originally absent app is observed, its exact ASN/PID/stable check-in token before
termination. Journal `attempted` before the normal termination command, then each
observed stopped/escalation outcome. Revalidate the exact identity before normal
and hard termination, preserving hard kill by original ASN only. Record a
processed key before its first attempt. An interrupted attempt with unknown
result may be resolved only by bounded exact read-only observation: stopped can
discharge it; a changed, reappeared or still-running uncertain instance is
failure, not permission to replay or pick a new identity. No already-processed
app key may be targeted again. Preserve the quiet-period rescan and fail
reappearance without retargeting. Initially running apps and preserve-mode apps
are never terminated.

A setup interruption before a complete original snapshot means no Bats admission.
After a complete snapshot but before Bats acknowledgment, the owner can apply
only that already-armed plan. Journal failure irreversibly stops admissions and
all new app/fixture effects, but MUST NOT prevent bounded signal/reap cleanup for
Bats/script anchors already owned in the live in-memory authority ledger. Install
that ledger entry immediately after successful native spawn and before any
post-spawn journal update or ACK. A journal failure before spawn admits no child; after
spawn, before/after ACK or during drain, continue only the bounded containment
work authorized by that existing kernel ownership. Never derive a signal target
from a damaged/stale journal, and never require a successful recovery-journal
write before stopping an owned group. File success remains impossible. If kernel
authority is lost, record unresolved containment and do not proceed to
app/fixture effects. File receipt requires snapshot completion, every attempted
operation accounted, quiet-period success and empty outstanding obligations. Keep
failed recovery state private for assessment; delete only validated own success
artifacts at the final close boundary.

Recovery order after script/Bats quiescence is exact fixture cleanup, then apps.
Initially admit filesystem fixtures only under predeclared private scratch roots
with recorded directory identities and a bounded source-reviewed member contract;
use descriptor-relative no-follow operations and reject replaced directories,
links/hardlinks outside the allowed contract and unknown members rather than
sweep HOME. Prefer precise private store removal/restoration over starting the
CLI merely to delete a template when the whole store is owned scratch. Real-store
creation requires a separately reviewed exact-ID and unknown-outcome contract
that survives creation-before-persistence; shell variables/write-then-log are
insufficient. Unsupported real-store files remain refused with their catalog
declarations intact.

The recovery capability was armed before Bats and can issue only its frozen
fixture operations and existing exact LaunchServices commands after proven
interpreter quiescence. It cannot run Git/build/test, discover new cleanup
targets, change TCC/keychain permissions, create a general session or admit
another file after poison. Real HOME preserves existing keychain/TCC/store
reachability; it does not authorize mutation of those settings or records. Never
set global sandbox/dry-run values that would change posture tests. Preserve
parent/client umask; private creation permissions are local to owner operations.

## Receipt and evidence

The complete final receipt is a separate bounded artifact, not an oversized
control frame. The owner writes at most 8 MiB of strict UTF-8 JSON to an
exclusive 0600 regular temporary file in its private root, with at most 4096
lease records and 1024 encoded bytes per lease record; no payload bytes,
arbitrary exception strings or unbounded path lists are permitted. Write/flush/
close and atomically publish the fixed name `local-owner-final.json` once, then
send a control completion notice. Completion notice contract version 1 has
exact keys: version, run_id, file_id, manifest_sha256, receipt_bytes,
receipt_sha256 and outcome; an unknown key or version mismatch refuses the
notice. The notice fits the 32 KiB frame and supplies no caller-selected
filename. A failed write, oversized receipt,
failed notice or incomplete publication is failed evidence. Do not truncate
records or drop unresolved obligations to fit.

The controller opens that fixed owner-root member with no-follow checks, verifies
regular type/owner/0600, checks the size bound before allocation and confirms
stable descriptor identity/size around the bounded read. It validates exact byte
length/digest against the completion notice plus complete schema, count and lease
identity closure. The journal is not accepted instead of a missing final receipt.
Post-publication drift, duplicate notices, partial files and extra records refuse
evidence. A receipt the controller cannot read because the owner's private root
is already gone is failed evidence, exactly like a missing receipt: the notice's
length and digest are not a substitute for the artifact, and a vanished root is
never interpreted as successful cleanup. Reading a final failure receipt
in-process is permitted after general-session poison; running Git or other new
commands to validate it is not. The owner retains the immutable artifact until
the controller validates or its independently bounded final close expires;
artifact acknowledgment does not extend that deadline or recreate ownership.

When the controller observes the owner's own exit without a valid final receipt,
the CONTROLLER writes a terminal record of its own, because the owner cannot
journal its own disappearance. Controller terminal record contract version 1 is
published under the fixed name `local-owner-terminal.json` as an exclusive 0600
regular file inside the CONTROLLER's own private root, never inside the owner's
root, and has exact keys: version, run_id, file_id, manifest_sha256,
observed_at, owner_exit_kind, owner_exit_value, last_journal_sequence_seen and
code. version is the integer 1; run_id and file_id are the 32 lowercase hex
scope identities; manifest_sha256 is the bound manifest digest; observed_at is a
shared-clock timestamp; owner_exit_kind is one of the fixed tokens `exited`,
`signalled` and `unknown`; owner_exit_value is a nullable bounded integer;
last_journal_sequence_seen is a nullable monotonic positive integer; and code is
exactly `owner-unexpected-exit`. The controller then treats the file as failed
with unresolved containment obligations.

Cross-record precedence is fixed. A valid owner final receipt, when present and
validated, is authoritative over the controller terminal record. When only the
controller terminal record is present, it governs and the file is failed with
unresolved containment obligations. When both are absent the file is failed
evidence. The owner never emits `owner-unexpected-exit` itself, and the
journal-ordering rules stated above apply only to owner-written records.

One immutable final owner receipt binds protocol/profile/trusted
package/native/clock/file/binary/manifest identities; file process status; counts
and fixed stage outcomes; last journal sequence; Bats and each anchor signal/reap
state; descriptor closure; fixture/app restoration; any unavailable final checks;
and unresolved obligations, under the exact version-1 key list above. Raw output
is held separately in existing private captures. It never grants PID authority.
Validate complete schema, exact identities, no missing leases, zero unresolved
obligations and successful restoration after cleanup before using any TAP rows.
Apparent TAP success, a client release, a killed owner or an app snapshot alone
cannot attest the file. Cancellation observed before logical result freeze wins;
after freeze receipt/stdout/exit remain consistent under the qualified controller
contract.

No native prerequisite or stand-in result qualifies this implementation.
Independently bound prerequisite receipts may be reused within their demonstrated
scope; they are not LocalFileOwner acceptance. Preserve earlier failed
prerequisite observations. Actual hosted acceptance remains after public
visibility; this local unit does not collapse the distinct hosted build/Bats
runners or authorize visibility.

**Deferred schema freezes.** Exactly two schema items remain deferred to
pre-implementation deliverables. First, the exact key list of every nested
record other than the per-lease record and the app-progress record frozen
above, in the manifest, the journal and the receipt alike. Second, the wire
operation and transport by which the controller requests the single frozen Bats
plan, which `startFrozenFile` arms but does not itself carry. Each must be
added to this document before the artifact or operation it governs is admitted;
no implementation may infer either from surrounding prose. Accordingly,
acceptance item 7's bounded receipt validator in this version validates the
frozen top-level key sets, the per-lease records and the app-progress records
in full, and treats every deferred nested record as an opaque bounded byte
string subject only to the artifact's size and count bounds, until that record's
key list is frozen here.

## Test-first acceptance and delivery

Items 1, 2 and 7 are grant-free: they require no exclusive runtime grant and are
the first deliverable. Items 3, 4 and 5 each require the SAME exclusive runtime
grant, because each drives actual native anchors, actual Swift transport or the
actual direct `/usr/bin/osascript` helper; none of them may run under the
grant-free increment. Item 6 uses synthetic adapters and item 8 is the reviewed
live-admission step, which additionally requires the ratifications recorded under
"Design choices pending operator ratification".

1. Add pre-run negatives for missing/invalid context, known unowned inner spawn,
   unknown wrapper command/environment, incomplete fixture contract, missing
   original snapshot, stale binary and exhausted limits. Assert zero native/Apple
   spawn and complete catalog closure. Add RED at the existing local integration
   boundary before production wiring. This item is owned by the Python
   owner/protocol tests in `Tests/automation` (unittest, no spawn), which is the
   named local integration boundary for context admission.
2. Pure fake ownership tests bypass all real spawn/native loaders. Item 7 (socket
   tests) is also grant-free and may be pulled forward beside this item. Cover
   every lease transition, interrupted spawn before ACK, duplicate/out-of-run/
   reordered frames, partial ancillary transfers, EOF at each boundary,
   descriptor 0/1/2 and duplicate merged-pipe roles, error precedence,
   ECHILD-before-deadline handling, required-signal failure, unexpected anchor
   death, no signals after reap and no general commands after poison. Test
   malformed/missing/forged success receipts; no fake PID is ever signaled. The
   owner-side half of this item belongs to the Python owner/protocol tests in
   `Tests/automation` (unittest, no spawn); the client-side lease seam half
   belongs to the Swift lease seam tests in `Tests/AppleKitTests`
   (swift-testing), which exercise the process-lifetime sum type against a fake
   backend.
3. Under a later exclusive runtime grant, test actual native anchors and Unix FD
   transport using finite self-expiring synthetic commands, including childless
   zero/nonzero, root-exited output-holding and closed-output descendants, TERM
   resistance, CLI/wrapper/Bats SIGKILL before/after ACK and after command
   terminal status, owner-controller EOF and late reply. Establish cessation
   before independent fallback expiry using the qualified clock. Show live anchor
   remains while command status is terminal and exact signal-before-anchor-reap
   order. Every spawned fixture arms its own expiry before blocking.
4. Under the same exclusive runtime grant as item 3, actual Swift transport tests
   exercise all four ScriptDelivery modes with exact argv and raw streams,
   normal/nonzero/signal statuses, timed late observation, delivery/pipe/capture
   failures, concurrent stderr fairness, fixed capture snapshot, explicit/env
   output policy precedence, exact aggregate boundary/overflow and
   marked/unmarked controls. Capture error sentinel proves identity propagation;
   separate actual error-boundary cases prove construction. The ordinary
   no-context backend and its successful-background controls remain green.
5. Under the same exclusive runtime grant as item 3, actual direct-helper tests
   compare merged output/status/grace/cancellation semantics and prove the direct
   osascript oracle remains independent of the CLI. Demonstrate wrapper and
   script groups cannot outlive lost clients within the supported fault model.
   Inspect descriptor identity/inheritance, not just pathname existence or mocked
   worker completion.
6. Synthetic lifecycle/fixture adapters interrupt every before/after journal
   boundary and normal/recovery handoff. Prove original-running and preserve
   behavior, exact identity refusal, no repeated app key, no retarget after
   reappearance, quiet-period behavior, no cleanup before script quiescence,
   retained outstanding obligations on failure, exact scratch scope, no unsafe
   umask changes and no Git/next-file launch after poison. Missing/wrong journal
   and result negative controls must fail independently of child assertions.
   Prove normal seal ACK returns while Bats is alive, app effects remain absent
   until actual Bats completion and group cleanup, failed tests keep their
   original status, and forced recovery works without any seal. Cover failure
   before/after each per-test cleanup and after-seal trap rejection. Inject
   journal failure before native spawn, after spawn before ACK, after ACK and
   during drain: no new admission/app/fixture effects, while every still-owned
   anchor receives bounded containment from the live ledger. Loss of that
   authority must leave explicit unresolved obligations.
7. Add socket tests for silent pre-hello clients, first-byte/ancillary stalls,
   oversized FD batches, saturated connection/queue budgets, a receiver that
   never reads ACKs and cancellation/controller EOF concurrently with those
   conditions. Assert another owned lease still drains before its fallback and
   all received FDs close. Exercise a full 4096-record final receipt through the
   real bounded artifact reader, plus oversized/missing/truncated/drifted/
   wrong-digest records and a plausible small success notice with no valid
   artifact. Pure framing tests cannot stand in for the actual nonblocking
   multi-client loop. This item is owned by the Python owner/protocol tests in
   `Tests/automation` (unittest, no spawn) and is grant-free, using the item-2
   fake ownership backend for every lease; real-anchor drain interaction is
   deferred to item 3.
8. Review the combined production and synthetic changes independently before any
   real local admission. Then admit one exact complete local Bats file under
   existing conduct and runtime approval, validate binary/source/environment/
   lifecycle bindings and restoration, and expand file by file. No filtering,
   skipped local declarations or isolated command passes substitute for full-file
   evidence. Full canonical/review/privacy requirements remain unchanged.

The principal implementation risk is the explicit process-lifetime seam and
native FD/anchor integration. Final interface code review must verify that the
local I/O loop never regains numeric signal authority for a remote lease and that
the generic session cannot kill recovery at the Bats deadline. This specification
defines the intended boundary without claiming those properties are implemented.
