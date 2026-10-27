import AppleKit
import Foundation

struct MessagesAttachmentRetrievalRequest: Codable, Sendable {
    enum Failure: Error { case invalidPayload }
    let chatRowid: Int64
    let chatGUID: String
    let messageRowid: Int64
    let messageGUID: String
    let selectedAttachmentGUID: String
    let nativePartIndex: Int
    let nativePartGUID: String?
    let participantHandles: [String]
    let isFromMe: Bool
    let membershipCount: Int
    let membershipSHA256: String
    let sandboxPrefix: String?

    enum CodingKeys: String, CodingKey {
        case chatRowid, chatGUID, messageRowid, messageGUID, nativePartIndex, nativePartGUID
        case participantHandles, isFromMe, membershipCount, membershipSHA256, selectedAttachmentGUID, sandboxPrefix
    }

    init(chatRowid: Int64, chatGUID: String, messageRowid: Int64, messageGUID: String,
         nativePartIndex: Int, nativePartGUID: String?, selectedAttachmentGUID: String, participantHandles: [String], isFromMe: Bool,
         membershipCount: Int, membershipSHA256: String, sandboxPrefix: String? = nil) throws {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 512 &&
                !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
        guard chatRowid > 0, messageRowid > 0, safe(chatGUID), safe(messageGUID), safe(selectedAttachmentGUID),
              !participantHandles.isEmpty, participantHandles.count <= 32,
              participantHandles.allSatisfy(safe),
              Set(participantHandles.map { Data($0.utf8) }).count == participantHandles.count,
              (1...MessagesAttachmentRetrievalState.maximumAttachments).contains(membershipCount),
              membershipSHA256.utf8.count == 64,
              membershipSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw Failure.invalidPayload }
        guard sandboxPrefix.map(safe) ?? true else { throw Failure.invalidPayload }
        do {
            try NativeMessagesURL.validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        } catch MessagesReactionAXError.invalidPayload {
            throw Failure.invalidPayload
        }
        self.chatRowid = chatRowid
        self.chatGUID = chatGUID
        self.messageRowid = messageRowid
        self.messageGUID = messageGUID
        self.selectedAttachmentGUID = selectedAttachmentGUID
        self.nativePartIndex = nativePartIndex
        self.nativePartGUID = nativePartGUID
        self.participantHandles = participantHandles
        self.isFromMe = isFromMe
        self.membershipCount = membershipCount
        self.membershipSHA256 = membershipSHA256
        self.sandboxPrefix = sandboxPrefix
        _ = try workerPayloadData()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chatRowid: c.decode(Int64.self, forKey: .chatRowid),
            chatGUID: c.decode(String.self, forKey: .chatGUID),
            messageRowid: c.decode(Int64.self, forKey: .messageRowid),
            messageGUID: c.decode(String.self, forKey: .messageGUID),
            nativePartIndex: c.decode(Int.self, forKey: .nativePartIndex),
            nativePartGUID: c.decodeIfPresent(String.self, forKey: .nativePartGUID),
            selectedAttachmentGUID: c.decode(String.self, forKey: .selectedAttachmentGUID),
            participantHandles: c.decode([String].self, forKey: .participantHandles),
            isFromMe: c.decode(Bool.self, forKey: .isFromMe),
            membershipCount: c.decode(Int.self, forKey: .membershipCount),
            membershipSHA256: c.decode(String.self, forKey: .membershipSHA256),
            sandboxPrefix: c.decodeIfPresent(String.self, forKey: .sandboxPrefix))
    }

    func workerPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw Failure.invalidPayload }
        return data
    }

    func matches(_ membership: MessagesAttachmentMembership) -> Bool {
        membershipCount == membership.count && membershipSHA256 == membership.sha256
    }
}
