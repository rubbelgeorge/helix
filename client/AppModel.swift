import AppKit
import Combine
import Foundation
import SwiftUI

/// Owns the long-lived services and the window's navigation state.
/// It deliberately does not forward the player's frequent position updates;
/// only views that display playback progress observe `AudioPlayer` directly.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let wrapper: WrapperConnection
    let player: AudioPlayer
    let queue: PlaybackQueue
    let remote: HTTPRemote
    let airPlay: AirPlayReceiver
    private var nowPlaying: NowPlayingController?

    enum AccountState: Equatable { case unknown, signedOut, signedIn }
    @Published private(set) var account = AccountState.unknown
    let home = HomeModel()
    let browse = BrowseModel()
    @Published var category: LibraryCategory? = .home {
        didSet {
            guard oldValue != category else { return }
            path = []
            // The search page keeps its term; other sections start unfiltered.
            if category != .search { searchText = "" }
        }
    }
    /// Albums, playlists and artists opened on top of the selected section.
    @Published var path: [Route] = []
    @Published var searchText = ""
    /// Incremented to move keyboard focus into the toolbar search field (⌘F).
    @Published private(set) var searchFocusRequest = 0
    let search = SearchModel()
    private var artistModels: [String: ArtistModel] = [:]
    @Published var showingQueue = false
    @Published var showingLinkSheet = false
    /// The full-window player over the main window's content.
    @Published private(set) var showingNowPlaying = false
    private var libraries: [String: LibraryModel] = [:]
    private var started = false

    private init() {
        wrapper = WrapperConnection(); player = AudioPlayer()
        queue = PlaybackQueue(player: player, wrapper: wrapper)
        remote = HTTPRemote(queue: queue)
        airPlay = AirPlayReceiver(player: player, queue: queue)
        player.onAirPlayDisconnect = { [weak airPlay] in airPlay?.disconnect() }
    }

    func start() async {
        guard !started else { return }; started = true
        nowPlaying = NowPlayingController(player: player, queue: queue)
        if UserDefaults.standard.object(forKey: "remoteEnabled") as? Bool ?? true { remote.start() }
        airPlay.start()
        await connectWrapper()
    }
    /// Checks the user's wrapper and its Apple Music sign-in.
    func connectWrapper() async {
        account = .unknown
        await wrapper.connect()
        guard wrapper.ready else { return }
        let account = try? await wrapper.service.account()
        setSignedIn(account?.authenticated == true)
    }
    func setSignedIn(_ value: Bool) {
        account = value ? .signedIn : .signedOut
        queue.authenticated = value
    }
    func setRemoteEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "remoteEnabled")
        enabled ? remote.start() : remote.stop()
    }

    // MARK: Library

    /// One model per Apple Music path, so lists keep loading and stay cached
    /// while the user switches between categories and collections.
    func library(_ path: String) -> LibraryModel {
        if let model = libraries[path] { return model }
        let model = LibraryModel(); libraries[path] = model; return model
    }
    var currentCollection: LibraryItem? { if case .collection(let item)? = path.last { return item }; return nil }
    var currentPath: String? { path.isEmpty ? category?.path : currentCollection?.trackPath }
    func refreshLibrary() {
        if case .artist(let artist)? = path.last { artistModel(artist.id).load(id: artist.id, service: wrapper.service, refresh: true); return }
        if case .category(let category)? = path.last { categoryModel(category).load(service: wrapper.service, refresh: true); return }
        if path.isEmpty, category == .home { home.load(service: wrapper.service, refresh: true); return }
        if path.isEmpty, category == .new { browse.load(service: wrapper.service, refresh: true); return }
        if path.isEmpty, category == .search { search.update(searchText, service: wrapper.service, force: true); return }
        guard let path = currentPath else { return }
        library(path).load(path, service: wrapper.service, refresh: true)
    }
    private var categoryModels: [String: CategoryModel] = [:]
    func categoryModel(_ category: BrowseCategory) -> CategoryModel {
        if let model = categoryModels[category.id] { return model }
        let model = CategoryModel(category: category); categoryModels[category.id] = model; return model
    }
    func openCategory(_ category: BrowseCategory) { leaveNowPlaying(); path.append(.category(category)) }
    func artistModel(_ id: String) -> ArtistModel {
        if let model = artistModels[id] { return model }
        let model = ArtistModel(); artistModels[id] = model; return model
    }

    // MARK: Navigation

    func open(_ collection: LibraryItem) {
        guard collection.trackPath != nil else { return }
        leaveNowPlaying()
        path.append(.collection(collection))
        if category != .search { searchText = "" }
    }
    func openArtist(_ artist: ArtistRef) {
        guard CatalogService.validID(artist.id) else { return }
        leaveNowPlaying()
        path.append(.artist(artist))
    }
    func goBack() { if !path.isEmpty { path.removeLast() } }
    func goToAlbum(songID: String) {
        navigate { [self] in
            guard let album = try await CatalogService.shared.links(song: songID, service: wrapper.service).album else {
                throw ClientError.message("No album found for this song.")
            }
            open(album)
        }
    }
    func goToArtist(songID: String) {
        navigate { [self] in
            guard let artist = try await CatalogService.shared.links(song: songID, service: wrapper.service).artists.first else {
                throw ClientError.message("No artist found for this song.")
            }
            openArtist(artist)
        }
    }
    func goToArtist(album: LibraryItem) {
        navigate { [self] in
            guard let artist = try await CatalogService.shared.artists(album: album, service: wrapper.service).first else {
                throw ClientError.message("No artist found for this album.")
            }
            openArtist(artist)
        }
    }
    func focusSearch() {
        if category != .search { category = .search }
        searchFocusRequest += 1
    }
    /// Typing on the home pages or an artist page searches Apple Music; in the
    /// library sections the field filters what is shown.
    func searchTextChanged(_ text: String) {
        let typing = !text.trimmingCharacters(in: .whitespaces).isEmpty
        if category == .search {
            if typing && !path.isEmpty { path = [] }
        } else if typing, category == .home || category == .new || { if case .artist? = path.last { return true }; return false }() {
            category = .search
        }
        if category == .search { search.update(text, service: wrapper.service) }
    }
    private func navigate(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() }
            catch { queue.failure = (error as? LocalizedError)?.errorDescription ?? "The page could not be opened." }
        }
    }
    private func leaveNowPlaying() { if showingNowPlaying { closeNowPlaying() } }

    // MARK: Playback

    func play(_ item: LibraryItem) { queue.perform { try queue.play(QueueEntry(item: item)) } }
    func playAll(_ items: [LibraryItem], shuffled: Bool = false) {
        let playable = items.filter(\.playable)
        queue.perform { try queue.playAll((shuffled ? playable.shuffled() : playable).map(QueueEntry.init(item:))) }
    }
    /// "Play Next" inserts in front of the queue, preserving the selection order.
    func playNext(_ items: [LibraryItem]) {
        let playable = items.filter(\.playable); guard !playable.isEmpty else { return }
        queue.perform { try queue.enqueue(playable.map(QueueEntry.init(item:)), first: true) }
    }
    /// "Play Last" appends to the end of the queue.
    func playLater(_ items: [LibraryItem]) {
        let playable = items.filter(\.playable); guard !playable.isEmpty else { return }
        queue.perform { try queue.enqueue(playable.map(QueueEntry.init(item:))) }
    }
    /// Plays an album or playlist straight from its cover, loading its tracks first.
    func playCollection(_ collection: LibraryItem, shuffled: Bool = false, next: Bool = false, later: Bool = false) {
        guard let path = collection.trackPath else { return }
        let service = wrapper.service
        Task {
            do {
                let items = try await LibraryModel.fetchAll(path, service: service)
                guard items.contains(where: \.playable) else { throw ClientError.message("“\(collection.title)” has no playable songs.") }
                if next { playNext(items) } else if later { playLater(items) } else { playAll(items, shuffled: shuffled) }
            } catch {
                queue.failure = (error as? LocalizedError)?.errorDescription ?? "“\(collection.title)” could not be loaded."
            }
        }
    }
    func playLink(_ link: String) { queue.perform { try queue.play(QueueEntry(link: link)) } }
    func enqueueLink(_ link: String, first: Bool) { queue.perform { try queue.enqueue([QueueEntry(link: link)], first: first) } }
    func copyLink(_ items: [LibraryItem]) {
        let links = items.compactMap { $0.catalogID.map { "https://music.apple.com/song/\($0)" } }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
    func openNowPlaying() { withAnimation(.easeInOut(duration: 0.35)) { showingNowPlaying = true } }
    func closeNowPlaying() { withAnimation(.easeInOut(duration: 0.3)) { showingNowPlaying = false } }
    func toggleNowPlaying() { showingNowPlaying ? closeNowPlaying() : openNowPlaying() }
    func changeVolume(by delta: Float) { player.volume = min(1, max(0, player.volume + delta)) }
    func skip(by seconds: Double) { player.seek(player.position + seconds) }
    var canControlPlayback: Bool { player.airPlay != nil || account == .signedIn && (player.stream != nil || player.loading || queue.state.current != nil || !queue.state.upcoming.isEmpty) }
}
