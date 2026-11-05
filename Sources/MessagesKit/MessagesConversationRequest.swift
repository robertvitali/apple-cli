import AppleKit
import CryptoKit
import Foundation

/// Only this bounded payload crosses the worker pipe. The complete baseline and
/// raw contact provenance stay in memory; the journal receives digests only.
struct MessagesConversationRequest: Codable, Sendable {
    enum Failure: Error { case invalidPayload }
    let recipients: [String]
    let initialText: String
    let service: String
    let baselineSHA256: String
    let sandboxPrefix: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recipients, initialText, service, baselineSHA256, sandboxPrefix
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(plan: MessagesConversationPlan.Plan, baseline: MessagesConversationBaseline.Snapshot) throws {
        let recipients = plan.recipients.map(\.candidate.address.canonical).sorted()
        guard recipients == baseline.requestedRecipients.map(\.canonical) else { throw Failure.invalidPayload }
        try self.init(recipients: recipients, initialText: plan.initialText, service: plan.service,
            baselineSHA256: Self.fingerprint(baseline),
            sandboxPrefix: plan.gate.sandboxActive ? plan.gate.sandboxPrefix : nil)
    }

    private init(recipients: [String], initialText: String, service: String,
                 baselineSHA256: String, sandboxPrefix: String?) throws {
        guard (1...32).contains(recipients.count), service == "iMessage",
              initialText.utf8.prefix(2049).count <= 2048, !initialText.utf8.contains(0),
              !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              baselineSHA256.utf8.count == 64,
              baselineSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidPayload
        }
        for raw in recipients {
            guard let address = try? MessagesConversationAddress.parse(raw),
                  address.canonical.utf8.elementsEqual(raw.utf8) else { throw Failure.invalidPayload }
        }
        guard Set(recipients).count == recipients.count, recipients == recipients.sorted() else {
            throw Failure.invalidPayload
        }
        if let sandboxPrefix {
            guard recipients.count == 1, !sandboxPrefix.isEmpty, sandboxPrefix.utf8.prefix(513).count <= 512,
                  !sandboxPrefix.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  initialText.utf8.starts(with: sandboxPrefix.utf8) else { throw Failure.invalidPayload }
        }
        self.recipients = recipients
        self.initialText = initialText
        self.service = service
        self.baselineSHA256 = baselineSHA256
        self.sandboxPrefix = sandboxPrefix
        _ = try workerPayloadData()
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw Failure.invalidPayload
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recipients: c.decode([String].self, forKey: .recipients),
            initialText: c.decode(String.self, forKey: .initialText), service: c.decode(String.self, forKey: .service),
            baselineSHA256: c.decode(String.self, forKey: .baselineSHA256),
            sandboxPrefix: c.decodeIfPresent(String.self, forKey: .sandboxPrefix))
    }

    func workerPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw Failure.invalidPayload }
        return data
    }

    /// Internal protocol accepts exactly the canonical bytes emitted by the
    /// parent. This also refuses duplicate keys or alternate JSON spellings.
    static func decodeWorkerPayload(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw Failure.invalidPayload }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard try request.workerPayloadData() == data else { throw Failure.invalidPayload }
        return request
    }

    func matches(_ snapshot: MessagesConversationBaseline.Snapshot) throws -> Bool {
        recipients == snapshot.requestedRecipients.map(\.canonical) && baselineSHA256 == Self.fingerprint(snapshot)
    }

    private static func fingerprint(_ snapshot: MessagesConversationBaseline.Snapshot) -> String {
        var hash = SHA256()
        hash.update(data: Data("apple-messages-conversation-baseline-v1\0".utf8))
        func integer(_ value: Int64) {
            var bigEndian = UInt64(bitPattern: value).bigEndian
            withUnsafeBytes(of: &bigEndian) { hash.update(data: Data($0)) }
        }
        func string(_ value: String) {
            integer(Int64(value.utf8.count))
            hash.update(data: Data(value.utf8))
        }
        integer(snapshot.maximumChatRowid)
        integer(snapshot.maximumMessageRowid)
        integer(Int64(snapshot.requestedRecipients.count))
        for recipient in snapshot.requestedRecipients { string(recipient.canonical) }
        integer(Int64(snapshot.matchingConversations.count))
        for conversation in snapshot.matchingConversations {
            integer(conversation.rowid)
            integer(conversation.style)
            string(conversation.guid)
            integer(Int64(conversation.recipients.count))
            for recipient in conversation.recipients { string(recipient.canonical) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
