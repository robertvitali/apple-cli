import EventJournal
import Darwin
import Foundation
import SQLite3
import AppleKit

private struct StreamSummary: Encodable {
    var stream_id:String
    var status:String
    var filter_digest:String?
    var oldest_retained_sequence:String?
    var head_sequence:String?
    var text: String {
        let retention = oldest_retained_sequence ?? "none"
        let head = head_sequence ?? "none"
        return "\(stream_id) \(status) filter=\(filter_digest ?? "unknown") oldest=\(retention) head=\(head)"
    }

    enum CodingKeys:String,CodingKey {case stream_id,status,filter_digest,oldest_retained_sequence,head_sequence}
    func encode(to encoder:any Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(stream_id,forKey:.stream_id);try c.encode(status,forKey:.status)
        try c.encode(filter_digest,forKey:.filter_digest);try c.encode(oldest_retained_sequence,forKey:.oldest_retained_sequence)
        try c.encode(head_sequence,forKey:.head_sequence)
    }
}
private struct Retirement:Encodable {let stream:StreamSummary;let files:[String];let dry_run:Bool}

private func readSummary(_ path:String,_ id:String,_ lease:RecoveryLease,_ clock:ReplayClock)throws->StreamSummary {
    try clock.check()
    let connection=try LeasedConnection(path:path,role:EVENT_INSPECT,lease:lease)
    let db=connection.database
    func snapshot()throws->StreamSummary {
        defer {sqlite3_progress_handler(db,0,nil,nil);withExtendedLifetime(clock){}}
        try clock.startSnapshot(db, configure: true)
        try lease.validate()
        var witness:StateWitness?
        _ = try checkedSchema(db).verifiedStateDigest(budget: integrityBudget("inspect", until: clock.end, restore: { clock.install(on: db) })) {
            try digest(db, clock.check, observe: { witness = $0 })
        }
        try statement(db,"SELECT source_identity,schema_digest FROM meta WHERE id=1"){s in
            guard policy_step(s)==SQLITE_ROW,try validIdentity(blob(s,0,29)),try blob(s,1,32).count==32 else {throw Bad.store}
        }
        let meta=try statement(db,"SELECT format,initialized,stream_id,source_epoch,filter_bytes,filter_digest,generation,head FROM meta WHERE id=1"){s in
            guard policy_step(s)==SQLITE_ROW else {throw Bad.store}
            return try PersistedEventMetadata(format:integer(s,0),initialized:integer(s,1),stream:blob(s,2,36),source:blob(s,3,36),filterBytes:blob(s,4,263174),filterDigest:blob(s,5,32),generation:integer(s,6),head:integer(s,7))
        }
        guard meta.stream.rawValue==id,let witness,witness.memberships<=250000 else {throw Bad.store}
        try checkedSchema(db).validateBaselineMemberships(filter: meta.filter, expectedCount: witness.memberships, checkpoint: clock.check)
        let oldest = try checkedSchema(db).validatedOldestSequence(metadata: meta, checkpoint: clock.check)
        guard meta.initialized || (witness.events==0 && witness.memberships==0) else {throw Bad.store}
        try sql(db,"COMMIT");try lease.validate();try clock.check()
        return StreamSummary(stream_id:id,status:meta.initialized ? "ready":"incomplete",filter_digest:meta.filter.digest.rawValue,
                             oldest_retained_sequence:oldest.map(String.init),head_sequence:meta.initialized ? String(meta.head):nil)
    }
    let result: StreamSummary
    do {
        result=try snapshot()
    } catch {
        let rc=sqlite3_extended_errcode(db)
        try lease.validate();try clock.check()
        if (rc&255)==SQLITE_READONLY {
            return StreamSummary(stream_id:id,status:"recovery-required")
        }
        throw error
    }
    try connection.close()
    return result
}
enum MessageEventStreamLifecycle {
    static func run(_ request: ExistingEventJournalLease.RegistryRequest, registry: MessageEventWatchRegistry,
                    text: Bool = false) throws {
        let clock = ReplayClock(milliseconds: 30_000)
        let writer = try RecordWriter(borrowing: STDOUT_FILENO)
        try MessageEventPollWait(output: STDOUT_FILENO).checkConnection()
        let records = try inspect(request, registry: registry, clock: clock)
        let summaries = records.map { record -> StreamSummary in
            let status: String
            switch record.status {
            case .active(let details): return details
            case .creating: status = "incomplete"
            case .retiring: status = "retirement-pending"
            case .busy: status = "busy"
            case .unavailable: status = "unavailable"
            }
            return StreamSummary(stream_id: record.id.uuidString.lowercased(), status: status)
        }
        let output: [Data]
        switch request {
        case .list:
            if text {
                let lines = summaries.isEmpty ? ["No event streams."] : summaries.map(\.text)
                output = lines.map { Data($0.utf8) }
            } else {
                output = [try Output.encodeCompactSuccess(tool: "messages", data: summaries)]
            }
        case .preview, .retire:
            guard records.count == 1, let record = records.first, let summary = summaries.first else {
                throw Bad.store
            }
            let dryRun: Bool
            if case .preview = request { dryRun = true } else { dryRun = false }
            if text {
                let verb = dryRun ? "Would retire" : "Retired"
                let files = record.files.isEmpty ? "none" : record.files.joined(separator: ", ")
                output = [Data("\(verb) \(summary.stream_id) (\(summary.status)), files: \(files)".utf8)]
            } else {
                let result = Retirement(stream: summary, files: record.files, dry_run: dryRun)
                output = [try Output.encodeCompactSuccess(tool: "messages", data: result)]
            }
        }
        for line in output { try writer.writeRecord(line, deadline: clock.end) }
        try writer.close()
    }

    private static func inspect(
        _ request: ExistingEventJournalLease.RegistryRequest,
        registry: MessageEventWatchRegistry,
        clock: ReplayClock
    ) throws -> [ExistingEventJournalLease.RegistryRecord<StreamSummary>] {
        do {
            return try inspectExisting(request, registry: registry, clock: clock)
        } catch ExistingEventJournalLease.Failure.unavailable {
            // A fresh account has no streams. A missing lock in an existing
            // registry must still fail, since it cannot be safely inspected.
            var info = stat()
            guard case .list = request,
                  lstat(registry.parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  lstat(registry.path, &info) != 0, errno == ENOENT else {
                throw ExistingEventJournalLease.Failure.unavailable
            }
            return []
        }
    }

    private static func inspectExisting(
        _ request: ExistingEventJournalLease.RegistryRequest,
        registry: MessageEventWatchRegistry,
        clock: ReplayClock
    ) throws -> [ExistingEventJournalLease.RegistryRecord<StreamSummary>] {
        try ExistingEventJournalLease.inspectRegistry(parent: registry.parent, registry: registry.name,
                                                     request: request, checkpoint: { stage in
            if case .beforeDetach = stage {
                try MessageEventPollWait(output: STDOUT_FILENO).checkConnection()
            }
            try clock.check()
        }) { id, lease in
            try clock.check()
            let name = id.uuidString.lowercased()
            do { return try readSummary(registry.journal(try MessageEventStreamID(name)), name, lease, clock) }
            catch {
                try clock.check()
                try lease.validate()
                return StreamSummary(stream_id: name, status: "unavailable")
            }
        }
    }
}
