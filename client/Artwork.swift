import AppKit
import ImageIO
import SwiftUI

/// Memory and disk cache for Apple Music artwork. Only HTTPS images from
/// Apple's artwork CDN are loaded.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSURL, NSImage>()
    private var pending: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.countLimit = 600
        thumbnails.countLimit = 1200
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Helix/Artwork", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16_000_000, diskCapacity: 300_000_000, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }
    private var airPlayArtwork: [URL: Data] = [:]
    private var airPlayArtworkOrder: [URL] = []
    func airPlayArtworkData(_ url: URL) -> Data? { airPlayArtwork[url] }

    /// Receiver artwork is an opaque in-memory URL, never a sender-provided path.
    func receiveAirPlayArtwork(_ data: Data) -> URL? {
        guard data.count <= 5 * 1024 * 1024,
              data.starts(with: [0xff, 0xd8, 0xff]) || data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height),
              let image = NSImage(data: data) else { return nil }
        let url = URL(string: "airplay-artwork://cover/\(UUID().uuidString)")!
        memory.setObject(image, forKey: url as NSURL)
        airPlayArtwork[url] = data; airPlayArtworkOrder.append(url)
        while airPlayArtworkOrder.count > 8 {
            let old = airPlayArtworkOrder.removeFirst(); airPlayArtwork[old] = nil; memory.removeObject(forKey: old as NSURL)
        }
        return url
    }
    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    // MARK: Display-sized versions

    /// Large artwork shown small looks pixelated: the display scales it down in one
    /// step without filtering. Views get a version drawn at their own pixel size
    /// with high-quality interpolation instead.
    private let thumbnails = NSCache<NSString, NSImage>()
    static func bucket(_ pixels: CGFloat) -> Int { max(64, Int((pixels / 32).rounded(.up)) * 32) }
    func cached(_ url: URL, pixels: Int) -> NSImage? {
        thumbnails.object(forKey: "\(pixels)@\(url.absoluteString)" as NSString)
    }
    func image(for url: URL, pixels: Int) async -> NSImage? {
        if let thumbnail = cached(url, pixels: pixels) { return thumbnail }
        guard let full = await image(for: url) else { return nil }
        let result = await Task.detached(priority: .userInitiated) { Self.downsample(full, to: pixels) }.value ?? full
        thumbnails.setObject(result, forKey: "\(pixels)@\(url.absoluteString)" as NSString)
        return result
    }
    nonisolated private static func downsample(_ image: NSImage, to pixels: Int) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = max(source.width, source.height)
        guard longest > pixels else { return image }
        let scale = Double(pixels) / Double(longest)
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
    }
    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard url.scheme == "https", url.host?.hasSuffix(".mzstatic.com") == true else { return nil }
        if let task = pending[url] { return await task.value }
        let session = self.session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct ArtworkView: View {
    let url: URL?
    var symbol = "music.note"
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?
    @State private var side: CGFloat = 0
    @Environment(\.displayScale) private var displayScale
    /// Pixel size this view needs, rounded so small layout changes reuse the same version.
    private var pixels: Int { ArtworkCache.bucket(side * displayScale) }
    private struct Key: Equatable { let url: URL?; let pixels: Int }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).antialiased(true)
                    .scaledToFill().transition(.opacity)
            } else {
                Image(systemName: symbol).imageScale(.large).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .onGeometryChange(for: CGFloat.self) { max($0.size.width, $0.size.height) } action: { side = $0 }
        .accessibilityHidden(true)
        .task(id: Key(url: url, pixels: side > 0 ? pixels : 0)) {
            guard let url else { image = nil; return }
            guard side > 0 else { return }   // wait for the first layout to know the size
            if let cached = ArtworkCache.shared.cached(url, pixels: pixels) { image = cached; return }
            // Keep the previous image until the new one is there (no blank flash).
            let loaded = await ArtworkCache.shared.image(for: url, pixels: pixels)
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}
