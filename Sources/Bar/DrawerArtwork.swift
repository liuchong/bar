import AppKit

/// One drawer drawing shared by the application artwork and every menu-bar state.
enum DrawerArtwork {
    enum State: CaseIterable, Sendable { case closed, left, below, paused }

    static func image(_ state: State, size: NSSize = NSSize(width: 20, height: 20), color: NSColor = .black) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            draw(state, in: NSRect(origin: .zero, size: size), color: color)
            return true
        }
    }

    static func draw(_ state: State, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 20, yBy: rect.height / 20)
        transform.concat()
        color.setStroke()
        let body = NSBezierPath()
        body.lineWidth = 1.9; body.lineCapStyle = .round; body.lineJoinStyle = .round
        if state == .closed || state == .paused {
            body.appendRoundedRect(NSRect(x: 3, y: 3, width: 14, height: 14), xRadius: 2, yRadius: 2)
            body.move(to: NSPoint(x: 3, y: 13)); body.line(to: NSPoint(x: 17, y: 13))
            body.move(to: NSPoint(x: 8, y: 8.5)); body.line(to: NSPoint(x: 12, y: 8.5))
            if state == .paused {
                body.move(to: NSPoint(x: 8, y: 5)); body.line(to: NSPoint(x: 8, y: 6))
                body.move(to: NSPoint(x: 12, y: 5)); body.line(to: NSPoint(x: 12, y: 6))
            }
        } else {
            if state == .left {
                let rotation = NSAffineTransform()
                rotation.translateX(by: 0, yBy: 20); rotation.rotate(byDegrees: -90); rotation.concat()
            }
            // The cabinet stays upright. The drawer front slides out below its opening.
            body.move(to: NSPoint(x: 5, y: 8)); body.line(to: NSPoint(x: 3, y: 8))
            body.line(to: NSPoint(x: 3, y: 16.5))
            body.curve(to: NSPoint(x: 4.5, y: 18), controlPoint1: NSPoint(x: 3, y: 17.4), controlPoint2: NSPoint(x: 3.6, y: 18))
            body.line(to: NSPoint(x: 15.5, y: 18))
            body.curve(to: NSPoint(x: 17, y: 16.5), controlPoint1: NSPoint(x: 16.4, y: 18), controlPoint2: NSPoint(x: 17, y: 17.4))
            body.line(to: NSPoint(x: 17, y: 8)); body.line(to: NSPoint(x: 15, y: 8))
            body.appendRoundedRect(NSRect(x: 5, y: 1, width: 10, height: 11), xRadius: 1.5, yRadius: 1.5)
            body.move(to: NSPoint(x: 8, y: 5.5)); body.line(to: NSPoint(x: 12, y: 5.5))
        }
        body.stroke()
    }

    static func applicationIcon() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let bounds = NSRect(x: 52, y: 52, width: 920, height: 920)
            let shape = NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
            NSColor.systemBlue.setFill(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.70, blue: 1, alpha: 1),
                       ending: NSColor(srgbRed: 0.08, green: 0.31, blue: 0.83, alpha: 1))!.draw(in: shape, angle: -90)
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(ovalIn: NSRect(x: -150, y: 580, width: 1350, height: 500)).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.28).setStroke(); shape.lineWidth = 3; shape.stroke()
            draw(.closed, in: NSRect(x: 132, y: 132, width: 760, height: 760), color: .white)
            return true
        }
    }
}
