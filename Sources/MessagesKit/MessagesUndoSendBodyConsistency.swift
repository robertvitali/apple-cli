import Foundation

/// Checks the SQL text representation against the exact decoded native body.
/// Alternate projection removes only mapped attachment placeholders. This does
/// not prove membership: the enclosing snapshot must still bind every GUID in
/// its pinned transaction before treating the part snapshot as usable.
enum MessagesUndoSendBodyConsistency {
    static func matches(_ sqlText: MessagesUndoSendObservation.Field<Data>,
                        fullText: String, nativeParts: [NativeMessageParts.NativePart],
                        checkpoint: () throws -> Void) throws -> Bool {
        try checkpoint()
        let bytes: Data
        switch sqlText {
        case .null: return true
        case .wrongType: return false
        case .value(let value): bytes = value
        }
        if bytes == Data(fullText.utf8) { return true }
        let limits = NativeMessageParts.Limits.default
        guard fullText.utf16.count <= limits.maxTextUTF16Units,
              nativeParts.count <= limits.maxRuns else { return false }
        let units = Array(fullText.utf16)
        var removedOffsets = Set<Int>()
        var attachmentGUIDs = Set<Data>()
        var indices = Set<Int>()
        var spanCount = 0
        for part in nativeParts {
            try checkpoint()
            guard (0...Int(Int32.max)).contains(part.index), indices.insert(part.index).inserted,
                  part.utf16Ranges.count <= limits.maxRuns - spanCount else { return false }
            spanCount += part.utf16Ranges.count
            guard let guid = part.attachmentGUID else { continue }
            let guidBytes = Data(guid.utf8)
            guard !guidBytes.isEmpty, guidBytes.count <= limits.maxGUIDBytes,
                  attachmentGUIDs.insert(guidBytes).inserted,
                  !part.utf16Ranges.isEmpty else { return false }
            for span in part.utf16Ranges {
                try checkpoint()
                guard span.length == 1, span.location >= 0, span.location < units.count,
                      units[span.location] == 0xfffc,
                      removedOffsets.insert(span.location).inserted else { return false }
            }
        }
        guard !removedOffsets.isEmpty else { return false }
        var projected: [UInt16] = []
        projected.reserveCapacity(units.count - removedOffsets.count)
        for (offset, unit) in units.enumerated() {
            if offset % 1024 == 0 { try checkpoint() }
            if !removedOffsets.contains(offset) { projected.append(unit) }
        }
        try checkpoint()
        return bytes == Data(String(decoding: projected, as: UTF16.self).utf8)
    }
}
