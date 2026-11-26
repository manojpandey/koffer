import Foundation

/// Keeps the last 20 finished runs in a small JSON file.
/// Default location: ~/Library/Application Support/Koffer/history.json
public final class HistoryStore: HistoryStoring {
    /// How many records are kept.
    public static let maxRecords: Int = 20

    private let fileURL: URL
    private let lock: NSLock = NSLock()

    public init(fileURL: URL? = nil) {
        if let url: URL = fileURL {
            self.fileURL = url
        } else {
            self.fileURL = HistoryStore.defaultFileURL()
        }
    }

    /// ~/Library/Application Support/Koffer/history.json
    public static func defaultFileURL() -> URL {
        let found: [URL] = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base: URL
        if let first: URL = found.first {
            base = first
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        return base
            .appendingPathComponent("Koffer", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    /// Newest first, at most 20. Returns [] if the file is missing or unreadable.
    public func load() -> [RunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    /// Adds a record, keeps the newest 20, and writes the file atomically.
    public func append(_ record: RunRecord) {
        lock.lock()
        defer { lock.unlock() }

        var records: [RunRecord] = readLocked()
        records.removeAll { (existing: RunRecord) -> Bool in existing.id == record.id }
        records.append(record)
        records = HistoryStore.normalized(records)

        do {
            let folder: URL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)

            let encoder: JSONEncoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience; a failed write must never break a backup run.
        }
    }

    // MARK: - Private

    private func readLocked() -> [RunRecord] {
        guard let data: Data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records: [RunRecord] = try? decoder.decode([RunRecord].self, from: data) else { return [] }
        return HistoryStore.normalized(records)
    }

    private static func normalized(_ records: [RunRecord]) -> [RunRecord] {
        var sorted: [RunRecord] = records
        sorted.sort { (a: RunRecord, b: RunRecord) -> Bool in a.startedAt > b.startedAt }
        if sorted.count > maxRecords {
            sorted = Array(sorted.prefix(maxRecords))
        }
        return sorted
    }
}
