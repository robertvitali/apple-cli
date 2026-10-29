import AppleKit
import CryptoKit
import Foundation

/// The replacement travels only in the bounded worker payload. Journal evidence
/// retains its digest and length; the baseline binds every captured observation.
struct MessagesEditRequest: Codable, Sendable {
    enum Failure: Error { case invalidPayload }
    let chatRowid: Int64
    let chatGUID: String
    let messageRowid: Int64
    let messageGUID: String
    let nativePartIndex: Int
    let baselineSHA256: String
    let replacement: String
    let sandboxPrefix: String?

    enum CodingKeys: String, CodingKey {
        case chatRowid, chatGUID, messageRowid, messageGUID, nativePartIndex
        case baselineSHA256, replacement, sandboxPrefix
    }

    init(chatRowid: Int64, chatGUID: String, messageRowid: Int64, messageGUID: String,
         nativePartIndex: Int, baselineSHA256: String, replacement: String, sandboxPrefix: String?) throws {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 512 &&
                !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
        guard chatRowid > 0, messageRowid > 0, safe(chatGUID), safe(messageGUID),
              (0...Int(Int32.max)).contains(nativePartIndex),
              baselineSHA256.utf8.count == 64,
              baselineSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !replacement.isEmpty, replacement.utf8.count <= 4096,
              !replacement.utf8.contains(0), sandboxPrefix.map(safe) ?? true else { throw Failure.invalidPayload }
        try NativeMessagesURL.validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex, nativePartGUID: nil)
        self.chatRowid = chatRowid
        self.chatGUID = chatGUID
        self.messageRowid = messageRowid
        self.messageGUID = messageGUID
        self.nativePartIndex = nativePartIndex
        self.baselineSHA256 = baselineSHA256
        self.replacement = replacement
        self.sandboxPrefix = sandboxPrefix
        _ = try workerPayloadData()
    }

    init(snapshot: MessagesEditTargetResolver.Snapshot, replacement: String, sandboxPrefix: String?) throws {
        try self.init(chatRowid: snapshot.chatRowid, chatGUID: snapshot.chatGUID,
            messageRowid: snapshot.messageRowid, messageGUID: snapshot.messageGUID, nativePartIndex: snapshot.partIndex,
            baselineSHA256: Self.fingerprint(snapshot), replacement: replacement, sandboxPrefix: sandboxPrefix)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chatRowid: c.decode(Int64.self, forKey: .chatRowid), chatGUID: c.decode(String.self, forKey: .chatGUID),
            messageRowid: c.decode(Int64.self, forKey: .messageRowid), messageGUID: c.decode(String.self, forKey: .messageGUID),
            nativePartIndex: c.decode(Int.self, forKey: .nativePartIndex), baselineSHA256: c.decode(String.self, forKey: .baselineSHA256),
            replacement: c.decode(String.self, forKey: .replacement), sandboxPrefix: c.decodeIfPresent(String.self, forKey: .sandboxPrefix))
    }

    func workerPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw Failure.invalidPayload }
        return data
    }

    func matches(_ snapshot: MessagesEditTargetResolver.Snapshot) throws -> Bool {
        guard chatRowid == snapshot.chatRowid, chatGUID.utf8.elementsEqual(snapshot.chatGUID.utf8),
              messageRowid == snapshot.messageRowid, messageGUID.utf8.elementsEqual(snapshot.messageGUID.utf8),
              nativePartIndex == snapshot.partIndex else { return false }
        return baselineSHA256 == (try Self.fingerprint(snapshot))
    }

    private static func fingerprint(_ snapshot: MessagesEditTargetResolver.Snapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        digest.update(data: Data("apple-messages-edit-baseline-v1\0".utf8))
        digest.update(data: try encoder.encode(snapshot))
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func preservesSandbox(_ snapshot: MessagesEditTargetResolver.Snapshot) -> Bool {
        guard let prefix = sandboxPrefix else { return true }
        guard !prefix.isEmpty, snapshot.chatStyle == 45, snapshot.participantHandles.count == 1,
              snapshot.fullText.utf8.starts(with: prefix.utf8),
              let part = snapshot.nativeParts.first(where: { $0.index == snapshot.partIndex }),
              part.attachmentGUID == nil, part.utf16Ranges.count == 1,
              let interval = part.utf16Ranges.first, interval.location >= 0, interval.length >= 0,
              interval.location <= snapshot.fullText.utf16.count,
              interval.length <= snapshot.fullText.utf16.count - interval.location,
              let range = Range(NSRange(location: interval.location, length: interval.length), in: snapshot.fullText),
              snapshot.fullText[range].utf8.elementsEqual(snapshot.partText.utf8) else { return false }
        let result = String(snapshot.fullText[..<range.lowerBound]) + replacement
            + String(snapshot.fullText[range.upperBound...])
        return result.utf8.starts(with: prefix.utf8)
    }
}
