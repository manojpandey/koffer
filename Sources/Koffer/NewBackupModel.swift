import AppKit
import Foundation
import KofferCore

/// Display helpers shared by the panel and the "New backup" window.
enum DisplayNames {

    /// "onedrive:" -> "OneDrive", "gdrive:" / "drive:" -> "Google Drive", otherwise the name without
    /// the colon, capitalised ("box:" -> "Box").
    static func friendly(remote: String) -> String {
        var bare: String = remote
        if bare.hasSuffix(":") { bare = String(bare.dropLast()) }
        let lower: String = bare.lowercased()
        if lower == "onedrive" { return "OneDrive" }
        if lower == "gdrive" || lower == "drive" || lower == "googledrive" { return "Google Drive" }
        if lower == "dropbox" { return "Dropbox" }
        if lower == "icloud" || lower == "iclouddrive" { return "iCloud Drive" }
        guard let first = bare.first else { return "your cloud storage" }
        return String(first).uppercased() + String(bare.dropFirst())
    }

    /// "/Users/someone/Pictures" -> "~/Pictures".
    static func abbreviated(_ path: String) -> String {
        let ns: NSString = path as NSString
        return ns.abbreviatingWithTildeInPath
    }

    /// Last folder of a cloud path, e.g. "onedrive:Photos/_2026_removed" -> "_2026_removed".
    static func lastComponent(ofCloudPath path: String) -> String {
        let afterColon: String
        if let idx = path.firstIndex(of: ":") {
            afterColon = String(path[path.index(after: idx)...])
        } else {
            afterColon = path
        }
        let parts: [Substring] = afterColon.split(separator: "/")
        if let last = parts.last { return String(last) }
        return afterColon.isEmpty ? "the removed folder" : afterColon
    }

    /// Last component of a local path, e.g. "/Volumes/MyDisk/Archive" -> "Archive".
    static func folderName(ofLocalPath path: String) -> String {
        let name: String = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// Everything the "New backup" window shows and edits. Owned by `AppModel`; reset each time the window opens.
@MainActor
final class NewBackupModel: ObservableObject {

    private let engine: SyncEngine

    // Step 1: folder on this Mac
    @Published private(set) var sourcePath: String = ""

    // Step 2: where in the cloud
    @Published private(set) var remote: String = ""
    @Published private(set) var pathComponents: [String] = []
    @Published private(set) var folders: [String] = []
    /// Folder in `folders` highlighted with a single click (it becomes the destination).
    @Published private(set) var selectedFolder: String? = nil
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: String? = nil
    @Published var newFolderName: String = ""
    @Published private(set) var isCreatingFolder: Bool = false
    @Published private(set) var folderError: String? = nil

    // Step 3: name and create
    @Published var jobName: String = ""
    @Published private(set) var refusal: String? = nil

    /// True while the window is on screen (not published: views do not depend on it).
    var isOpen: Bool = false
    /// True after the user asked for the window; guards against the window being opened by the system on launch.
    var wasRequested: Bool = false

    private var autoName: String = ""
    private var loadToken: Int = 0

    init(engine: SyncEngine) {
        self.engine = engine
    }

    // MARK: Lifecycle

    /// Start over with a clean form. `preferredRemote` is used when it is one of the known accounts.
    func reset(preferredRemote: String?) {
        loadToken += 1
        sourcePath = ""
        pathComponents = []
        folders = []
        selectedFolder = nil
        isLoading = false
        loadError = nil
        newFolderName = ""
        isCreatingFolder = false
        folderError = nil
        jobName = ""
        autoName = ""
        refusal = nil
        let remotes: [String] = engine.remotes
        if let preferred = preferredRemote, !preferred.isEmpty, remotes.contains(preferred) {
            remote = preferred
        } else {
            remote = remotes.first ?? ""
        }
        loadFolders()
    }

    /// Called whenever the engine's list of accounts changes.
    func adoptRemotes(_ remotes: [String]) {
        if !remote.isEmpty && remotes.contains(remote) { return }
        let next: String = remotes.first ?? ""
        if next == remote { return }
        remote = next
        pathComponents = []
        loadFolders()
    }

    // MARK: Step 1

    func chooseSource() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Koffer should back up."
        if !sourcePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: sourcePath)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = panel.runModal()
        guard response == NSApplication.ModalResponse.OK, let url = panel.url else { return }
        setSource(url.path)
    }

    private func setSource(_ path: String) {
        sourcePath = path
        refusal = nil
        let name: String = DisplayNames.folderName(ofLocalPath: path)
        let current: String = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == autoName {
            jobName = name
        }
        autoName = name
    }

    // MARK: Step 2

    func chooseRemote(_ newRemote: String) {
        guard newRemote != remote else { return }
        remote = newRemote
        pathComponents = []
        refusal = nil
        loadFolders()
    }

    /// The folder currently shown in the browser, without the account, e.g. "Photos/2026".
    var currentPath: String { pathComponents.joined(separator: "/") }

    var isAtRoot: Bool { pathComponents.isEmpty }

    /// Folder the backup goes into, without the account; "" means the top level (not allowed).
    var remotePath: String {
        var parts: [String] = pathComponents
        if let selected = selectedFolder { parts.append(selected) }
        return parts.joined(separator: "/")
    }

    /// e.g. "onedrive:Photos/2026", or nil while no folder is chosen.
    var destination: String? {
        guard !remote.isEmpty, !remotePath.isEmpty else { return nil }
        return remote + remotePath
    }

    func toggleSelection(_ name: String) {
        if selectedFolder == name {
            selectedFolder = nil
        } else {
            selectedFolder = name
        }
        refusal = nil
    }

    func enter(_ name: String) {
        pathComponents.append(name)
        refusal = nil
        loadFolders()
    }

    /// Go to a depth in the breadcrumb: 0 is the top of the account.
    func goTo(depth: Int) {
        let clamped: Int = max(0, min(depth, pathComponents.count))
        if clamped == pathComponents.count && selectedFolder == nil { return }
        pathComponents = Array(pathComponents.prefix(clamped))
        refusal = nil
        loadFolders()
    }

    func goUp() {
        guard !pathComponents.isEmpty else { return }
        goTo(depth: pathComponents.count - 1)
    }

    func loadFolders() {
        loadToken += 1
        let token: Int = loadToken
        selectedFolder = nil
        folders = []
        loadError = nil
        folderError = nil
        guard !remote.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        let engine: SyncEngine = self.engine
        let remote: String = self.remote
        let path: String = currentPath
        Task { @MainActor in
            let result: Result<[String], EngineError> = await engine.listFolders(remote: remote, path: path)
            guard token == self.loadToken else { return }
            self.isLoading = false
            switch result {
            case .success(let names):
                self.folders = names
            case .failure(let error):
                self.loadError = error.message
            }
        }
    }

    var canCreateFolder: Bool {
        !remote.isEmpty && !isCreatingFolder
            && !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func createFolder() {
        let name: String = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !remote.isEmpty, !isCreatingFolder else { return }
        if name.contains("/") || name.contains(":") {
            folderError = "A folder name can't contain \u{201C}/\u{201D} or \u{201C}:\u{201D}."
            return
        }
        if folders.contains(name) {
            newFolderName = ""
            enter(name)
            return
        }
        isCreatingFolder = true
        folderError = nil
        let engine: SyncEngine = self.engine
        let remote: String = self.remote
        let parent: [String] = pathComponents
        let path: String = (parent + [name]).joined(separator: "/")
        Task { @MainActor in
            let result: Result<Bool, EngineError> = await engine.createFolder(remote: remote, path: path)
            self.isCreatingFolder = false
            // Ignore the answer if the user moved somewhere else meanwhile.
            guard self.remote == remote, self.pathComponents == parent else { return }
            switch result {
            case .success(let ok):
                if ok {
                    self.newFolderName = ""
                    self.enter(name)
                } else {
                    self.folderError = "Couldn't make that folder. Please try again."
                }
            case .failure(let error):
                self.folderError = error.message
            }
        }
    }

    // MARK: Step 3

    var trimmedName: String { jobName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canCreate: Bool {
        !sourcePath.isEmpty && destination != nil && !trimmedName.isEmpty
    }

    /// The job "Create backup" would add, or nil while something is missing.
    var proposedJob: SyncJob? {
        guard canCreate else { return nil }
        return engine.proposedJob(name: trimmedName, source: sourcePath, remote: remote, remotePath: remotePath)
    }

    /// "Koffer will copy ~/Pictures to onedrive:Photos. Files you remove later are kept in _Photos_removed, never deleted."
    var summary: String? {
        guard let job = proposedJob else { return nil }
        let removed: String = DisplayNames.lastComponent(ofCloudPath: job.removedRoot)
        return "Koffer will copy \(DisplayNames.abbreviated(job.source)) to \(job.destination). "
            + "Files you remove later are kept in \(removed), never deleted."
    }

    /// Adds the job. Returns it on success; on refusal keeps the form and shows the reason.
    func create() -> SyncJob? {
        guard let job = proposedJob else { return nil }
        let verdict: SafetyVerdict = engine.addJob(job)
        if let reason = verdict.reason {
            refusal = reason
            return nil
        }
        refusal = nil
        return job
    }
}
