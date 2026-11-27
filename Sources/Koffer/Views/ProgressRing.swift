import SwiftUI
import AppKit
import KofferCore

/// The progress ring: a neutral track, a golden-hour arc with round caps, and a calm centre.
struct HeroRing: View {
    let phase: JobPhase
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: Theme.Ring.lineWidth)
            RingFill(phase: phase, fraction: fraction)
            RingCenter(phase: phase, fraction: fraction)
        }
        .frame(width: Theme.Ring.diameter, height: Theme.Ring.diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Backup progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch phase {
        case .syncing:
            if let f = fraction { return "\(Int((f * 100).rounded(.down))) percent" }
            return "Starting"
        case .working(let step):
            if let f = fraction { return "\(step), \(Int((f * 100).rounded(.down))) percent compared" }
            return step
        case .done: return "Everything is backed up"
        case .paused: return "Paused"
        case .attention: return "Needs your attention"
        case .setup(let text): return text
        case .off: return "Switched off"
        case .waitingForDisk(let volume): return "Waiting for \(volume)"
        case .busyElsewhere: return "Waiting its turn"
        case .notYet: return "Not backed up yet"
        }
    }
}

private struct RingFill: View {
    let phase: JobPhase
    let fraction: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch phase {
        case .syncing:
            GradientArc(fraction: fraction ?? 0)
        case .working:
            if let f = fraction {
                // Files compared so far (a rough guide: the total can still grow while rclone lists).
                GradientArc(fraction: f)
            } else {
                SpinningArc()
            }
        case .paused:
            GradientArc(fraction: fraction ?? 0)
                .saturation(0)
                .opacity(0.45)
        case .done:
            Circle()
                .fill(Theme.deepLinear(scheme))
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        case .setup, .off, .waitingForDisk, .busyElsewhere, .attention, .notYet:
            EmptyView()
        }
    }
}

/// Trimmed arc whose gradient always runs amber -> violet across the part that is drawn.
struct GradientArc: View {
    let fraction: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown: Double = max(0.0, min(1.0, fraction))
        let colors: [Color] = Theme.golden(scheme)
        let style: StrokeStyle = StrokeStyle(lineWidth: Theme.Ring.lineWidth, lineCap: .round)
        let gradient: AngularGradient = AngularGradient(
            gradient: Gradient(colors: colors), center: .center,
            startAngle: .degrees(0), endAngle: .degrees(360.0 * max(shown, 0.02)))
        ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(shown))
                .stroke(gradient, style: style)
                .rotationEffect(.degrees(-90))
            // Covers the start cap so it shows the first colour, not the wrap-around.
            if shown > 0.001 {
                Circle()
                    .fill(colors[0])
                    .frame(width: Theme.Ring.lineWidth, height: Theme.Ring.lineWidth)
                    .offset(y: -Theme.Ring.diameter / 2)
            }
        }
        .animation(reduceMotion ? nil : Animation.spring(response: 0.7, dampingFraction: 0.85), value: shown)
    }
}

/// Short arc that circles while Koffer gets ready. Static when Reduce Motion is on.
struct SpinningArc: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            arc(angle: angle(at: context.date))
        }
    }

    private func angle(at date: Date) -> Double {
        if reduceMotion { return 0.0 }
        return (date.timeIntervalSinceReferenceDate * 140.0).truncatingRemainder(dividingBy: 360.0)
    }

    private func arc(angle: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(
                AngularGradient(gradient: Gradient(colors: Theme.golden(scheme)), center: .center,
                                startAngle: .degrees(0), endAngle: .degrees(80)),
                style: StrokeStyle(lineWidth: Theme.Ring.lineWidth, lineCap: .round))
            .rotationEffect(.degrees(angle - 90.0))
    }
}

/// Percent while backing up, a checkmark when done, a quiet glyph otherwise.
private struct RingCenter: View {
    let phase: JobPhase
    let fraction: Double?

    var body: some View {
        switch phase {
        case .syncing:
            Text(percentText)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Animation.easeOut(duration: 0.3), value: percentText)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(nsColor: NSColor.windowBackgroundColor))
        case .working:
            glyph("suitcase.fill", .secondary)
        case .paused:
            glyph("pause.fill", .secondary)
        case .attention, .setup:
            glyph("exclamationmark", Theme.warning)
        case .off:
            glyph("eye.slash", .tertiary)
        case .waitingForDisk:
            glyph("externaldrive", .tertiary)
        case .busyElsewhere, .notYet:
            glyph("suitcase", .tertiary)
        }
    }

    private var percentText: String {
        guard let f = fraction else { return "…" }
        return "\(Int((f * 100).rounded(.down)))%"
    }

    private func glyph<S: ShapeStyle>(_ name: String, _ style: S) -> some View {
        Image(systemName: name)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(style)
    }
}
