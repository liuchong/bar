import AppKit
import ScreenCaptureKit

struct MenuBarImage {
    let image: NSImage
    let dark: Bool
    let width: CGFloat
}

/// Captures only the menu-bar strip, never stores screenshots, and extracts the original glyph.
@MainActor
final class MenuBarImages {
    private(set) static var backgroundDark: [CGDirectDisplayID: Bool] = [:]
    static var authorized: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccess() {
        CGRequestScreenCaptureAccess()
        if !authorized, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func capture(_ items: [MenuItem]) async throws -> [String: MenuBarImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [String: MenuBarImage] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let bounds = CGDisplayBounds(display.displayID)
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top, 24)
            let strip = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
            let visible = items.filter { strip.contains($0.frame) && $0.frame.width > 1 && $0.frame.height > 1 }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            filter.includeMenuBar = true
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            config.width = Int(bounds.width * scale); config.height = Int(height * scale)
            config.showsCursor = false; config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            backgroundDark[display.displayID] = isDark(image)
            var foregroundVotes: [Bool] = []
            for item in visible {
                let rect = item.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
                guard let crop = image.cropping(to: rect), let glyph = extract(crop, points: item.frame.size) else { continue }
                result[item.id] = glyph
                if glyph.image.isTemplate { foregroundVotes.append(glyph.dark) }
            }
            if !foregroundVotes.isEmpty {
                backgroundDark[display.displayID] = foregroundVotes.filter { $0 }.count * 2 >= foregroundVotes.count
            }
        }
        return result
    }

    private static func isDark(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 128 * 4)
        return bytes.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: 128, height: 1, bitsPerComponent: 8,
                bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 1))
            let luminance = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) {
                $0 + 0.2126 * Double(pixels[$1]) + 0.7152 * Double(pixels[$1 + 1]) + 0.0722 * Double(pixels[$1 + 2])
            }
            return luminance / 128 < 128
        }
    }

    /// Estimate the wallpaper behind each pixel from the quiet top/bottom margins of its column.
    /// Keep original color for colored status glyphs; monochrome glyphs become adaptive templates.
    private static func extract(_ image: CGImage, points: CGSize) -> MenuBarImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 4, w < 2048, h < 256 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var foreground = 0, colorful = 0, brightness = 0.0
            for x in 0..<w {
                let top = x * 4, bottom = ((h - 1) * w + x) * 4
                let start = (0..<3).map { Double(buffer[top + $0]) }
                let end = (0..<3).map { Double(buffer[bottom + $0]) }
                for y in 0..<h {
                    let i = (y * w + x) * 4, t = Double(y) / Double(h - 1)
                    let rgb = (0..<3).map { Double(buffer[i + $0]) }
                    let background = (0..<3).map { start[$0] * (1 - t) + end[$0] * t }
                    let contrast = (0..<3).map { abs(rgb[$0] - background[$0]) }.max() ?? 0
                    let alpha = min(1, max(0, (contrast - 10) / 40))
                    if alpha > 0.6 {
                        foreground += 1
                        brightness += (rgb[0] + rgb[1] + rgb[2]) / 3
                        if (rgb.max()! - rgb.min()!) > 45 { colorful += 1 }
                    }
                    for c in 0..<3 { buffer[i + c] = UInt8(min(255, max(0, rgb[c] * alpha))) }
                    buffer[i + 3] = UInt8(alpha * 255)
                }
            }
            guard foreground > 3 else { return nil }
            let template = Double(colorful) / Double(foreground) < 0.12
            if template {
                for i in stride(from: 0, to: buffer.count, by: 4) {
                    buffer[i] = buffer[i + 3]; buffer[i + 1] = buffer[i + 3]; buffer[i + 2] = buffer[i + 3]
                }
            }
            guard let output = context.makeImage() else { return nil }
            let icon = NSImage(cgImage: output, size: points); icon.isTemplate = template
            return MenuBarImage(image: icon, dark: brightness / Double(foreground) > 127, width: points.width)
        }
    }
}
