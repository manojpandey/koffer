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

---

# v0.2 additions: everything through the panel, no Terminal

Product rule: the user never opens Terminal. Installing rclone, checking the connection, signing in again,
creating a backup, choosing and creating cloud folders all happen in the UI.

## Engine additions (Module A)

```swift
public struct EngineError: Error, Equatable { public let message: String; public init(_ message: String) }

public enum RemoteState: Equatable {
    case unknown
    case checking
    case connected(used: Int64?, total: Int64?, free: Int64?)
    case failed(String)            // plain words; e.g. "OneDrive needs you to sign in again"
}

public enum TaskState: Equatable { case idle, running(String), failed(String), succeeded }

extension SyncEngine {
    @Published public private(set) var remotes: [String]                     // e.g. ["onedrive:"], from `rclone listremotes`
    @Published public private(set) var remoteStates: [String: RemoteState]   // keyed by remote name with colon
    @Published public private(set) var installState: TaskState               // installing rclone
    @Published public private(set) var reconnectState: TaskState             // signing in again

    public func refreshRemotes(force: Bool)      // listremotes, then `about --json` per remote; skips if checked < 60 s ago unless force; no-op while a backup runs
    public func listFolders(remote: String, path: String) async -> Result<[String], EngineError>   // folder names, sorted, `lsjson --dirs-only`
    public func createFolder(remote: String, path: String) async -> Result<Bool, EngineError>      // `rclone mkdir`; true on success
    public func proposedJob(name: String, source: String, remote: String, remotePath: String) -> SyncJob
        // destination = remote + remotePath; removedRoot = sibling folder "_<last component>_removed";
        // requiredVolume = volume name when source is under /Volumes/<name>/...; enabled = true; previewApproved = false;
        // autoSyncOnMount = (requiredVolume != nil); unique id derived from the name
    public func addJob(_ job: SyncJob) -> SafetyVerdict     // SafetyRules.check, then save to config; .refused(reason) changes nothing
    public func removeJob(id: String) -> SafetyVerdict      // forgets the job in config only; never touches the cloud; refused while that job runs
    public var homebrewPath: String? { get }                // /opt/homebrew/bin/brew or /usr/local/bin/brew if executable
    public func installRclone()                             // see below; ends with recheckRclone() and refreshRemotes(force: true)
    public func reconnect(remote: String)                   // see below
}
```

`installRclone()`: if Homebrew exists run `brew install rclone` as a child process (installState = .running("Installing rclone with Homebrew…")).
Otherwise download the official build for this Mac's CPU from `https://downloads.rclone.org/rclone-current-osx-<arm64|amd64>.zip`
with URLSession, unzip with `/usr/bin/ditto -x -k`, and place the binary at
`~/Library/Application Support/Koffer/bin/rclone` (chmod 755). `RcloneLocator.defaultCandidates` gains that path (last).
Failure -> `.failed(plain words)`; never leave a half-written binary in place.

`reconnect(remote:)`: must work without Terminal. rclone's sign-in opens the default browser by itself and waits on a
local callback. Drive it as a child process and answer its prompts programmatically (investigate with the real binary:
`rclone config reconnect <remote>: --help`, `--auto-confirm`, and the `--non-interactive` / `--continue --state --result`
protocol). reconnectState = .running("Waiting for you to sign in in your browser…") with a timeout (5 min) and cancel via `cancelReconnect()`.
On success: needsReconnect = false, refreshRemotes(force: true).

`SafetyRules.assertSafe` must keep refusing anything destructive; `mkdir`, `listremotes`, `lsjson`, `config reconnect` are allowed, `purge` only on a removedRoot.

## UI additions (Module D)

No `@State`, `@Binding`, `@AppStorage`, `@FocusState` anywhere (see ground rules): every piece of view state is a
`@Published` property on an ObservableObject (`AppModel` or a new `NewBackupModel`), bound with `$model.property`.

- Connection row at the top of the panel for the selected job's remote: "OneDrive connected · 412 GB free of 1 TB", "Checking…",
  or a failure with a "Sign in again" button (-> engine.reconnect). Refresh when the panel appears.
- Every job shows its route: local folder -> remote:path (middle-truncated, selectable).
- rclone missing card: one "Install rclone" button (-> engine.installRclone) with progress and failure text. No commands shown.
- "New backup…" button opens a separate window (`Window` scene, id "new-backup", opened with `@Environment(\.openWindow)`;
  call `NSApp.activate(ignoringOtherApps: true)`), three steps on one screen:
  1. Folder on this Mac: "Choose…" -> NSOpenPanel (directories only).
  2. Where in the cloud: remote picker (if more than one) + a folder browser (breadcrumb, list of folders, double-click or
     chevron to enter, "New folder" with a name field that creates it immediately via engine.createFolder and enters it).
     The chosen destination must not be the remote's root.
  3. Name (prefilled from the local folder name) and a summary sentence: "Koffer will copy <local> to <remote:path>.
     Removed files are kept in <removed folder>." -> "Create backup" (engine.addJob; show the refusal reason inline if refused),
     then select the new job in the panel and offer "What will change?".
- Settings for a job gains "Forget this backup…" (confirmation; says nothing in the cloud is deleted) for non-built-in jobs.
- Reconnect card uses engine.reconnect / reconnectState instead of Terminal. `TerminalLauncher` is no longer used by the UI.
