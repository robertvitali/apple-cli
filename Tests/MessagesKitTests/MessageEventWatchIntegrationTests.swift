import AppleKit
import ArgumentParser
import Darwin
import Foundation
import SQLite3
import TestSupport
import Testing

@testable import MessagesKit

struct MessageEventWatchIntegrationTests {
  private let scratch = ScratchDirs("messages-watch-resume")

  @Test func fullRegistryReportsActionableErrorBeforeStartingStream() throws {
    let root = try scratch.directory()
    let url = root.appendingPathComponent("output.ndjson")
    try Data().write(to: url)
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    let command = try MessagesWatch.parse([])
    #expect(throws: ExitCode(AppleExit.upstream)) {
      try command.run(storage: { throw ExistingEventJournalLease.ProvisionFailure.full },
                      output: output.fileDescriptor)
    }
    let lines = try Data(contentsOf: url).split(separator: 10)
    try #require(lines.count == 1)
    let envelope = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
    #expect(envelope["ok"] as? Bool == false)
    let error = try #require(envelope["error"] as? [String: Any])
    #expect(error["message"] as? String == "streamRegistryFull")
    #expect((error["remediation"] as? String)?.contains("preview retirement") == true)
  }

  @Test func baselineReconcileAndReplayAfterRestart() throws {
    let root = try scratch.directory()
    // The journal VFS compares its exact resolved path with SQLite's path.
    let physical = try #require(realpath(root.path, nil))
    defer { free(physical) }
    let parent = String(cString: physical)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let source = root.appendingPathComponent("chat.db").path
    let registry = try MessageEventWatchRegistry(parent: parent, name: "streams")
    let storage = try MessageEventWatchStorage(source: source, registry: registry)
    var db: OpaquePointer?
    try #require(sqlite3_open(source, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    func execute(_ sql: String) throws {
      try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    try execute(
      """
      PRAGMA journal_mode=WAL;
      CREATE TABLE chat(guid TEXT UNIQUE);
      CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER, UNIQUE(chat_id, message_id));
      CREATE TABLE message(guid TEXT UNIQUE, text, attributedBody, thread_originator_guid,
          thread_originator_part, message_summary_info, date_edited, date_retracted,
          associated_message_type, associated_message_guid, associated_message_emoji,
          is_from_me, handle_id, date, error, is_delivered, date_delivered, is_read, date_read);
      INSERT INTO chat VALUES ('selected'), ('other');
      INSERT INTO message(guid,text,date) VALUES ('message-a','original text',1), ('message-b','original text',2);
      INSERT INTO chat_message_join VALUES (1,1), (2,2);
      """)

    func watch(_ arguments: [String]) throws -> [[String: Any]] {
      let command = try #require(
        try MessagesCommand.parseAsRoot(
          ["watch", "--duration", "1.5", "--poll-interval", "0.25"] + arguments) as? MessagesWatch)
      let destination = root.appendingPathComponent(UUID().uuidString + ".ndjson")
      try Data().write(to: destination)
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      do {
        try command.run(storage: { storage }, output: output.fileDescriptor)
      } catch {
        let diagnostics = try Data(contentsOf: destination)
        Issue.record("Watch failed with \(String(decoding: diagnostics, as: UTF8.self))")
        throw error
      }
      let records = try Data(contentsOf: destination)
      #expect(!String(decoding: records, as: UTF8.self).contains("private replacement"))
      return try records.split(separator: 10).map { line in
        let envelope = try #require(
          try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["data"] as? [String: Any])
      }
    }

    let initial = try watch(["--conversation", "selected"])
    try #require(initial.count == 1)
    #expect(initial[0]["record_type"] as? String == "stream_started")
    let baseline = try #require(initial[0]["last_committed_cursor"] as? String)
    try execute("UPDATE message SET text = 'private replacement';")
    let live = try watch(["--resume", baseline])
    try #require(live.count == 2)
    #expect(live[0]["record_type"] as? String == "stream_resumed")
    #expect(live[1]["delivery_mode"] as? String == "live")
    let event = try #require(live[1]["event"] as? NSDictionary)
    #expect(event["message_guid"] as? String == "message-a")
    let after = try #require(live[1]["cursor"] as? String)
    #expect(after != baseline)

    let replay = try watch(["--resume", baseline])
    try #require(replay.count == 2)
    #expect(replay[1]["delivery_mode"] as? String == "replay")
    #expect(replay[1]["cursor"] as? String == after)
    #expect(replay[1]["event"] as? NSDictionary == event)
    let caughtUp = try watch(["--resume", after])
    #expect(caughtUp.compactMap { $0["record_type"] as? String } == ["stream_resumed"])
  }
}
