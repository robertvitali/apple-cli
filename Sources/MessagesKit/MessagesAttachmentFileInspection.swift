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
        let first = try openConfined(components, checkpoint: checkpoint)
        let descriptor: Int32
        switch first {
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .opened(let value): descriptor = value
        }
        defer { close(descriptor) }
        guard let before = regularFileStat(descriptor) else { return .unavailable }
        try checkpoint()
        // Reopen through the same no-symlink walk to detect observed path
        // replacement. Neither pass promises continuous namespace stability.
        guard case .opened(let current) = try openConfined(components, checkpoint: checkpoint) else { return .unavailable }
        defer { close(current) }
        guard let after = regularFileStat(current),
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
        guard Self.safeText(raw), Self.safeText(home), home.hasPrefix("/") else { return nil }
        let root = home + "/Library/Messages/Attachments"
        let prefixes = ["~/Library/Messages/Attachments/", root + "/",
                        displayedHome + "/Library/Messages/Attachments/"]
        guard let prefix = prefixes.first(where: { raw.utf8.starts(with: $0.utf8) }) else { return nil }
        let suffix = String(decoding: raw.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        let full = root + "/" + suffix
        guard full.utf8.count <= 4_096 else { return nil }
        let components = full.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 128,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private enum OpenResult { case opened(Int32), missing, unavailable }

    private func openConfined(_ components: [String], checkpoint: () throws -> Void) throws -> OpenResult {
        try checkpoint()
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .unavailable }
        var keep = false
        defer { if !keep { close(directory) } }
        let rootComponentCount = home.dropFirst().split(separator: "/").count + 3
        for (index, component) in components.enumerated() {
            try checkpoint()
            let leaf = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (leaf ? 0 : O_DIRECTORY)
            let next = openat(directory, component, flags)
            guard next >= 0 else { return errno == ENOENT ? .missing : .unavailable }
            close(directory)
            directory = next
            if index == rootComponentCount - 1 {
                var rootInfo = stat()
                guard fstat(directory, &rootInfo) == 0, rootInfo.st_uid == getuid() else { return .unavailable }
            }
        }
        try checkpoint()
        keep = true
        return .opened(directory)
    }

    private func regularFileStat(_ descriptor: Int32) -> stat? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0 else { return nil }
        return info
    }

    private static func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 &&
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func canonicalSystemAlias(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private" + path : path
    }
}
