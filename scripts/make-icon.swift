import AppKit

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
        let background = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.48, blue: 0.39, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.28, blue: 0.23, alpha: 1))!.draw(in: background, angle: -70)
        let text = "Aa" as NSString
        text.draw(at: NSPoint(x: 208, y: 335), withAttributes: [.font: NSFont.systemFont(ofSize: 370, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.95, green: 0.97, blue: 0.90, alpha: 1)])
        let underline = NSBezierPath()
        underline.move(to: NSPoint(x: 246, y: 314))
        underline.line(to: NSPoint(x: 547, y: 314))
        underline.lineWidth = 24
        underline.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.4).setStroke()
        underline.stroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: 628, y: 323))
        check.line(to: NSPoint(x: 693, y: 264))
        check.line(to: NSPoint(x: 797, y: 390))
        check.lineWidth = 33
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor(srgbRed: 0.77, green: 0.91, blue: 0.61, alpha: 1).setStroke()
        check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/icon_\(size)x\(size)\(suffix).png"))
    }
}
