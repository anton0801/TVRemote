// Renders the 1024×1024 app icon (graphite background, violet/blue TV screen, orange remote).
// Usage: swift Tools/Icon/render_icon.swift <output.png> [dark]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[1])
let dark = args.count > 2 && args[2] == "dark"
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// Background: subtle vertical graphite gradient.
let gradient = CGGradient(colorsSpace: space, colors: [color(dark ? 0x0B0C0F : 0x23262D), color(dark ? 0x16181D : 0x121317)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

// TV screen (back layer): same violet → blue light as the in-app illustrations.
let screen = CGRect(x: 212, y: 470, width: 600, height: 340)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 52, cornerHeight: 52, transform: nil)
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
let screenGradient = CGGradient(colorsSpace: space, colors: [color(0x6D4AFF), color(0x2F6FDE)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(screenGradient, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
ctx.restoreGState()
ctx.setStrokeColor(color(0x0A0B0F))
ctx.setLineWidth(18)
ctx.addPath(screenPath)
ctx.strokePath()

// Remote body (front).
let body = CGRect(x: 387, y: 170, width: 250, height: 560)
// Dark rim so the remote separates from the screen behind it.
ctx.setStrokeColor(color(0x121317))
ctx.setLineWidth(28)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 110, cornerHeight: 110, transform: nil))
ctx.strokePath()
ctx.setFillColor(color(0xFF9F0A))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 110, cornerHeight: 110, transform: nil))
ctx.fillPath()

// D-pad ring and keys in graphite.
ctx.setStrokeColor(color(0x1A1206))
ctx.setLineWidth(22)
ctx.strokeEllipse(in: CGRect(x: 437, y: 480, width: 150, height: 150))
ctx.setFillColor(color(0x1A1206))
ctx.fillEllipse(in: CGRect(x: 487, y: 530, width: 50, height: 50))
for (index, y) in [390.0, 310.0].enumerated() {
    ctx.fillEllipse(in: CGRect(x: 447, y: y, width: 44, height: 44))
    ctx.fillEllipse(in: CGRect(x: 533, y: y, width: 44, height: 44))
    _ = index
}
ctx.fill(CGRect(x: 462, y: 235, width: 100, height: 26))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
