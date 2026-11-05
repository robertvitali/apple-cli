import AppleKit
import Foundation

/// Creation-only resolution. Preserve raw provenance until every matching address
/// is valid; a failed source or invalid match cannot manufacture a unique target.
enum MessagesConversationRecipientResolver {
    enum Failure: Error { case invalidInput, invalidMatchedAddress, limitExceeded }

    /// Private request evidence, not a durable journal or diagnostic payload.
    struct Candidate: Sendable {
        let address: MessagesConversationAddress
        let displayName: String?
        let score: Double
        let matchedOn: String?
        let rawAddresses: [String]
    }

    enum Resolution: Sendable { case resolved(Candidate), ambiguous([Candidate]), notFound }

    /// `loadContacts` must return the complete bounded capture or throw. It is called
    /// only for a name. Deadlines are cooperative, including around the callback and
    /// each bounded Fuzzy invocation; they do not preempt synchronous I/O or scoring.
    static func resolve(_ raw: String, deadline: WorkerDeadline,
                        isCancelled: @escaping () -> Bool = { false },
                        loadContacts: () throws -> [MessagesConversationRawContacts.Record]) throws -> Resolution {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || ContinuousClock.now >= end { throw WorkerProtocolError.deadlineExpired }
        }
        try checkpoint()
        guard raw.utf8.prefix(513).count <= 512,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidInput
        }
        let input = raw.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !input.isEmpty else { throw Failure.invalidInput }
        if input.contains("@") || input.hasPrefix("+")
            || input.allSatisfy({ $0.isNumber || "+-. ()".contains($0) }) {
            let address = try MessagesConversationAddress.parse(raw)
            try checkpoint()
            return .resolved(Candidate(address: address, displayName: nil,
                score: 1, matchedOn: nil, rawAddresses: [raw]))
        }
        guard !Fuzzy.cleanName(input).isEmpty else { throw Failure.invalidInput }
        let records = try loadContacts()
        try checkpoint()
        guard records.count <= 8192 else { throw Failure.limitExceeded }
        var byteCount = 0
        var matches: [MessagesConversationAddress: Candidate] = [:]
        for record in records {
            try checkpoint()
            guard record.fullName.utf8.prefix(1026).count <= 1025,
                  record.nickname.utf8.prefix(513).count <= 512,
                  record.rawAddress.utf8.prefix(513).count <= 512 else { throw Failure.limitExceeded }
            byteCount += record.fullName.utf8.count + record.nickname.utf8.count + record.rawAddress.utf8.count
            guard byteCount <= 8_388_608 else { throw Failure.limitExceeded }
            var names = [Fuzzy.ContactCandidate(name: record.fullName, value: record.rawAddress)]
            if !record.nickname.isEmpty {
                names.append(.init(name: record.nickname, value: record.rawAddress))
            }
            let scored = Fuzzy.matchContacts(query: input, candidates: names).sorted {
                $0.score != $1.score ? $0.score > $1.score : $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
            }
            try checkpoint()
            guard let best = scored.first else { continue }
            let address: MessagesConversationAddress
            do { address = try MessagesConversationAddress.parse(record.rawAddress) }
            catch { throw Failure.invalidMatchedAddress }
            let next = Candidate(address: address, displayName: record.fullName,
                                 score: best.score, matchedOn: best.name, rawAddresses: [record.rawAddress])
            if let prior = matches[address] {
                let preferred = precedes(next, prior) ? next : prior
                let evidence = Set(prior.rawAddresses + next.rawAddresses).sorted()
                matches[address] = Candidate(address: address, displayName: preferred.displayName,
                    score: preferred.score, matchedOn: preferred.matchedOn, rawAddresses: evidence)
            } else { matches[address] = next }
        }
        try checkpoint()
        let candidates = matches.values.sorted(by: precedes)
        try checkpoint()
        if candidates.isEmpty { return .notFound }
        if candidates.count == 1 { return .resolved(candidates[0]) }
        return .ambiguous(candidates)
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.address.canonical != rhs.address.canonical { return lhs.address.canonical < rhs.address.canonical }
        let left = lhs.displayName ?? "", right = rhs.displayName ?? ""
        if !left.utf8.elementsEqual(right.utf8) { return left.utf8.lexicographicallyPrecedes(right.utf8) }
        return (lhs.matchedOn ?? "").utf8.lexicographicallyPrecedes((rhs.matchedOn ?? "").utf8)
    }
}
