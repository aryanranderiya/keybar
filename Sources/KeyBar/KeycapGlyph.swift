import AppKit

/// A single mechanical keycap seen from the front: the skirt, and the dished top sitting above it.
enum KeycapGlyph {
    static func image(pointSize: CGFloat, dimmed: Bool = false) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let unit = rect.width / 18
            let skirt = rect.insetBy(dx: 1.5 * unit, dy: 2 * unit)
            let top = NSRect(
                x: skirt.minX + 3 * unit,
                y: skirt.minY + 4.6 * unit,
                width: skirt.width - 6 * unit,
                height: skirt.height - 6.2 * unit
            )
            NSColor.black.withAlphaComponent(dimmed ? 0.45 : 1).setStroke()
            let outer = NSBezierPath(roundedRect: skirt, xRadius: 3.6 * unit, yRadius: 3.6 * unit)
            outer.lineWidth = 1.4 * unit
            outer.stroke()
            let inner = NSBezierPath(roundedRect: top, xRadius: 2.2 * unit, yRadius: 2.2 * unit)
            inner.lineWidth = 1.2 * unit
            inner.stroke()
            // Short bevels from the top face down to the skirt's lower corners give the cap its depth.
            let bevels = NSBezierPath()
            bevels.move(to: NSPoint(x: top.minX + 0.7 * unit, y: top.minY + 0.7 * unit))
            bevels.line(to: NSPoint(x: skirt.minX + 1.1 * unit, y: skirt.minY + 1.1 * unit))
            bevels.move(to: NSPoint(x: top.maxX - 0.7 * unit, y: top.minY + 0.7 * unit))
            bevels.line(to: NSPoint(x: skirt.maxX - 1.1 * unit, y: skirt.minY + 1.1 * unit))
            bevels.lineWidth = 1.0 * unit
            bevels.lineCapStyle = .round
            bevels.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
