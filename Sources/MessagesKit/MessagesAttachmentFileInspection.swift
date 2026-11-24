import Darwin
import Foundation

/// Instant file-access evidence, not a promise that a path stays readable.
/// Run inside the supervised worker: checkpoints are cooperative and cannot
/// interrupt an individual filesystem syscall.
struct MessagesAttachmentFileInspection {
    private let home: String
    private let displayedHome: String

    init(homeDirectory: String) {
        displayedHome = homeDirectory
        home = Self.canonicalSystemAlias(homeDirectory)
    }

    func inspect(filename: String?, checkpoint: () throws -> Void = {}) throws -> MessagesAttachmentRetrievalState.FileObservation {
        try checkpoint()
        guard let filename, let components = confinedComponents(filename) else { return .unavailable }
        return try MessagesAttachmentFileAccess.withoutMaterialization(unavailable: .unavailable) {
            try inspectLocal(components, checkpoint: checkpoint)
        }
    }

    private func inspectLocal(_ components: [String], checkpoint: () throws -> Void) throws -> MessagesAttachmentRetrievalState.FileObservation {
        let first = try openConfined(components, checkpoint: checkpoint)
        let descriptor: Int32
        let before: stat
        switch first {
        case .missing: return .missing
        case .dataless: return .dataless
        case .unavailable: return .unavailable
        case let .opened(fd, info): (descriptor, before) = (fd, info)
        }
        defer { close(descriptor) }
        if before.st_flags & UInt32(SF_DATALESS) != 0 { return .dataless }
        try checkpoint()
        // Reopen through the same no-symlink walk to detect observed path
        // replacement. Neither pass promises continuous namespace stability.
        guard case let .opened(current, after) = try openConfined(components, checkpoint: checkpoint) else { return .unavailable }
        defer { close(current) }
        guard after.st_flags & UInt32(SF_DATALESS) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return .unavailable }
        try checkpoint()
        return .readableRegularFile
    }

    private func confinedComponents(_ raw: String) -> [String]? {
        guard Self.safeText(raw), Self.safeText(home), home.utf8.first == 0x2f else { return nil }
        let root = home + "/Library/Messages/Attachments"
        let prefixes = ["~/Library/Messages/Attachments/", root + "/",
                        displayedHome + "/Library/Messages/Attachments/"]
        guard let prefix = prefixes.first(where: { raw.utf8.starts(with: $0.utf8) }) else { return nil }
        let suffix = String(decoding: raw.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        let full = root + "/" + suffix
        guard full.utf8.count <= 4_096 else { return nil }
        // POSIX treats every slash as a separator, even before a combining mark.
        let components = full.unicodeScalars.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 128,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private enum OpenResult { case opened(Int32, stat), dataless, missing, unavailable }

    private func openConfined(_ components: [String], checkpoint: () throws -> Void) throws -> OpenResult {
        try checkpoint()
        guard let leaf = components.last else { return .unavailable }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .unavailable }
        defer { close(directory) }
        let rootComponentCount = home.unicodeScalars.dropFirst().split(separator: "/").count + 3
        for (index, component) in components.dropLast().enumerated() {
            try checkpoint()
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { return errno == ENOENT ? .missing : .unavailable }
            close(directory)
            directory = next
            if index == rootComponentCount - 1 {
                var rootInfo = stat()
                guard fstat(directory, &rootInfo) == 0, rootInfo.st_uid == getuid() else { return .unavailable }
            }
        }
        try checkpoint()
        // A nonblocking read-open still connects a FIFO peer. Check the named
        // leaf first, then compare the descriptor since the name can change.
        var named = stat()
        guard fstatat(directory, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .unavailable
        }
        guard Self.isOwnedRegularFile(named) else { return .unavailable }
        let fd = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else {
            // The thread policy can refuse a placeholder read-open with EDEADLK.
            guard errno == EDEADLK else { return .unavailable }
            var current = stat()
            if fstatat(directory, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
               Self.isOwnedRegularFile(current), named.st_dev == current.st_dev, named.st_ino == current.st_ino,
               current.st_flags & UInt32(SF_DATALESS) != 0 {
                return .dataless
            }
            return .unavailable
        }
        var keep = false
        defer { if !keep { close(fd) } }
        try checkpoint()
        var opened = stat()
        guard fstat(fd, &opened) == 0, Self.isOwnedRegularFile(opened),
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { return .unavailable }
        keep = true
        return .opened(fd, opened)
    }

    private static func isOwnedRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_size >= 0
    }

    private static func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 &&
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func canonicalSystemAlias(_ path: String) -> String {
        path.utf8.starts(with: "/var/".utf8) ? "/private" + path : path
    }
}
