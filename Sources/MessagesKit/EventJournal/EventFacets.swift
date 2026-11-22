import EventJournal
import Foundation

func facets(_ raw: Observation, check: () throws -> Void) throws -> [Observation] {
  guard raw.status == "available" else {
    return Array(repeating: Observation(raw.status), count: 3)
  }
  let result = try MessageEventSummaryFacets.read(raw.bytes, checkCancellation: check)
  return [result.editedParts, result.history, result.retractedParts].map {
    Observation($0.status.rawValue, $0.digest)
  }
}
