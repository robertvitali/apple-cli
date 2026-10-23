import Foundation

/// Shared whole-second rendering only; native columns and edit-event seconds
/// deliberately apply different validation, sentinel and normalization rules.
enum NativeMessageTimestamp {
    static func unavailable(_ status: String, raw: Int64? = nil) -> ChatDB.ExactNativeStatus.TimestampField {
        .init(status: status, raw: raw, normalized_seconds: nil, normalized_nanoseconds: nil, date: nil, date_local: nil)
    }

    static func valid(utc: String, local: String) -> Bool {
        utc.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z"#, options: .regularExpression) != nil
            && local.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\z"#, options: .regularExpression) != nil
    }

    static func formatSeconds(_ seconds: Int64, _ timeZone: TimeZone) -> (String, String) {
        let date = Date(timeIntervalSince1970: Double(seconds) + MessageTime.appleUnixOffset)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.gregorianStartDate = .distantPast
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let utc = formatter.string(from: date)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (utc, formatter.string(from: date))
    }
}
