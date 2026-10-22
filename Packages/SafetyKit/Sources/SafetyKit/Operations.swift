import Foundation

public enum OperationKind: String, Sendable, Codable, CaseIterable {
    case cleanup, uninstall, trashFile, duplicates, leftovers, maintenance, loginItem
}

public enum OperationResult: String, Sendable, Codable, CaseIterable {
    case trashed, deleted, ran, disabled, enabled, removed, skipped, failed, refused

    /// Whether the item is gone from its original place.
    public var removedItem: Bool { self == .trashed || self == .deleted || self == .removed }
}

/// One row of the operation log.
public struct OperationEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let batchID: UUID
    public let kind: OperationKind
    public let title: String
    public let path: String
    public let bytes: Int64
    public let result: OperationResult
    public let reason: String?

    public init(id: UUID = UUID(), date: Date = Date(), batchID: UUID, kind: OperationKind, title: String,
                path: String, bytes: Int64, result: OperationResult, reason: String? = nil) {
        self.id = id; self.date = date; self.batchID = batchID; self.kind = kind; self.title = title
        self.path = path; self.bytes = bytes; self.result = result; self.reason = reason
    }
}

/// Where operation entries go. The app writes them to SwiftData; tests use `InMemoryOperationLog`.
public protocol OperationLogging: Sendable {
    func record(_ entries: [OperationEntry]) async
}

public actor InMemoryOperationLog: OperationLogging {
    public private(set) var entries: [OperationEntry] = []
    public init() {}
    public func record(_ new: [OperationEntry]) async { entries.append(contentsOf: new) }
}

/// Exports the operation log as CSV, JSON or Markdown.
public enum OperationLogExporter {
    public enum Format: String, Sendable, CaseIterable { case csv, json, markdown
        public var fileExtension: String { self == .markdown ? "md" : rawValue }
    }

    public static func export(_ entries: [OperationEntry], as format: Format) throws -> Data {
        switch format {
        case .csv: return Data(csv(entries).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(entries)
        case .markdown: return Data(markdown(entries).utf8)
        }
    }

    static func isoString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }

    public static func csv(_ entries: [OperationEntry]) -> String {
        var lines = ["date,operation,title,path,bytes,result,reason"]
        for e in entries {
            lines.append([isoString(e.date), e.kind.rawValue, e.title, e.path, String(e.bytes), e.result.rawValue, e.reason ?? ""]
                .map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func markdown(_ entries: [OperationEntry]) -> String {
        var out = "# KeelMac operation log\n\n| Date | Operation | Path | Size | Result |\n|---|---|---|---:|---|\n"
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        for e in entries {
            let result = e.reason.map { "\(e.result.rawValue): \($0)" } ?? e.result.rawValue
            let path = e.path.replacingOccurrences(of: "|", with: "\\|")
            out += "| \(isoString(e.date)) | \(e.title) | `\(path)` | \(e.bytes > 0 ? bytes.string(fromByteCount: e.bytes) : "–") | \(result) |\n"
        }
        return out
    }
}
