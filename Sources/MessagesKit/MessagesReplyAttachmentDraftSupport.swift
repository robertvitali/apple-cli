import AppKit
import Carbon
import CryptoKit
import Foundation
import AppleKit

struct MessagesClipboardRepresentation: Equatable, Sendable {
    let type: String
    let data: Data
}

struct MessagesClipboardSnapshot: Equatable, Sendable {
    let changeCount: Int
    let items: [[MessagesClipboardRepresentation]]

    var isEmptyAtCount: Bool { items.isEmpty }

    func isExactFileURLPayload(_ url: URL) -> Bool {
        guard items.count == 1, items[0].count == 1, items[0][0].type == NSPasteboard.PasteboardType.fileURL.rawValue else { return false }
        return items[0][0].data == Data(url.absoluteString.utf8)
    }
}

protocol MessagesClipboardBackend: AnyObject {
    var changeCount: Int { get }
    func readItems(deadline: WorkerDeadline) throws -> [[MessagesClipboardRepresentation]]
    func clearContents(deadline: WorkerDeadline) throws -> Int
    func publishFileURLData(_ data: Data, deadline: WorkerDeadline) throws -> Bool
    func writeItems(_ items: [[MessagesClipboardRepresentation]], deadline: WorkerDeadline) throws -> Bool
}

protocol MessagesClipboarding: AnyObject {
    var backend: any MessagesClipboardBackend { get }
}

extension MessagesClipboarding {
    func snapshot(deadline: WorkerDeadline) throws -> MessagesClipboardSnapshot {
        try checkMessagesAXDeadline(deadline)
        let firstCount = backend.changeCount
        let firstItems = try backend.readItems(deadline: deadline)
        try checkMessagesAXDeadline(deadline)
        let secondItems = try backend.readItems(deadline: deadline)
        try checkMessagesAXDeadline(deadline)
        let secondCount = backend.changeCount
        guard firstCount == secondCount, firstItems == secondItems else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
        return MessagesClipboardSnapshot(changeCount: secondCount, items: secondItems)
    }

    func clearContentsReturningCount(deadline: WorkerDeadline) throws -> Int {
        try checkMessagesAXDeadline(deadline)
        return try backend.clearContents(deadline: deadline)
    }

    func verifyEmpty(ownerCount: Int, deadline: WorkerDeadline) throws {
        let empty = try snapshot(deadline: deadline)
        guard empty.changeCount == ownerCount, empty.isEmptyAtCount else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
    }

    func clearAndVerifyEmpty(deadline: WorkerDeadline) throws -> Int {
        let count = try clearContentsReturningCount(deadline: deadline)
        try verifyEmpty(ownerCount: count, deadline: deadline)
        return count
    }

    func publishAndVerifyFileURL(_ url: URL, ownerCount: Int, deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        guard try backend.publishFileURLData(Data(url.absoluteString.utf8), deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
        let published = try snapshot(deadline: deadline)
        guard published.changeCount == ownerCount, published.isExactFileURLPayload(url) else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
    }

    func verifyOwnedPayload(ownerCount: Int, url: URL, deadline: WorkerDeadline) throws {
        let current = try snapshot(deadline: deadline)
        guard current.changeCount == ownerCount, current.isExactFileURLPayload(url) else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
    }

    func restore(_ snapshot: MessagesClipboardSnapshot, deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        let restoreCount = try backend.clearContents(deadline: deadline)
        let empty = try self.snapshot(deadline: deadline)
        guard empty.changeCount == restoreCount, empty.isEmptyAtCount else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
        if !snapshot.items.isEmpty {
            guard try backend.writeItems(snapshot.items, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
            }
        }
        let restored = try self.snapshot(deadline: deadline)
        guard restored.changeCount == restoreCount, restored.items == snapshot.items else {
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
    }
}

final class LiveMessagesClipboardBackend: MessagesClipboardBackend {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func readItems(deadline: WorkerDeadline) throws -> [[MessagesClipboardRepresentation]] {
        try checkMessagesAXDeadline(deadline)
        let pasteboardItems = pasteboard.pasteboardItems
        return try Self.readRepresentations(itemTypes: pasteboardItems?.map(\.types),
                                            declaredTypes: pasteboardItems == nil ? pasteboard.types : nil,
                                            deadline: deadline) { index, type in
            pasteboardItems?[index].data(forType: type)
        }
    }

    // No pasteboard writes; the same provider/bounds parser is exercised with
    // synthetic data in logic tests. Nil items need independent empty evidence.
    static func readRepresentations(itemTypes: [[NSPasteboard.PasteboardType]]?,
                                    declaredTypes: [NSPasteboard.PasteboardType]?,
                                    deadline: WorkerDeadline,
                                    data: (Int, NSPasteboard.PasteboardType) throws -> Data?) throws -> [[MessagesClipboardRepresentation]] {
        try checkMessagesAXDeadline(deadline)
        guard let itemTypes else {
            guard declaredTypes?.isEmpty == true else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
            return []
        }
        guard itemTypes.count <= 8 else { throw MessagesReplyComposerAXError.invalidPayload }
        var totalTypes = 0
        var totalBytes = 0
        var items: [[MessagesClipboardRepresentation]] = []
        for (index, types) in itemTypes.enumerated() {
            try checkMessagesAXDeadline(deadline)
            var representations: [MessagesClipboardRepresentation] = []
            for type in types {
                totalTypes += 1
                guard totalTypes <= 32 else { throw MessagesReplyComposerAXError.invalidPayload }
                guard let data = try data(index, type) else { throw MessagesReplyComposerAXError.invalidPayload }
                try checkMessagesAXDeadline(deadline)
                guard data.count <= 65_536 else { throw MessagesReplyComposerAXError.invalidPayload }
                totalBytes += data.count
                guard totalBytes <= 262_144 else { throw MessagesReplyComposerAXError.invalidPayload }
                representations.append(MessagesClipboardRepresentation(type: type.rawValue, data: data))
            }
            items.append(representations)
        }
        return items
    }

    func clearContents(deadline: WorkerDeadline) throws -> Int {
        try checkMessagesAXDeadline(deadline)
        return pasteboard.clearContents()
    }

    func publishFileURLData(_ data: Data, deadline: WorkerDeadline) throws -> Bool {
        try checkMessagesAXDeadline(deadline)
        return pasteboard.setData(data, forType: .fileURL)
    }

    func writeItems(_ items: [[MessagesClipboardRepresentation]], deadline: WorkerDeadline) throws -> Bool {
        try checkMessagesAXDeadline(deadline)
        var restoredItems: [NSPasteboardItem] = []
        for item in items {
            let pasteboardItem = NSPasteboardItem()
            for representation in item {
                guard pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) else {
                    throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
                }
            }
            restoredItems.append(pasteboardItem)
        }
        return pasteboard.writeObjects(restoredItems)
    }
}

final class LiveMessagesClipboard: MessagesClipboarding {
    let backend: any MessagesClipboardBackend

    init(backend: any MessagesClipboardBackend = LiveMessagesClipboardBackend()) {
        self.backend = backend
    }
}

struct MessagesPasteKeyEvidence: Equatable, Sendable {
    let inputSourceID: String
    let layoutSHA256: String
    let keyboardType: UInt32
    let keyCode: UInt16
}

protocol MessagesPasteKeyResolving: Sendable {
    func resolvePasteKey(deadline: WorkerDeadline) throws -> MessagesPasteKeyEvidence
}

struct LiveMessagesPasteKeyResolver: MessagesPasteKeyResolving {
    func resolvePasteKey(deadline: WorkerDeadline) throws -> MessagesPasteKeyEvidence {
        try checkMessagesAXDeadline(deadline)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable
        }
        let sourceIDString = Unmanaged<CFString>.fromOpaque(UnsafeRawPointer(sourceID)).takeUnretainedValue() as String
        guard !sourceIDString.isEmpty, sourceIDString.utf8.count <= 512,
              let layoutProperty = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(UnsafeRawPointer(layoutProperty)).takeUnretainedValue()
        let data = layoutData as Data
        let layoutHash = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let keyboardType = UInt32(LMGetKbdType())
        var matches: [UInt16] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0..<128 {
                var chars = [UniChar](repeating: 0, count: 2)
                var length = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xff), keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 2, &length, &chars)
                if status == noErr, length == 1, deadKeyState == 0, chars[0] == UInt16(Character("v").utf16.first!) {
                    matches.append(UInt16(code))
                }
            }
        }
        guard matches.count == 1 else { throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable }
        return MessagesPasteKeyEvidence(inputSourceID: sourceIDString, layoutSHA256: layoutHash, keyboardType: keyboardType, keyCode: matches[0])
    }
}

private let replyAttachmentDraftCopyName = "apple-cli-test-attachment.bin"

private struct ValidatedReplyAttachmentDraftCopy {
    let url: URL
    let directoryFD: Int32

    func closeDirectory() { close(directoryFD) }
}

func replyAttachmentDraftCopyBasename() -> String { replyAttachmentDraftCopyName }

func validateReplyAttachmentDraftCopy(_ evidence: MessagesReplyAttachmentDraftEvidence, deadline: WorkerDeadline) throws -> URL {
    let validated = try openValidatedReplyAttachmentDraftCopy(evidence, deadline: deadline)
    defer { validated.closeDirectory() }
    return validated.url
}

private func openValidatedReplyAttachmentDraftCopy(_ evidence: MessagesReplyAttachmentDraftEvidence, deadline: WorkerDeadline) throws -> ValidatedReplyAttachmentDraftCopy {
    try checkMessagesAXDeadline(deadline)
    let directoryURL = URL(fileURLWithPath: evidence.directoryPath, isDirectory: true).standardizedFileURL
    let copyURL = URL(fileURLWithPath: evidence.copyPath).standardizedFileURL
    guard copyURL.deletingLastPathComponent().path == directoryURL.path,
          copyURL.lastPathComponent == replyAttachmentDraftCopyName else {
        throw MessagesReplyComposerAXError.invalidPayload
    }
    let dirFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dirFD >= 0 else { throw MessagesReplyComposerAXError.invalidPayload }
    do {
        var dirStat = stat()
        guard fstat(dirFD, &dirStat) == 0,
              directoryStatMatches(dirStat, evidence.directoryStat) else {
            throw MessagesReplyComposerAXError.invalidPayload
        }
        let copyFD = openat(dirFD, replyAttachmentDraftCopyName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard copyFD >= 0 else { throw MessagesReplyComposerAXError.invalidPayload }
        defer { close(copyFD) }
        var before = stat()
        guard fstat(copyFD, &before) == 0,
              copyStatMatches(before, evidence.copyStat),
              before.st_size == evidence.copySize else {
            throw MessagesReplyComposerAXError.invalidPayload
        }
        let data = try FileHandle(fileDescriptor: copyFD, closeOnDealloc: false).read(upToCount: 65_537) ?? Data()
        try checkMessagesAXDeadline(deadline)
        var after = stat()
        guard fstat(copyFD, &after) == 0,
              fileStatMatches(after, evidence.copyStat),
              data.count == evidence.copySize else {
            throw MessagesReplyComposerAXError.invalidPayload
        }
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == evidence.copySHA256 else { throw MessagesReplyComposerAXError.invalidPayload }
        return ValidatedReplyAttachmentDraftCopy(url: copyURL, directoryFD: dirFD)
    } catch {
        close(dirFD)
        throw error
    }
}

@discardableResult
func removeReplyAttachmentDraftCopyIfOwned(_ evidence: MessagesReplyAttachmentDraftEvidence, deadline: WorkerDeadline) throws -> Bool {
    let validated = try openValidatedReplyAttachmentDraftCopy(evidence, deadline: deadline)
    defer { validated.closeDirectory() }
    guard unlinkat(validated.directoryFD, replyAttachmentDraftCopyName, 0) == 0 else {
        throw MessagesReplyComposerAXError.invalidPayload
    }
    guard directoryIdentityStillMatches(evidence.directoryPath, evidence.directoryStat) else {
        throw MessagesReplyComposerAXError.invalidPayload
    }
    guard rmdir(evidence.directoryPath) == 0 else {
        throw MessagesReplyComposerAXError.invalidPayload
    }
    return true
}

private func directoryIdentityStillMatches(_ path: String, _ evidence: MessagesReplyAttachmentFileStat) -> Bool {
    var current = stat()
    return lstat(path, &current) == 0 &&
    (current.st_mode & S_IFMT) == S_IFDIR &&
    UInt64(current.st_dev) == evidence.device &&
    UInt64(current.st_ino) == evidence.inode &&
    UInt16(current.st_mode & 0o777) == evidence.mode &&
    UInt32(current.st_uid) == evidence.uid
}

private func fileStatMatches(_ stat: stat, _ evidence: MessagesReplyAttachmentFileStat) -> Bool {
    UInt64(stat.st_dev) == evidence.device &&
    UInt64(stat.st_ino) == evidence.inode &&
    Int64(stat.st_size) == evidence.size &&
    UInt16(stat.st_mode & 0o777) == evidence.mode &&
    UInt32(stat.st_uid) == evidence.uid &&
    Int64(stat.st_mtimespec.tv_sec) == evidence.modifiedSeconds &&
    Int64(stat.st_mtimespec.tv_nsec) == evidence.modifiedNanoseconds &&
    Int64(stat.st_ctimespec.tv_sec) == evidence.changedSeconds &&
    Int64(stat.st_ctimespec.tv_nsec) == evidence.changedNanoseconds
}

private func copyStatMatches(_ stat: stat, _ evidence: MessagesReplyAttachmentFileStat) -> Bool {
    (stat.st_mode & S_IFMT) == S_IFREG && fileStatMatches(stat, evidence) && evidence.mode == 0o600 && evidence.uid == UInt32(getuid())
}

private func directoryStatMatches(_ stat: stat, _ evidence: MessagesReplyAttachmentFileStat) -> Bool {
    (stat.st_mode & S_IFMT) == S_IFDIR && fileStatMatches(stat, evidence) && evidence.mode == 0o700 && evidence.uid == UInt32(getuid())
}
