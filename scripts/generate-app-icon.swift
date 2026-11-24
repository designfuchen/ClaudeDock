#!/usr/bin/env swift
// Renders the ClaudeDock app icon with CoreGraphics (no assets, no dependencies).
//
// Concept: three distinct account tiles fanned in 3D carousel depth above a frosted macOS dock
// shelf — deep teal, rich amethyst, and an elevated, glowing warm terracotta hero tile carrying
// an active avatar and subtle quota ring — crowned by a sculpted bidirectional switching arc.
//
// Usage: generate-app-icon.swift <output.icns> [master.png]

import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-app-icon.swift <output.icns> [master.png]\n", stderr)
    exit(1)
}
let outICNS = URL(fileURLWithPath: CommandLine.arguments[1])
let masterOut = CommandLine.arguments.count >= 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Continuous-curvature rounded rectangle (superellipse corners), matching Apple's macOS icon grid.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.528665
    let c = min(radius * k, min(r.width, r.height) / 2)
    let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
    p.move(to: CGPoint(x: x0 + c, y: y0))
    p.addLine(to: CGPoint(x: x1 - c, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + c),
               control1: CGPoint(x: x1 - c * 0.24, y: y0),
               control2: CGPoint(x: x1, y: y0 + c * 0.24))
    p.addLine(to: CGPoint(x: x1, y: y1 - c))
    p.addCurve(to: CGPoint(x: x1 - c, y: y1),
               control1: CGPoint(x: x1, y: y1 - c * 0.24),
               control2: CGPoint(x: x1 - c * 0.24, y: y1))
    p.addLine(to: CGPoint(x: x0 + c, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - c),
               control1: CGPoint(x: x0 + c * 0.24, y: y1),
               control2: CGPoint(x: x0, y: y1 - c * 0.24))
    p.addLine(to: CGPoint(x: x0, y: y0 + c))
    p.addCurve(to: CGPoint(x: x0 + c, y: y0),
               control1: CGPoint(x: x0, y: y0 + c * 0.24),
               control2: CGPoint(x: x0 + c * 0.24, y: y0))
    p.closeSubpath()
    return p
}

func fillLinear(
    _ ctx: CGContext,
    _ path: CGPath,
    _ colors: [CGColor],
    locations: [CGFloat]? = nil,
    from: CGPoint,
    to: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fillRadial(
    _ ctx: CGContext,
    clipPath: CGPath? = nil,
    _ colors: [CGColor],
    locations: [CGFloat]? = nil,
    center: CGPoint,
    radius: CGFloat
) {
    ctx.saveGState()
    if let clipPath {
        ctx.addPath(clipPath)
        ctx.clip()
    }
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func strokeLinear(
    _ ctx: CGContext,
    _ path: CGPath,
    width: CGFloat,
    _ colors: [CGColor],
    locations: [CGFloat]? = nil,
    from: CGPoint,
    to: CGPoint
) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    fillLinear(ctx, stroked, colors, locations: locations, from: from, to: to)
}

func pillPath(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Draws a bold, sculpted circular account avatar (head + shoulders clipped to a medallion).
func drawAccountAvatar(
    _ ctx: CGContext,
    center: CGPoint,
    radius: CGFloat,
    medallionColor: CGColor,
    silhouetteTop: CGColor,
    silhouetteBottom: CGColor,
    shadowColor: CGColor? = nil
) {
    let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let circlePath = CGPath(ellipseIn: circleRect, transform: nil)

    // Soft circular medallion backing
    ctx.saveGState()
    ctx.addPath(circlePath)
    ctx.setFillColor(medallionColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clipped silhouette (head + rounded shoulders)
    ctx.saveGState()
    ctx.addPath(circlePath)
    ctx.clip()

    let headR = radius * 0.31
    let headRect = CGRect(
        x: center.x - headR,
        y: center.y + radius * 0.24 - headR,
        width: headR * 2,
        height: headR * 2
    )
    let shoulderRX = radius * 0.68
    let shoulderRY = radius * 0.58
    let shoulderRect = CGRect(
        x: center.x - shoulderRX,
        y: center.y - radius * 0.76 - shoulderRY,
        width: shoulderRX * 2,
        height: shoulderRY * 2
    )

    let avatarPath = CGMutablePath()
    avatarPath.addEllipse(in: headRect)
    avatarPath.addEllipse(in: shoulderRect)

    if let shadowColor {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: shadowColor)
        ctx.addPath(avatarPath)
        ctx.setFillColor(silhouetteBottom)
        ctx.fillPath()
        ctx.restoreGState()
    }

    fillLinear(
        ctx,
        avatarPath,
        [silhouetteTop, silhouetteBottom],
        from: CGPoint(x: center.x - radius * 0.2, y: center.y + radius * 0.6),
        to: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.9)
    )
    ctx.restoreGState()
}

guard let ctx = CGContext(
    data: nil,
    width: Int(S),
    height: Int(S),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CoreGraphics context\n", stderr)
    exit(1)
}
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: 1. macOS Big Sur+ Squircle Body (824pt centered on 1024pt canvas)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile, radius: 185.4)

// Dual-layer realistic drop shadow inside the canvas margin
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: rgb(0x000000, 0.36))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x161117))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.24))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x161117))
ctx.fillPath()
ctx.restoreGState()

// Deep warm cocoa-obsidian base gradient (top-left key light)
fillLinear(
    ctx,
    tilePath,
    [rgb(0x3B2C35), rgb(0x231A22), rgb(0x140F15)],
    locations: [0.0, 0.48, 1.0],
    from: CGPoint(x: 200, y: 924),
    to: CGPoint(x: 840, y: 100)
)

// Subtle atmospheric bounce lights matching each account card's hue
fillRadial(
    ctx,
    clipPath: tilePath,
    [rgb(0xF28450, 0.34), rgb(0xE06838, 0.12), rgb(0xE06838, 0.0)],
    locations: [0.0, 0.48, 1.0],
    center: CGPoint(x: 512, y: 526),
    radius: 410
)
fillRadial(
    ctx,
    clipPath: tilePath,
    [rgb(0x3AC2A5, 0.16), rgb(0x3AC2A5, 0.0)],
    locations: [0.0, 1.0],
    center: CGPoint(x: 250, y: 470),
    radius: 290
)
fillRadial(
    ctx,
    clipPath: tilePath,
    [rgb(0x8E72EE, 0.16), rgb(0x8E72EE, 0.0)],
    locations: [0.0, 1.0],
    center: CGPoint(x: 774, y: 470),
    radius: 290
)

// Soft top-left key-light sheen on the icon surface
fillLinear(
    ctx,
    tilePath,
    [rgb(0xFFF6EE, 0.11), rgb(0xFFF6EE, 0.0)],
    locations: [0.0, 1.0],
    from: CGPoint(x: 260, y: 924),
    to: CGPoint(x: 560, y: 560)
)

// Subtle bottom darkening vignette for grounding
fillLinear(
    ctx,
    tilePath,
    [rgb(0x000000, 0.0), rgb(0x000000, 0.22)],
    locations: [0.0, 1.0],
    from: CGPoint(x: 512, y: 310),
    to: CGPoint(x: 512, y: 100)
)

// Clip all interior artwork strictly to the squircle body
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// MARK: 2. Frosted Dock Tray Base (ties visually to "ClaudeDock")

let dockRect = CGRect(x: 228, y: 152, width: 568, height: 74)
let dockPath = pillPath(dockRect)

// Grounding shadow under the floating dock pill
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, 0.50))
ctx.addPath(dockPath)
ctx.setFillColor(rgb(0x161118, 0.90))
ctx.fillPath()
ctx.restoreGState()

// Warm frosted glass body
fillLinear(
    ctx,
    dockPath,
    [rgb(0xFFF5EC, 0.16), rgb(0xFFF5EC, 0.06)],
    from: CGPoint(x: 512, y: dockRect.maxY),
    to: CGPoint(x: 512, y: dockRect.minY)
)

// Subtle warm color reflection cast onto the dock from the glowing center card
fillRadial(
    ctx,
    clipPath: dockPath,
    [rgb(0xFF9C64, 0.26), rgb(0xFF9C64, 0.0)],
    locations: [0.0, 1.0],
    center: CGPoint(x: 512, y: dockRect.maxY),
    radius: 170
)

// Crisp directional glass bevel rim on the dock tray
strokeLinear(
    ctx,
    pillPath(dockRect.insetBy(dx: 1.5, dy: 1.5)),
    width: 2.5,
    [rgb(0xFFFFFF, 0.34), rgb(0xFFFFFF, 0.06)],
    from: CGPoint(x: 512, y: dockRect.maxY),
    to: CGPoint(x: 512, y: dockRect.minY)
)

// Three dock slot indicators corresponding to the 3 accounts (center active & glowing)
let dockY = dockRect.midY
let sideDotR: CGFloat = 11.5

func drawDockDot(x: CGFloat, topHex: UInt32, bottomHex: UInt32) {
    let r = CGRect(x: x - sideDotR, y: dockY - sideDotR, width: sideDotR * 2, height: sideDotR * 2)
    let p = CGPath(ellipseIn: r, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: rgb(0x000000, 0.35))
    ctx.addPath(p)
    ctx.setFillColor(rgb(bottomHex))
    ctx.fillPath()
    ctx.restoreGState()
    fillLinear(ctx, p, [rgb(topHex), rgb(bottomHex)], from: CGPoint(x: x, y: r.maxY), to: CGPoint(x: x, y: r.minY))
}

drawDockDot(x: 344, topHex: 0x5CE0C2, bottomHex: 0x26927F)
drawDockDot(x: 680, topHex: 0xB49AFF, bottomHex: 0x6F51CE)

let activePillRect = CGRect(x: 512 - 33, y: dockY - 11.5, width: 66, height: 23)
let activePill = pillPath(activePillRect)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 16, color: rgb(0xFF9C60, 0.72))
ctx.addPath(activePill)
ctx.setFillColor(rgb(0xFFF6EB))
ctx.fillPath()
ctx.restoreGState()
fillLinear(
    ctx,
    activePill,
    [rgb(0xFFFFFF), rgb(0xFFE0C2)],
    from: CGPoint(x: 512, y: activePillRect.maxY),
    to: CGPoint(x: 512, y: activePillRect.minY)
)

// MARK: 3. Side Account Tiles (Fanned in Depth Behind the Selected Card)

struct SideCardStyle {
    let center: CGPoint
    let angle: CGFloat
    let avatarShiftX: CGFloat
    let topColor: UInt32
    let midColor: UInt32
    let bottomColor: UInt32
    let avatarTint: UInt32
}

let sideCards = [
    // Left account: rich deep sage-teal
    SideCardStyle(
        center: CGPoint(x: 298, y: 486),
        angle: deg(11),
        avatarShiftX: -26,
        topColor: 0x45C9AC,
        midColor: 0x248D7D,
        bottomColor: 0x155E56,
        avatarTint: 0xECFFF9
    ),
    // Right account: rich warm amethyst-indigo
    SideCardStyle(
        center: CGPoint(x: 726, y: 486),
        angle: deg(-11),
        avatarShiftX: 26,
        topColor: 0xA487F6,
        midColor: 0x6D4FC8,
        bottomColor: 0x49309A,
        avatarTint: 0xF5F0FF
    ),
]

for card in sideCards {
    ctx.saveGState()
    ctx.translateBy(x: card.center.x, y: card.center.y)
    ctx.rotate(by: card.angle)

    let rect = CGRect(x: -136, y: -172, width: 272, height: 344)
    let path = squircle(rect, radius: 58)

    // Cast shadow onto background
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: rgb(0x000000, 0.48))
    ctx.addPath(path)
    ctx.setFillColor(rgb(card.bottomColor))
    ctx.fillPath()
    ctx.restoreGState()

    // Rich 3-stop hue gradient
    fillLinear(
        ctx,
        path,
        [rgb(card.topColor), rgb(card.midColor), rgb(card.bottomColor)],
        locations: [0.0, 0.52, 1.0],
        from: CGPoint(x: rect.minX + 20, y: rect.maxY),
        to: CGPoint(x: rect.maxX - 20, y: rect.minY)
    )

    // Subtle top-left specular sheen
    fillRadial(
        ctx,
        clipPath: path,
        [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.0)],
        locations: [0.0, 1.0],
        center: CGPoint(x: rect.minX + 40, y: rect.maxY - 30),
        radius: 210
    )

    // Account avatar shifted outward so it reads cleanly peeking from behind the hero card
    let avatarCenter = CGPoint(x: card.avatarShiftX, y: 24)
    drawAccountAvatar(
        ctx,
        center: avatarCenter,
        radius: 64,
        medallionColor: rgb(0xFFFFFF, 0.16),
        silhouetteTop: rgb(card.avatarTint, 0.94),
        silhouetteBottom: rgb(card.avatarTint, 0.72),
        shadowColor: rgb(0x000000, 0.18)
    )

    // Subtle secondary label pill below avatar
    let barRect = CGRect(x: card.avatarShiftX - 44, y: -92, width: 88, height: 18)
    ctx.addPath(pillPath(barRect))
    ctx.setFillColor(rgb(card.avatarTint, 0.36))
    ctx.fillPath()

    // Crisp directional edge bevel
    strokeLinear(
        ctx,
        squircle(rect.insetBy(dx: 1.5, dy: 1.5), radius: 56.5),
        width: 3,
        [rgb(0xFFFFFF, 0.42), rgb(0xFFFFFF, 0.08)],
        from: CGPoint(x: rect.minX, y: rect.maxY),
        to: CGPoint(x: rect.maxX, y: rect.minY)
    )

    ctx.restoreGState()
}

// MARK: 4. Center Hero Account Tile (Selected — Lifted, Brighter, Warm Halo Glow)

let frontRect = CGRect(x: 344, y: 314, width: 336, height: 410)
let frontPath = squircle(frontRect, radius: 70)

// Warm ambient selection halo glowing behind the active card onto the side cards
fillRadial(
    ctx,
    [rgb(0xFF9C60, 0.46), rgb(0xF0743E, 0.16), rgb(0xF0743E, 0.0)],
    locations: [0.0, 0.50, 1.0],
    center: CGPoint(x: frontRect.midX, y: frontRect.midY),
    radius: 295
)

// Deep multi-layered elevation shadow separating the selected card from the carousel
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 48, color: rgb(0x000000, 0.58))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xC94D2A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: rgb(0x1A0802, 0.38))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xC94D2A))
ctx.fillPath()
ctx.restoreGState()

// Rich luminous warm terracotta / apricot-coral surface
fillLinear(
    ctx,
    frontPath,
    [rgb(0xFFC48E), rgb(0xEE7B4A), rgb(0xC94D2A)],
    locations: [0.0, 0.48, 1.0],
    from: CGPoint(x: frontRect.minX + 24, y: frontRect.maxY),
    to: CGPoint(x: frontRect.maxX - 20, y: frontRect.minY)
)

// Soft top-left ceramic key-light sheen
fillRadial(
    ctx,
    clipPath: frontPath,
    [rgb(0xFFF9F2, 0.32), rgb(0xFFF9F2, 0.0)],
    locations: [0.0, 1.0],
    center: CGPoint(x: frontRect.minX + 64, y: frontRect.maxY - 46),
    radius: 260
)

// Subtle bottom reflected warmth inside the card
fillLinear(
    ctx,
    frontPath,
    [rgb(0xFFD5B0, 0.0), rgb(0xFFD5B0, 0.14)],
    from: CGPoint(x: frontRect.midX, y: frontRect.minY + 70),
    to: CGPoint(x: frontRect.midX, y: frontRect.minY)
)

// Secondary detail: refined remaining-quota ring (~76%) framing the hero avatar
let avatarCenter = CGPoint(x: frontRect.midX, y: frontRect.midY + 26)
let ringR: CGFloat = 104
let ringW: CGFloat = 15

// Subtle recessed quota track
ctx.saveGState()
ctx.setLineWidth(ringW)
ctx.setStrokeColor(rgb(0x4A1608, 0.24))
ctx.addArc(center: avatarCenter, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Luminous warm-ivory quota arc (clockwise from 12 o'clock)
let quotaStart = CGFloat.pi / 2
let quotaEnd = quotaStart - (.pi * 2 * 0.76)
let quotaArc = CGMutablePath()
quotaArc.addArc(center: avatarCenter, radius: ringR, startAngle: quotaStart, endAngle: quotaEnd, clockwise: true)
let quotaStroke = quotaArc.copy(strokingWithWidth: ringW, lineCap: .round, lineJoin: .round, miterLimit: 10)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: rgb(0xFFF2DE, 0.45))
ctx.addPath(quotaStroke)
ctx.setFillColor(rgb(0xFFFDF8))
ctx.fillPath()
ctx.restoreGState()

fillLinear(
    ctx,
    quotaStroke,
    [rgb(0xFFFFFF), rgb(0xFFE6C4)],
    from: CGPoint(x: avatarCenter.x, y: avatarCenter.y + ringR),
    to: CGPoint(x: avatarCenter.x, y: avatarCenter.y - ringR)
)

// Hero account avatar nestled inside the quota ring
drawAccountAvatar(
    ctx,
    center: avatarCenter,
    radius: 80,
    medallionColor: rgb(0xFFF8F0, 0.17),
    silhouetteTop: rgb(0xFFFFFF, 0.99),
    silhouetteBottom: rgb(0xFFF0DF, 0.94),
    shadowColor: rgb(0x7A240C, 0.28)
)

// Clean minimal UI card bars beneath the avatar (no text)
let primaryBar = CGRect(x: frontRect.midX - 68, y: frontRect.minY + 62, width: 136, height: 22)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: rgb(0x7A240C, 0.20))
ctx.addPath(pillPath(primaryBar))
ctx.setFillColor(rgb(0xFFFBF5, 0.84))
ctx.fillPath()
ctx.restoreGState()

let secondaryBar = CGRect(x: frontRect.midX - 38, y: frontRect.minY + 32, width: 76, height: 14)
ctx.addPath(pillPath(secondaryBar))
ctx.setFillColor(rgb(0xFFF5EB, 0.36))
ctx.fillPath()

// Bright selection focus rim around the active front card
strokeLinear(
    ctx,
    squircle(frontRect.insetBy(dx: 2.25, dy: 2.25), radius: 67.8),
    width: 4.5,
    [rgb(0xFFFDF9, 0.95), rgb(0xFFE5C8, 0.56), rgb(0xFFC89B, 0.38)],
    locations: [0.0, 0.55, 1.0],
    from: CGPoint(x: frontRect.minX, y: frontRect.maxY),
    to: CGPoint(x: frontRect.maxX, y: frontRect.minY)
)

// MARK: 5. Sculpted Crown Switching Arc (Bidirectional Carousel Cue)

let arcCenter = CGPoint(x: 512, y: 318)
let arcRadius: CGFloat = 496
let leftTipAngle = deg(117)
let rightTipAngle = deg(63)
let arrowStrokeW: CGFloat = 26
let wingBack: CGFloat = 44
let wingSpread: CGFloat = 34

func circlePoint(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint {
    CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}

let arrowSkeleton = CGMutablePath()

// Main sweeping carousel arc (ends slightly tucked inside each chevron apex for a seamless join)
arrowSkeleton.addArc(
    center: arcCenter,
    radius: arcRadius,
    startAngle: leftTipAngle - deg(0.25),
    endAngle: rightTipAngle + deg(0.25),
    clockwise: true
)

// Left chevron (points down-left along increasing angle tangent)
let leftTip = circlePoint(arcCenter, arcRadius, leftTipAngle)
let leftTan = CGPoint(x: -sin(leftTipAngle), y: cos(leftTipAngle))
let leftNorm = CGPoint(x: cos(leftTipAngle), y: sin(leftTipAngle))
let leftWingOut = CGPoint(
    x: leftTip.x - leftTan.x * wingBack + leftNorm.x * wingSpread,
    y: leftTip.y - leftTan.y * wingBack + leftNorm.y * wingSpread
)
let leftWingIn = CGPoint(
    x: leftTip.x - leftTan.x * wingBack - leftNorm.x * wingSpread,
    y: leftTip.y - leftTan.y * wingBack - leftNorm.y * wingSpread
)
arrowSkeleton.move(to: leftWingOut)
arrowSkeleton.addLine(to: leftTip)
arrowSkeleton.addLine(to: leftWingIn)

// Right chevron (points down-right along decreasing angle tangent)
let rightTip = circlePoint(arcCenter, arcRadius, rightTipAngle)
let rightTan = CGPoint(x: sin(rightTipAngle), y: -cos(rightTipAngle))
let rightNorm = CGPoint(x: cos(rightTipAngle), y: sin(rightTipAngle))
let rightWingOut = CGPoint(
    x: rightTip.x - rightTan.x * wingBack + rightNorm.x * wingSpread,
    y: rightTip.y - rightTan.y * wingBack + rightNorm.y * wingSpread
)
let rightWingIn = CGPoint(
    x: rightTip.x - rightTan.x * wingBack - rightNorm.x * wingSpread,
    y: rightTip.y - rightTan.y * wingBack - rightNorm.y * wingSpread
)
arrowSkeleton.move(to: rightWingOut)
arrowSkeleton.addLine(to: rightTip)
arrowSkeleton.addLine(to: rightWingIn)

let arrowFilled = arrowSkeleton.copy(
    strokingWithWidth: arrowStrokeW,
    lineCap: .round,
    lineJoin: .round,
    miterLimit: 10
)

// Soft grounding shadow + subtle warm glow behind the switching arc
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: rgb(0x000000, 0.50))
ctx.addPath(arrowFilled)
ctx.setFillColor(rgb(0xE8D2BE))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xFFD6B5, 0.28))
ctx.addPath(arrowFilled)
ctx.setFillColor(rgb(0xFFF8F0))
ctx.fillPath()
ctx.restoreGState()

// Brushed warm-pearl metallic gradient across the sculpted arrow
fillLinear(
    ctx,
    arrowFilled,
    [rgb(0xFFFFFF), rgb(0xF6E5D6), rgb(0xDFC4AE)],
    locations: [0.0, 0.55, 1.0],
    from: CGPoint(x: 512, y: 842),
    to: CGPoint(x: 512, y: 720)
)

// End squircle clip
ctx.restoreGState()

// MARK: 6. Outer Squircle Specular Bevel Rim (Key Light Catch)

strokeLinear(
    ctx,
    squircle(tile.insetBy(dx: 1.5, dy: 1.5), radius: 183.9),
    width: 3,
    [rgb(0xFFF6EE, 0.28), rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0.04)],
    locations: [0.0, 0.50, 1.0],
    from: CGPoint(x: 180, y: 924),
    to: CGPoint(x: 844, y: 100)
)

// MARK: 7. Export (.png master + full .iconset via iconutil)

guard let cg = ctx.makeImage() else {
    fputs("Failed to make CGImage\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed PNG export\n", stderr)
    exit(1)
}

let fm = FileManager.default
if let masterOut {
    try png.write(to: masterOut)
}

let tmp = fm.temporaryDirectory.appendingPathComponent("claudedock-appicon-\(UUID().uuidString)", isDirectory: true)
let iconset = tmp.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

let master = tmp.appendingPathComponent("master.png")
try png.write(to: master)

func run(_ exe: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { exit(p.terminationStatus) }
}

for sz in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(sz)", "\(sz)", master.path, "--out", iconset.appendingPathComponent("icon_\(sz)x\(sz).png").path])
    run("/usr/bin/sips", ["-z", "\(sz * 2)", "\(sz * 2)", master.path, "--out", iconset.appendingPathComponent("icon_\(sz)x\(sz)@2x.png").path])
}

try? fm.removeItem(at: outICNS)
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", outICNS.path])
print("Generated \(outICNS.path)")
