import Foundation
import Contacts
import AppleKit

// Contacts engine — the shipping mechanism for every operation except the two
// entitlement-gated ones (contact NOTES and group REMOVE-member), which fall back to
// AppleScript exactly as apple-contacts-mcp @ 1cd8789 (v0.3.0) does. Mirrors
// contacts_connector.py + the server-layer error dispatch. Every framework call goes
// through a `ContactsStoreBackend`; in production that is always the file-private
// `LiveContactsStoreBackend`, which owns the one `CNContactStore` + `AppleScriptRunner`.
//
// SECURITY: the AppleScript fallbacks bind user/CN data via osascript ARGV
// (`on run argv`), never string-interpolated into the script source — strictly safer
// than the MCP (which interpolates an escaped id). Injection is RCE-class; argv closes it.

/// Photo read result: nil ⇒ contact not found; else availability + raw bytes.
struct PhotoData {
    let available: Bool
    let bytes: Data
}

/// The `CNContactStore` + `osascript` surface `ContactsStore` actually touches, extracted so
/// logic tests can bind a pure in-memory stand-in. `LiveContactsStoreBackend` below is the ONLY
/// production implementation and is `private` to this file, so no flag, env var, or public
/// initializer can swap it — `ContactsStore()` always talks to the real `CNContactStore`.
///
/// `requestAccess`'s handler is `@escaping @Sendable`: it is bridged to a synchronous call
/// through a `DispatchSemaphore`, and Contacts is free to invoke it on an arbitrary queue.
/// `enumerateContacts`'s block is deliberately NON-escaping, matching `CNContactStore`, so the
/// caller can keep accumulating into local vars.
protocol ContactsStoreBackend {
    /// `CNContactStore.authorizationStatus(for: .contacts).rawValue` — the raw value, not the
    /// enum, because the mapping deliberately avoids SDK case-availability differences.
    var authorizationStatusRawValue: Int { get }
    func requestAccess(completion: @escaping @Sendable (Bool, Error?) -> Void)
    func enumerateContacts(with request: CNContactFetchRequest,
                           usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws
    func unifiedContact(withIdentifier identifier: String, keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact
    func unifiedContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact]
    func groups(matching predicate: NSPredicate?) throws -> [CNGroup]
    func containers(matching predicate: NSPredicate?) throws -> [CNContainer]
    func defaultContainerIdentifier() -> String
    func execute(_ request: CNSaveRequest) throws
    /// The osascript fallback used by the two entitlement-gated ops. `arguments` are opaque
    /// argv — never interpolated into the script source.
    func runScript(_ script: String, arguments: [String]) throws -> String
}

private final class LiveContactsStoreBackend: ContactsStoreBackend {
    private let store = CNContactStore()
    private let runner = AppleScriptRunner()

    var authorizationStatusRawValue: Int {
        CNContactStore.authorizationStatus(for: .contacts).rawValue
    }

    func requestAccess(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        store.requestAccess(for: .contacts, completionHandler: completion)
    }

    func enumerateContacts(with request: CNContactFetchRequest,
                           usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        try store.enumerateContacts(with: request, usingBlock: block)
    }

    func unifiedContact(withIdentifier identifier: String, keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
    }

    func unifiedContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        try store.unifiedContacts(matching: predicate, keysToFetch: keys)
    }

    func groups(matching predicate: NSPredicate?) throws -> [CNGroup] {
        try store.groups(matching: predicate)
    }

    func containers(matching predicate: NSPredicate?) throws -> [CNContainer] {
        try store.containers(matching: predicate)
    }

    func defaultContainerIdentifier() -> String {
        store.defaultContainerIdentifier()
    }

    func execute(_ request: CNSaveRequest) throws {
        try store.execute(request)
    }

    func runScript(_ script: String, arguments: [String]) throws -> String {
        try runner.run(script, arguments: arguments)
    }
}

public final class ContactsStore {
    private let backend: any ContactsStoreBackend
    private let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 10) {
        self.backend = LiveContactsStoreBackend()
        self.requestTimeout = requestTimeout
    }

    /// Test-only seam. Internal (and the protocol is internal), so no other module — and no
    /// flag or env var — can reach it; `ContactsStore()` is the only production path.
    init(backend: any ContactsStoreBackend, requestTimeout: TimeInterval = 10) {
        self.backend = backend
        self.requestTimeout = requestTimeout
    }

    // MARK: - Authorization

    /// TCC status string, mapped from the CNAuthorizationStatus raw value exactly as
    /// the MCP's `_CN_AUTHORIZATION_STATUS` (0..4). Switching on rawValue avoids SDK
    /// enum-case availability differences for `.limited`.
    public func authorizationStatus() -> String {
        switch backend.authorizationStatusRawValue {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        case 4: return "limited"
        default: return "notDetermined"
        }
    }

    /// Remediation copy for a non-granted status (mirror server `_AUTH_REMEDIATION`).
    static func remediation(for status: String) -> String? {
        switch status {
        case "notDetermined":
            return "Contacts access has not been requested yet. Run a data command "
                + "(e.g. list) to trigger the system permission prompt, or grant access "
                + "manually in System Settings → Privacy & Security → Contacts."
        case "denied":
            return "Contacts access was denied. Open System Settings → Privacy & Security "
                + "→ Contacts and enable access for this tool (macOS will not re-prompt automatically)."
        case "restricted":
            return "Contacts access is locked by parental controls or device management. "
                + "Contact your administrator."
        default:
            return nil
        }
    }

    /// Result box for the CN access-request bridge.
    ///
    /// `@unchecked Sendable` is carried by the explicit `NSLock` below, NOT by call-order
    /// discipline. The semaphore alone orders only the HAPPY path: on the TIMEOUT path
    /// `requestAccess` returns while Contacts' completion handler is still in flight on its own
    /// queue, so that handler's write and a later read of this box genuinely can overlap. The
    /// lock is what makes the overlap benign; the previous "externally-synchronized via the
    /// semaphore" claim did not hold for the timeout case.
    private final class AccessResult: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = false
        private var error: Error?

        func complete(granted: Bool, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            self.granted = granted
            self.error = error
        }

        var value: (granted: Bool, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            return (granted, error)
        }
    }

    @discardableResult
    private func requestAccess() throws -> Bool {
        let sema = DispatchSemaphore(value: 0)
        let result = AccessResult()
        backend.requestAccess { ok, err in
            result.complete(granted: ok, error: err)
            sema.signal()
        }
        if sema.wait(timeout: .now() + requestTimeout) == .timedOut {
            // Mirrors the oracle's request-timeout branch (`server.py:99-109`) EXACTLY, including
            // that it carries `status` but NO `remediation` — the prompt is already on screen, so
            // "open System Settings" would be wrong advice. The message text is the oracle's
            // verbatim; it used to be a paraphrase with the status folded into the prose, which no
            // consumer could branch on.
            throw AppleError.permissionDenied(
                "Contacts permission prompt is awaiting your response. Grant access in the "
                + "system dialog and retry.",
                status: "notDetermined")
        }
        let outcome = result.value
        if let err = outcome.error {
            throw AppleError.permissionDenied("Contacts authorization error: \(err.localizedDescription)")
        }
        return outcome.granted
    }

    /// Gate every data command (mirror `_require_contacts_authorization`): request on
    /// `notDetermined`, then require authorized/limited. Throws `authorization_denied` carrying
    /// `status` and `remediation` as STRUCTURED envelope fields, matching the oracle key-for-key.
    /// They were previously folded into the message prose, which is what CONTACTS-M2 was.
    public func requireAuthorization() throws {
        var status = authorizationStatus()
        if status == "notDetermined" {
            _ = try requestAccess()
            status = authorizationStatus()
        }
        if status == "authorized" || status == "limited" { return }
        // `server.py:113-126`: message, status and remediation are three SEPARATE keys, and the
        // message does NOT have the remediation appended. We used to concatenate them, so the only
        // way to recover either was to parse English out of one string.
        let rem = Self.remediation(for: status) ?? "Open System Settings → Privacy & Security → Contacts."
        throw AppleError.permissionDenied("Contacts access not granted (status=\(status)).",
                                          status: status, remediation: rem)
    }

    // MARK: - Key sets

    // Computed (not stored static) so the non-Sendable `[CNKeyDescriptor]` isn't a
    // shared-mutable global under Swift 6 strict concurrency; arrays are tiny.
    private static var summaryKeys: [CNKeyDescriptor] {
        [CNContactIdentifierKey, CNContactGivenNameKey,
         CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
    }

    private static var p1Keys: [CNKeyDescriptor] {
        [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
         CNContactNamePrefixKey, CNContactNameSuffixKey, CNContactNicknameKey,
         CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactDepartmentNameKey,
         CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
         CNContactUrlAddressesKey, CNContactBirthdayKey, CNContactIdentifierKey] as [CNKeyDescriptor]
    }

    private static var nicheKeys: [CNKeyDescriptor] {
        [CNContactDatesKey, CNContactSocialProfilesKey,
         CNContactRelationsKey, CNContactInstantMessageAddressesKey] as [CNKeyDescriptor]
    }

    // MARK: - Reads

    /// Paged 4-field summaries (mirror `_run_cn_enumerate_contacts`).
    public func enumerateContacts(offset: Int, limit: Int) throws -> [ContactSummary] {
        let req = CNContactFetchRequest(keysToFetch: Self.summaryKeys)
        var out: [ContactSummary] = []
        var skipped = 0
        do {
            try backend.enumerateContacts(with: req) { contact, stop in
                if skipped < offset { skipped += 1; return }
                if out.count >= limit { stop.pointee = true; return }
                out.append(serializeSummary(contact))
            }
        } catch {
            throw AppleError.unknown("Fetch failed: \(error.localizedDescription)")
        }
        return out
    }

    /// Full single contact (+ niche when requested); nil ⇒ no match.
    public func unifiedContact(_ identifier: String, includeNiche: Bool) -> Contact? {
        var keys = Self.p1Keys
        if includeNiche { keys += Self.nicheKeys }
        guard let c = try? backend.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else {
            return nil
        }
        return serializeContact(c, includeNiche: includeNiche)
    }

    /// Field-scoped search (mirror `_run_cn_search_contacts`). `field` ∈
    /// name|phone|email|organization.
    public func searchContacts(field: String, value: String, limit: Int) throws -> [ContactSummary] {
        var keys = Self.summaryKeys
        let predicate: NSPredicate
        switch field {
        case "name":
            predicate = CNContact.predicateForContacts(matchingName: value)
        case "phone":
            keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: value))
        case "email":
            keys.append(CNContactEmailAddressesKey as CNKeyDescriptor)
            predicate = CNContact.predicateForContacts(matchingEmailAddress: value)
        case "organization":
            predicate = NSPredicate(format: "organizationName CONTAINS[cd] %@", value)
        default:
            throw AppleError.validation("Unknown search field: \(field)")
        }
        let results: [CNContact]
        do {
            results = try backend.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw AppleError.unknown("Search failed: \(error.localizedDescription)")
        }
        return results.prefix(limit).map(serializeSummary)
    }

    // MARK: - Groups + containers

    /// Fetch a CNGroup by identifier; nil ⇒ no match (mirror `_run_cn_fetch_group`).
    func fetchGroup(_ identifier: String) throws -> CNGroup? {
        let pred = CNGroup.predicateForGroups(withIdentifiers: [identifier])
        let results: [CNGroup]
        do {
            results = try backend.groups(matching: pred)
        } catch {
            throw AppleError.unknown("CN group fetch failed: \(error.localizedDescription)")
        }
        return results.first
    }

    /// Fetched-target write-safety: throw unless the CONTACT at `identifier` is a labeled test
    /// item (its primary name — given/family/org — carries `prefix`). Call before any id-addressed
    /// contact mutation so `update`/`delete`/`note`/`photo --id <real> --execute --test-mode`
    /// cannot touch real data. The `resolveWrite` gate checks execute+test-mode; this checks the
    /// TARGET itself — matching the fetched-target guard Calendar/Reminders/Notes already apply.
    public func requireLabeledContactTarget(_ identifier: String, prefix: String) throws {
        guard let c = unifiedContact(identifier, includeNiche: false) else {
            throw AppleError.notFound("Contact not found: '\(identifier)'")
        }
        let name = ContactsLabel.primaryName(given: c.given_name, family: c.family_name, organization: c.organization)
        guard ContactsLabel.isLabeled(name, prefix: prefix) else {
            throw AppleError.safetyViolation(
                "refusing to mutate a non-test contact: its name '\(name)' does not start with "
                + "'\(prefix)' — id-addressed writes only touch labeled test data.", sandbox: true)
        }
    }

    /// Same fetched-target guard for a GROUP (rename/delete + membership add/remove).
    public func requireLabeledGroupTarget(_ identifier: String, prefix: String) throws {
        guard let g = try fetchGroup(identifier) else {
            throw AppleError.notFound("Group not found: '\(identifier)'")
        }
        guard ContactsLabel.isLabeled(g.name, prefix: prefix) else {
            throw AppleError.safetyViolation(
                "refusing to mutate a non-test group: its name '\(g.name)' does not start with "
                + "'\(prefix)' — id-addressed writes only touch labeled test data.", sandbox: true)
        }
    }

    /// TCC-free: the primary name of every contact a vCard would import — so `import` can
    /// enforce (in test mode) that every card is labeled before any live create. `parseVCard`
    /// is static + does not touch the store, so this needs no authorization.
    public static func vcardPrimaryNames(text: String) throws -> [String] {
        try parseVCard(text: text).map {
            ContactsLabel.primaryName(given: $0.givenName, family: $0.familyName, organization: $0.organizationName)
        }
    }

    private func resolveContainerId(forGroup groupIdentifier: String) -> String {
        let pred = CNContainer.predicateForContainerOfGroup(withIdentifier: groupIdentifier)
        guard let containers = try? backend.containers(matching: pred), let first = containers.first else {
            return ""
        }
        return first.identifier
    }

    public func listGroups() throws -> [Group] {
        let groups: [CNGroup]
        do {
            groups = try backend.groups(matching: nil)
        } catch {
            throw AppleError.unknown("list_groups failed: \(error.localizedDescription)")
        }
        return groups.map { g in
            Group(id: g.identifier, name: g.name, container_id: resolveContainerId(forGroup: g.identifier))
        }
    }

    public func contactsInGroup(_ groupId: String, limit: Int) throws -> [ContactSummary] {
        let pred = CNContact.predicateForContactsInGroup(withIdentifier: groupId)
        let results: [CNContact]
        do {
            results = try backend.unifiedContacts(matching: pred, keysToFetch: Self.summaryKeys)
        } catch {
            throw AppleError.unknown("get_contacts_in_group failed: \(error.localizedDescription)")
        }
        return results.prefix(limit).map(serializeSummary)
    }

    public func listContainers() throws -> [Container] {
        let containers: [CNContainer]
        do {
            containers = try backend.containers(matching: nil)
        } catch {
            throw AppleError.unknown("list_containers failed: \(error.localizedDescription)")
        }
        let defaultId = backend.defaultContainerIdentifier()
        return containers.map { c in
            Container(id: c.identifier, name: c.name, type: Self.containerType(c.type),
                      is_default: c.identifier == defaultId)
        }
    }

    /// Internal (not private) so the logic tier can pin all four branches directly: `CNContainer`
    /// has no initializer that sets `type`, so a fake backend cannot vend one of each kind.
    static func containerType(_ type: CNContainerType) -> String {
        switch type.rawValue {
        case 1: return "local"
        case 2: return "exchange"
        case 3: return "cardDAV"
        default: return "unknown(\(type.rawValue))"
        }
    }

    // MARK: - vCard

    public func exportVCard(_ identifiers: [String]) throws -> String {
        let descriptor = CNContactVCardSerialization.descriptorForRequiredKeys()
        var contacts: [CNContact] = []
        for ident in identifiers {
            guard let c = try? backend.unifiedContact(withIdentifier: ident, keysToFetch: [descriptor]) else {
                throw AppleError.notFound("Contact not found: '\(ident)'")
            }
            contacts.append(c)
        }
        do {
            let data = try CNContactVCardSerialization.data(with: contacts)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw AppleError.unknown("vCard serialization failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Photo read

    func readPhoto(_ identifier: String) -> PhotoData? {
        let keys = [CNContactImageDataKey, CNContactImageDataAvailableKey] as [CNKeyDescriptor]
        guard let c = try? backend.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else {
            return nil
        }
        if !c.imageDataAvailable { return PhotoData(available: false, bytes: Data()) }
        return PhotoData(available: true, bytes: c.imageData ?? Data())
    }

    // MARK: - Notes (AppleScript fallback — entitlement-gated field)

    public func readNote(_ identifier: String) throws -> String {
        let script = """
        on run argv
          set theId to item 1 of argv
          tell application "Contacts"
            set p to first person whose id is theId
            if note of p is missing value then
              return ""
            else
              return note of p
            end if
          end tell
        end run
        """
        do {
            return try backend.runScript(script, arguments: [identifier])
        } catch let e as AppleScriptRunner.RunError {
            throw Self.mapAppleScriptError(e, notFoundMessage: "Contact not found: '\(identifier)'",
                                           genericPrefix: "read_note failed")
        }
    }

    public func writeNote(_ identifier: String, note: String) throws {
        let script = """
        on run argv
          set theId to item 1 of argv
          set theNote to item 2 of argv
          tell application "Contacts"
            set p to first person whose id is theId
            set note of p to theNote
            save
          end tell
        end run
        """
        do {
            _ = try backend.runScript(script, arguments: [identifier, note])
        } catch let e as AppleScriptRunner.RunError {
            throw Self.mapAppleScriptError(e, notFoundMessage: "Contact not found: '\(identifier)'",
                                           genericPrefix: "write_note failed")
        }
    }

    // MARK: - Writes (all gated at the command layer; execution mutates the real store)

    public func createContact(fields: ContactFields, groupIdentifier: String?, containerIdentifier: String?) throws -> String {
        let mutable = buildMutableContact(from: fields)
        var group: CNGroup?
        if let gid = groupIdentifier {
            guard let g = try fetchGroup(gid) else { throw AppleError.notFound("Group not found: '\(gid)'") }
            group = g
        }
        let save = CNSaveRequest()
        save.add(mutable, toContainerWithIdentifier: containerIdentifier)
        if let group { save.addMember(mutable, to: group) }
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("Create failed: \(error.localizedDescription)")
        }
        return mutable.identifier
    }

    public func updateContact(identifier: String, fields: ContactFields) throws -> String {
        var keys = Self.p1Keys
        keys += Self.nicheKeys
        guard let contact = try? backend.unifiedContact(withIdentifier: identifier, keysToFetch: keys),
              let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AppleError.notFound("Contact not found: '\(identifier)'")
        }
        applyUpdateFields(to: mutable, from: fields)
        let save = CNSaveRequest()
        save.update(mutable)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("Update failed: \(error.localizedDescription)")
        }
        return identifier
    }

    public func deleteContact(identifier: String) throws -> String {
        let keys = [CNContactIdentifierKey] as [CNKeyDescriptor]
        guard let contact = try? backend.unifiedContact(withIdentifier: identifier, keysToFetch: keys),
              let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AppleError.notFound("Contact not found: '\(identifier)'")
        }
        let save = CNSaveRequest()
        save.delete(mutable)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("Delete failed: \(error.localizedDescription)")
        }
        return identifier
    }

    /// Parse-only vCard validation (TCC-free; no store access). Shared by the import
    /// dry-run (validate without mutating) and the execute path. Throws `validation_error`
    /// on malformed/empty input, mirroring `import_vcard`'s pre-save checks.
    static func parseVCard(text: String) throws -> [CNContact] {
        let parsed: [CNContact]
        do {
            parsed = try CNContactVCardSerialization.contacts(with: Data(text.utf8))
        } catch {
            throw AppleError.validation("vCard parse failed: \(error.localizedDescription)")
        }
        if parsed.isEmpty { throw AppleError.validation("No vCards found in input") }
        return parsed
    }

    /// Count of contacts a vCard payload would import (drives the dry-run preview).
    static func validateVCard(text: String) throws -> Int { try parseVCard(text: text).count }

    public func importVCard(text: String, groupIdentifier: String?) throws -> [String] {
        let parsed = try Self.parseVCard(text: text)

        var group: CNGroup?
        if let gid = groupIdentifier {
            guard let g = try fetchGroup(gid) else { throw AppleError.notFound("Group not found: '\(gid)'") }
            group = g
        }
        let save = CNSaveRequest()
        var mutables: [CNMutableContact] = []
        for c in parsed {
            guard let m = c.mutableCopy() as? CNMutableContact else { continue }
            save.add(m, toContainerWithIdentifier: nil)
            if let group { save.addMember(m, to: group) }
            mutables.append(m)
        }
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("import_vcard failed: \(error.localizedDescription)")
        }
        return mutables.map { $0.identifier }
    }

    public func addContactToGroup(contactIdentifier: String, groupIdentifier: String) throws {
        let (mutable, group) = try loadContactAndGroup(contactIdentifier, groupIdentifier)
        let save = CNSaveRequest()
        save.addMember(mutable, to: group)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("add_contact_to_group failed: \(error.localizedDescription)")
        }
    }

    /// Remove-member via AppleScript — `CNSaveRequest.removeMember(_:from:)` silently
    /// no-ops (empirically verified by the MCP); `remove p from g` + `save` persists.
    public func removeContactFromGroup(contactIdentifier: String, groupIdentifier: String) throws {
        _ = try loadContactAndGroup(contactIdentifier, groupIdentifier) // preflight → clean not_found
        let script = """
        on run argv
          set cId to item 1 of argv
          set gId to item 2 of argv
          tell application "Contacts"
            set p to first person whose id is cId
            set g to first group whose id is gId
            remove p from g
            save
          end tell
        end run
        """
        do {
            _ = try backend.runScript(script, arguments: [contactIdentifier, groupIdentifier])
        } catch let e as AppleScriptRunner.RunError {
            throw Self.mapAppleScriptError(
                e,
                notFoundMessage: "Contact or group not found (contact='\(contactIdentifier)', group='\(groupIdentifier)')",
                genericPrefix: "remove_contact_from_group failed")
        }
    }

    private func loadContactAndGroup(_ contactIdentifier: String, _ groupIdentifier: String) throws -> (CNMutableContact, CNGroup) {
        let keys = [CNContactIdentifierKey] as [CNKeyDescriptor]
        guard let contact = try? backend.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys),
              let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AppleError.notFound("Contact not found: '\(contactIdentifier)'")
        }
        guard let group = try fetchGroup(groupIdentifier) else {
            throw AppleError.notFound("Group not found: '\(groupIdentifier)'")
        }
        return (mutable, group)
    }

    public func writePhoto(identifier: String, imageData: Data?) throws -> String {
        let keys = [CNContactImageDataKey] as [CNKeyDescriptor]
        guard let contact = try? backend.unifiedContact(withIdentifier: identifier, keysToFetch: keys),
              let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AppleError.notFound("Contact not found: '\(identifier)'")
        }
        mutable.imageData = imageData
        let save = CNSaveRequest()
        save.update(mutable)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("write_photo failed: \(error.localizedDescription)")
        }
        return identifier
    }

    public func createGroup(name: String, containerIdentifier: String?) throws -> Group {
        let mutable = CNMutableGroup()
        mutable.name = name
        let save = CNSaveRequest()
        save.add(mutable, toContainerWithIdentifier: containerIdentifier)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("create_group failed: \(error.localizedDescription)")
        }
        return Group(id: mutable.identifier, name: mutable.name,
                     container_id: resolveContainerId(forGroup: mutable.identifier))
    }

    public func renameGroup(identifier: String, newName: String) throws -> Group {
        guard let group = try fetchGroup(identifier), let mutable = group.mutableCopy() as? CNMutableGroup else {
            throw AppleError.notFound("Group not found: '\(identifier)'")
        }
        mutable.name = newName
        let save = CNSaveRequest()
        save.update(mutable)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("rename_group failed: \(error.localizedDescription)")
        }
        return Group(id: identifier, name: mutable.name, container_id: resolveContainerId(forGroup: identifier))
    }

    public func deleteGroup(identifier: String) throws -> String {
        guard let group = try fetchGroup(identifier), let mutable = group.mutableCopy() as? CNMutableGroup else {
            throw AppleError.notFound("Group not found: '\(identifier)'")
        }
        let save = CNSaveRequest()
        save.delete(mutable)
        do {
            try backend.execute(save)
        } catch {
            throw AppleError.unknown("delete_group failed: \(error.localizedDescription)")
        }
        return identifier
    }

    // MARK: - AppleScript error mapping

    private static func mapAppleScriptError(
        _ e: AppleScriptRunner.RunError, notFoundMessage: String, genericPrefix: String
    ) -> AppleError {
        if case let .scriptFailed(_, stderr) = e, isAppleScriptNotFound(stderr) {
            return AppleError.notFound(notFoundMessage)
        }
        // Stable, locale-independent classification. Raw osascript stderr is kept OUT of the
        // JSON envelope (it is unstable/locale-variable, and AppleScriptRunner deliberately
        // keeps it off `.description`). `error.type` stays `unknown` to match the MCP oracle
        // (generic AppleScript failures surface as `unknown` there). The common real causes are
        // named so the message is actionable without leaking raw stderr.
        return AppleError.unknown(
            "\(genericPrefix): Contacts automation via osascript failed. Ensure Contacts.app is "
            + "available and Automation access to Contacts is granted (System Settings → Privacy "
            + "& Security → Automation).")
    }
}
