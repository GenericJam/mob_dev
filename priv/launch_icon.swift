// launch_icon.swift <source.png> <out_dir> <points>
//
// Writes the iOS launch screen's icon (MobDev.LaunchIcon): the app icon at
// <points> pt with the home screen's corner radius, as
// <out_dir>/launch_icon@2x.png and @3x.png. CoreGraphics and ImageIO only,
// so it runs on any Mac that can build for iOS.
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 4, let points = Int(args[3]) else {
    FileHandle.standardError.write("usage: launch_icon.swift <source.png> <out_dir> <points>\n".data(using: .utf8)!)
    exit(2)
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("launch_icon.swift: cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

for scale in [2, 3] {
    let px = points * scale
    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    // 22.5% of the side: the radius iOS gives an app icon.
    let radius = CGFloat(px) * 0.225
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(icon, in: rect)

    let url = URL(fileURLWithPath: args[2]).appendingPathComponent("launch_icon@\(scale)x.png")
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}
