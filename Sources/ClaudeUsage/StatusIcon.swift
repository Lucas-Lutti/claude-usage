import AppKit

/// Desenha os ícones da barra de menus. `fill` vai de 0 a 1.
enum StatusIcon {
    static func image(style: IconStyle, fill: Double, tint: NSColor?) -> NSImage? {
        let f = min(max(fill, 0), 1)
        let size: NSSize
        switch style {
        case .none: return nil
        case .ring: size = NSSize(width: 15, height: 15)
        case .bar: size = NSSize(width: 26, height: 14)
        case .segments: size = NSSize(width: 27, height: 12)
        case .rays: size = NSSize(width: 16, height: 16)
        case .battery: size = NSSize(width: 25, height: 12)
        }

        let img = NSImage(size: size, flipped: false) { rect in
            // Sem cor = imagem template (segue claro/escuro). Com cor, o trilho usa a cor neutra
            // do texto da barra, exceto nos Blocos, que usam a própria cor translúcida.
            let on = tint ?? .black
            let neutral = tint == nil ? NSColor.black : NSColor.labelColor
            let off = neutral.withAlphaComponent(0.25)
            switch style {
            case .ring: drawRing(rect, f, on, off)
            case .bar: drawBar(rect, f, on, off)
            case .segments: drawSegments(rect, f, on, on.withAlphaComponent(0.28))
            case .rays: drawRays(rect, f, on, off)
            case .battery: drawBattery(rect, f, on, off)
            case .none: break
            }
            return true
        }
        img.isTemplate = tint == nil
        return img
    }

    private static func drawRing(_ r: NSRect, _ f: Double, _ on: NSColor, _ off: NSColor) {
        let c = NSPoint(x: r.midX, y: r.midY), radius = r.width / 2 - 1.6
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.6
        off.setStroke(); track.stroke()
        guard f > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
        arc.lineWidth = 2.6
        arc.lineCapStyle = .round
        on.setStroke(); arc.stroke()
    }

    private static func drawBar(_ r: NSRect, _ f: Double, _ on: NSColor, _ off: NSColor) {
        let track = NSRect(x: 1, y: r.midY - 2.5, width: r.width - 2, height: 5)
        off.setFill(); NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        guard f > 0 else { return }
        let w = max(track.width * f, 5)
        on.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: track.height),
                     xRadius: 2.5, yRadius: 2.5).fill()
    }

    /// Blocos sólidos; os vazios ficam na mesma cor, translúcida.
    private static func drawSegments(_ r: NSRect, _ f: Double, _ on: NSColor, _ off: NSColor) {
        let n = 5, gap: CGFloat = 1.5
        let w = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let seg = NSRect(x: CGFloat(i) * (w + gap), y: 1, width: w, height: r.height - 2)
            let path = NSBezierPath(roundedRect: seg, xRadius: 1.5, yRadius: 1.5)
            off.setFill(); path.fill()
            let part = min(max(f * Double(n) - Double(i), 0), 1)   // fração deste bloco
            if part > 0 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                on.setFill()
                NSRect(x: seg.minX, y: seg.minY, width: seg.width * part, height: seg.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private static func drawRays(_ r: NSRect, _ f: Double, _ on: NSColor, _ off: NSColor) {
        let n = 10
        let c = NSPoint(x: r.midX, y: r.midY)
        let lit = Int((f * Double(n)).rounded(.up))
        for i in 0..<n {
            let angle = (90 - Double(i) * 360 / Double(n)) * .pi / 180
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(angle) * 2.6, y: c.y + sin(angle) * 2.6))
            p.line(to: NSPoint(x: c.x + cos(angle) * 7.2, y: c.y + sin(angle) * 7.2))
            p.lineWidth = 1.9
            p.lineCapStyle = .round
            (i < lit ? on : off).setStroke()
            p.stroke()
        }
    }

    private static func drawBattery(_ r: NSRect, _ f: Double, _ on: NSColor, _ off: NSColor) {
        let body = NSRect(x: 0.5, y: 0.5, width: 21.5, height: 11)
        let outline = NSBezierPath(roundedRect: body, xRadius: 3.2, yRadius: 3.2)
        outline.lineWidth = 1
        off.setStroke(); outline.stroke()
        off.setFill()
        NSBezierPath(roundedRect: NSRect(x: 23, y: 4, width: 1.6, height: 4), xRadius: 0.8, yRadius: 0.8).fill()
        guard f > 0 else { return }
        let inner = body.insetBy(dx: 2, dy: 2)
        on.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(inner.width * f, 2), height: inner.height),
                     xRadius: 1.6, yRadius: 1.6).fill()
    }
}
