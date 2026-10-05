import AppKit
import CoreGraphics
import Foundation

// 用法：makeicon <logo.png> <out.iconset目录>
// 把 logo 居中放在圆角纸色底上，生成 macOS 图标所需的全套尺寸
let args = CommandLine.arguments
guard args.count >= 3 else { print("用法: makeicon <logo.png> <iconsetDir>"); exit(1) }
guard let logo = NSImage(contentsOfFile: args[1]) else { print("读不到 \(args[1])"); exit(2) }
let dir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let paper = CGColor(srgbRed: 0xF6/255, green: 0xF1/255, blue: 0xE7/255, alpha: 1)
let ink   = CGColor(srgbRed: 0x23/255, green: 0x21/255, blue: 0x1E/255, alpha: 1)

func render(_ S: CGFloat) -> NSImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    // 圆角底（macOS 图标习惯：圆角约 22.4%）
    let r = S * 0.224
    let rect = CGRect(x: 0, y: 0, width: S, height: S)
    let path = CGPath(roundedRect: rect.insetBy(dx: S * 0.015, dy: S * 0.015), cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path); ctx.setFillColor(paper); ctx.fillPath()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)); ctx.setLineWidth(S * 0.006); ctx.strokePath()
    // logo 居中，占 68%
    let inset = S * 0.16
    let box = rect.insetBy(dx: inset, dy: inset)
    if let cg = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
        ctx.draw(cg, in: box)
        ctx.restoreGState()
    }
    _ = ink
    let img = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: S, height: S))
    return img
}

func writePNG(_ img: NSImage, _ url: URL) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs { writePNG(render(size), dir.appendingPathComponent(name)) }
writePNG(render(1024), dir.appendingPathComponent("../icon-preview.png"))
print("已生成 \(specs.count) 个尺寸 → \(dir.path)")
