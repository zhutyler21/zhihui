import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let variants: [(String, Int)] = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]
for (name, pixels) in variants {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(2) }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    NSColor(srgbRed: 247.0 / 255, green: 248.0 / 255, blue: 250.0 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 48*scale,y: 48*scale,width: 928*scale,height: 928*scale),xRadius: 218*scale,yRadius: 218*scale).fill()
    let badge = NSBezierPath(roundedRect: NSRect(x: 158*scale,y: 158*scale,width: 708*scale,height: 708*scale),xRadius: 178*scale,yRadius: 178*scale)
    NSColor(srgbRed: 54.0 / 255, green: 92.0 / 255, blue: 186.0 / 255, alpha: 1).setFill()
    badge.fill()
    NSColor.white.setFill()
    let heights: [CGFloat] = [180,350,470,280]
    for (index,height) in heights.enumerated() {
        NSBezierPath(roundedRect: NSRect(x: CGFloat(316 + index*106)*scale,y: (512-height/2)*scale,width: 62*scale,height: height*scale),xRadius: 28*scale,yRadius: 28*scale).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
    try png.write(to: folder.appendingPathComponent(name + ".png"))
}
