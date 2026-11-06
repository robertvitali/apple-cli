/// Value consistency at the creation adapter's pre-send boundary. The adapter
/// must freshly acquire a complete recipient-token list, native service evidence
/// and body from its retained, uniquely owned composer. A display name is never
/// an address; unresolved or unavailable token addresses are nil.
///
/// This check does not establish AX ownership, completeness of acquisition,
/// native service semantics, or send success. Those remain adapter and persisted
/// verifier obligations. Do not cache this value across native mutations.
struct MessagesConversationNativeEnvelope {
    let recipientAddresses: [String?]
    let service: String?
    let body: MessagesAXBodyTextSnapshot?

    func validate(request: MessagesConversationRequest) throws {
        guard (1...32).contains(recipientAddresses.count),
              recipientAddresses.count == request.recipients.count,
              let service, service.utf8.elementsEqual(request.service.utf8),
              let body, body.text.utf8.elementsEqual(request.initialText.utf8) else {
            throw MessagesAXNavigationError.targetDrift
        }
        var addresses: [String] = []
        for raw in recipientAddresses {
            guard let raw, let address = try? MessagesConversationAddress.parse(raw) else {
                throw MessagesAXNavigationError.targetDrift
            }
            addresses.append(address.canonical)
        }
        guard Set(addresses).count == addresses.count,
              addresses.sorted() == request.recipients else {
            throw MessagesAXNavigationError.targetDrift
        }
    }
}
