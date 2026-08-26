---
topic: mail-automation
last-used: 2026-08-26
importance: high
uses: 2
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

## 2026-08-26 — Poll GUI state; never sample it once

Mail can create and display a compose window without making it the front Accessibility window by
one predetermined instant. A fixed delay followed by one nonce-title check therefore produces a
false `wrong-window` refusal even though the intended compose appears moments later. Wait for the
actual condition with a bounded poll instead: the front Mail window must carry this invocation's
unique nonce before any paste or send keystroke can run.

Treat the first match as provisional. After the proven 2.5-second compose settle, re-check that Mail
is still frontmost and the nonce window is still frontmost before any editing keystroke; check both
again immediately before paste, then check Mail process focus once more after subject verification
and immediately before Send (the nonce is intentionally already gone from the title). Any focus
loss restores the real subject and leaves the compose unsent. A timeout follows the same fail-closed
path; neither case may fall back to another visible window or broaden the match.

Do not occupy the pasteboard while waiting for readiness. Snapshot and replace it only after the
post-settle focus/nonce check, record the pasteboard `changeCount`, and clean up conditionally: if
the count is unchanged, clear the injected HTML and restore the prior string; if it changed, the
operator's newer clipboard wins and must not be overwritten. A recognized refusal sentinel is an
expected Mail upstream failure, not an unexpected runner crash, so map it to a typed
`upstream_error` before `runGuarded` can collapse it into `unknown` / exit 70. Live GUI validation
remains operator-present and one-send-at-a-time because source and syntax tests cannot prove focus
behavior on a particular Mac.

GUI cleanup must sit outside an outer `try`/`on error` that encloses every Accessibility call made
after the pasteboard is touched. Otherwise a mid-sequence System Events failure skips straight-line
subject and clipboard cleanup. Catch the failure without reflecting AppleScript's error text (it may
embed window titles), run cleanup, and report delivery as unconfirmed rather than promising no send.
