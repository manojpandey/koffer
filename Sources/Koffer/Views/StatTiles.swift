import SwiftUI
import KofferCore

/// New / Moved / Removed (and Errors only when there are some), for this run or the last one.
struct StatTiles: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let numbers: RunNumbers

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionTitle(numbers.isLive ? "This backup" : "Last backup")
            HStack(alignment: .top, spacing: Theme.Space.s) {
                StatTile(title: "New", value: numbers.uploaded, symbol: "plus", caption: "uploaded")
                StatTile(title: "Moved", value: numbers.moved, symbol: "arrow.turn.down.right",
                         caption: "not re-sent")
                StatTile(title: "Removed", value: numbers.removed, symbol: "archivebox",
                         caption: "kept in \(model.removedFolderName(for: job))")
                if numbers.errors > 0 {
                    StatTile(title: "Errors", value: numbers.errors, symbol: "exclamationmark.triangle",
                             caption: "see the log", tint: Theme.warning)
                }
            }
            if numbers.isThrottled {
                ThrottleNote()
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let symbol: String
    let caption: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint ?? Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(Format.count(value))
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Animation.easeOut(duration: 0.3), value: value)
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.tileFill)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(Format.count(value)), \(caption)")
    }
}

struct ThrottleNote: View {
    var body: some View {
        Label("OneDrive is slowing us down, still going", systemImage: "tortoise")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// Up to two files in flight, middle-truncated so both ends of the path stay readable.
struct CurrentFilesView: View {
    let files: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(files.prefix(2).enumerated()), id: \.offset) { item in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(item.element)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending \(files.prefix(2).joined(separator: ", "))")
    }
}
