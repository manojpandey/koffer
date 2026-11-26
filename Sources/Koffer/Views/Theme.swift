import SwiftUI

/// One place for Koffer's look: spacing, radii, neutrals and the single "golden hour" accent.
///
/// The gradient is the only accent in the app. It is used in exactly three places:
/// the progress ring, the soft glow behind it, and the primary button. Everything else
/// stays in quiet, semantic neutrals so the gradient always means "this is the backup".
enum Theme {

    // MARK: Layout

    static let panelWidth: CGFloat = 360
    static let maxPanelHeight: CGFloat = 560

    /// 8-pt grid (with a 4-pt half step for tight text stacks).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let button: CGFloat = 10
        static let card: CGFloat = 12
        static let hero: CGFloat = 16
    }

    enum Ring {
        static let diameter: CGFloat = 96
        static let lineWidth: CGFloat = 9
    }

    // MARK: Neutrals

    static let tileFill: Color = Color.primary.opacity(0.045)
    static let quietFill: Color = Color.primary.opacity(0.07)
    static let quietFillPressed: Color = Color.primary.opacity(0.13)
    static let track: Color = Color.primary.opacity(0.08)
    static let hairline: Color = Color.primary.opacity(0.08)

    // Status colours are always paired with a distinct symbol, never used alone.
    static let success: Color = Color.green
    static let warning: Color = Color.orange
    static let failure: Color = Color.red

    // MARK: Golden hour

    /// Amber -> coral -> rose -> a touch of violet. Slightly desaturated in dark mode.
    static func golden(_ scheme: ColorScheme) -> [Color] {
        if scheme == .dark {
            return [
                Color(red: 0.93, green: 0.69, blue: 0.38),
                Color(red: 0.92, green: 0.51, blue: 0.41),
                Color(red: 0.86, green: 0.41, blue: 0.53),
                Color(red: 0.62, green: 0.49, blue: 0.90),
            ]
        }
        return [
            Color(red: 1.00, green: 0.70, blue: 0.28),
            Color(red: 1.00, green: 0.48, blue: 0.35),
            Color(red: 0.95, green: 0.33, blue: 0.49),
            Color(red: 0.61, green: 0.42, blue: 1.00),
        ]
    }

    static func goldenLinear(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: Gradient(colors: golden(scheme)),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Deeper stops of the same blend, so white text and glyphs on it stay above 4.5:1.
    static func deep(_ scheme: ColorScheme) -> [Color] {
        if scheme == .dark {
            return [
                Color(red: 0.76, green: 0.32, blue: 0.22),
                Color(red: 0.71, green: 0.24, blue: 0.40),
                Color(red: 0.48, green: 0.31, blue: 0.76),
            ]
        }
        return [
            Color(red: 0.80, green: 0.30, blue: 0.18),
            Color(red: 0.76, green: 0.20, blue: 0.40),
            Color(red: 0.50, green: 0.28, blue: 0.80),
        ]
    }

    static func deepLinear(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: Gradient(colors: deep(scheme)),
                       startPoint: .leading, endPoint: .trailing)
    }

    static func glowColors(_ scheme: ColorScheme) -> [Color] {
        let base: [Color] = golden(scheme)
        return base + [base[0]]   // closes the loop so a rotating angular gradient has no seam
    }
}

// MARK: - Small shared building blocks

/// A quiet section heading: sentence case, secondary, no all-caps.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Soft neutral container used for tiles and sections.
    func quietCard(padding: CGFloat = Theme.Space.m) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.tileFill)
            )
    }
}
