import AVFoundation
import AppKit
import CryptoKit
import SwiftUI

/// Finds animated album covers ("motion artwork"). Apple's public API strips
/// `editorialVideo`; the internal API host returns it for the token of the
/// embedded Apple Music client. The videos are unencrypted HLS without audio.
@MainActor
final class AnimatedArtworkService {
    static let shared = AnimatedArtworkService()
    static let settingKey = "animatedArtwork"
    private var albums: [String: URL?] = [:]
    private var songs: [String: URL?] = [:]

    /// The album video for a catalog song, in one request (song plus its album).
    func video(forSong id: String, service: WrapperService) async -> URL? {
        guard Self.valid(id) else { return nil }
        if let cached = songs[id] { return cached }
        let url = await fetch("songs/\(id)?include=albums&extend=editorialVideo", service: service) { (response: SongResponse) in
            response.data.first?.relationships?.albums?.data.first?.attributes?.editorialVideo?.best
        }
        songs[id] = url
        return url
    }
    func video(forAlbum id: String, service: WrapperService) async -> URL? {
        guard Self.valid(id) else { return nil }
        if let cached = albums[id] { return cached }
        let url = await fetch("albums/\(id)?extend=editorialVideo", service: service) { (response: AlbumResponse) in
            response.data.first?.attributes?.editorialVideo?.best
        }
        albums[id] = url
        return url
    }

    // MARK: Local copies for seamless loops

    /// Seamless looping (AVPlayerLooper) needs a file, not an HLS stream. Apple's
    /// motion artwork is short; each variant is one fragmented MP4 addressed by
    /// byte ranges, so the whole file is downloaded once and cached.
    private var localFiles: [URL: Task<URL?, Never>] = [:]
    func localFile(for master: URL) async -> URL? {
        if let task = localFiles[master] { return await task.value }
        let task = Task<URL?, Never> { await Self.download(master) }
        localFiles[master] = task
        let file = await task.value
        if file == nil { localFiles[master] = nil }   // allow a retry later
        return file
    }
    nonisolated private static func download(_ master: URL) async -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Helix/MotionArtwork", isDirectory: true)
        let name = SHA256.hash(data: Data(master.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name + ".mp4")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        func trusted(_ url: URL) -> Bool { url.scheme == "https" && url.host?.hasSuffix(".apple.com") == true }
        func text(_ url: URL) async -> String? {
            guard trusted(url), let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return nil }
            return String(data: data, encoding: .utf8)
        }
        // AVC plays with hardware decoding on every supported Mac, Intel included.
        guard trusted(master), let masterText = await text(master) else { return nil }
        let lines = masterText.components(separatedBy: .newlines)
        var best: (width: Int, url: URL)?
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") && line.contains("avc1") && index + 1 < lines.count {
            let width = line.range(of: #"RESOLUTION=(\d+)x"#, options: .regularExpression)
                .flatMap { Int(line[$0].dropFirst("RESOLUTION=".count).dropLast()) } ?? 0
            guard width <= 1080, width > (best?.width ?? -1),
                  let url = URL(string: lines[index + 1].trimmingCharacters(in: .whitespaces), relativeTo: master)?.absoluteURL else { continue }
            best = (width, url)
        }
        guard let variant = best?.url, let variantText = await text(variant) else { return nil }
        // One file behind all segments: download it whole.
        let references = variantText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let mapLine = variantText.components(separatedBy: .newlines).first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
              let uri = mapLine.range(of: #"URI="[^"]+""#, options: .regularExpression).map({ String(mapLine[$0].dropFirst(5).dropLast()) }),
              !references.isEmpty, references.allSatisfy({ $0 == uri }),
              let source = URL(string: uri, relativeTo: variant)?.absoluteURL, trusted(source),
              let (data, response) = try? await URLSession.shared.data(from: source),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000, data.count < 80_000_000 else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private func fetch<T: Decodable>(_ path: String, service: WrapperService, pick: (T) -> URL?) async -> URL? {
        guard let account = try? await service.account(), account.authenticated,
              let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(Storefront.current)/\(path)"),
              let data = try? await LibraryService(wrapper: service).data(url, account: account),
              let response = try? JSONDecoder().decode(T.self, from: data),
              let video = pick(response), video.scheme == "https", video.host?.hasSuffix(".apple.com") == true else { return nil }
        return video
    }
    private static func valid(_ id: String) -> Bool { !id.isEmpty && id.count < 30 && id.allSatisfy { $0.isASCII && $0.isNumber } }

    private struct EditorialVideo: Decodable {
        struct Motion: Decodable { let video: String? }
        let motionSquareVideo1x1: Motion?
        let motionDetailSquare: Motion?
        /// Square variants only; the tall and wide ones belong to editorial banners.
        var best: URL? { (motionSquareVideo1x1?.video ?? motionDetailSquare?.video).flatMap(URL.init(string:)) }
    }
    private struct Attributes: Decodable { let editorialVideo: EditorialVideo? }
    private struct Album: Decodable { let attributes: Attributes? }
    private struct AlbumResponse: Decodable { let data: [Album] }
    private struct SongResponse: Decodable {
        let data: [Song]
        struct Song: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let albums: Albums? }
        struct Albums: Decodable { let data: [Album] }
    }
}

/// A cover that turns into its animated version when one exists: the static
/// artwork shows first, the muted video loop fades in once its first frame is ready.
struct AnimatedCover<Placeholder: View>: View {
    let video: URL?
    let placeholder: Placeholder
    @AppStorage(AnimatedArtworkService.settingKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ready = false

    init(video: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.video = video; self.placeholder = placeholder()
    }

    var body: some View {
        ZStack {
            placeholder
            if let video, enabled, !reduceMotion {
                LoopingVideo(url: video, ready: $ready)
                    .opacity(ready ? 1 : 0)
                    .animation(.easeInOut(duration: 0.6), value: ready)
                    .id(video)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: video) { ready = false }
    }
}

/// Muted, endlessly looping HLS video in an AVPlayerLayer, without controls.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL
    @Binding var ready: Bool

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.onReady = { ready = true }
        view.play(url)
        return view
    }
    func updateNSView(_ view: PlayerView, context: Context) {}
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        private var player = AVQueuePlayer()
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var loop: NSObjectProtocol?
        private var readyObservation: NSKeyValueObservation?
        private var loading: Task<Void, Never>?
        var onReady: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.addSublayer(playerLayer)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.onReady?() }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
        /// Plays a cached local copy with AVPlayerLooper, which loops without a gap.
        /// Seeking back at the end (the stream fallback) shows a black frame.
        func play(_ url: URL) {
            loading = Task { @MainActor [weak self] in
                let file = await AnimatedArtworkService.shared.localFile(for: url)
                guard !Task.isCancelled, let self else { return }
                if let file {
                    self.looper = AVPlayerLooper(player: self.player, templateItem: AVPlayerItem(url: file))
                } else {
                    let item = AVPlayerItem(url: url)
                    item.preferredMaximumResolution = CGSize(width: 1400, height: 1400)
                    self.player.replaceCurrentItem(with: item)
                    self.loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                        self?.player.seek(to: .zero); self?.player.play()
                    }
                }
                self.player.play()
            }
        }
        func stop() {
            loading?.cancel()
            looper?.disableLooping(); looper = nil
            player.pause(); player.removeAllItems()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            readyObservation = nil
        }
    }
}
