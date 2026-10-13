import AppKit

/// The menu bar icon: a headphones glyph with a battery bar underneath.
///
/// Drawn rather than taken from SF Symbols, because no stock symbol pairs a
/// glyph with a live level indicator. Pairing them also keeps the item
/// distinguishable from the system Sound item, which shows a bare headphones
/// glyph whenever headphones are the output device.
///
/// The result is a template image: macOS ignores the colours and uses only the
/// alpha channel, so it inverts correctly in light and dark menu bars and when
/// the menu is pulled down. That is why the bar's empty track is drawn as
/// partial alpha rather than a grey.
enum StatusIcon {
    static let width: CGFloat = 20
    static let height: CGFloat = 18

    private static let barWidth: CGFloat = 16
    private static let barHeight: CGFloat = 2.5
    /// Breathing room between the glyph and the bar.
    private static let gap: CGFloat = 1

    /// The largest headphones glyph that still leaves room for the bar.
    ///
    /// Point size does not map to rendered height one-to-one, and the mapping
    /// is Apple's to change, so the size is measured rather than assumed: walk
    /// down from optimistic until one actually fits. 18pt total is the usable
    /// height inside a 24pt menu bar — overshoot it and the status button
    /// scales the image down, which reads as blurry rather than larger.
    private static func headphones(tint: NSColor) -> NSImage? {
        let available = height - barHeight - gap
        for pointSize in stride(from: CGFloat(16), through: CGFloat(10), by: -0.5) {
            var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            guard let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { continue }
            if symbol.size.height <= available, symbol.size.width <= width {
                return symbol
            }
        }
        return nil
    }

    /// - Parameter connectingPhase: 0...1 to draw an indeterminate sweep in
    ///   place of the battery fill. Opening the control channel can take
    ///   several seconds, and a still, dim icon is indistinguishable from "no
    ///   headphones here" — which is precisely the wrong thing to say while
    ///   we are in the middle of reaching them.
    static func image(batteryPercent: Int?, connected: Bool,
                      connectingPhase: Double? = nil, chargingPhase: Double? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            render(batteryPercent: batteryPercent, connected: connected,
                   tint: .black, connectingPhase: connectingPhase, chargingPhase: chargingPhase)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func render(batteryPercent: Int?, connected: Bool, tint: NSColor,
                               connectingPhase: Double? = nil, chargingPhase: Double? = nil) {
        // Headphones, centred along the top.
        if let symbol = headphones(tint: tint) {
            let size = symbol.size
            let origin = NSPoint(x: ((width - size.width) / 2).rounded(),
                                 y: height - size.height)
            symbol.draw(in: NSRect(origin: origin, size: size))
        }

        // Empty track, always drawn so the icon keeps a stable shape.
        let track = NSRect(x: ((width - barWidth) / 2).rounded(), y: 0,
                           width: barWidth, height: barHeight)
        tint.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        // A segment sweeping along the track: busy, with no false precision
        // about how far along we are.
        if let phase = connectingPhase {
            let segment = barWidth * 0.4
            let travel = barWidth + segment
            let x = track.minX - segment + travel * CGFloat(phase.truncatingRemainder(dividingBy: 1))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2)
                .addClip()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: segment, height: barHeight),
                         xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Fill, proportional to charge.
        guard connected, let percent = batteryPercent else { return }
        let fraction = CGFloat(max(0, min(100, percent))) / 100
        // Never narrower than the pill is tall, so a nearly flat battery still
        // reads as a dot rather than vanishing.
        let filledWidth = max(barHeight, (barWidth * fraction).rounded())

        // Charging breathes. A bolt would be the obvious choice, but at 2.5pt
        // tall it is an unreadable smudge; motion survives the size where a
        // glyph does not.
        if let phase = chargingPhase {
            let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase * 2 * .pi))
            tint.withAlphaComponent(pulse).setFill()
        } else {
            tint.setFill()
        }
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                         width: filledWidth, height: barHeight),
                     xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    /// Renders a scaled-up strip of the icon at several charge levels, on both
    /// a dark and a light background, so the design can be judged without
    /// squinting at the menu bar. Development aid; see `--icon-preview`.
    static func writePreview(to path: String) throws {
        let levels: [Int?] = [nil, 0, 5, 25, 50, 75, 100]
        let scale: CGFloat = 8
        let pad: CGFloat = 3
        let cell = NSSize(width: width + pad * 2, height: height + pad * 2)
        let total = NSSize(width: cell.width * CGFloat(levels.count) * scale,
                           height: cell.height * 2 * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(total.width), pixelsHigh: Int(total.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

        // Row 0 (bottom): light menu bar, dark glyph. Row 1 (top): the reverse.
        for (row, background) in [NSColor.white, NSColor(white: 0.15, alpha: 1)].enumerated() {
            background.setFill()
            NSRect(x: 0, y: CGFloat(row) * cell.height,
                   width: cell.width * CGFloat(levels.count), height: cell.height).fill()

            for (column, level) in levels.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: CGFloat(column) * cell.width + pad,
                                     yBy: CGFloat(row) * cell.height + pad)
                transform.concat()
                render(batteryPercent: level, connected: level != nil,
                       tint: row == 0 ? .black : .white)
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let glyph = headphones(tint: .black)?.size ?? .zero
        print(String(format: "menu bar thickness: %.1fpt, icon canvas: %.0fx%.0f, glyph: %.1fx%.1f, bar: %.1fpt",
                     NSStatusBar.system.thickness, width, height,
                     glyph.width, glyph.height, barHeight))

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
