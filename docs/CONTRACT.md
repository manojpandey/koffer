# Koffer: module contract

Koffer is a macOS 14+ menu bar app that backs a folder up to the cloud by wrapping `rclone`.
This file fixes the seams between modules so
several people can build in parallel. **Match the names and signatures here exactly.**

## Ground rules (everyone)

- Swift tools 5.9, Swift 5 language mode, macOS 14. SwiftPM only, no Xcode project.
- **No macros**: no `@Observable`, no `#Preview`, no Swift Testing. Use `ObservableObject` +
  `@Published`, and XCTest. (The app must build with only the Command Line Tools.)
- **No `@State`** (nor `@Binding`, `@AppStorage`, `@FocusState`) in views: on newer SDKs these can be macros that the
  Command Line Tools cannot expand. Keep view state as `@Published` properties on `AppModel`.
- No third-party dependencies.
- There is no Swift compiler in the authoring environment; CI on macOS is the compiler.
  Write conservative, explicit Swift: annotate types where inference could be ambiguous,
  avoid clever generics, mark UI types `@MainActor`, and double-check every API name.
- Plain words in anything the user sees: "Backing up", "New", "Moved", "Removed (kept in <removed folder name>)".
- Do not run `git`. The orchestrator commits.
- Only touch the files listed for your module.

## Targets

- `KofferCore` (`Sources/KofferCore`): Foundation (+ Combine) only. No AppKit/SwiftUI.
- `Koffer` (`Sources/Koffer`): the app. SwiftUI + AppKit. Depends on `KofferCore`.
- `KofferCoreTests` (`Tests/KofferCoreTests`): XCTest; fixtures in `Fixtures/` are real
  rclone v1.71 `--use-json-log` output, loaded via `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures")`.

`Sources/KofferCore/Models.swift` already exists and is final: `SyncJob`, `PrivatePathRule`, `KofferConfig`, `EngineStatus`,
`SyncProgress`, `ChangeKind`, `ChangeItem`, `PreviewResult`, `RunOutcome`, `RunRecord`, and the
service protocols `Notifying`, `PowerKeeping`, `HistoryStoring`.

## Module A: engine (KofferCore)

Files: everything in `Sources/KofferCore` except `Models.swift`, `HistoryStore.swift`, `Formatting.swift`;
all of `Tests/KofferCoreTests` except `HistoryStoreTests.swift`, `FormattingTests.swift`.

Public surface the app relies on:

```swift
public struct EngineServices {
    public var notifier: Notifying
    public var power: PowerKeeping
    public var history: HistoryStoring
    public init(notifier: Notifying, power: PowerKeeping, history: HistoryStoring)
}

@MainActor
public final class SyncEngine: ObservableObject {
    @Published public private(set) var status: EngineStatus          // starts .idle
    @Published public private(set) var progress: SyncProgress
    @Published public private(set) var activeJobID: String?          // job being previewed/synced
    @Published public private(set) var preview: PreviewResult?       // last dry-run result
    @Published public private(set) var history: [RunRecord]          // newest first, max 20
    @Published public private(set) var jobs: [SyncJob]               // persisted
    @Published public private(set) var removedBytes: [String: Int64] // job id -> size of its removedRoot
    @Published public private(set) var rclonePath: String?           // nil = rclone not installed
    @Published public private(set) var needsReconnect: Bool          // token expired
    @Published public private(set) var mountedVolumes: Set<String>
    @Published public private(set) var statusJobID: String?         // job `status` is about; nil = all jobs

    public init(services: EngineServices)

    public func job(id: String) -> SyncJob?
    public func isAvailable(_ job: SyncJob) -> Bool      // enabled, and requiredVolume (if any) mounted
    public func setEnabled(_ enabled: Bool, jobID: String)
    public func setAutoSync(_ on: Bool, jobID: String)

    public func syncNow(jobID: String)                   // no-op if busy
    public func previewChanges(jobID: String)            // dry run; on success fills `preview` and sets job.previewApproved = true
    public func cancel()                                 // stop cleanly -> .paused("Stopped by you")

    public func volumeMounted(_ name: String)            // waits ~10 s, then auto-syncs eligible jobs
    public func volumeUnmounted(_ name: String)          // stops a running job on that volume -> .paused
    public func networkChanged(isOnline: Bool)           // offline mid-sync -> .paused

    public func refreshRemovedSize(jobID: String)        // fills removedBytes[jobID]
    public func emptyRemovedItems(jobID: String)         // `rclone purge <removedRoot>`; UI confirms first
    public func recheckRclone()                          // re-run the locator
    public func reconnectCommand(for jobID: String) -> String  // e.g. "rclone config reconnect onedrive:"
}
```

Behaviour the engine owns: locating rclone (`/opt/homebrew/bin/rclone`, `/usr/local/bin/rclone`),
building the command, safety validation, pre-flight (source exists and is not empty, network,
`rclone about --json` free space vs. new data + 10%), running the child process, parsing JSON
logs into `SyncProgress`, classifying errors into plain words, writing log files, history via
`services.history`, notifications via `services.notifier`, sleep prevention via `services.power`,
and loading/saving `KofferConfig` at `~/Library/Application Support/Koffer/config.json`
(seeded with `KofferConfig()` = test job only; `jobs` mirrors `config.jobs`). On launch, if
`config.json` is missing the seed is written. The file is hand-editable; decode failures must
surface as `.needsAttention("Koffer's settings file can't be read")`, never silently reset.

**This repository is public.** No real folder names, volume names, remote paths or e-mail
addresses in source, tests, comments or docs. Use made-up names in tests ("Archive", "Private Papers", "MyDisk").
The user's real jobs live only in their local config.json.

Logs: `~/Library/Logs/Koffer/<jobID>_<yyyy-MM-dd_HHmm>.log` (raw rclone JSON lines), plus a copy
in `job.extraLogDirectory` when set and writable.

## Module B: persistence + formatting (KofferCore)

Files: `Sources/KofferCore/HistoryStore.swift`, `Sources/KofferCore/Formatting.swift`,
`Tests/KofferCoreTests/HistoryStoreTests.swift`, `Tests/KofferCoreTests/FormattingTests.swift`.

```swift
public final class HistoryStore: HistoryStoring {
    public init(fileURL: URL? = nil)   // default ~/Library/Application Support/Koffer/history.json
    public func load() -> [RunRecord]  // newest first, max 20; never throws, returns [] on any problem
    public func append(_ record: RunRecord)
}

public enum Format {
    public static func bytes(_ n: Int64) -> String            // "1.2 GB", "340 MB", "12 KB" (decimal units like Finder)
    public static func speed(_ bytesPerSecond: Double) -> String  // "4.1 MB/s"
    public static func duration(_ t: TimeInterval) -> String  // "3h 12m", "4m 05s", "12s"
    public static func eta(_ seconds: Double?) -> String      // "about 2h 40m left", "less than a minute left", "" when nil
    public static func count(_ n: Int) -> String              // "1,204"
    public static func summary(_ r: RunRecord) -> String      // "312 new files, 1,204 moved, 0 errors, 3h 12m"
    public static func relativeDay(_ date: Date, now: Date) -> String // "Today 14:02", "Yesterday 09:10", "12 Nov 18:30"
}
```

## Module C: system services (app target)

Files: `Sources/Koffer/Services/*.swift`.

```swift
@MainActor final class VolumeWatcher {            // NSWorkspace didMount/didUnmount
    init(onMount: @escaping (String) -> Void, onUnmount: @escaping (String) -> Void)
    func start()
    static func currentVolumes() -> Set<String>   // names under /Volumes
}
final class NetworkWatcher {                      // NWPathMonitor
    init(onChange: @escaping (Bool) -> Void)      // called on main queue
    func start()
}
final class PowerAssertion: PowerKeeping          // IOPMAssertionCreateWithName, PreventUserIdleSystemSleep
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    func requestPermission()
}
enum LoginItem {                                  // SMAppService.mainApp
    static var isEnabled: Bool { get }
    static func setEnabled(_ on: Bool) throws
}
enum TerminalLauncher { static func run(_ command: String) }   // opens Terminal.app and runs the command (via a temp .command file + NSWorkspace.open)
enum TestFolder { static func createIfMissing(at path: String) } // makes ~/Koffer Test with a few small text files and generated PNGs
```

## Module D: UI (app target)

Files: `Sources/Koffer/KofferApp.swift`, `Sources/Koffer/AppModel.swift`, `Sources/Koffer/Views/*.swift`.

`AppModel` (`@MainActor final class AppModel: ObservableObject`) owns the `SyncEngine` and the
Module C services, wires watchers to the engine, and is created once in `KofferApp`.
`KofferApp` is `@main`, a `MenuBarExtra` with `.menuBarExtraStyle(.window)`; the label shows a
status icon (idle / syncing with % / done / needs attention). UI reads engine state only through
the published properties above and uses `Format` for every number.

## Module E: build, CI, docs

Files: `scripts/*`, `.github/workflows/*`, `README.md`, `Resources/*`.
