import SwiftUI
import KofferCore

/// Result of "What will change?": one summary line and an expandable list per kind.
struct PreviewSection: View {
    let preview: PreviewResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("What will change")
                Spacer(minLength: Theme.Space.s)
                Text(Format.relativeDay(preview.date, now: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(PreviewSection.summary(preview))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if !preview.isEmpty {
                PreviewGroups(preview: preview)
            }
        }
        .quietCard()
    }

    static func summary(_ p: PreviewResult) -> String {
        if p.isEmpty { return "Nothing to change. It's all backed up already." }
        var parts: [String] = ["\(Format.count(p.count(.new))) new"]
        let replaced: Int = p.count(.replaced)
        if replaced > 0 { parts.append("\(Format.count(replaced)) changed") }
        parts.append("\(Format.count(p.count(.moved))) moved")
        parts.append("\(Format.count(p.count(.removed))) removed")
        parts.append("\(Format.bytes(p.uploadBytes)) to upload")
        return parts.joined(separator: ", ")
    }
}

private struct PreviewGroups: View {
    @EnvironmentObject var model: AppModel
    let preview: PreviewResult
    static let kinds: [ChangeKind] = [.new, .replaced, .moved, .removed]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(PreviewGroups.kinds, id: \.self) { (kind: ChangeKind) in
                if preview.count(kind) > 0 {
                    DisclosureGroup(isExpanded: expandedBinding(kind)) {
                        ChangeList(kind: kind, items: preview.items(kind))
                    } label: {
                        Text("\(ChangeList.title(kind)) (\(Format.count(preview.count(kind))))")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
    }

    private func expandedBinding(_ kind: ChangeKind) -> Binding<Bool> {
        let key: String = kind.rawValue
        let model: AppModel = self.model
        return Binding<Bool>(
            get: { model.expandedKinds.contains(key) },
            set: { (on: Bool) in
                if on { _ = model.expandedKinds.insert(key) } else { _ = model.expandedKinds.remove(key) }
            }
        )
    }
}

/// Up to 200 rows per kind, scrolling inside a fixed height, then "and N more".
struct ChangeList: View {
    let kind: ChangeKind
    let items: [ChangeItem]
    static let cap: Int = 200

    var body: some View {
        let shown: [ChangeItem] = Array(items.prefix(ChangeList.cap))
        let rowHeight: CGFloat = kind == .moved ? 32 : 18
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { (item: ChangeItem) in
                        ChangeRow(item: item)
                    }
                }
            }
            .frame(height: min(CGFloat(shown.count) * rowHeight + 4, 168))
            if items.count > ChangeList.cap {
                Text("and \(Format.count(items.count - ChangeList.cap)) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    static func title(_ kind: ChangeKind) -> String {
        switch kind {
        case .new: return "New"
        case .replaced: return "Changed"
        case .moved: return "Moved"
        case .removed: return "Removed"
        }
    }
}

private struct ChangeRow: View {
    let item: ChangeItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if item.kind == .moved, let newPath = item.newPath {
                VStack(alignment: .leading, spacing: 1) {
                    pathText(newPath, primary: true)
                    pathText("from \(item.path)", primary: false)
                }
            } else {
                pathText(item.path, primary: true)
            }
            Spacer(minLength: Theme.Space.xs)
            if let size = item.size, item.kind != .moved {
                Text(Format.bytes(size))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pathText(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(primary ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
