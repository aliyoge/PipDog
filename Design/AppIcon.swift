// 生成 PipDog 应用图标（石墨配色：大窗口描边 + 右下小窗里的垂耳小狗）。
// 用法：swift Design/AppIcon.swift Design/AppIcon-1024.png
// 1024×1024 透明画布，主体 824×824 居中（macOS 图标网格），带模板式投影。
import AppKit
import CoreGraphics

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// macOS 图标外形：直边 + 超椭圆圆角（连续曲率）
func squircle(_ r: CGRect) -> CGPath {
    let rc = r.width * 0.30, n: CGFloat = 2.8, steps = 90
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - rc, y: r.minY + rc), -.pi / 2), (CGPoint(x: r.maxX - rc, y: r.maxY - rc), 0),
        (CGPoint(x: r.minX + rc, y: r.maxY - rc), .pi / 2), (CGPoint(x: r.minX + rc, y: r.minY + rc), .pi),
    ]
    let path = CGMutablePath()
    for (center, start) in corners {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: center.x + rc * copysign(pow(abs(c), 2 / n), c),
                                y: center.y + rc * copysign(pow(abs(s), 2 / n), s))
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func ellipse(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat, rotate: CGFloat = 0) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotate)
    return CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: &t)
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size) // 下面的坐标 y 向下
ctx.scaleBy(x: 1, y: -1)

func fill(_ path: CGPath, _ c: CGColor, shadow: (dy: CGFloat, blur: CGFloat, alpha: CGFloat)? = nil) {
    ctx.saveGState()
    if let shadow { ctx.setShadow(offset: CGSize(width: 0, height: -shadow.dy), blur: shadow.blur, color: color(0, shadow.alpha)) }
    ctx.addPath(path)
    ctx.setFillColor(c)
    ctx.fillPath()
    ctx.restoreGState()
}

func stroke(_ path: CGPath, _ c: CGColor, _ width: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(c)
    ctx.setLineWidth(width)
    ctx.strokePath()
    ctx.restoreGState()
}

func fillGradient(_ path: CGPath, top: UInt32, bottom: UInt32, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body)
let bigWindow = CGRect(x: 196, y: 248, width: 544, height: 400)
let pip = CGRect(x: 470, y: 494, width: 362, height: 270)
let background = (top: UInt32(0xFDFDFE), bottom: UInt32(0xDFE2E7))
let ink = color(0x2C2F35)

// 底板：投影 + 浅灰渐变
fill(bodyPath, color(background.bottom), shadow: (12, 28, 0.28))
fill(bodyPath, color(background.bottom), shadow: (2, 4, 0.12))
fillGradient(bodyPath, top: background.top, bottom: background.bottom, from: body.minY, to: body.maxY)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
// 大窗口描边；小窗外圈用底色留缝
stroke(roundedRect(bigWindow, 66), ink, 30)
fillGradient(roundedRect(pip.insetBy(dx: -24, dy: -24), 70), top: background.top, bottom: background.bottom,
             from: body.minY, to: body.maxY)
fill(roundedRect(pip, 48), ink, shadow: (8, 22, 0.22))
fillGradient(roundedRect(pip, 48), top: 0x3B3F46, bottom: 0x24272C, from: pip.minY, to: pip.maxY)
// 垂耳小狗
let k: CGFloat = 1.45
let dog = CGPoint(x: pip.midX, y: pip.midY + 10)
fill(ellipse(CGPoint(x: dog.x - 60 * k, y: dog.y + 2 * k), 46 * k, 98 * k, rotate: 0.30), color(0xC3C7CE))
fill(ellipse(CGPoint(x: dog.x + 60 * k, y: dog.y + 2 * k), 46 * k, 98 * k, rotate: -0.30), color(0xC3C7CE))
fill(ellipse(dog, 120 * k, 114 * k), color(0xF3F4F6))
fill(ellipse(CGPoint(x: dog.x - 24 * k, y: dog.y - 6 * k), 15 * k, 15 * k), ink)
fill(ellipse(CGPoint(x: dog.x + 24 * k, y: dog.y - 6 * k), 15 * k, 15 * k), ink)
fill(ellipse(CGPoint(x: dog.x, y: dog.y + 22 * k), 30 * k, 21 * k), ink)
// 内侧细高光
ctx.addPath(bodyPath)
ctx.clip()
stroke(bodyPath, color(0xFFFFFF, 0.28), 3)
ctx.restoreGState()
stroke(bodyPath, color(0, 0.06), 1)

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print(output)
