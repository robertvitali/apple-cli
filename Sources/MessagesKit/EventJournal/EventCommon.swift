import AppleKit
import CryptoKit
import EventJournal
import Foundation

typealias Row = SQLiteReader.Row
func big(_ x: Int64) -> Data { withUnsafeBytes(of: x.bigEndian) { Data($0) } }
func hex(_ bytes: some Sequence<UInt8>) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

typealias Observation = MessageEventSummaryRecord.Observation

extension Observation {
  init(_ status: String, _ bytes: Data = Data()) { self.init(status: status, bytes: bytes) }
}
