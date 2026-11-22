import EventJournal
import SQLite3

enum WriterSchema {
  private static func execute(_ db: OpaquePointer, _ sql: String) throws {
    let rc = policy_exec(db, sql)
    guard rc == SQLITE_OK else { throw JournalSchemaError.sqliteCode(rc) }
  }

  // The caller exclusively owns this connection and handles rollback on failure.
  static func begin(_ db: OpaquePointer, exclusive: Bool) throws {
    guard sqlite3_get_autocommit(db) != 0 else {
      throw JournalSchemaError.sqliteCode(SQLITE_MISUSE)
    }
    let protectiveSettings = policy_protect(db)
    guard protectiveSettings == SQLITE_OK else {
      throw JournalSchemaError.sqliteCode(protectiveSettings)
    }
    try execute(db, "BEGIN")
    try checkedSchema(db).validateMain()
    try checkedSchema(db).requireEmptyTemp()
    try execute(db, "COMMIT")
    let config = leased_configure(db)
    guard config == SQLITE_OK else { throw JournalSchemaError.sqliteCode(config) }
    try execute(db, exclusive ? "BEGIN EXCLUSIVE" : "BEGIN IMMEDIATE")
    try checkedSchema(db).validateMain()
    try execute(db, MessageEventJournalFormat.createStaging)
    try checkedSchema(db).validateStaging()
  }
}
