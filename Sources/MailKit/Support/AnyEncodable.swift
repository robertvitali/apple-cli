import Foundation

/// Type-erased `Encodable`, so commands can emit small heterogeneous `[String: …]` payloads
/// (dry-run previews, confirmations) without a bespoke struct for each shape.
public struct AnyEncodableBox: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    public init<T: Encodable>(_ value: T) { encodeFunc = value.encode }
    public func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
