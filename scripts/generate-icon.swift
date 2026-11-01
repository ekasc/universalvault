import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Expected iconset output directory.") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fatalError("Cannot allocate icon bitmap.") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205
    ).fill()
    NSColor(calibratedRed: 0.65, green: 0.76, blue: 0.87, alpha: 1).setStroke()
    let door = NSBezierPath(
      roundedRect: NSRect(x: 218, y: 218, width: 588, height: 588), xRadius: 98, yRadius: 98)
    door.lineWidth = 24
    door.stroke()
    NSColor.white.setStroke()
    let dial = NSBezierPath(ovalIn: NSRect(x: 368, y: 368, width: 288, height: 288))
    dial.lineWidth = 30
    dial.stroke()
    for index in 0..<3 {
      let angle = CGFloat(index) * 2 * .pi / 3
      let spoke = NSBezierPath()
      spoke.move(to: NSPoint(x: 512, y: 512))
      spoke.line(to: NSPoint(x: 512 + cos(angle) * 110, y: 512 + sin(angle) * 110))
      spoke.lineWidth = 28
      spoke.lineCapStyle = .round
      spoke.stroke()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 479, y: 479, width: 66, height: 66)).fill()
    for y in [342, 642] {
      NSBezierPath(
        roundedRect: NSRect(x: 192, y: y, width: 58, height: 100), xRadius: 18, yRadius: 18
      ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      fatalError("Cannot encode icon.")
    }
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try data.write(to: output.appendingPathComponent(name))
  }
}
