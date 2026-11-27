import Foundation
import XCTest
@testable import KofferCore

final class FakeNotifier: Notifying {
    var started: [String] = []
    var finished: [RunRecord] = []
    var paused: [(String, String)] = []
    var failed: [(String, String)] = []

    func syncStarted(job: SyncJob) { started.append(job.id) }
    func syncFinished(record: RunRecord) { finished.append(record) }
    func syncPaused(job: SyncJob, reason: String) { paused.append((job.id, reason)) }
    func syncFailed(job: SyncJob, reason: String) { failed.append((job.id, reason)) }

    var cloudFound: [(String, Int)] = []
    func cloudDeletionsFound(job: SyncJob, count: Int) { cloudFound.append((job.id, count)) }
}

/// Does nothing beyond the four original calls: proves the new `cloudDeletionsFound` has a default.
final class MinimalNotifier: Notifying {
    func syncStarted(job: SyncJob) {}
    func syncFinished(record: RunRecord) {}
    func syncPaused(job: SyncJob, reason: String) {}
    func syncFailed(job: SyncJob, reason: String) {}
}

final class FakePower: PowerKeeping {
    var begins: Int = 0
    var ends: Int = 0
    func begin(reason: String) { begins += 1 }
    func end() { ends += 1 }
}

final class FakeHistory: HistoryStoring {
    var records: [RunRecord] = []
    func load() -> [RunRecord] { return Array(records.prefix(20)) }
    func append(_ record: RunRecord) { records.insert(record, at: 0) }
}

enum Fixtures {
    static func url(_ name: String) -> URL? {
        return Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")
    }

    static func lines(_ name: String) throws -> [String] {
        guard let url = url(name) else {
            XCTFail("Missing fixture \(name)")
            return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    /// The `stats` object of the last stats line in the fixture.
    static func finalStats(_ name: String) throws -> [String: Any] {
        var last: [String: Any] = [:]
        for line in try lines(name) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = obj as? [String: Any],
                  let stats = dict["stats"] as? [String: Any] else { continue }
            last = stats
        }
        return last
    }

    /// Lines whose `msg` equals or starts with the given text.
    static func countMessages(_ name: String, prefix: String) throws -> Int {
        var n = 0
        for line in try lines(name) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = obj as? [String: Any],
                  let msg = dict["msg"] as? String else { continue }
            if msg.hasPrefix(prefix) { n += 1 }
        }
        return n
    }

    static func parse(_ name: String) throws -> RcloneLogParser {
        let parser = RcloneLogParser()
        for line in try lines(name) { parser.consume(line: line) }
        return parser
    }
}

func statInt(_ stats: [String: Any], _ key: String) -> Int {
    return (stats[key] as? NSNumber)?.intValue ?? -1
}

func statInt64(_ stats: [String: Any], _ key: String) -> Int64 {
    return (stats[key] as? NSNumber)?.int64Value ?? -1
}

func makeTempDirectory(_ label: String = "koffer") throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
    return base
}
