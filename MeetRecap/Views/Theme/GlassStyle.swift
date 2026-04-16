import SwiftUI

/// Shared design tokens + modifiers for the macOS 26 Liquid Glass aesthetic.
///
/// Everything is guarded with `if #available(macOS 26.0, *)` so the app also
/// runs on older macOS with the older `regularMaterial` / `ultraThinMaterial`
/// fallbacks. Typography and metrics are tuned to feel like a first-party app.
enum GlassStyle {
    // Corners
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let chipRadius: CGFloat = 10

    // Accents
    static let primaryAccent = Color.accentColor
    static let recordTint = Color(nsColor: NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0))

    // Typography
    static let hero = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let sectionTitle = Font.system(size: 11, weight: .semibold, design: .rounded).smallCaps()
    static let displayNumber = Font.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit()
}

// MARK: - View modifiers

extension View {
    /// Apply a glass-surface background with rounded corners. Falls back to
    /// `.regularMaterial` on pre-26 systems.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = GlassStyle.cardRadius, tinted: Bool = false) -> some View {
        self
            .background(
                _GlassBackground(cornerRadius: cornerRadius, tinted: tinted)
            )
    }

    /// Slim glass pill — used for buttons and chips inside glass cards.
    @ViewBuilder
    func glassChip(cornerRadius: CGFloat = GlassStyle.chipRadius) -> some View {
        self.background(
            _GlassBackground(cornerRadius: cornerRadius, tinted: false)
        )
    }

    /// Subtle hairline border that looks right over glass surfaces.
    func glassStroke(cornerRadius: CGFloat = GlassStyle.cardRadius, opacity: Double = 0.10) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(opacity), lineWidth: 0.5)
        )
    }
}

private struct _GlassBackground: View {
    let cornerRadius: CGFloat
    let tinted: Bool

    var body: some View {
        if #available(macOS 26.0, *) {
            // Native Liquid Glass
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tinted ? Color.accentColor.opacity(0.12) : Color.clear)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tinted ? Color.accentColor.opacity(0.10) : Color.clear)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
