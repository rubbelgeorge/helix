import AppKit
import Combine
import MediaPlayer

/// Publishes the current title to Control Center, the menu bar Now Playing
/// module and the keyboard media keys. AVAudioEngine does not do this on its
/// own, so state and elapsed time are reported explicitly.
@MainActor
final class NowPlayingController {
    private let player: AudioPlayer
    private let queue: PlaybackQueue
    private var subscriptions: Set<AnyCancellable> = []
    private var reportedPosition = 0.0
    private var reportedAt = Date()
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(player: AudioPlayer, queue: PlaybackQueue) {
        self.player = player; self.queue = queue
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.queue.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.queue.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, !self.queue.state.upcoming.isEmpty else { return .noSuchContent }
            self.queue.advance(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.queue.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent, self.player.canSeek else { return .commandFailed }
            self.player.seek(event.positionTime); return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        player.$airPlay.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        player.$stream.combineLatest(player.$playing, player.$loading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.update() }
            .store(in: &subscriptions)
        // Elapsed time is extrapolated by the system; report only seeks and drift.
        player.$position
            .sink { [weak self] position in
                guard let self, self.player.hasTrack else { return }
                let expected = self.reportedPosition + (self.player.playing ? Date().timeIntervalSince(self.reportedAt) : 0)
                if abs(expected - position) > 1.5 { self.update() }
            }
            .store(in: &subscriptions)
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = player.airPlay == nil && !queue.state.upcoming.isEmpty
        commands.previousTrackCommand.isEnabled = player.canSeek
        commands.changePlaybackPositionCommand.isEnabled = player.canSeek
        commands.playCommand.isEnabled = player.airPlay == nil
        commands.pauseCommand.isEnabled = player.airPlay == nil
        commands.togglePlayPauseCommand.isEnabled = player.airPlay == nil
        guard player.hasTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = player.loading ? .interrupted : .stopped
            return
        }
        reportedPosition = player.position; reportedAt = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.displayTitle ?? "AirPlay",
            MPMediaItemPropertyArtist: player.displayArtist ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork, artworkURL == player.displayArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.playing ? .playing : .paused
        if let url = player.displayArtwork, url != artworkURL { loadArtwork(url) }
    }

    private func loadArtwork(_ url: URL) {
        artworkURL = url; artwork = nil
        Task { [weak self] in
            guard let image = await ArtworkCache.shared.image(for: url), let self, self.artworkURL == url else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.update()
        }
    }
}
