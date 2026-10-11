---
topic: messages-automation
last-used: 2026-10-11
importance: high
uses: 1
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
