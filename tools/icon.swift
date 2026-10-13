// Renders Marky's app icon into an .iconset directory (see `make icon`): a sheet of paper on which a
// radical sign's bar runs on into three lines of text, math and notes in one mark.

import CoreGraphics
import Foundation
import ImageIO

func color(_ rgb: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

func render(pixels: Int, to file: String) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let g = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    g.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas, on a soft shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                      transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    g.addPath(tile)
    g.setFillColor(color(0xF6F4EF))
    g.fillPath()
    g.restoreGState()

    // Paper: a quiet top-to-bottom shade.
    g.saveGState()
    g.addPath(tile)
    g.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xECE8DF)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(paper, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    g.restoreGState()

    // The radicand: three lines of text under the bar, each shorter than the last.
    g.setFillColor(color(0xBDB7AB))
    for (y, end) in [(616.0, 806.0), (514.0, 768.0), (412.0, 690.0)] {
        g.addPath(CGPath(roundedRect: CGRect(x: 548, y: y - 21, width: end - 548, height: 42), cornerWidth: 21,
                         cornerHeight: 21, transform: nil))
        g.fillPath()
    }

    // The radical sign, in one stroke: the small hook, down to the foot, up the long side, then the bar.
    let radical = CGMutablePath()
    radical.move(to: CGPoint(x: 232, y: 534))
    radical.addLine(to: CGPoint(x: 292, y: 566))
    radical.addLine(to: CGPoint(x: 384, y: 316))
    radical.addLine(to: CGPoint(x: 492, y: 744))
    radical.addLine(to: CGPoint(x: 816, y: 744))
    g.addPath(radical)
    g.setLineWidth(60)
    g.setLineCap(.round)
    g.setLineJoin(.round)
    g.setStrokeColor(color(0x3346D3))
    g.strokePath()

    let image = g.makeImage()!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: icon <dir.iconset>")
    exit(1)
}
let directory = CommandLine.arguments[1]
// Sizes above 256pt@2x are left out on purpose: Finder scales up, and the app stays small.
// 16pt@2x and 256pt@1x are left out too: macOS picks icons by pixel size, and 32pt@1x and
// 128pt@2x already provide those exact images.
for (points, scale) in [(16, 1), (32, 1), (32, 2), (128, 1), (128, 2), (256, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    render(pixels: points * scale, to: directory + "/" + name)
}
if CommandLine.arguments.count >= 3 { render(pixels: 1024, to: CommandLine.arguments[2]) }
