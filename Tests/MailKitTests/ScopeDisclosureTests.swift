import Testing
import Foundation
@testable import MailKit

/// CI-tier coverage for the "All"-scope disclosure surfaces.
///
/// These exist because the bats equivalents are all `require_index`-gated: on a CI runner with
/// no Mail store they SKIP, so the suite stays green even if the behavior they protect is
/// reverted. Everything asserted here is pure — no Mail, no TCC, no Envelope Index — so it runs
/// in the logic tier and actually fails when the behavior changes.
@Suite("All-scope disclosure")
struct ScopeDisclosureTests {

    // MARK: the wildcard predicate itself

    /// `search`'s `system_folders_excluded`, bulk's `scope_note`, and `resolveMailboxes` must
    /// agree on what "All" means. They agree only because all three call this one function.
    @Test func allWildcardIsCaseInsensitiveAndExact() {
        #expect(EnvelopeIndex.isAllWildcard("All"))
        #expect(EnvelopeIndex.isAllWildcard("all"))
        #expect(EnvelopeIndex.isAllWildcard("ALL"))
        // Not a wildcard: real mailboxes whose names merely contain or resemble it.
        #expect(!EnvelopeIndex.isAllWildcard("All Mail"))
        #expect(!EnvelopeIndex.isAllWildcard("[Gmail]/All Mail"))
        #expect(!EnvelopeIndex.isAllWildcard("INBOX"))
        #expect(!EnvelopeIndex.isAllWildcard(""))
    }

    /// The regression that started this: `thread` lost the account's own Sent replies because
    /// it inherits this default. `thread` now also sets it explicitly, but a flip here would
    /// still silently narrow every other caller that does not.
    @Test func messageFiltersIncludeSystemFoldersDefaultsToTrue() {
        #expect(EnvelopeIndex.MessageFilters().includeSystemFolders == true)
    }

    // MARK: mailboxScopeNote

    @Test func scopeNoteFiresForTheAllWildcard() {
        let note = mailboxScopeNote("All")
        #expect(note != nil)
        // The note's job is to warn that bulk "All" is WIDER than search "All".
        #expect(note?.contains("INCLUDES") == true)
        #expect(mailboxScopeNote("all") != nil)
    }

    /// A mutation pointed straight at a system mailbox is not a divergence from `search`, but it
    /// is still worth stating — an All-scoped preview would not have shown those messages.
    @Test func scopeNoteFiresForAnExplicitSystemMailbox() {
        #expect(mailboxScopeNote("Trash") != nil)
        #expect(mailboxScopeNote("Deleted Messages") != nil)
        #expect(mailboxScopeNote("Sent Messages") != nil)
        #expect(mailboxScopeNote("[Gmail]/Spam") != nil)
    }

    /// Drafts holds UNSENT composes, so moving one out of Drafts is qualitatively different from
    /// re-filing a received message. The note must say so by name.
    @Test func scopeNoteCallsOutDraftsAsUnsentComposes() {
        let note = mailboxScopeNote("Drafts")
        #expect(note?.contains("UNSENT") == true)
        #expect(mailboxScopeNote("[Gmail]/Drafts")?.contains("UNSENT") == true)
        // A non-Drafts system mailbox still warns, but without the unsent-compose clause.
        #expect(mailboxScopeNote("Trash")?.contains("UNSENT") == false)
    }

    @Test func scopeNoteIsSilentForAnOrdinaryMailbox() {
        #expect(mailboxScopeNote("INBOX") == nil)
        #expect(mailboxScopeNote("Archive") == nil)
        #expect(mailboxScopeNote("[Gmail]/All Mail") == nil)
    }

    // MARK: wire shape — absent vs false

    private func encode<T: Encodable>(_ v: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(v), as: UTF8.self)
    }

    /// `nil` must be OMITTED, not serialized as `null`: a named-mailbox search makes no claim
    /// about system folders, and `"system_folders_excluded": null` reads as one.
    @Test func searchResultOmitsTheDisclosureWhenNotAnAllSweep() throws {
        let base = MailMessagesResult(
            account: nil, mailbox: "INBOX", messages: [], count: 0, offset: 0, limit: 50,
            has_more: false, next_offset: nil, sort: "date_desc", system_folders_excluded: nil)
        #expect(!(try encode(base)).contains("system_folders_excluded"))

        let excluded = MailMessagesResult(
            account: nil, mailbox: "All", messages: [], count: 0, offset: 0, limit: 50,
            has_more: false, next_offset: nil, sort: "date_desc", system_folders_excluded: true)
        #expect((try encode(excluded)).contains("\"system_folders_excluded\":true"))

        let included = MailMessagesResult(
            account: nil, mailbox: "All", messages: [], count: 0, offset: 0, limit: 50,
            has_more: false, next_offset: nil, sort: "date_desc", system_folders_excluded: false)
        #expect((try encode(included)).contains("\"system_folders_excluded\":false"))
    }

    /// Analytics is a counts-only payload, so silent filtering there is worse than on `search`:
    /// the caller sees a number and cannot tell what it covered.
    @Test func statisticsResultCarriesTheDisclosure() throws {
        let filtered = Analytics.statistics([], scope: "account_overview", account: "iCloud",
                                            daysBack: 7, systemFoldersExcluded: true) { _ in "?" }
        #expect(filtered.system_folders_excluded == true)
        #expect((try encode(filtered)).contains("\"system_folders_excluded\":true"))

        let unfiltered = Analytics.statistics([], scope: "account_overview", account: "iCloud",
                                              daysBack: 7, systemFoldersExcluded: false) { _ in "?" }
        #expect(unfiltered.system_folders_excluded == false)
    }
}
