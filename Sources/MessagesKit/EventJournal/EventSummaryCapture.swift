import CryptoKit
import EventJournal
import Foundation

extension Journal {
  func priorMembership(_ chat: Data, _ message: Data) throws -> [V]? {
    try one(
      "SELECT id,message_rowid,chat_rowid,component_hashes,availability,summary_facets,projection FROM baseline WHERE chat_guid=? AND message_guid=?",
      [.b(chat), .b(message)])
  }

  func summaryRecord(
    _ raw: Observation, digest: Data, old: [V]?, projection: Data, dates: ArraySlice<Observation>
  ) throws -> Data {
    if let old, try old[3].bytes(256)[32..<64].elementsEqual(digest) {
      let previous = try old[5].bytes(100)
      // Journal.begin validated all stored facets on this pinned transaction.
      if previous[0] == 2 { return previous }
      // Preserve legacy component hashes on a no-op. A projection change
      // is already a real baseline change. An unavailable date always
      // precedes the plist facets in the old component availability.
      let availability = try old[4].bytes(8)
      if try old[6].bytes() == projection {
        var datesMatch = true
        for (i, date) in dates.enumerated() where date.status != "available" {
          if try code(date.status) != availability[2 + i] { datesMatch = false }
        }
        if datesMatch { return previous }
      }
      return Data([2]) + previous.dropFirst()
    }
    let decoded = try facets(raw, check: check)
    return try MessageEventSummaryRecord.encode(decoded, sourceStatus: code(raw.status))
  }
}
