// Рисует значок Lark: поющий жаворонок на фоне рассвета, из клюва — звуковые волны.
// Использование: swift scripts/make-icon.swift <out.iconset> [preview.png]
// Затем: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Сетка значков macOS: ~10% поля вокруг скруглённого квадрата.
    let inset = s * 0.1
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let w = box.width
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * w, y: box.minY + y * w) }
    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rotate deg: CGFloat = 0) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: -rx * w, y: -ry * w, width: 2 * rx * w, height: 2 * ry * w))
        var t = AffineTransform(translationByX: p(cx, cy).x, byY: p(cx, cy).y)
        t.rotate(byDegrees: deg)
        path.transform(using: t)
        return path
    }
    func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: p(pts[0].0, pts[0].1))
        for q in pts.dropFirst() { path.line(to: p(q.0, q.1)) }
        path.close()
        return path
    }

    // Фон — небо на рассвете: синий сверху, к низу розовый и оранжевый.
    let bg = NSBezierPath(roundedRect: box, xRadius: w * 0.225, yRadius: w * 0.225)
    NSGradient(colors: [rgb(0.98, 0.62, 0.34), rgb(0.86, 0.38, 0.50), rgb(0.33, 0.25, 0.62), rgb(0.16, 0.17, 0.42)],
               atLocations: [0, 0.32, 0.72, 1], colorSpace: .sRGB)!.draw(in: bg, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()

    // Солнце, встающее из-за края.
    rgb(1.0, 0.86, 0.55, 0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: p(0.5, 0).x - 0.34 * w, y: p(0, 0).y - 0.2 * w, width: 0.68 * w, height: 0.68 * w)).fill()

    // Ветка.
    let branch = NSBezierPath()
    branch.move(to: p(-0.05, 0.215)); branch.curve(to: p(0.78, 0.235), controlPoint1: p(0.25, 0.17), controlPoint2: p(0.55, 0.26))
    branch.lineWidth = w * 0.045; branch.lineCapStyle = .round
    rgb(0.30, 0.18, 0.20).setStroke(); branch.stroke()

    let brown = rgb(0.47, 0.32, 0.23), dark = rgb(0.33, 0.22, 0.17), cream = rgb(0.99, 0.92, 0.80)

    // Хвост, тело, грудка, крыло.
    dark.setFill(); poly([(0.20, 0.40), (0.04, 0.49), (0.09, 0.33)]).fill()
    let body = oval(0.38, 0.39, 0.24, 0.17, rotate: 22)
    brown.setFill(); body.fill()
    NSGraphicsContext.saveGraphicsState(); body.addClip()
    cream.setFill(); oval(0.47, 0.32, 0.17, 0.12, rotate: 30).fill()
    NSGraphicsContext.restoreGraphicsState()
    dark.setFill(); oval(0.32, 0.43, 0.15, 0.075, rotate: 15).fill()
    // Лапки.
    for x in [0.37, 0.45] as [CGFloat] {
        let leg = NSBezierPath(); leg.move(to: p(x, 0.27)); leg.line(to: p(x - 0.01, 0.215))
        leg.lineWidth = w * 0.022; leg.lineCapStyle = .round; rgb(0.95, 0.60, 0.25).setStroke(); leg.stroke()
    }

    // Голова с хохолком (у жаворонка он есть).
    brown.setFill()
    for (base, tip) in [((0.47, 0.66), (0.37, 0.75)), ((0.51, 0.69), (0.42, 0.79))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        let crest = NSBezierPath()
        crest.move(to: p(base.0 - 0.03, base.1 - 0.02))
        crest.curve(to: p(tip.0, tip.1), controlPoint1: p(base.0 - 0.02, base.1 + 0.04), controlPoint2: p(tip.0 + 0.04, tip.1 + 0.01))
        crest.curve(to: p(base.0 + 0.05, base.1 - 0.01), controlPoint1: p(tip.0 + 0.06, tip.1 - 0.02), controlPoint2: p(base.0 + 0.03, base.1 + 0.02))
        crest.close(); crest.fill()
    }
    oval(0.56, 0.58, 0.125, 0.125).fill()
    cream.setFill(); oval(0.615, 0.525, 0.05, 0.035, rotate: 20).fill()

    // Глаз.
    NSColor.white.setFill(); oval(0.595, 0.615, 0.032, 0.032).fill()
    rgb(0.10, 0.08, 0.12).setFill(); oval(0.602, 0.615, 0.02, 0.02).fill()

    // Открытый клюв — поёт.
    let beak = rgb(0.98, 0.70, 0.26)
    beak.setFill()
    poly([(0.665, 0.62), (0.79, 0.615), (0.67, 0.575)]).fill()
    poly([(0.67, 0.565), (0.77, 0.525), (0.665, 0.545)]).fill()

    // Звуковые волны из клюва.
    for (i, r) in ([0.085, 0.14, 0.195] as [CGFloat]).enumerated() {
        let arc = NSBezierPath()
        let c = p(0.745, 0.57)
        arc.appendArc(withCenter: c, radius: r * w, startAngle: -38, endAngle: 38)
        arc.lineWidth = w * 0.034; arc.lineCapStyle = .round
        NSColor(white: 1, alpha: [1.0, 0.8, 0.55][i]).setStroke(); arc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
