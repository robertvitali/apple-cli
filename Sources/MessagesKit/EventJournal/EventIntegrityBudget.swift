import EventJournal
import Foundation

func integrityBudget(
  _ phase: String, until deadline: ContinuousClock.Instant, restore: @escaping () -> Void
)
  -> MessageEventJournalSchema.IntegrityBudget
{
  MessageEventJournalSchema.IntegrityBudget(deadline: deadline, restoreProgressHandler: restore)
}
