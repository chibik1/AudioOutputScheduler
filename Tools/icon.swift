import AppKit

// Flat style (like Logi Options+): one saturated color, bold uniform white line glyphs,
// overlapping shapes separated by a background-colored gap.
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSColor(srgbRed: 0.27, green: 0.40, blue: 1.0, alpha: 1)   // vivid blue
let fg = NSColor.white

// squircle
let S = CGFloat(px)
let rect = NSRect(x: 100, y: 100, width: S - 200, height: S - 200)
let shape = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.22)
sh.shadowBlurRadius = 20
sh.shadowOffset = NSSize(width: 0, height: -8)
sh.set()
bg.setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()

// glyphs in reference coordinates (1254 canvas, y down)
let s: CGFloat = 0.70
let t = NSAffineTransform()
t.translateX(by: 498, yBy: 520)
t.scaleX(by: s, yBy: -s)
t.translateX(by: -646, yBy: -657)
t.concat()

let lw: CGFloat = 62
func stroke(_ p: NSBezierPath, _ w: CGFloat = lw) {
    p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round
    fg.setStroke(); p.stroke()
}

// speaker: box + cone as one outline with a divider
let body = NSBezierPath()
body.move(to: NSPoint(x: 290, y: 470))
body.line(to: NSPoint(x: 440, y: 470))
body.line(to: NSPoint(x: 700, y: 300))
body.line(to: NSPoint(x: 700, y: 880))
body.line(to: NSPoint(x: 440, y: 710))
body.line(to: NSPoint(x: 290, y: 710))
body.close()
stroke(body)
let divider = NSBezierPath()
divider.move(to: NSPoint(x: 440, y: 470))
divider.line(to: NSPoint(x: 440, y: 710))
stroke(divider)

// sound waves
let c = NSPoint(x: 712, y: 590)
let small = NSBezierPath()
small.appendArc(withCenter: c, radius: 150, startAngle: -50, endAngle: 50)
stroke(small)
let big = NSBezierPath()
big.appendArc(withCenter: c, radius: 268, startAngle: -46, endAngle: 46)
stroke(big)

// clock badge with background-colored gap (knockout)
let cc = NSPoint(x: 878, y: 900)
let r: CGFloat = 168
let gap: CGFloat = 56
bg.setFill()
NSBezierPath(ovalIn: NSRect(x: cc.x - r - gap, y: cc.y - r - gap, width: 2 * (r + gap), height: 2 * (r + gap))).fill()
stroke(NSBezierPath(ovalIn: NSRect(x: cc.x - r, y: cc.y - r, width: 2 * r, height: 2 * r)))
let hands = NSBezierPath()
hands.move(to: NSPoint(x: cc.x, y: cc.y - 92))
hands.line(to: cc)
hands.line(to: NSPoint(x: cc.x + 64, y: cc.y + 56))
stroke(hands, 54)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
