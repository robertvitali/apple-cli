import AppleKit

extension ChatDB {
    public struct NativeAttachmentFlags: Encodable, Equatable, Sendable {
        public let is_sticker: ExactNativeStatus.BooleanField
        public let hide_attachment: ExactNativeStatus.BooleanField
    }
}

/// Strict native observations alongside unchanged legacy attachment flags.
enum NativeAttachmentFlagsDecoder {
    private enum Column: String, CaseIterable {
        case is_sticker, hide_attachment
        var typeAlias: String { "native_attachment_\(rawValue)_type" }
        var valueAlias: String { "native_attachment_\(rawValue)_value" }
    }

    static func projection(columns: Set<String>) -> String {
        Column.allCases.map { column in
            guard columns.contains(column.rawValue) else {
                return "'missing-schema' AS \(column.typeAlias), NULL AS \(column.valueAlias)"
            }
            // Only fixed enum identifiers enter SQL. The new fields never
            // materialize noninteger values or reinterpret legacy coercion.
            return "typeof(a.\(column.rawValue)) AS \(column.typeAlias), "
                + "CASE WHEN typeof(a.\(column.rawValue)) = 'integer' THEN a.\(column.rawValue) "
                + "ELSE NULL END AS \(column.valueAlias)"
        }.joined(separator: ", ")
    }

    static func decode(_ row: SQLiteReader.Row) -> ChatDB.NativeAttachmentFlags {
        .init(is_sticker: boolean(row, .is_sticker), hide_attachment: boolean(row, .hide_attachment))
    }

    private static func boolean(_ row: SQLiteReader.Row, _ column: Column) -> ChatDB.ExactNativeStatus.BooleanField {
        NativeMessageStatusDecoder.boolean(storageType: row.values[column.typeAlias],
                                           value: row.values[column.valueAlias])
    }
}
