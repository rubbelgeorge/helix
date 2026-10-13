import AppKit
import SwiftUI

/// Full-window player shown over the main window's content: large artwork on a slowly moving
/// mesh gradient made from the artwork's colors. Title, quality, timeline and
/// "Playing Next" stay; transport and volume fade out after a few seconds
/// without mouse movement while music plays, and the cover grows into the
/// space. Esc closes it. It does not enter macOS full screen by itself;
/// the window's green button does that, with the player inside.
struct NowPlayingFullView: View {
    @ObservedObject var player: AudioPlayer
    @ObservedObject var queue: PlaybackQueue
    @State private var image: NSImage?
    @State private var palette = ArtworkPalette.fallback
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var video: URL?
    @StateObject private var albumPlayback = AlbumPlaybackModel()
    @AppStorage(AlbumPlaybackModel.settingKey) private var albumViewEnabled = true
    /// The album being played in order, shown as a track list beside the cover.
    private var album: CatalogService.AlbumDetail? { player.airPlay == nil ? albumPlayback.active : nil }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var artworkURL: URL? { largeArtwork(player.displayArtwork ?? (player.airPlay == nil ? queue.state.current?.artwork : nil)) }
    private var title: String { player.displayTitle ?? queue.state.current?.title ?? "Not Playing" }
    private var artist: String { player.displayArtist ?? queue.state.current?.artist ?? "" }
    private var songID: String? { player.airPlay == nil ? (player.stream?.id ?? queue.state.current?.catalogID) : nil }

    // Appearance, adjustable in the settings popover next to the close button.
    @AppStorage(NowPlayingAppearance.layoutKey) private var layoutRaw = NowPlayingAppearance.Layout.stacked.rawValue
    @AppStorage(NowPlayingAppearance.textScaleKey) private var textScale = 1.0
    @AppStorage(NowPlayingAppearance.coverScaleKey) private var coverScale = 1.0
    @AppStorage(NowPlayingAppearance.spacingKey) private var spacingScale = 1.0
    @AppStorage(NowPlayingAppearance.marginKey) private var margin = 56.0
    @AppStorage(NowPlayingAppearance.upNextKey) private var showUpNext = true
    @AppStorage(NowPlayingAppearance.qualityKey) private var showQuality = true
    @State private var showingSettings = false
    @State private var mouse = MouseActivity()
    private var sideBySide: Bool { layoutRaw == NowPlayingAppearance.Layout.side.rawValue }
    private var t: CGFloat { CGFloat(textScale) }

    // Fixed heights of the rows, so the cover size can change in the same
    // animation as rows appearing or disappearing.
    private var gap: CGFloat { 28 * CGFloat(spacingScale) }
    private var rowGap: CGFloat { 20 * CGFloat(spacingScale) }
    private var hasQuality: Bool { showQuality && (player.airPlay != nil || player.stream != nil) }
    private var infoHeight: CGFloat { 36 * t + (album == nil ? 28 * t : 0) + (hasQuality ? 32 * t : 0) + 4 }
    private var timelineHeight: CGFloat { 26 + 16 * t }
    private let transportHeight: CGFloat = 70, volumeHeight: CGFloat = 22
    private var upNextHeight: CGFloat { max(34, 38 * t) }
    private var showsUpNext: Bool { showUpNext && album == nil && queue.state.upcoming.first != nil }
    /// Height of everything except the cover; transport and volume hide.
    private var controlsHeight: CGFloat {
        var height = infoHeight + rowGap + timelineHeight
        if controlsVisible { height += transportHeight + volumeHeight + 2 * rowGap }
        if showsUpNext { height += upNextHeight + rowGap }
        return height
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size, edge = CGFloat(margin)
            ZStack {
                MeshBackdrop(palette: palette, animated: !reduceMotion)
                if let album {
                    // Album view: cover and controls on the left, the album's titles on the right.
                    let listWidth = min(640, max(340, (size.width - 2 * edge) * 0.42))
                    let side = max(160, min(size.height - 2 * edge - gap - controlsHeight, size.width - 2 * edge - gap * 2 - listWidth) * CGFloat(coverScale))
                    HStack(alignment: .center, spacing: gap * 2) {
                        VStack(spacing: gap) {
                            artwork(side: side)
                            controls(alignment: .leading).frame(width: max(side, 300))
                        }
                        AlbumTrackList(album: album, currentID: queue.state.current?.catalogID, playing: player.playing, textScale: t)
                            .frame(width: listWidth)
                            .frame(maxHeight: size.height - 2 * edge - 24)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sideBySide {
                    // Cover left at full height, everything else in a column on the right.
                    let column = min(560, max(320, size.width * 0.34))
                    let side = max(160, min(size.height - 2 * edge, size.width - 2 * edge - gap * 2 - column) * CGFloat(coverScale))
                    HStack(spacing: gap * 2) {
                        artwork(side: side)
                        controls(alignment: .leading).frame(width: column)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The cover takes whatever height the visible rows leave free.
                    let side = max(160, min(size.width - 2 * edge, size.height - 2 * edge - gap - controlsHeight) * CGFloat(coverScale))
                    VStack(spacing: gap) {
                        artwork(side: side)
                        controls(alignment: .center).frame(width: min(size.width - 2 * edge, max(side, 420)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                topButtons
            }
            .animation(resize, value: layoutRaw)
            .animation(resize, value: textScale)
            .animation(resize, value: coverScale)
            .animation(resize, value: spacingScale)
            .animation(resize, value: margin)
            .animation(resize, value: album?.album.id)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .background(WindowChrome())
        // Real pointer movement only: hover tracking also fires when the cover
        // resizes under a resting pointer, which brought controls and pointer back.
        .onAppear { mouse.start { showControls(); scheduleCursorHide() } }
        .onDisappear { mouse.stop() }
        // Only a real pause brings the controls back; title changes (automatic or
        // via media keys) don't. Resuming lets them fade out again.
        .onChange(of: player.paused) { _, paused in paused ? showControls() : scheduleHide() }
        .onChange(of: showingSettings) { _, open in open ? showControls() : scheduleHide(); scheduleCursorHide() }
        .onAppear { showControls(); scheduleCursorHide() }
        .onDisappear { hideTask?.cancel(); cursorTask?.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
        .task(id: artworkURL) { await loadArtwork() }
        .task(id: queue.state.current?.catalogID) {
            await albumPlayback.resolve(songID: queue.state.current?.catalogID, service: AppModel.shared.wrapper.service)
            albumPlayback.evaluate(queue.state, enabled: albumViewEnabled)
        }
        .onChange(of: queue.state) { _, state in albumPlayback.evaluate(state, enabled: albumViewEnabled) }
        .onChange(of: albumViewEnabled) { _, enabled in albumPlayback.evaluate(queue.state, enabled: enabled) }
        .task(id: songID) {
            video = nil
            if let songID { video = await AnimatedArtworkService.shared.video(forSong: songID, service: AppModel.shared.wrapper.service) }
        }
        #if SNAPSHOT
        .onReceive(NotificationCenter.default.publisher(for: .init("AMHideControls"))) { _ in withAnimation(resize) { controlsVisible = false } }
        .onReceive(NotificationCenter.default.publisher(for: .init("AMOpenNowPlayingSettings"))) { _ in withAnimation(resize) { controlsVisible = true }; showingSettings = true }
        #endif
    }

    private func controls(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: rowGap) {
            info(alignment: alignment).frame(height: infoHeight, alignment: .top)
            progress.frame(height: timelineHeight)
            if controlsVisible {
                transport.frame(height: transportHeight).transition(.opacity)
                volume.frame(height: volumeHeight).transition(.opacity)
            }
            if showsUpNext { upNext(alignment: alignment).frame(height: upNextHeight) }
        }
    }

    // MARK: Pieces

    private func artwork(side: CGFloat) -> some View {
        AnimatedCover(video: video) {
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.025, style: .continuous).fill(.white.opacity(0.08))
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).antialiased(true).scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "music.note").font(.system(size: side * 0.25, weight: .light)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.025, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.03)
        // Like the Music app: the artwork recedes slightly while paused.
        .scaleEffect(player.playing || reduceMotion ? 1 : 0.92)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: player.playing)
        .accessibilityLabel(image == nil ? "No artwork" : "Artwork of \(title)")
    }

    private func info(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4 * t) {
            LinkText(text: title, help: "Go to Album", action: songID.map { id in { AppModel.shared.goToAlbum(songID: id) } })
                .font(.system(size: 28 * t, weight: .bold)).lineLimit(1)
            if !artist.isEmpty, album == nil {
                LinkText(text: artist, help: "Go to Artist", action: songID.map { id in { AppModel.shared.goToArtist(songID: id) } })
                    .font(.system(size: 20 * t, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            if showQuality, let track = player.airPlay {
                Label(track.quality, systemImage: "airplay.audio")
                    .font(.system(size: 13 * t, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            } else if showQuality, let stream = player.stream {
                Label { Text("\(stream.rate > 48_000 ? "Hi-Res Lossless" : "Lossless") · \(stream.depth)-bit / \(kHz(stream.rate))") }
                    icon: { LosslessMark().frame(width: 18 * t, height: 11 * t) }
                    .font(.system(size: 12 * t, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10 * t).padding(.vertical, 4 * t)
                    .background(.white.opacity(0.12), in: Capsule())
                    .padding(.top, 6 * t)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private var progress: some View {
        VStack(spacing: 6) {
            CapsuleSlider(value: scrubbing ?? player.position, range: 0...max(1, player.duration), label: "Playback position",
                          valueText: "\(formatTime(player.position)) of \(formatTime(player.duration))") { value, done in
                if done { scrubbing = nil; player.seek(value) } else { scrubbing = value }
            }
            .disabled(!player.canSeek)
            HStack {
                Text(formatTime(scrubbing ?? player.position))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - (scrubbing ?? player.position))))
            }
            .font(.system(size: 11 * t).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Spacer()
            TransportButton(symbol: "backward.fill", size: 28, label: "Previous Song") { queue.previous() }
                .disabled(!player.canSeek)
            Spacer()
            TransportButton(symbol: player.airPlay != nil ? "stop.fill" : player.playing ? "pause.fill" : "play.fill", size: 44, label: player.airPlay != nil ? "Disconnect AirPlay" : player.playing ? "Pause" : "Play") { queue.toggle() }
            Spacer()
            TransportButton(symbol: "forward.fill", size: 28, label: "Next Song") { queue.advance() }
                .disabled(player.airPlay != nil || queue.state.upcoming.isEmpty)
            Spacer()
        }
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption)
            CapsuleSlider(value: Double(player.volume), range: 0...1, label: "Volume", valueText: "\(Int(player.volume * 100)) percent") { value, _ in
                player.volume = Float(value)
            }
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    @ViewBuilder private func upNext(alignment: HorizontalAlignment) -> some View {
        if let next = queue.state.upcoming.first {
            HStack(spacing: 10) {
                ArtworkView(url: next.artwork, cornerRadius: 4).frame(width: 32 * t, height: 32 * t).opacity(0.9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Playing Next").font(.system(size: 11 * t)).foregroundStyle(.white.opacity(0.55))
                    Text(next.artist.isEmpty ? next.title : "\(next.title) – \(next.artist)").font(.system(size: 13 * t)).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .accessibilityElement(children: .combine)
        }
    }

    private var topButtons: some View {
        VStack {
            HStack(spacing: 10) {
                Spacer()
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(showingSettings ? 0.28 : 0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Adjust Appearance")
                .accessibilityLabel("Adjust Appearance")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) { NowPlayingSettingsView() }
                Button { AppModel.shared.closeNowPlaying() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close full-screen player (Esc)")
                .accessibilityLabel("Close Full-Screen Player")
            }
            Spacer()
        }
        .padding(24)
        .opacity(controlsVisible ? 1 : 0)
    }

    // MARK: Behaviour

    /// Rows and cover size change in one spring, so the cover grows smoothly
    /// into the space the hidden rows leave.
    private var resize: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.88) }
    private func showControls() {
        if !controlsVisible { withAnimation(resize) { controlsVisible = true } }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            // Hide only while music plays (or the next title loads), never when paused or idle.
            guard !Task.isCancelled, !player.paused, player.playing || player.loading, scrubbing == nil, !showingSettings else { return }
            withAnimation(resize) { controlsVisible = false }
        }
    }
    /// Hides the pointer after a short rest, also while paused; any movement shows it again.
    @State private var cursorTask: Task<Void, Never>?
    private func scheduleCursorHide() {
        cursorTask?.cancel()
        cursorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !showingSettings, NSApp.isActive else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func loadArtwork() async {
        guard let url = artworkURL else { image = nil; withAnimation(.easeInOut(duration: 1)) { palette = .fallback }; return }
        // Show the smaller cached version at once, then swap in the large one.
        if let small = player.displayArtwork ?? (player.airPlay == nil ? queue.state.current?.artwork : nil), let cached = ArtworkCache.shared.cached(small), image == nil { image = cached }
        guard let loaded = await ArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
        let colors = ArtworkPalette.extract(from: loaded)
        withAnimation(.easeInOut(duration: 0.6)) { image = loaded }
        withAnimation(.easeInOut(duration: 1.2)) { palette = colors }
    }

    private func largeArtwork(_ url: URL?) -> URL? { url.flatMap(NowPlayingArtwork.large) }
}

/// Reports real pointer movement in the app's windows (not layout changes under the pointer).
final class MouseActivity {
    private var monitor: Any?
    func start(_ moved: @escaping () -> Void) {
        stop()
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { event in
            if event.type != .mouseMoved || event.deltaX != 0 || event.deltaY != 0 { moved() }
            return event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

/// Stored appearance of the full-window player.
enum NowPlayingAppearance {
    enum Layout: String, CaseIterable { case stacked, side }
    static let layoutKey = "nowPlaying.layout", textScaleKey = "nowPlaying.textScale", coverScaleKey = "nowPlaying.coverScale"
    static let spacingKey = "nowPlaying.spacing", marginKey = "nowPlaying.margin", upNextKey = "nowPlaying.upNext", qualityKey = "nowPlaying.quality"
    static func reset() {
        for key in [layoutKey, textScaleKey, coverScaleKey, spacingKey, marginKey, upNextKey, qualityKey, AlbumPlaybackModel.settingKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// Settings popover of the full-window player; changes apply live.
private struct NowPlayingSettingsView: View {
    @AppStorage(NowPlayingAppearance.layoutKey) private var layoutRaw = NowPlayingAppearance.Layout.stacked.rawValue
    @AppStorage(NowPlayingAppearance.textScaleKey) private var textScale = 1.0
    @AppStorage(NowPlayingAppearance.coverScaleKey) private var coverScale = 1.0
    @AppStorage(NowPlayingAppearance.spacingKey) private var spacingScale = 1.0
    @AppStorage(NowPlayingAppearance.marginKey) private var margin = 56.0
    @AppStorage(NowPlayingAppearance.upNextKey) private var showUpNext = true
    @AppStorage(NowPlayingAppearance.qualityKey) private var showQuality = true
    @AppStorage(AlbumPlaybackModel.settingKey) private var albumView = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.headline)
            Picker("Layout", selection: $layoutRaw) {
                Label("Cover on top", systemImage: "rectangle.portrait.topthird.inset.filled").tag(NowPlayingAppearance.Layout.stacked.rawValue)
                Label("Cover on the left", systemImage: "rectangle.lefthalf.inset.filled").tag(NowPlayingAppearance.Layout.side.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden()
            slider("Text size", value: $textScale, range: 0.7...1.8, display: "\(Int((textScale * 100).rounded())) %")
            slider("Cover size", value: $coverScale, range: 0.5...1.0, display: "\(Int((coverScale * 100).rounded())) %")
            slider("Spacing", value: $spacingScale, range: 0.4...2.0, display: "\(Int((spacingScale * 100).rounded())) %")
            slider("Margin", value: $margin, range: 16...160, display: "\(Int(margin)) pt")
            Divider()
            Toggle("Show “Playing Next”", isOn: $showUpNext)
            Toggle("Show quality", isOn: $showQuality)
            Toggle("Album view while listening to an album", isOn: $albumView)
                .help("Shows the track list when an album plays in order.")
            HStack {
                Spacer()
                Button("Reset") { withAnimation { NowPlayingAppearance.reset() } }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 300)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}

enum NowPlayingArtwork {
    /// Apple artwork URLs encode their size; request a sharp version for the big cover.
    static func large(_ url: URL) -> URL? {
        if url.scheme == "airplay-artwork" { return url }
        let text = url.absoluteString.replacingOccurrences(of: #"/\d{2,4}x\d{2,4}(bb|cc)?\."#, with: "/1400x1400bb.", options: .regularExpression)
        return URL(string: text) ?? url
    }
}

// MARK: - Backdrop

/// A 3×3 mesh gradient whose inner points drift slowly. Static with Reduce Motion.
private struct MeshBackdrop: View {
    let palette: ArtworkPalette
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) / 7)
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors, smoothsColors: true)
        }
        .overlay(RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 200, endRadius: 1400))
        .animation(.easeInOut(duration: 1.2), value: palette)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        let c = palette.colors + ArtworkPalette.fallback.colors
        return [c[0], c[1], c[2],
                c[3], c[0], c[1],
                c[2], c[3], c[0]]
    }
    private func points(_ t: Float) -> [SIMD2<Float>] {
        [[0, 0], [0.5 + 0.15 * sin(t * 0.8), 0], [1, 0],
         [0, 0.5 + 0.15 * cos(t * 0.7)], [0.5 + 0.18 * sin(t * 1.1), 0.5 + 0.18 * cos(t * 0.9)], [1, 0.5 + 0.15 * sin(t * 0.6)],
         [0, 1], [0.5 + 0.15 * cos(t * 0.75), 1], [1, 1]]
    }
}

// MARK: - Controls

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: size * 1.8, height: size * 1.6)
                .contentTransition(.symbolEffect(.replace))
                .background(Circle().fill(.white.opacity(hovering && enabled ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Thin white capsule slider that grows on hover, as in the Music app's full-screen player.
private struct CapsuleSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    let valueText: String
    let onChange: (Double, Bool) -> Void
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled
    private var fraction: Double { range.upperBound > range.lowerBound ? min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let height: CGFloat = hovering || dragging ? 10 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(enabled ? 0.9 : 0.4)).frame(width: max(height, geometry.size.width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = true; onChange(value(at: drag.location.x, width: geometry.size.width), false) }
                .onEnded { drag in dragging = false; onChange(value(at: drag.location.x, width: geometry.size.width), true) })
        }
        .frame(height: 22)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.15), value: hovering || dragging)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            onChange(min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step))), true)
        }
    }
    private func value(at x: CGFloat, width: CGFloat) -> Double {
        range.lowerBound + Double(min(1, max(0, x / max(1, width)))) * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Window

/// While the player is shown, the window's toolbar and title step back so the
/// player fills the whole window under the traffic lights. Restored on close.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = HostView()
        // Applied once the view is in the window; right after creation it may not be yet.
        view.onWindow = { [coordinator = context.coordinator] window in coordinator.apply(to: window) }
        return view
    }
    private final class HostView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let onWindow else { return }
            self.onWindow = nil
            DispatchQueue.main.async { onWindow(window) }
        }
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.restore() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var saved: (toolbar: Bool, transparent: Bool, title: NSWindow.TitleVisibility, fullSize: Bool)?
        private var observations: [NSKeyValueObservation] = []
        private var guardTimer: Timer?

        /// Hides the toolbar (search field included) in AppKit, which keeps the
        /// traffic lights; SwiftUI's own toolbar hiding removes them too. SwiftUI
        /// re-shows or replaces the toolbar when it rebuilds it, so the toolbar is
        /// watched and hidden again while the player is open.
        func apply(to window: NSWindow) {
            guard saved == nil else { return }
            self.window = window
            saved = (window.toolbar?.isVisible ?? false, window.titlebarAppearsTransparent, window.titleVisibility, window.styleMask.contains(.fullSizeContentView))
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            hideToolbar()
            observations = [window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.hideToolbar() } }]
            guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.hideToolbar() }
        }
        private func hideToolbar() {
            guard saved != nil, let window else { return }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            guard let toolbar = window.toolbar else { return }
            if toolbar.isVisible { toolbar.isVisible = false }
            if observations.count < 2 {
                observations.append(toolbar.observe(\.isVisible, options: [.new]) { [weak self] toolbar, _ in
                    DispatchQueue.main.async { if self?.saved != nil, toolbar.isVisible { toolbar.isVisible = false } }
                })
            }
        }
        func restore() {
            observations = []; guardTimer?.invalidate(); guardTimer = nil
            guard let window, let saved else { return }
            self.saved = nil
            if !saved.fullSize { window.styleMask.remove(.fullSizeContentView) }
            window.titleVisibility = saved.title
            window.titlebarAppearsTransparent = saved.transparent
            window.toolbar?.isVisible = saved.toolbar || window.toolbar != nil
        }
    }
}
