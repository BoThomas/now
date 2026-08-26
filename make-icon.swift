import AppKit

let sizes = [16, 32, 128, 256, 512]
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func whiteSymbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        fatalError("Symbol not found")
    }
    let image = NSImage(size: base.size)
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { fatalError("No graphics context") }
    let rect = CGRect(origin: .zero, size: base.size)
    base.draw(in: rect)
    context.setBlendMode(.sourceIn)
    NSColor.white.setFill()
    context.fill(rect)
    image.unlockFocus()
    return image
}

func makeIcon(size: Int, scale: Int, path: String) throws {
    let pixels = CGFloat(size * scale)
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { fatalError("No graphics context") }

    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let radius = pixels * 0.22
    let inset: CGFloat = pixels > 64 ? 2 : 0
    let shape = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.95, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.45, green: 0.15, blue: 0.90, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: pixels), end: CGPoint(x: pixels, y: 0), options: [])

    let side = pixels * 0.62
    let symbolRect = NSRect(x: (pixels - side) / 2, y: (pixels - side) / 2, width: side, height: side)
    whiteSymbol("alarm", pointSize: side).draw(in: symbolRect)

    context.restoreGState()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not make PNG") }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

for size in sizes {
    try makeIcon(size: size, scale: 1, path: "\(output)/icon_\(size)x\(size).png")
    try makeIcon(size: size, scale: 2, path: "\(output)/icon_\(size)x\(size)@2x.png")
}
