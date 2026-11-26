import SwiftUI

/// One place for Koffer's look: spacing, radii and a monochrome palette.
///
/// Everything is drawn in the system label colour at different opacities, so the panel follows
/// light and dark mode exactly and stays calm. No gradients.
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
        static let lineWidth: CGFloat = 6
    }

    // MARK: Neutrals

    static let tileFill: Color = Color.primary.opacity(0.045)
    static let quietFill: Color = Color.primary.opacity(0.07)
    static let quietFillPressed: Color = Color.primary.opacity(0.13)
    static let track: Color = Color.primary.opacity(0.08)
    static let hairline: Color = Color.primary.opacity(0.08)

    // Status colours are always paired with a distinct symbol, never used alone.
    static let success: Color = Color.primary
    static let warning: Color = Color.orange
    static let failure: Color = Color.red

    // MARK: Ink (monochrome)

    /// The single "accent" is the system label colour: near-black in light mode, near-white in dark.
    /// No hues, no gradients. Colour appears only for warnings and failures.
    static let ink: Color = Color.primary

    /// Text and glyphs drawn on top of `ink`.
    static func onInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black : Color.white
    }

    // The functions below keep their old names so views did not have to change; they are all solid ink now.
    static func golden(_ scheme: ColorScheme) -> [Color] { [ink, ink] }

    static func goldenLinear(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: Gradient(colors: golden(scheme)), startPoint: .leading, endPoint: .trailing)
    }

    static func deep(_ scheme: ColorScheme) -> [Color] { [ink, ink, ink] }

    static func deepLinear(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: Gradient(colors: deep(scheme)), startPoint: .leading, endPoint: .trailing)
    }

    static func glowColors(_ scheme: ColorScheme) -> [Color] { [Color.clear, Color.clear] }
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
