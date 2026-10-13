import AppKit
import SwiftUI

/// Dominant colors of an artwork, tuned as a backdrop for white text.
/// The image is reduced to 32×32 pixels and grouped by hue and brightness;
/// buckets are ranked by area weighted with saturation, so a small vivid
/// accent can win over a large dull area, as in the Music app.
struct ArtworkPalette: Equatable {
    let colors: [Color]

    static let fallback = ArtworkPalette(colors: [
        Color(red: 0.55, green: 0.10, blue: 0.24), Color(red: 0.30, green: 0.08, blue: 0.22),
        Color(red: 0.62, green: 0.20, blue: 0.30), Color(red: 0.16, green: 0.06, blue: 0.14),
    ])

    static func extract(from image: NSImage, count: Int = 4) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        struct Bucket { var red = 0.0, green = 0.0, blue = 0.0, count = 0.0, score = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset]) / 255, green = Double(pixels[offset + 1]) / 255, blue = Double(pixels[offset + 2]) / 255
            let (hue, saturation, brightness) = hsb(red, green, blue)
            // Grays share buckets by brightness only; colors by 12 hues × 3 brightness steps.
            let key = saturation < 0.18 ? 1000 + Int(brightness * 2.99) : Int(hue * 11.99) * 3 + Int(brightness * 2.99)
            var bucket = buckets[key, default: Bucket()]
            bucket.red += red; bucket.green += green; bucket.blue += blue; bucket.count += 1
            bucket.score += 0.25 + saturation * (0.4 + brightness)
            buckets[key] = bucket
        }
        var chosen: [(Double, Double, Double)] = []
        for bucket in buckets.values.sorted(by: { $0.score > $1.score }) where chosen.count < count {
            let color = (bucket.red / bucket.count, bucket.green / bucket.count, bucket.blue / bucket.count)
            if chosen.allSatisfy({ distance($0, color) > 0.16 }) { chosen.append(color) }
        }
        guard !chosen.isEmpty else { return fallback }
        while chosen.count < count { let base = chosen[chosen.count % max(1, chosen.count)]; chosen.append((base.0 * 0.6, base.1 * 0.6, base.2 * 0.6)) }
        return ArtworkPalette(colors: chosen.map(backdrop))
    }

    /// Keeps hue, lifts saturation a little and caps brightness so white text stays readable.
    private static func backdrop(_ rgb: (Double, Double, Double)) -> Color {
        let (hue, saturation, brightness) = hsb(rgb.0, rgb.1, rgb.2)
        // Grays get a lower ceiling: a light gray behind white text reads poorly.
        let ceiling = saturation < 0.2 ? 0.46 : 0.62
        return Color(hue: hue, saturation: min(1, saturation * 1.15), brightness: min(ceiling, max(0.14, brightness * 0.85)))
    }
    private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }
    private static func hsb(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == green { hue = (blue - red) / delta + 2 }
            else { hue = (red - green) / delta + 4 }
            hue /= 6; if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }
}
