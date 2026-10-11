---
topic: messages-automation
last-used: 2026-10-11
importance: high
uses: 3
---

# Messages automation decisions

## 2026-10-11 — Preserve uncertainty after a timed-out UI request

Use a bounded worker mode in the existing executable, with the parent owning the
cross-process lock and a durable pending-operation record. Terminating a worker
stops new client calls but cannot cancel a request already delivered to Messages.
A later caller must therefore refuse UI writes until causal completion is proved
or the operator explicitly resolves the uncertainty. A matching snapshot or
idempotence alone cannot exclude a late conflicting action.

The [port design](../../discovery/beeper-imessage-port.md#automation-and-mutation-safety)
contains the worker-channel, minimal-data, recovery and crash-test requirements.
This is an implementation decision, not a claim that live AX identity or
cancellation behavior has been verified.

## 2026-10-11 — Keep unresolved state separate from successful completion

The journal stores one pending operation and at most 32 resolved receipts under
a stable per-directory lock. Targets are persisted as fixed SHA-256 digests;
raw conversation identifiers can contain addresses and do not belong in this
state. State replacement uses a private temporary file, file synchronization,
atomic rename and directory synchronization. Invalid or unsafe state blocks
writers rather than being silently discarded.

The initial API can resolve a request before possible delivery or record an
explicit operator recovery that acknowledges possible late effects. Successful
post-delivery completion remains deferred until the concrete worker and exact
state verifier can provide operation-bound evidence. Neither an arbitrary proof
string nor a matching snapshot can clear pending state through this foundation.

## 2026-10-11 — Keep worker transport separate from real action construction

The executable now has a hidden worker dispatch with an empty production
registry. Its package-scoped transport uses inherited anonymous pipes, canonical
parent and child executable identity, a fresh operation nonce, bounded frames
and one monotonic deadline. The parent holds the journal lock through the
exchange and records uncertainty before sending any action-capable bytes.
Worker acknowledgment is lifecycle evidence; it never clears the pending action.

Only a named test factory can currently construct a launch request. Before a
real Messages operation is registered, a typed descriptor must derive both the
worker command and journal identity from the same validated target and action.
The test factory must not become a production shortcut. Exact AX identity,
permission diagnostics, live cancellation effects and postcondition verification
remain separate work; this transport adds no public mutation command.
