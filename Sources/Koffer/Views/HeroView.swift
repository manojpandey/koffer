import SwiftUI
import KofferCore

/// The ring, the glow behind it, and the numbers that explain it.
struct HeroView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let job: SyncJob

    var body: some View {
        let phase: JobPhase = model.phase(for: job)
        HStack(alignment: .center, spacing: Theme.Space.l) {
            HeroRing(phase: phase, fraction: model.engine.progress.fraction)
                .background(HeroGlow(intensity: glowIntensity(phase), isActive: phase == .syncing))
            HeroDetails(job: job, phase: phase)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(Theme.tileFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
    }

    private func glowIntensity(_ phase: JobPhase) -> Double {
        let dim: Double = scheme == .dark ? 0.8 : 1.0
        switch phase {
        case .syncing: return 0.55 * dim
        case .done: return 0.35 * dim
        case .working: return 0.30 * dim
        case .setup, .off, .waitingForDisk, .busyElsewhere, .paused, .attention, .notYet: return 0.12 * dim
        }
    }
}

/// Soft, blurred golden-hour light behind the ring. Rotates slowly while backing up.
struct HeroGlow: View {
    let intensity: Double
    let isActive: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: true)) { context in
            glow(angle: angle(at: context.date))
        }
        .animation(reduceMotion ? nil : Animation.easeInOut(duration: 0.8), value: intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isMoving: Bool { isActive && !reduceMotion }

    private func angle(at date: Date) -> Double {
        guard isMoving else { return 0.0 }
        return (date.timeIntervalSinceReferenceDate * 14.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// The coloured glow is gone (monochrome design); this keeps the layout slot without drawing anything.
    private func glow(angle: Double) -> some View {
        Color.clear.frame(width: 130, height: 130)
    }
}

/// The numbers next to the ring.
struct HeroDetails: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let phase: JobPhase

    var body: some View {
        if phase == .syncing {
            SyncingDetails(progress: model.engine.progress)
        } else {
            RestingDetails(job: job, phase: phase, last: model.lastRecord(for: job))
        }
    }
}

struct SyncingDetails: View {
    let progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(bytesLine)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(filesLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if progress.speed > 0 {
                Text(Format.speed(progress.speed))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !Format.eta(progress.etaSeconds).isEmpty {
                Text(Format.eta(progress.etaSeconds))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Label("Keep the lid open", systemImage: "laptopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .animation(Animation.easeOut(duration: 0.3), value: progress.bytesDone)
    }

    private var bytesLine: String {
        guard progress.bytesTotal > 0 else { return "Working out what to send…" }
        return "\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))"
    }

    private var filesLine: String {
        if progress.filesTotal > 0 {
            return "\(Format.count(progress.filesDone)) of \(Format.count(progress.filesTotal)) files"
        }
        return "Checked \(Format.count(progress.checksDone)) files"
    }
}

struct RestingDetails: View {
    let job: SyncJob
    let phase: JobPhase
    let last: RunRecord?

    var body: some View {
        let lines: (String, String?) = text
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(lines.0)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = lines.1 {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = last, phase != .done {
                Text("Last backup \(Format.relativeDay(last.endedAt, now: Date()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var text: (String, String?) {
        switch phase {
        case .done:
            if let last = last {
                return ("All safe", "Last backup \(Format.relativeDay(last.endedAt, now: Date()))")
            }
            return ("All safe", nil)
        case .working(let step): return (step, "This only takes a moment.")
        case .paused(let why): return ("Paused", why.isEmpty ? "Picks up where it stopped." : why)
        case .off: return ("Switched off", "Switch it on in Settings below.")
        case .waitingForDisk(let volume):
            let how: String = job.autoSyncOnMount ? "Backs up by itself when you plug it in." : "Plug it in, then press Back up now."
            return ("Waiting for \(volume)", how)
        case .busyElsewhere(let name): return ("Waiting its turn", "Koffer is backing up \(name).")
        case .attention: return ("Needs a look", "Details above.")
        case .setup: return ("Almost ready", "One step above, then you're set.")
        case .notYet:
            if !job.isTest && !job.previewApproved { return ("Ready", "Start with What will change?") }
            return ("Ready", "Press Back up now to start.")
        case .syncing: return ("Backing up", nil)
        }
    }
}
