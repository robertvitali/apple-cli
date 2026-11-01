import Foundation

extension NativeMessageParts {
    /// Typed decoded values, not Foundation objects to instantiate or execute.
    /// Data-backed keys and strings preserve exact UTF-8 identity.
    indirect enum AttributeValue: Equatable, Sendable {
        case null
        case integer(Int)
        case string(Data)
        case data(Data)
        case dictionary([Data: AttributeValue])
        case url(Int, AttributeValue)
    }

    struct AttributeRun: Equatable, Sendable {
        let range: UTF16Range
        let values: [Data: AttributeValue]
    }

    struct AttributeDecoded: Sendable {
        let body: Decoded
        let runs: [AttributeRun]?
    }
}
