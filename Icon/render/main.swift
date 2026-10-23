import AppKit

// Usage: render <icon.svg> <AppIcon.appiconset dir>
let args = CommandLine.arguments
guard args.count >= 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    fatalError("usage: render <icon.svg> <output dir>; the SVG must load")
}
if args.count == 4 {  // single opaque PNG: render <svg> <out.png> <pixels>
    // Draw the SVG into an RGBA bitmap (a non-alpha NSBitmapImageRep renders it black), then flatten onto
    // white into an alpha-free CGImage, which is what iOS app icons require.
    let px = Int(args[3])!
    let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = rgba.cgImage,
          let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("could not create bitmap context")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: px, height: px))
    context.draw(rendered, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let flat = context.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("could not create PNG destination")
    }
    CGImageDestinationAddImage(dest, flat, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
    exit(0)
}
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
}
let images = sizes.map { name, px -> String in
    let scale = name.hasSuffix("@2x") ? "2x" : "1x"
    let size = scale == "2x" ? px / 2 : px
    return "{\"filename\":\"\(name).png\",\"idiom\":\"mac\",\"scale\":\"\(scale)\",\"size\":\"\(size)x\(size)\"}"
}
try "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
    .write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
