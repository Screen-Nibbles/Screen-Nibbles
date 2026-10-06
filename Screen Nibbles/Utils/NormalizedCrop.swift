import Foundation
import CoreGraphics

/// A screen/image rectangle with a top-left origin, independent of preview size.
struct NormalizedCrop: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    nonisolated init(rect: CGRect) {
        let bounded = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        x = bounded.isNull ? 0 : bounded.minX
        y = bounded.isNull ? 0 : bounded.minY
        width = bounded.isNull ? 0 : bounded.width
        height = bounded.isNull ? 0 : bounded.height
    }

    nonisolated var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    nonisolated func pixelRect(width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, x.isFinite, y.isFinite,
              self.width.isFinite, self.height.isFinite else { return nil }
        let bounded = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else { return nil }
        let pixels = CGRect(x: bounded.minX * Double(width), y: bounded.minY * Double(height),
                            width: bounded.width * Double(width), height: bounded.height * Double(height)).integral
        return pixels.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
