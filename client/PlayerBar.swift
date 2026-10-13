import SwiftUI

/// Transport, progress and volume at the bottom of the window. This is the
/// only view observing the player's position, which changes five times a second.
struct PlayerBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var player: AudioPlayer
    @ObservedObject var queue: PlaybackQueue
    @State private var hoveringArtwork = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0

    private var failure: String? { queue.failure ?? player.failure }
    private var hasTrack: Bool { player.hasTrack }
    private var title: String { player.displayTitle ?? queue.state.current?.title ?? "Not connected" }
    /// The catalog song behind the current title; AirPlay has none.
    private var songID: String? { player.airPlay == nil ? (player.stream?.id ?? queue.state.current?.catalogID) : nil }
    private var artist: String { player.displayArtist ?? queue.state.current?.artist ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            if let failure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(failure).font(.callout).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { queue.failure = nil; player.failure = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider()
            }
            HStack(spacing: 18) {
                // Only the transport has a minimum; the sides shrink and truncate first.
                nowPlaying.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                transport.frame(minWidth: 200, maxWidth: 480).layoutPriority(1)
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeOut(duration: 0.2), value: failure)
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            Button { app.openNowPlaying() } label: {
                ArtworkView(url: player.displayArtwork ?? (player.airPlay == nil ? queue.state.current?.artwork : nil), cornerRadius: 5)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if player.loading { ProgressView().controlSize(.small) }
                        else if hoveringArtwork {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hoveringArtwork = inside } }
            .help("Open full-screen player (⇧⌘F)")
            .accessibilityLabel("Open Full-Screen Player")
            VStack(alignment: .leading, spacing: 2) {
                LinkText(text: player.loading && !hasTrack ? "Loading …" : (hasTrack || queue.state.current != nil ? title : "Not Playing"),
                         help: "Go to Album", action: songID.map { id in { app.goToAlbum(songID: id) } })
                    .font(.callout.weight(.semibold)).lineLimit(1)
                if !artist.isEmpty {
                    LinkText(text: artist, help: "Go to Artist", action: songID.map { id in { app.goToArtist(songID: id) } })
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let track = player.airPlay {
                    Label(track.quality, systemImage: "airplay.audio").font(.caption2).foregroundStyle(.secondary)
                } else if let stream = player.stream { QualityBadge(stream: stream, outputRate: player.outputRate) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(hasTrack ? "Current song: \(title), \(artist)" : "Not Playing")
        }
    }

    private var transport: some View {
        VStack(spacing: 4) {
            HStack(spacing: 22) {
                Button { queue.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
                    .help("Previous song (⌘←)").accessibilityLabel("Previous Song")
                    .disabled(!player.canSeek)
                Button { queue.toggle() } label: {
                    Image(systemName: player.airPlay != nil ? "stop.fill" : player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 30, height: 26)
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(player.airPlay != nil ? "Disconnect AirPlay" : player.playing ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(player.airPlay != nil ? "Disconnect AirPlay" : player.playing ? "Pause" : "Play")
                .disabled(!app.canControlPlayback)
                Button { queue.advance() } label: { Image(systemName: "forward.fill").font(.title3) }
                    .help("Next song (⌘→)").accessibilityLabel("Next Song")
                    .disabled(player.airPlay != nil || queue.state.upcoming.isEmpty)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            HStack(spacing: 8) {
                Text(formatTime(scrubbing ? scrubPosition : player.position))
                    .frame(width: 44, alignment: .trailing)
                Slider(value: Binding(get: { scrubbing ? scrubPosition : player.position }, set: { scrubPosition = $0 }),
                       in: 0...max(1, player.duration)) { editing in
                    if editing { scrubPosition = player.position; scrubbing = true } else { scrubbing = false; player.seek(scrubPosition) }
                }
                .controlSize(.mini)
                .disabled(!player.canSeek)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(player.position)) of \(formatTime(player.duration))")
                Text(hasTrack ? "-" + formatTime(max(0, player.duration - (scrubbing ? scrubPosition : player.position))) : "0:00")
                    .frame(width: 44, alignment: .leading)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).controlSize(.mini).frame(width: 84)
                .accessibilityLabel("Volume")
                .help("Volume (⌘↑ / ⌘↓)")
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Hi-Res Lossless · 24-bit / 96 kHz", with a hint when the device plays at another rate.
private struct QualityBadge: View {
    let stream: TrackStream
    let outputRate: Double
    @AppStorage(AudioPlayer.matchRateKey) private var matchRate = true
    private var differs: Bool { outputRate > 0 && Int(outputRate) != stream.rate }

    var body: some View {
        HStack(spacing: 4) {
            LosslessMark().frame(width: 15, height: 9)
            Text(stream.rate > 48_000 ? "Hi-Res Lossless" : "Lossless").fontWeight(.semibold)
            Text("\(stream.depth)-bit / \(kHz(stream.rate))")
            // Only a hint when matching is on but the device could not follow.
            if differs && matchRate { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(help)
    }
    private var help: String {
        guard outputRate > 0 else { return "" }
        if !differs { return "Output at \(kHz(Int(outputRate))), no resampling" }
        return matchRate ? "The output device does not support \(kHz(stream.rate)) and plays at \(kHz(Int(outputRate)))."
                         : "Output through the system mixer at \(kHz(Int(outputRate))). Sample-rate matching is off."
    }
}

func kHz(_ rate: Int) -> String { String(format: "%g kHz", Double(rate) / 1000) }
