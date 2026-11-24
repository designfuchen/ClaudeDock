import AppKit

/// The menu bar glyph: the app icon's card stack and quota ring, redrawn as a crisp template image
/// so macOS tints it for light, dark and highlighted menu bars.
@MainActor
enum MenuBarIcon {
    enum Badge {
        case none
        /// Something needs the user: an exit incident or a paused account.
        case attention
        /// A quota is running low.
        case quota
    }

    private static var cache: [String: NSImage] = [:]

    /// Remaining quota (0–100) drawn on the ring; nil draws a full outline ring.
    static func image(badge: Badge, remaining: Double?) -> NSImage {
        // Quantise so the cache stays tiny and the ring only redraws on visible change.
        let bucket = remaining.map { Int(($0 / 12.5).rounded()) } ?? -1
        let key = "\(badge)-\(bucket)"
        if let cached = cache[key] { return cached }

        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            // Back cards peeking above the front card.
            // Each card is knocked out of the one behind it, so translucent layers never stack into a muddy band.
            let back = CGRect(x: 5.5, y: 13.4, width: 9, height: 3.4)
            let middle = CGRect(x: 3.5, y: 11.0, width: 13, height: 4.0)
            ctx.setAlpha(0.4)
            ctx.addPath(CGPath(roundedRect: back, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
            ctx.setAlpha(1)
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: middle.insetBy(dx: -0.9, dy: -0.9), cornerWidth: 2.6, cornerHeight: 2.6, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.setAlpha(0.7)
            ctx.addPath(CGPath(roundedRect: middle, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
            ctx.fillPath()
            ctx.setAlpha(1)

            // Front card, knocked out of the cards behind it.
            let front = CGRect(x: 1.5, y: 1.5, width: 17, height: 10.5)
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: front.insetBy(dx: -1.1, dy: -1.1), cornerWidth: 3.6, cornerHeight: 3.6, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(1.4)
            ctx.addPath(CGPath(roundedRect: front.insetBy(dx: 0.7, dy: 0.7), cornerWidth: 2.6, cornerHeight: 2.6, transform: nil))
            ctx.strokePath()

            // Quota ring.
            let c = CGPoint(x: 6.6, y: front.midY)
            let r: CGFloat = 2.5
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.5)
            ctx.setAlpha(0.35)
            ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            ctx.setAlpha(1)
            let fraction = max(0.08, min(1, (remaining ?? 100) / 100))
            ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * fraction, clockwise: true)
            ctx.strokePath()

            // Name lines.
            ctx.addPath(CGPath(roundedRect: CGRect(x: 10.6, y: front.midY + 0.6, width: 5.6, height: 1.5), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
            ctx.fillPath()
            ctx.setAlpha(0.5)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 10.6, y: front.midY - 2.4, width: 3.6, height: 1.3), cornerWidth: 0.65, cornerHeight: 0.65, transform: nil))
            ctx.fillPath()
            ctx.setAlpha(1)

            // Badge: punched-out ring with a solid dot (attention) or a hollow dot (quota).
            if badge != .none {
                let b = CGPoint(x: 16.4, y: 14.6)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: b.x - 4.0, y: b.y - 4.0, width: 8.0, height: 8.0))
                ctx.setBlendMode(.normal)
                if badge == .attention {
                    ctx.fillEllipse(in: CGRect(x: b.x - 2.7, y: b.y - 2.7, width: 5.4, height: 5.4))
                } else {
                    ctx.setLineWidth(1.4)
                    ctx.strokeEllipse(in: CGRect(x: b.x - 2.2, y: b.y - 2.2, width: 4.4, height: 4.4))
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClaudeDock"
        cache[key] = image
        return image
    }
}
