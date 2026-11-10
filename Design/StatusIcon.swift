// 生成菜单栏图标（模板图，单色）：大窗口描边 + 右下实心小窗，@2x 的小窗里镂空一只垂耳小狗。
// 用法：swift Design/StatusIcon.swift PipDog/Resources/Assets.xcassets/StatusIcon.imageset
// 输出 18×18（@1x）和 36×36（@2x）的 PNG；资源目录里标成 template，系统按菜单栏深浅自动着色。
import AppKit
import CoreGraphics

let points: CGFloat = 18

func render(scale: CGFloat) -> CGImage {
    let pixels = Int(points * scale)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: points) // 下面的坐标以 pt 计，y 向下
    ctx.scaleBy(x: 1, y: -1)
    let black = CGColor(gray: 0, alpha: 1)
    ctx.setFillColor(black)
    ctx.setStrokeColor(black)

    func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    func ellipse(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat, rotate: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotate)
        return CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: &t)
    }
    func fill(_ path: CGPath, clear: Bool = false) {
        ctx.setBlendMode(clear ? .clear : .normal)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // 大窗口描边
    ctx.setLineWidth(1.5)
    ctx.addPath(roundedRect(CGRect(x: 1.25, y: 2, width: 12.25, height: 9.75), 2.5))
    ctx.strokePath()
    // 小窗：外圈挖出缝，再填实心
    let pip = CGRect(x: 6.5, y: 7.5, width: 11, height: 8.75)
    fill(roundedRect(pip.insetBy(dx: -1.25, dy: -1.25), 3.25), clear: true)
    fill(roundedRect(pip, 2))
    // 小狗镂空（只画在 @2x：@1x 只有十几个像素，小狗会糊成一团，保留实心小窗更干净）
    guard scale >= 2 else { return ctx.makeImage()! }
    let dog = CGPoint(x: pip.midX, y: pip.midY + 0.35)
    fill(ellipse(CGPoint(x: dog.x - 2.7, y: dog.y + 0.15), 2.0, 4.2, rotate: 0.32), clear: true)
    fill(ellipse(CGPoint(x: dog.x + 2.7, y: dog.y + 0.15), 2.0, 4.2, rotate: -0.32), clear: true)
    fill(ellipse(dog, 5.3, 5.0), clear: true)
    fill(ellipse(CGPoint(x: dog.x - 1.15, y: dog.y - 0.4), 1.0, 1.0))
    fill(ellipse(CGPoint(x: dog.x + 1.15, y: dog.y - 0.4), 1.0, 1.0))
    fill(ellipse(CGPoint(x: dog.x, y: dog.y + 1.05), 1.6, 1.15))
    return ctx.makeImage()!
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (scale, name) in [(CGFloat(1), "StatusIcon.png"), (2, "StatusIcon@2x.png")] {
    let png = NSBitmapImageRep(cgImage: render(scale: scale)).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
}
print(dir)
