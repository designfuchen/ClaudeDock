import AppKit
import Foundation

/// Renders crisp macOS launcher `.icns` icons using native CoreGraphics / AppKit (zero external deps, no bundled Anthropic assets).
public enum IconRenderer {
    public static func renderICNS(
        style: IconStyle,
        label: String,
        colorHex: String,
        claudeAppURL: URL?,
        outputICNSURL: URL
    ) throws {
        let letter = String(label.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let badgeChar = letter.isEmpty ? "C" : letter
        let color = nsColor(fromHex: colorHex) ?? NSColor(srgbRed: 0.23, green: 0.44, blue: 0.85, alpha: 1.0)

        let pngData = try renderPNGData(
            style: style,
            letter: badgeChar,
            color: color,
            claudeAppURL: claudeAppURL
        )

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("claudedock-icon-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let masterPNG = tmpDir.appendingPathComponent("master.png")
        try pngData.write(to: masterPNG)

        let iconsetDir = tmpDir.appendingPathComponent("icon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

        for sz in [16, 32, 128, 256, 512] {
            let out1x = iconsetDir.appendingPathComponent("icon_\(sz)x\(sz).png")
            let out2x = iconsetDir.appendingPathComponent("icon_\(sz)x\(sz)@2x.png")
            try runTool("/usr/bin/sips", args: ["-z", "\(sz)", "\(sz)", masterPNG.path, "--out", out1x.path])
            try runTool("/usr/bin/sips", args: ["-z", "\(sz * 2)", "\(sz * 2)", masterPNG.path, "--out", out2x.path])
        }

        try? fm.removeItem(at: outputICNSURL)
        try runTool("/usr/bin/iconutil", args: ["-c", "icns", iconsetDir.path, "-o", outputICNSURL.path])

        guard fm.fileExists(atPath: outputICNSURL.path) else {
            throw DockError.launcherOperationFailed("iconutil did not produce \(outputICNSURL.path)")
        }
    }

    public static func renderPNGData(
        style: IconStyle,
        letter: String,
        color: NSColor,
        claudeAppURL: URL?
    ) throws -> Data {
        let size = 1024
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw DockError.launcherOperationFailed("Failed allocating bitmap context")
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw DockError.launcherOperationFailed("Failed creating NSGraphicsContext")
        }
        NSGraphicsContext.current = ctx

        let effectiveStyle: IconStyle
        var baseImage: NSImage?
        switch style {
        case .claudeBadge:
            if let appURL = claudeAppURL, FileManager.default.fileExists(atPath: appURL.path) {
                baseImage = NSWorkspace.shared.icon(forFile: appURL.path)
                effectiveStyle = .claudeBadge
            } else {
                effectiveStyle = .letter
            }
        case .image(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            if let img = NSImage(contentsOfFile: expanded), img.size.width > 0 {
                baseImage = img
                effectiveStyle = .image(path: expanded)
            } else {
                effectiveStyle = .letter
            }
        case .letter:
            effectiveStyle = .letter
        }

        switch effectiveStyle {
        case .letter:
            // Modern macOS squircle with subtle top-to-bottom gradient
            let rect = NSRect(x: 96, y: 96, width: 832, height: 832)
            let path = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
            let lighter = color.blended(withFraction: 0.16, of: .white) ?? color
            let darker = color.blended(withFraction: 0.14, of: .black) ?? color
            if let gradient = NSGradient(starting: darker, ending: lighter) {
                gradient.draw(in: path, angle: 90)
            } else {
                color.setFill()
                path.fill()
            }
            drawCenteredText(letter, fontSize: 480, center: NSPoint(x: 512, y: 512))

        case .claudeBadge:
            if let img = baseImage {
                let w = img.size.width
                let h = img.size.height
                let scale = CGFloat(size) / max(w, h)
                let dw = w * scale
                let dh = h * scale
                img.draw(
                    in: NSRect(x: (CGFloat(size) - dw) / 2, y: (CGFloat(size) - dh) / 2, width: dw, height: dh),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }
            // Crisp white halo + colored circular badge at bottom-right
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 556, y: 42, width: 430, height: 430)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 582, y: 68, width: 378, height: 378)).fill()
            drawCenteredText(letter, fontSize: 245, center: NSPoint(x: 771, y: 257))

        case .image:
            if let img = baseImage {
                let rect = NSRect(x: 96, y: 96, width: 832, height: 832)
                let clipPath = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
                clipPath.addClip()
                let w = img.size.width
                let h = img.size.height
                let scale = max(rect.width / w, rect.height / h)
                let dw = w * scale
                let dh = h * scale
                img.draw(
                    in: NSRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }
        }

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw DockError.launcherOperationFailed("Failed encoding PNG icon data")
        }
        return data
    }

    private static func drawCenteredText(_ text: String, fontSize: CGFloat, center: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let nsStr = NSString(string: text)
        let sz = nsStr.size(withAttributes: attrs)
        nsStr.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
    }

    public static func nsColor(fromHex hex: String) -> NSColor? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let val = UInt32(clean, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private static func runTool(_ executable: String, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw DockError.launcherOperationFailed("\(executable) exited with status \(p.terminationStatus)")
        }
    }
}
