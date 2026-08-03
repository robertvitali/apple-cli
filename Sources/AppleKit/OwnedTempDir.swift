import Foundation

/// A private, this-user-only directory under the temp dir, for files that hold the operator's data.
///
/// Two domains needed the same thing and the second one must not reinvent it: `SQLiteReader` puts
/// snapshots of the Mail/Messages/Notes stores in one, and MailKit puts generated `.eml` files —
/// complete RFC-822 messages — in another. Both were previously loose in the shared temp root at
/// mode 0644.
///
/// The validation is the point. `createDirectory(withIntermediateDirectories:attributes:)` applies
/// its mode ONLY when it actually creates, so on every run after the first the directory keeps
/// whatever mode and owner it already had — and it may be a symlink pointing somewhere else
/// entirely. Since these directories hold copies of the operator's mail, that is re-asserted on
/// every call rather than trusted.
public enum OwnedTempDir {

    /// Where the directory WOULD be, touching nothing.
    ///
    /// Separate from `make` because a `--dry-run` must be able to report a planned destination
    /// without creating a directory or reaping anything — a preview that mutates the filesystem, or
    /// that can newly fail, is not a preview. This guarantees nothing about what is at the path.
    public static func path(_ name: String, base: URL? = nil) -> URL {
        (base ?? FileManager.default.temporaryDirectory).appendingPathComponent(name, isDirectory: true)
    }

    /// `<base>/<name>`, guaranteed to be a real directory owned by this uid at mode 0700.
    ///
    /// - Parameter base: defaults to the process temp directory. Tests pass their own so they
    ///   exercise creation in a directory they own — asserting the mode of the real shared one
    ///   passes when the code is wrong (create-time only) and fails when it is right (a stray
    ///   `chmod` by anything else).
    public static func make(_ name: String, base: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = path(name, base: base)

        // Inspect BEFORE creating. `createDirectory` fails with a Cocoa error naming neither this
        // tool nor the remedy when a plain file or a symlink already sits at the path, and that
        // error would then propagate out of every affected command until a human went looking.
        var st = stat()
        if lstat(dir.path, &st) == 0 {
            try validate(dir, st)
            return dir
        }

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw AppleError.upstream("could not create \(dir.path): \(error.localizedDescription)")
        }
        // Validate the create path too. `withIntermediateDirectories: true` succeeds SILENTLY when
        // the directory already exists and does NOT apply `attributes` in that case — so if it
        // appeared between the lstat above and this call, we would otherwise return a directory of
        // unverified mode and unverified owner from the one function whose job is verifying it.
        var after = stat()
        guard lstat(dir.path, &after) == 0 else {
            throw AppleError.upstream("\(dir.path) vanished immediately after being created")
        }
        try validate(dir, after)
        return dir
    }

    /// The guarantee, enforced identically on the already-exists and the just-created paths.
    ///
    /// `createDirectory(attributes:)` applies its mode ONLY when it actually creates, so on every
    /// run after the first the directory keeps whatever mode and owner it already had — and it may
    /// be a symlink pointing somewhere else entirely. `lstat`, never `stat`.
    private static func validate(_ dir: URL, _ st: stat) throws {
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw AppleError.upstream("\(dir.path) exists but is not a directory; "
                                      + "remove it so apple can create its directory there")
        }
        guard st.st_uid == getuid() else {
            throw AppleError.upstream("\(dir.path) is owned by uid \(st.st_uid), not \(getuid()); "
                                      + "remove it or change its owner")
        }
        guard (st.st_mode & 0o777) != 0o700 else { return }
        // Verify, do not hope: a silently-failed chmod would hand back a world-readable path while
        // the doc comment above promises 0700.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var after = stat()
        guard lstat(dir.path, &after) == 0, (after.st_mode & 0o777) == 0o700 else {
            throw AppleError.upstream("\(dir.path) could not be secured to 0700 "
                                      + "(it is \(String(st.st_mode & 0o777, radix: 8))); "
                                      + "fix its permissions or remove it")
        }
    }

    /// 0600 on a file this tool just wrote. Defense in depth — the enclosing directory is already
    /// 0700 — so nothing about correctness rides on it succeeding.
    public static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Delete files directly inside `dir` older than `olderThan`, returning how many went.
    ///
    /// Age is a weak liveness signal and is used here ONLY because nothing better exists: these
    /// files are handed to Mail.app via `open`, so the "owner" is Mail, which we cannot lock or
    /// interrogate. (Where the owner IS one of our own processes — the SQLite snapshots — an
    /// `flock` answers the question exactly and age is not used at all; see `SQLiteReader`.) The
    /// window is therefore set far longer than the real hand-off, which completes in seconds.
    ///
    /// Regular files only: `removeItem` recurses, so a directory sharing the suffix would otherwise
    /// be deleted wholesale. Symlinks are skipped for the same reason — `lstat`, never `stat`.
    @discardableResult
    /// - Parameter prefix: matched on the NAME, not the extension. `write(atomically:)` stages
    ///   through an intermediate whose name is not `<uuid>.eml`, so a suffix match would leave a
    ///   partially-written message body behind forever if a write were interrupted — the exact
    ///   class of leak this whole change exists to close.
    public static func reapFiles(in dir: URL, prefix: String, olderThan: TimeInterval,
                                 now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(mtime) > olderThan else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
