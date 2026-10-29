import SwiftUI

// One small design system for the whole window, after Microsoft Fluent 2 and Apple's Liquid
// Glass. From Fluent 2: the 4-point spacing grid, the type ramp (Caption, Body, Subtitle,
// Large title) and quiet layered cards with hairline strokes. From Liquid Glass: the glass
// itself, kept for what you touch (tiles, buttons, the segmented and switch controls) and the
// battery, never for the content underneath.

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

enum Radius {
    static let tile: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let toggle: CGFloat = 14
}

extension Font {
    /// Large title: the charge readout.
    static let uiReadout = Font.system(size: 34, weight: .semibold, design: .rounded)
    /// A number that matters inside a card.
    static let uiMetric = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// Subtitle: card and section titles.
    static let uiSection = Font.system(size: 13, weight: .semibold)
    /// Body.
    static let uiRow = Font.system(size: 13)
    /// Caption.
    static let uiDetail = Font.system(size: 11)
    static let uiCode = Font.system(size: 11, design: .monospaced)
}

extension View {
    /// A quiet layer for a group of rows: a faint fill with a hairline edge.
    func cardSurface(cornerRadius: CGFloat = Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.primary.opacity(0.045), in: shape)
            .overlay { shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
    }

    /// A tinted layer for messages, like a Fluent 2 message bar.
    func messageSurface(_ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return self
            .background(tint.opacity(0.1), in: shape)
            .overlay { shape.stroke(tint.opacity(0.28), lineWidth: 0.5) }
    }
}
