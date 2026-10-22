import Foundation
import ReportKit
import SafetyKit
import SwiftData

/// One row of the operation log (see docs/forge/04-plan.md, Data model).
@Model
final class OperationRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var batchID: UUID
    var operation: String
    var title: String
    var path: String
    var bytes: Int64
    var result: String
    var reason: String?

    init(_ entry: OperationEntry) {
        id = entry.id
        date = entry.date
        batchID = entry.batchID
        operation = entry.kind.rawValue
        title = entry.title
        path = entry.path
        bytes = entry.bytes
        result = entry.result.rawValue
        reason = entry.reason
    }

    var entry: OperationEntry {
        OperationEntry(id: id, date: date, batchID: batchID, kind: OperationKind(rawValue: operation) ?? .cleanup, title: title,
                       path: path, bytes: bytes, result: OperationResult(rawValue: result) ?? .failed, reason: reason)
    }

    var resultValue: OperationResult { OperationResult(rawValue: result) ?? .failed }
    var kindValue: OperationKind { OperationKind(rawValue: operation) ?? .cleanup }
}

@Model
final class StorageSnapshot {
    @Attribute(.unique) var id: UUID
    var date: Date
    var volumeTotal: Int64
    var volumeUsed: Int64
    var batteryMaxCapacity: Double?
    var reclaimableBytes: Int64
    @Relationship(deleteRule: .cascade, inverse: \SnapshotEntry.snapshot) var entries: [SnapshotEntry]

    init(id: UUID, date: Date, volumeTotal: Int64, volumeUsed: Int64, batteryMaxCapacity: Double?, reclaimableBytes: Int64, entries: [SnapshotEntry]) {
        self.id = id; self.date = date; self.volumeTotal = volumeTotal; self.volumeUsed = volumeUsed
        self.batteryMaxCapacity = batteryMaxCapacity; self.reclaimableBytes = reclaimableBytes; self.entries = entries
    }
}

@Model
final class SnapshotEntry {
    var path: String
    var bytes: Int64
    var snapshot: StorageSnapshot?

    init(path: String, bytes: Int64) { self.path = path; self.bytes = bytes }
}

enum Store {
    static let schema = Schema([OperationRecord.self, StorageSnapshot.self, SnapshotEntry.self])

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeelMac", isDirectory: true)
    }

    @MainActor
    static func makeContainer(inMemory: Bool) -> ModelContainer {
        if !inMemory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: directory.appendingPathComponent("KeelMac.store"))
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // A damaged store must not stop the app; keep the old file aside and start fresh.
            let url = directory.appendingPathComponent("KeelMac.store")
            try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("KeelMac-damaged-\(Int(Date().timeIntervalSince1970)).store"))
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        }
    }
}

/// Writes operation log entries from any isolation domain into SwiftData.
@ModelActor
actor OperationLogStore: OperationLogging {
    func record(_ entries: [OperationEntry]) async {
        for entry in entries { modelContext.insert(OperationRecord(entry)) }
        try? modelContext.save()
    }

    /// Keeps one year of history.
    func prune(olderThan cutoff: Date) {
        try? modelContext.delete(model: OperationRecord.self, where: #Predicate { $0.date < cutoff })
        try? modelContext.save()
    }

    func all() -> [OperationEntry] {
        let descriptor = FetchDescriptor<OperationRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.entry)
    }
}

/// Stores weekly storage snapshots in SwiftData for ReportKit.
@ModelActor
actor SnapshotStore: SnapshotStoring {
    func save(_ s: SnapshotValue) async throws {
        let entries = s.entries.map { SnapshotEntry(path: $0.key, bytes: $0.value) }
        modelContext.insert(StorageSnapshot(id: s.id, date: s.date, volumeTotal: s.volumeTotal, volumeUsed: s.volumeUsed,
                                            batteryMaxCapacity: s.batteryMaxCapacityPercent, reclaimableBytes: s.reclaimableBytes, entries: entries))
        // Keep a year of weekly snapshots.
        let all = try modelContext.fetch(FetchDescriptor<StorageSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        for old in all.dropFirst(52) { modelContext.delete(old) }
        try modelContext.save()
    }

    func all() async throws -> [SnapshotValue] {
        let rows = try modelContext.fetch(FetchDescriptor<StorageSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        return rows.map { row in
            SnapshotValue(id: row.id, date: row.date, volumeTotal: row.volumeTotal, volumeUsed: row.volumeUsed,
                          batteryMaxCapacityPercent: row.batteryMaxCapacity, reclaimableBytes: row.reclaimableBytes,
                          entries: Dictionary(row.entries.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
        }
    }
}
