import SwiftUI

/// Decides whether the full-window player shows the album view: the current
/// title belongs to a catalog album and the queue continues with the album's
/// remaining titles in their original order (not shuffled, nothing in between).
@MainActor
final class AlbumPlaybackModel: ObservableObject {
    nonisolated static let settingKey = "nowPlaying.albumView"
    @Published private(set) var active: CatalogService.AlbumDetail?
    private var resolved: CatalogService.AlbumDetail?
    private var resolvedSong: String?
    /// The album stays active on its last title, where no queue order is left to compare.
    private var stickyAlbum: String?

    func resolve(songID: String?, service: WrapperService) async {
        guard let songID, CatalogService.validID(songID) else { resolved = nil; resolvedSong = nil; return }
        if resolvedSong == songID { return }
        resolvedSong = songID
        // Next title of the same album: no request.
        if let resolved, resolved.playableIDs.contains(songID) { return }
        resolved = nil
        guard let albumID = try? await CatalogService.shared.links(song: songID, service: service).album?.id,
              let detail = try? await CatalogService.shared.albumDetail(id: albumID, service: service),
              resolvedSong == songID else { return }
        resolved = detail
    }

    func evaluate(_ state: QueueState, enabled: Bool) {
        guard enabled, let album = resolved, let current = state.current?.catalogID,
              let index = album.playableIDs.firstIndex(of: current) else { set(nil); return }
        let ids = album.playableIDs
        let remaining = Array(ids[(index + 1)...])
        let followsAlbum = state.upcoming.prefix(remaining.count).map(\.catalogID) == remaining
        let started = !remaining.isEmpty || stickyAlbum == album.album.id
            || (index > 0 && state.history.last?.catalogID == ids[index - 1])
        set(followsAlbum && started ? album : nil)
    }
    private func set(_ album: CatalogService.AlbumDetail?) {
        stickyAlbum = album?.album.id
        if active != album { withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) { active = album } }
    }
}

/// The album's header and full track list, with the current title highlighted.
/// The list follows the playing title; it can be scrolled freely in between.
struct AlbumTrackList: View {
    let album: CatalogService.AlbumDetail
    let currentID: String?
    let playing: Bool
    let textScale: CGFloat
    @State private var hovered: String?
    private var t: CGFloat { textScale }
    private var multiDisc: Bool { album.discs.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * t) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(album.discs, id: \.self) { disc in
                            if multiDisc {
                                Text("CD \(disc)").font(.system(size: 12 * t, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 12).padding(.top, disc == album.discs.first ? 4 : 16).padding(.bottom, 4)
                            }
                            ForEach(album.tracks.filter { $0.disc == disc }) { track in row(track).id(track.id) }
                        }
                        footer
                    }
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.never)
                // Soft edges instead of hard cuts while titles scroll by.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: currentID) { scroll(proxy, animated: true) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4 * t) {
            LinkText(text: album.album.title, help: "Go to Album", action: { AppModel.shared.open(album.album) })
                .font(.system(size: 30 * t, weight: .bold)).lineLimit(2)
            LinkText(text: album.album.artist, help: "Go to Artist", action: { AppModel.shared.goToArtist(album: album.album) })
                .font(.system(size: 20 * t, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            let meta = [album.genre, album.releaseDate.map { String(Calendar.current.component(.year, from: $0)) }].compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.system(size: 13 * t, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
    }

    private func row(_ track: CatalogService.AlbumDetail.Track) -> some View {
        let item = track.item
        let current = item.catalogID != nil && item.catalogID == currentID
        let hovering = hovered == track.id && item.playable
        return Button {
            guard let index = album.tracks.firstIndex(of: track) else { return }
            AppModel.shared.playAll(album.tracks[index...].map(\.item))
        } label: {
            HStack(spacing: 14 * t) {
                ZStack {
                    if current {
                        // Wide enough for the full helix (not the simplified badge form).
                        LosslessMark(animating: playing).frame(width: 30 * t, height: 18 * t)
                    } else if hovering {
                        Image(systemName: "play.fill")
                    } else {
                        Text(track.number.map(String.init) ?? "–").monospacedDigit()
                    }
                }
                .font(.system(size: 14 * t, weight: .medium))
                .foregroundStyle(.white.opacity(current || hovering ? 1 : 0.5))
                .frame(width: 30 * t, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 16 * t, weight: current ? .semibold : .regular)).lineLimit(1)
                    // Guest artists only; the album artist is in the header.
                    if item.artist != album.album.artist, !item.artist.isEmpty {
                        Text(item.artist).font(.system(size: 13 * t)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(item.duration.flatMap { $0 > 0 ? formatTime($0) : nil } ?? "").font(.system(size: 13 * t).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12).padding(.vertical, 9 * t)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(current ? 0.16 : hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.playable)
        .opacity(item.playable ? 1 : 0.35)
        .onHover { hovered = $0 ? track.id : (hovered == track.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.2), value: current)
        .help(item.playable ? "Play from here" : "Not yet available on Apple Music")
        .accessibilityLabel("\(track.number.map { "\($0). " } ?? "")\(item.title)")
        .accessibilityValue(current ? "Now Playing" : item.playable ? "" : "Not available")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let date = album.releaseDate { Text(date.formatted(date: .long, time: .omitted)) }
            Text("\(album.tracks.count) songs, \(Int((album.totalDuration / 60).rounded())) minutes")
            if let copyright = album.copyright { Text(copyright).lineLimit(2) }
        }
        .font(.system(size: 12 * t)).foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 12).padding(.top, 18)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = album.tracks.first(where: { $0.item.catalogID == currentID })?.id else { return }
        // A little above the middle, so the next titles stay visible.
        let anchor = UnitPoint(x: 0.5, y: 0.3)
        if animated { withAnimation(.smooth(duration: 0.7)) { proxy.scrollTo(id, anchor: anchor) } }
        else { proxy.scrollTo(id, anchor: anchor) }
    }
}
