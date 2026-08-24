---
topic: mail-automation
last-used: 2026-08-24
importance: high
uses: 1
---

# Mail automation learnings

## 2026-08-24 — Bound stalled Apple events at the host process

Mail.app message lookup can stall inside an Apple event while `osascript` remains alive. An
AppleScript `with timeout` block is not a reliable overall deadline for this code: the shared
mailbox locator catches individual AppleScript errors while scanning, and AppleScript timeouts
apply per event rather than to the whole process. A host-side deadline around `osascript` is the
reliable bound.

The attachment metadata lookup uses an opt-in 30-second `AppleScriptRunner` deadline for each
RFC Message-ID spelling. A timeout aborts the alternate spelling. Attachment listing catches the
error and returns disclosed Envelope-Index rows; attachment-save preview preserves that fallback
and cause, while execute refuses without Mail.app's live positional order. The Bats live wiring
test uses a wider process-group deadline so a missing in-process bound fails without stranding an
`osascript` descendant.

Timed process output cannot use the old stdout-before-wait pipe pattern: waiting for termination
while a large result fills a pipe recreates a deadlock. Capture into mode-0600 temporary files,
unlink them before launching the child, and read them only after successful termination. On a
timeout, discard their contents and use bounded TERM→KILL cleanup; never wait indefinitely while
trying to enforce a deadline.
