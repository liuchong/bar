import AppKit
import ScreenCaptureKit

/// Samples only the narrow rectangles occupied by the drawer, excluding Bar's own windows.
@MainActor
enum DrawerContrast {
    static func prefersLight(luminance: Double, previous: Bool?) -> Bool {
        // A small dead band prevents flicker on middle-gray backgrounds.
        let threshold = previous.map { $0 ? 0.20 : 0.16 } ?? 0.179
        return luminance < threshold
    }

    static func sample(_ frames: [CGRect]) async throws -> [Double?] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var values: [Double?] = []
        for frame in frames {
            guard !Task.isCancelled else { return [] }
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                values.append(nil); continue
            }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                       width: frame.width, height: frame.height)
            config.width = 64; config.height = 8; config.showsCursor = false
            config.scalesToFit = true; config.preservesAspectRatio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            values.append(luminance(of: image))
        }
        return values
    }

    static func luminance(of image: CGImage) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 64 * 8 * 4)
        return bytes.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: 64, height: 8, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 8))
            func linear(_ byte: UInt8) -> Double {
                let value = Double(byte) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let sum = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) {
                $0 + 0.2126 * linear(pixels[$1]) + 0.7152 * linear(pixels[$1 + 1]) + 0.0722 * linear(pixels[$1 + 2])
            }
            return sum / (64 * 8)
        }
    }
}
