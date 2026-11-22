import CoreFoundation
import EventJournal
import Foundation

func nativeInteger(_ value: Any?) -> Int64? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    return nil
  }
  switch String(cString: number.objCType) {
  case "q", "i", "l", "s", "c": return number.int64Value
  case "Q", "I", "L", "S", "C": return Int64(exactly: number.uint64Value)
  default: return nil
  }
}
func supportedType(_ type: Int64?) -> (standard: Bool, custom: Bool) {
  guard let type else { return (false, false) }
  return (
    (2000...2005).contains(type) || (3000...3005).contains(type), type == 2006 || type == 3006
  )
}
func validAssociation(_ a: [String: Any]) -> Bool {
  guard
    Set(a.keys)
      == Set([
        "target_message_guid", "target_part", "target_status", "actor_kind", "supported",
        "native_type",
      ]),
    let kind = a["actor_kind"] as? String, ["self", "other", "unknown"].contains(kind),
    let flag = a["supported"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
    let target = a["target_status"] as? String
  else { return false }
  let type = nativeInteger(a["native_type"])
  guard type != nil || a["native_type"] is NSNull else { return false }
  let forms = supportedType(type)
  if forms.standard && !flag.boolValue || flag.boolValue && !(forms.standard || forms.custom) {
    return false
  }
  let guid = a["target_message_guid"] as? String
  if let guid {
    guard !guid.utf8.starts(with: "p:".utf8), !guid.utf8.starts(with: "bp:".utf8),
      (try? MessageEventGUID(guid)) != nil
    else { return false }
  }
  let part = nativeInteger(a["target_part"])
  switch target {
  case "not_associated":
    return type == 0 && !flag.boolValue && a["target_message_guid"] is NSNull
      && a["target_part"] is NSNull
  case "unresolved": return a["target_message_guid"] is NSNull && a["target_part"] is NSNull
  case "bare_alias_uncertain": return guid != nil && a["target_part"] is NSNull
  case "parsed_part": return guid != nil && part.map { (0...Int64(Int32.max)).contains($0) } == true
  default: return false
  }
}
