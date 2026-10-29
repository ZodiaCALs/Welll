import AppKit

/// The menu bar battery in the style of macOS 26: a rounded body whose charged part is solid
/// and whose empty part is translucent, a small terminal, and a bolt (charging) or plug (on
/// power, not charging) cut out of the middle. The percentage is the status item's title,
/// outside the icon on the left.
enum StatusIcon {
    private static let size = NSSize(width: 26, height: 12)
    private static let body = NSRect(x: 0, y: 0, width: 23, height: 12)
    private static let terminal = NSRect(x: 23.75, y: 3.75, width: 2, height: 4.5)
    private static let radius: CGFloat = 4

    static func image(percent: Int?, limit: Int?, charging: Bool, pluggedIn: Bool, lowPower: Bool) -> NSImage {
        let level = CGFloat(min(max(percent ?? 0, 0), 100)) / 100
        let lowBattery = !pluggedIn && (percent ?? 100) <= 10
        // Template images adapt to the menu bar like the system icon; the coloured states
        // draw in label colour instead, which resolves when the icon is drawn.
        let template = !lowBattery && !lowPower
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = template ? NSColor.black : NSColor.labelColor
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

            // The empty part and the terminal, translucent.
            ink.withAlphaComponent(0.35).setFill()
            shape.fill()
            NSBezierPath(roundedRect: terminal, xRadius: 1, yRadius: 1).fill()

            // The charge, solid, clipped to the body so its right edge stays straight.
            if level > 0 {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                var fill = body
                fill.size.width = max(body.width * level, 2)
                (lowBattery ? NSColor.systemRed : (lowPower ? NSColor.systemYellow : ink)).setFill()
                fill.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Optional notch at the charge limit.
            if let limit, limit < 100 {
                let x = (body.minX + body.width * CGFloat(limit) / 100).rounded()
                NSColor.black.setFill()
                NSRect(x: x - 0.5, y: body.minY, width: 1, height: body.height).fill(using: .destinationOut)
            }

            if charging {
                cutOut("bolt.fill")
            } else if pluggedIn {
                cutOut("powerplug.fill")
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = percent.map { "Battery \($0) percent" } ?? "Battery"
        return image
    }

    /// Punches a symbol out of the middle of the battery, as macOS does with its bolt.
    private static func cutOut(_ name: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .heavy)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let glyph = symbol.size
        let rect = NSRect(x: (body.midX - glyph.width / 2).rounded(),
                          y: (body.midY - glyph.height / 2).rounded(),
                          width: glyph.width, height: glyph.height)
        symbol.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
    }
}
