// Рисует значок Lark: тёмный поющий жаворонок на ярком тёплом фоне, из клюва — белые звуковые волны.
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

    // Фон — яркий тёплый рассвет: жёлтый сверху, оранжевый снизу. Птица — тёмный силуэт, волны — белые: читается и в 16 px.
    let bg = NSBezierPath(roundedRect: box, xRadius: w * 0.225, yRadius: w * 0.225)
    NSGradient(colors: [rgb(0.99, 0.43, 0.22), rgb(1.0, 0.62, 0.25), rgb(1.0, 0.80, 0.33)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: bg, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()

    let navy = rgb(0.12, 0.13, 0.27), wing = rgb(0.22, 0.24, 0.43), cream = rgb(1.0, 0.95, 0.86)

    // Мягкая тень под птицей — отделяет её от фона.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.45, green: 0.12, blue: 0.0, alpha: 0.35)
    shadow.shadowBlurRadius = w * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -w * 0.015)
    shadow.set()
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)   // тень у силуэта целиком, без швов между частями
    navy.setFill()
    poly([(0.24, 0.42), (0.07, 0.52), (0.11, 0.31)]).fill()        // хвост
    oval(0.40, 0.40, 0.24, 0.185, rotate: 22).fill()              // тело
    oval(0.575, 0.58, 0.13, 0.13).fill()                           // голова
    poly([(0.47, 0.66), (0.37, 0.75), (0.54, 0.70)]).fill()        // хохолок, назад
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // Грудка и крыло.
    let body = oval(0.40, 0.40, 0.24, 0.185, rotate: 22)
    NSGraphicsContext.saveGraphicsState(); body.addClip()
    cream.setFill(); oval(0.50, 0.31, 0.18, 0.12, rotate: 30).fill()
    NSGraphicsContext.restoreGraphicsState()
    wing.setFill(); oval(0.33, 0.44, 0.15, 0.072, rotate: 14).fill()

    // Глаз.
    NSColor.white.setFill(); oval(0.605, 0.61, 0.035, 0.035).fill()
    navy.setFill(); oval(0.614, 0.607, 0.02, 0.02).fill()

    // Открытый клюв — поёт.
    let beak = rgb(0.80, 0.18, 0.14)
    beak.setFill()
    poly([(0.68, 0.62), (0.79, 0.60), (0.685, 0.574)]).fill()
    poly([(0.685, 0.562), (0.77, 0.52), (0.68, 0.54)]).fill()

    // Звуковые волны из клюва.
    for (i, r) in ([0.065, 0.115, 0.165] as [CGFloat]).enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: p(0.775, 0.57), radius: r * w, startAngle: -42, endAngle: 42)
        arc.lineWidth = w * 0.042; arc.lineCapStyle = .round
        NSColor(white: 1, alpha: [1.0, 0.9, 0.75][i]).setStroke(); arc.stroke()
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
