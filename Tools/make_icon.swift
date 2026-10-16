// Renders the black & white camera + car app icon as a 1024x1024 PNG.
// Run on macOS:  swift Tools/make_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon1024.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

let black = CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
let white = CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)

// Background
ctx.setFillColor(white)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// NOTE: CoreGraphics origin is bottom-left; y values below are measured from
// the bottom of the canvas.

// --- Camera body (upper two thirds) ---
let bodyRect = CGRect(x: 192, y: 430, width: 640, height: 400)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.setFillColor(black)
ctx.addPath(bodyPath)
ctx.fillPath()

// Viewfinder bump on top of the body
let bumpRect = CGRect(x: 400, y: 796, width: 224, height: 78)
let bumpPath = CGPath(roundedRect: bumpRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
ctx.addPath(bumpPath)
ctx.fillPath()

// Shutter button nub, top right of body
ctx.fill(CGRect(x: 700, y: 800, width: 90, height: 40))

// --- Lens (white ring, black core, white glint) ---
let lensCenter = CGPoint(x: 512, y: 630)
func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}
ctx.setFillColor(white)
ctx.fillEllipse(in: circle(lensCenter, 150))
ctx.setFillColor(black)
ctx.fillEllipse(in: circle(lensCenter, 112))
ctx.setFillColor(white)
ctx.fillEllipse(in: circle(CGPoint(x: lensCenter.x + 44, y: lensCenter.y + 44), 26))

// Small status dot on the body, top-left
ctx.fillEllipse(in: circle(CGPoint(x: 268, y: 770), 18))

// --- Car silhouette (bottom third) ---
ctx.setFillColor(black)

// Cabin: rounded trapezoid drawn as a path
let cabin = CGMutablePath()
cabin.move(to: CGPoint(x: 330, y: 300))
cabin.addLine(to: CGPoint(x: 396, y: 388))
cabin.addQuadCurve(to: CGPoint(x: 448, y: 410), control: CGPoint(x: 412, y: 406))
cabin.addLine(to: CGPoint(x: 596, y: 410))
cabin.addQuadCurve(to: CGPoint(x: 648, y: 384), control: CGPoint(x: 630, y: 408))
cabin.addLine(to: CGPoint(x: 710, y: 300))
cabin.closeSubpath()
ctx.addPath(cabin)
ctx.fillPath()

// Lower body
let carBody = CGPath(
    roundedRect: CGRect(x: 210, y: 210, width: 604, height: 110),
    cornerWidth: 44,
    cornerHeight: 44,
    transform: nil
)
ctx.addPath(carBody)
ctx.fillPath()

// Wheels: black tires with white hubcaps
let leftWheel = CGPoint(x: 352, y: 208)
let rightWheel = CGPoint(x: 672, y: 208)
for wheel in [leftWheel, rightWheel] {
    ctx.setFillColor(black)
    ctx.fillEllipse(in: circle(wheel, 66))
    ctx.setFillColor(white)
    ctx.fillEllipse(in: circle(wheel, 28))
}

// Window cutout in the cabin
ctx.setFillColor(white)
let window = CGMutablePath()
window.move(to: CGPoint(x: 380, y: 312))
window.addLine(to: CGPoint(x: 424, y: 372))
window.addLine(to: CGPoint(x: 500, y: 372))
window.addLine(to: CGPoint(x: 500, y: 312))
window.closeSubpath()
ctx.addPath(window)
ctx.fillPath()

let window2 = CGMutablePath()
window2.move(to: CGPoint(x: 540, y: 312))
window2.addLine(to: CGPoint(x: 540, y: 372))
window2.addLine(to: CGPoint(x: 616, y: 372))
window2.addLine(to: CGPoint(x: 660, y: 312))
window2.closeSubpath()
ctx.addPath(window2)
ctx.fillPath()

guard let image = ctx.makeImage() else {
    fatalError("Could not render image")
}
let url = URL(fileURLWithPath: outputPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write PNG")
}
print("Wrote \(outputPath)")
