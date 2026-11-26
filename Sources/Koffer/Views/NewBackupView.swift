import AppKit
import SwiftUI
import KofferCore

// MARK: - Opening the window

/// "New backup…" in its three looks: a small plus in the job picker, a footer link, or the primary button.
struct NewBackupButton: View {
    enum Look { case icon, footer, prominent }

    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let style: Look

    var body: some View {
        switch style {
        case .icon:
            Button(action: openNewBackup) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New backup\u{2026}")
            .accessibilityLabel("New backup")
        case .footer:
            Button(action: openNewBackup) {
                Label("New backup\u{2026}", systemImage: "plus")
            }
        case .prominent:
            Button("New backup\u{2026}", action: openNewBackup)
                .buttonStyle(GradientButtonStyle())
        }
    }

    private func openNewBackup() {
        model.prepareNewBackup()
        openWindow(id: NewBackupView.windowID)
        // Koffer has no Dock icon, so bring the new window to the front explicitly.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - The window

/// Root of the "New backup" window scene.
struct NewBackupView: View {
    static let windowID: String = "new-backup"
    static let size: CGSize = CGSize(width: 520, height: 620)

    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NewBackupForm(flow: model.newBackup, close: close)
            .frame(width: NewBackupView.size.width, height: NewBackupView.size.height)
            .onAppear { appeared() }
            .onDisappear { disappeared() }
            .onChange(of: model.engine.remotes) { (_: [String], remotes: [String]) in
                model.newBackup.adoptRemotes(remotes)
            }
    }

    private func appeared() {
        let flow: NewBackupModel = model.newBackup
        if !flow.wasRequested {
            // Opened by the system (launch or window restoration), not by the user: close it again.
            DispatchQueue.main.async { dismissWindow(id: NewBackupView.windowID) }
            return
        }
        flow.isOpen = true
        flow.adoptRemotes(model.engine.remotes)
    }

    private func disappeared() {
        model.newBackup.isOpen = false
        model.newBackup.wasRequested = false
    }

    private func close() {
        dismissWindow(id: NewBackupView.windowID)
    }
}

/// One screen, three numbered steps, buttons pinned at the bottom.
struct NewBackupForm: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: NewBackupModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Pick a folder, pick where it goes, and Koffer keeps a copy safe in the cloud.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SourceStep(flow: flow)
                    CloudStep(flow: flow)
                    NameStep(flow: flow)
                }
                .padding(Theme.Space.xl)
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
            NewBackupButtons(flow: flow, onCancel: close, onCreate: create)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
        }
    }

    private func create() {
        guard let job = flow.create() else { return }
        model.didCreate(job)
        close()
    }
}

private struct NewBackupButtons: View {
    @ObservedObject var flow: NewBackupModel
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button("Cancel", action: onCancel)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                .frame(width: 120)
            Button("Create backup", action: onCreate)
                .buttonStyle(GradientButtonStyle())
                .disabled(!flow.canCreate)
        }
    }
}

// MARK: - Step chrome

/// A numbered step in the existing card style.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let content: () -> Content

    init(number: Int, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.number = number
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StepHeader(number: number, title: title)
            content()
        }
        .quietCard(padding: Theme.Space.l)
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.quietFill))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityLabel("Step \(number): \(title)")
                .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - Step 1: folder on this Mac

private struct SourceStep: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        StepCard(number: 1, title: "Folder on this Mac") {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(sourceText)
                    .font(.system(size: 13))
                    .foregroundStyle(hasSource ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(flow.sourcePath)
                Spacer(minLength: Theme.Space.s)
                Button("Choose\u{2026}") { flow.chooseSource() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }

    private var hasSource: Bool { !flow.sourcePath.isEmpty }

    private var sourceText: String {
        hasSource ? DisplayNames.abbreviated(flow.sourcePath) : "No folder chosen yet"
    }
}

// MARK: - Step 2: where in the cloud

private struct CloudStep: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        StepCard(number: 2, title: "Where in the cloud") {
            if flow.remote.isEmpty {
                NoCloudNote()
            } else {
                CloudBrowser(flow: flow)
            }
        }
    }
}

/// Shown until Koffer knows which cloud storage it can use.
private struct NoCloudNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.engine.rclonePath != nil {
                Button("Check again") { model.refreshConnection() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }

    private var message: String {
        if model.engine.rclonePath == nil {
            return "Finish the setup step in the Koffer menu first, then come back here."
        }
        return "Looking for your cloud storage\u{2026}"
    }
}

private struct CloudBrowser: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if model.engine.remotes.count > 1 {
                AccountPicker(flow: flow)
            }
            CrumbBar(flow: flow)
            FolderListBox(flow: flow)
            NewFolderRow(flow: flow)
            DestinationLine(flow: flow)
        }
    }
}

private struct AccountPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        Picker("Cloud storage", selection: remoteBinding) {
            ForEach(model.engine.remotes, id: \.self) { (remote: String) in
                Text(DisplayNames.friendly(remote: remote)).tag(remote)
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .fixedSize()
    }

    private var remoteBinding: Binding<String> {
        let flow: NewBackupModel = self.flow
        return Binding<String>(
            get: { flow.remote },
            set: { (remote: String) in flow.chooseRemote(remote) }
        )
    }
}

/// One step of the breadcrumb.
private struct Crumb: Identifiable {
    let depth: Int
    let title: String
    var id: Int { depth }
}

/// Up button, then "OneDrive › Photos › 2026", each part clickable.
private struct CrumbBar: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        let crumbs: [Crumb] = makeCrumbs()
        let lastDepth: Int = flow.pathComponents.count
        HStack(spacing: Theme.Space.s) {
            Button { flow.goUp() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .disabled(flow.isAtRoot)
            .help("Up one folder")
            .accessibilityLabel("Up one folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(crumbs) { (crumb: Crumb) in
                        CrumbButton(crumb: crumb, isCurrent: crumb.depth == lastDepth) {
                            flow.goTo(depth: crumb.depth)
                        }
                    }
                }
            }
        }
    }

    private func makeCrumbs() -> [Crumb] {
        var result: [Crumb] = [Crumb(depth: 0, title: DisplayNames.friendly(remote: flow.remote))]
        var depth: Int = 0
        for name in flow.pathComponents {
            depth += 1
            result.append(Crumb(depth: depth, title: name))
        }
        return result
    }
}

private struct CrumbButton: View {
    let crumb: Crumb
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if crumb.depth > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Button(action: action) {
                Text(crumb.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCurrent ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
        }
    }
}

/// The folders at the current place, with loading, error and empty states.
private struct FolderListBox: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        content
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(shape.fill(Color.primary.opacity(0.03)))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(shape)
    }

    @ViewBuilder
    private var content: some View {
        if flow.isLoading {
            HStack(spacing: Theme.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading folders\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if let error = flow.loadError {
            VStack(spacing: Theme.Space.s) {
                TaskFailureText(message: error)
                Button("Try again") { flow.loadFolders() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(Theme.Space.m)
        } else if flow.folders.isEmpty {
            Text("No folders here yet. You can make one below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            FolderList(flow: flow)
        }
    }
}

private struct FolderList: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(flow.folders, id: \.self) { (name: String) in
                    FolderRow(name: name,
                              isSelected: flow.selectedFolder == name,
                              onSelect: { flow.toggleSelection(name) },
                              onEnter: { flow.enter(name) })
                }
            }
            .padding(4)
        }
    }
}

/// Click to choose, double-click or the chevron to open.
private struct FolderRow: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onEnter: () -> Void

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            Button(action: onEnter) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(name)")
            .accessibilityLabel("Open \(name)")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 4)
        .background(shape.fill(isSelected ? Theme.quietFillPressed : Color.clear))
        .contentShape(shape)
        .onTapGesture(count: 2, perform: onEnter)
        .onTapGesture(count: 1, perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityAction(named: "Open", onEnter)
    }
}

/// "New folder" name field plus "Create"; on success Koffer opens the new folder.
private struct NewFolderRow: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("New folder", text: $flow.newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { flow.createFolder() }
                if flow.isCreatingFolder {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Create") { flow.createFolder() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(!flow.canCreateFolder)
            }
            if let error = flow.folderError {
                TaskFailureText(message: error)
            }
        }
    }
}

/// "Backs up into onedrive:Photos/2026", or a gentle note while still at the top.
private struct DestinationLine: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        if let destination = flow.destination {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Backs up into \(destination)")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.system(size: 12, weight: .medium))
        } else {
            Text("Choose or open a folder. Koffer doesn\u{2019}t back up into the top level of \(DisplayNames.friendly(remote: flow.remote)).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 3: name

private struct NameStep: View {
    @ObservedObject var flow: NewBackupModel

    var body: some View {
        StepCard(number: 3, title: "Name") {
            TextField("Name", text: $flow.jobName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let refusal = flow.refusal {
                AttentionCard(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                              title: "Koffer can\u{2019}t set this up", message: refusal) {
                    EmptyView()
                }
            }
        }
    }

    private var summaryText: String {
        if let summary = flow.summary { return summary }
        if flow.trimmedName.isEmpty && !flow.sourcePath.isEmpty { return "Give this backup a name." }
        return "Choose a folder and a place in the cloud, and Koffer will tell you exactly what it does."
    }
}
