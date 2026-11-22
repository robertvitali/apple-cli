import Darwin
import Foundation

/// The registry is private state. Its location comes from the host, never from a cursor.
struct MessageEventWatchRegistry {
    enum Failure: Error { case invalidLocation }

    let parent: String
    let name: String
    var path: String { parent + "/" + name }

    init(parent: String, name: String) throws {
        guard Self.absolute(parent), !name.isEmpty, name.utf8.count <= 255,
              name != ".", name != "..", !name.utf8.contains(47), !name.utf8.contains(0) else {
            throw Failure.invalidLocation
        }
        self.parent = parent
        self.name = name
    }

    static func currentUser() throws -> Self {
        // Foundation's current-user home honors process environment overrides.
        // Resolve the real account before opening or retiring private state.
        let uid = getuid()
        var size = min(max(sysconf(_SC_GETPW_R_SIZE_MAX), 16_384), 1 << 20)
        while true {
            var buffer = [CChar](repeating: 0, count: size)
            let home: String? = try buffer.withUnsafeMutableBufferPointer { bytes in
                var account = passwd()
                var result: UnsafeMutablePointer<passwd>?
                let code = getpwuid_r(uid, &account, bytes.baseAddress!, bytes.count, &result)
                if code == ERANGE { return nil }
                guard code == 0, result != nil, account.pw_uid == uid,
                      let directory = account.pw_dir, let path = String(validatingCString: directory) else {
                    throw Failure.invalidLocation
                }
                return path
            }
            if let home { return try Self(parent: home, name: ".apple-cli-messages-events") }
            guard size < 1 << 20 else { throw Failure.invalidLocation }
            size *= 2
        }
    }

    func journal(_ stream: MessageEventStreamID) -> String {
        path + "/" + stream.rawValue + "/state.sqlite"
    }

    static func absolute(_ path: String) -> Bool {
        let components = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
        return components.count > 1 && components.first?.isEmpty == true &&
            !path.utf8.contains(0) && components.dropFirst().allSatisfy {
                !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8)
            }
    }
}

/// A caller supplies the exact read-only source and the separately owned journal namespace.
struct MessageEventWatchStorage {
    let source: String
    let registry: MessageEventWatchRegistry
    private let validateSource: (String) throws -> Void

    init(source: String, registry: MessageEventWatchRegistry,
         validateSource: @escaping (String) throws -> Void = { _ in }) throws {
        guard MessageEventWatchRegistry.absolute(source) else {
            throw MessageEventWatchRegistry.Failure.invalidLocation
        }
        self.source = source
        self.registry = registry
        self.validateSource = validateSource
        try checkSource()
    }

    static func currentUser() throws -> Self {
        let registry = try MessageEventWatchRegistry.currentUser()
        return try Self(source: ChatDB.path(inHome: registry.parent), registry: registry)
    }

    func checkSource() throws {
        try validateSource(source)
        guard !source.utf8.elementsEqual(registry.path.utf8),
              !source.utf8.starts(with: (registry.path + "/").utf8) else {
            throw MessageEventWatchRegistry.Failure.invalidLocation
        }
        // A case or Unicode alias on APFS can name the same directory. Compare
        // filesystem identities along the resolved source ancestry before each read.
        var journalDirectory = stat()
        if lstat(registry.path, &journalDirectory) != 0 {
            guard errno == ENOENT else { throw MessageEventWatchRegistry.Failure.invalidLocation }
            return
        }
        guard journalDirectory.st_mode & S_IFMT == S_IFDIR else {
            throw MessageEventWatchRegistry.Failure.invalidLocation
        }
        var parent = URL(fileURLWithPath: source).deletingLastPathComponent().resolvingSymlinksInPath()
        while true {
            var ancestor = stat()
            if stat(parent.path, &ancestor) == 0 {
                guard ancestor.st_dev != journalDirectory.st_dev || ancestor.st_ino != journalDirectory.st_ino else {
                    throw MessageEventWatchRegistry.Failure.invalidLocation
                }
            } else if errno != ENOENT && errno != ENOTDIR {
                throw MessageEventWatchRegistry.Failure.invalidLocation
            }
            // The source anchor classifies a missing component as a reset.
            // Check the existing ancestors before handing the path to that reader.
            if parent.path == "/" { return }
            parent.deleteLastPathComponent()
        }
    }
}
