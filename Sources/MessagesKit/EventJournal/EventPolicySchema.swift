import EventJournal
import SQLite3

typealias JournalSchemaError = MessageEventJournalSchema.Failure

func checkedSchema(_ db: OpaquePointer) -> MessageEventJournalSchema {
  MessageEventJournalSchema(
    database: db, prepare: { policy_prepare($0, $1, &$2) }, step: policy_step)
}
