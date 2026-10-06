---
topic: input-safety
last-used: 2026-10-05
importance: medium
uses: 1
---

# Input-safety decisions

## 2026-10-05 — `contacts … --file` takes regular files and handed-over pipes, with the attachment refusals

- **Refusals applied.** `contacts note set`, `photo set` and `vcard import` refuse a `--file`
  path with a control character, or a file inside a credential directory (`sensitiveDirectories`),
  as `safety_violation`, the rules `AttachmentSource.resolve` applies to `mail send --attach` and
  `messages send --file`. `--file` is a CLI extra with no oracle counterpart (the Contacts tools
  take inline strings only), so nothing is narrowed; this is consistent with D12's no-oracle
  precedent, where the CLI blocks credential directories on Contacts' `--out`. Why: the file's
  content is copied into a contact, which can sync off the machine. Porting these rules to the
  attachment sources would refuse inputs Mail's oracle accepts, so that waits on D22 (OPEN).
- **Credential directories are compared by identity.** The reader opens the file's directory,
  then the file inside it (`openat`), and compares each credential directory's `st_dev`/`st_ino`
  (following links) with every ancestor of the opened file's `F_GETPATH` path and of that
  directory's, and with every directory the spelling (made absolute) passes through, each
  resolved by `stat` as the kernel walks it. Why: matching paths as text misses a directory that
  is itself a link (a dotfiles checkout), a link out of a directory named through an unusual
  spelling (`ſ`, the Data volume, a second link), and relative or `..` spellings, including a path
  that enters a directory and leaves it through `..` after a link; Foundation's path standardising
  cannot replace it, because it resolves links once a `..` is present. The comparison reads the
  directories by path at that moment, so one moved while the command runs can escape it.
- **Pipes are read only when handed over.** A regular file is read, and so is a pipe or socket
  handed over as exactly `/dev/stdin` or `/dev/fd/N`, which is duplicated (`F_DUPFD_CLOEXEC`)
  rather than opened by path, so a lookalike spelling resolving to a named pipe cannot pass for
  it (a shell pipe hands over a pipe; Node's and Bun's spawn input, a socket). A named pipe,
  device, directory, a socket opened by path, or a terminal on stdin is refused as
  `validation_error`. Every read stops one byte past 25 MB. Why: piped input through `/dev/stdin`
  worked before and the inline flags cannot replace it (the argument list is capped at `ARG_MAX`,
  1 MB here, not 25 MB), while a named pipe opened by path reads as empty when nothing writes to
  it.
- **Hard links are a stated boundary, not refused.** A hard link to a credential file made outside
  the directories is read under the name it was opened by, as on `AttachmentSource`, and a test
  pins it. Why: anyone who can make the link can copy the file; refusing every multiply-linked
  file would refuse legitimate inputs for no real protection. For the same reason the target of a
  link out of a credential directory, named directly or through a further link, is read.
