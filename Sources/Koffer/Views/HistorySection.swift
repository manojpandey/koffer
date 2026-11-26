import SwiftUI
import KofferCore

/// The last runs of this job: 5 by default, up to 20 with "Show all".
struct HistorySection: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    private static let rowHeight: CGFloat = 40

    var body: some View {
        let records: [RunRecord] = model.history(for: job)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Recent backups")
                Spacer(minLength: Theme.Space.s)
                if records.count > 5 {
                    let toggleTitle: String = model.showAllHistory ? "Show fewer" : "Show all"
                    Button(toggleTitle) {
                        model.showAllHistory.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            if model.showAllHistory && records.count > 5 {
                let all: [RunRecord] = Array(records.prefix(20))
                ScrollView(.vertical) {
                    HistoryRows(records: all)
                }
                .frame(height: min(CGFloat(all.count) * HistorySection.rowHeight, 240))
            } else {
                HistoryRows(records: Array(records.prefix(5)))
            }
        }
    }
}

private struct HistoryRows: View {
    let records: [RunRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(records) { (record: RunRecord) in
                HistoryRow(record: record)
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let record: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            OutcomeGlyph(outcome: record.outcome, hasErrors: record.errors > 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.relativeDay(record.endedAt, now: Date()))
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.xs)
            if let path = record.logPath {
                Button("Log") { model.revealLog(path) }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .help("Show the full log in Finder")
                    .accessibilityLabel("Show log in Finder")
            }
        }
    }

    private var detail: String {
        let summary: String = Format.summary(record)
        guard let message = record.message, !message.isEmpty, record.outcome != .completed else { return summary }
        return "\(message). \(summary)"
    }
}

/// Shape and colour both carry the outcome, so it never relies on colour alone.
struct OutcomeGlyph: View {
    let outcome: RunOutcome
    let hasErrors: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 16)
            .padding(.top, 1)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch outcome {
        case .completed: return hasErrors ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .completed: return hasErrors ? Theme.warning : Theme.success
        case .paused: return Color.secondary
        case .failed: return Theme.failure
        }
    }

    private var label: String {
        switch outcome {
        case .completed: return hasErrors ? "Finished with errors" : "Finished"
        case .paused: return "Paused"
        case .failed: return "Didn't finish"
        }
    }
}
