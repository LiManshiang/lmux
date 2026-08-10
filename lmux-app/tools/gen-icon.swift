import AppKit

// lmux app icon: dark terminal-style background with a green `>_` prompt.
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

if let ctx = NSGraphicsContext.current?.cgContext {
    let colors = [
        CGColor(red: 0.09, green: 0.10, blue: 0.16, alpha: 1),
        CGColor(red: 0.15, green: 0.17, blue: 0.26, alpha: 1),
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

    // Subtle bottom glow
    ctx.setFillColor(CGColor(red: 0.35, green: 0.85, blue: 0.65, alpha: 0.06))
    ctx.fillEllipse(in: CGRect(x: 250, y: 200, width: 520, height: 520))
}

let green = NSColor(calibratedRed: 0.38, green: 0.88, blue: 0.68, alpha: 1)

// Prompt `>`
let chevron = NSBezierPath()
chevron.lineWidth = 74
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 690, y: 668))
chevron.line(to: NSPoint(x: 424, y: 512))
chevron.line(to: NSPoint(x: 690, y: 356))
green.setStroke()
chevron.stroke()

// Underscore `_`
let underscore = NSBezierPath()
underscore.lineWidth = 62
underscore.lineCapStyle = .round
underscore.move(to: NSPoint(x: 396, y: 332))
underscore.line(to: NSPoint(x: 690, y: 332))
green.setStroke()
underscore.stroke()

// Cursor block after the underscore
NSColor(calibratedRed: 0.38, green: 0.88, blue: 0.68, alpha: 0.85).setFill()
let cursor = NSRect(x: 706, y: 296, width: 44, height: 72)
NSBezierPath(roundedRect: cursor, xRadius: 6, yRadius: 6).fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "lmux-icon.png")
try! png.write(to: out)
print("wrote \(out.path)")
