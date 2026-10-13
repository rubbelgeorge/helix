import Combine
import Foundation

struct QueueEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let catalogID: String
    var title: String
    var artist: String
    var artwork: URL?
    var link: String { "https://music.apple.com/song/\(catalogID)" }
    /// Known title data for immediate display; links added by URL have none yet.
    var hint: AudioPlayer.Hint? {
        guard artwork != nil || !artist.isEmpty else { return nil }
        return AudioPlayer.Hint(title: title, artist: artist, artwork: artwork)
    }
    init(link: String) throws {
        catalogID = try TrackLink(link).id; title = "Apple Music song"; artist = ""
    }
    init(item: LibraryItem) throws {
        guard item.playable, let catalogID = item.catalogID else { throw ClientError.message("This song is not available.") }
        self.catalogID = catalogID; title = item.title; artist = item.artist; artwork = item.artwork
    }
}

/// The same ordered state is used by the native app and every remote device.
struct QueueState: Codable, Equatable {
    var current: QueueEntry?
    var upcoming: [QueueEntry] = []
    var history: [QueueEntry] = []
    var revision = 0
    mutating func start(_ entry: QueueEntry) {
        if let current { history.append(current); history = Array(history.suffix(100)) }
        current = entry; revision += 1
    }
    mutating func next() -> QueueEntry? {
        guard !upcoming.isEmpty else { return nil }
        let entry = upcoming.removeFirst(); start(entry); return entry
    }
    mutating func previous() -> QueueEntry? {
        guard let entry = history.popLast() else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = entry; revision += 1; return entry
    }
    mutating func add(_ entries: [QueueEntry], first: Bool = false) throws {
        guard !entries.isEmpty, upcoming.count + entries.count <= 1000 else { throw ClientError.message("The queue holds up to 1,000 songs.") }
        if first { upcoming.insert(contentsOf: entries, at: 0) } else { upcoming.append(contentsOf: entries) }
        revision += 1
    }
    mutating func move(_ id: UUID, to index: Int, revision expected: Int? = nil) throws {
        guard expected == nil || expected == revision else { throw ClientError.message("The queue has changed in the meantime. Please try again.") }
        guard let old = upcoming.firstIndex(where: { $0.id == id }), index >= 0, index < upcoming.count else { throw ClientError.message("This queue entry no longer exists.") }
        let entry = upcoming.remove(at: old); upcoming.insert(entry, at: index); revision += 1
    }
    mutating func remove(_ id: UUID) {
        let count = upcoming.count; upcoming.removeAll { $0.id == id }
        if count != upcoming.count { revision += 1 }
    }
    mutating func clear() { upcoming = []; revision += 1 }
}

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var state = QueueState()
    @Published var failure: String?
    @Published var authenticated = false
    let player: AudioPlayer
    let wrapper: WrapperConnection
    var beforeAppleMusicPlayback: (() -> Void)?
    private var loadTask: Task<Void, Never>?
    private var metadata: AnyCancellable?
    private var next: AnyCancellable?
    private let file: URL
    init(player: AudioPlayer, wrapper: WrapperConnection) {
        self.player = player; self.wrapper = wrapper
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Helix/queue.json")
        if let data = try? Data(contentsOf: file), data.count < 2_000_000,
           let saved = try? JSONDecoder().decode(QueueState.self, from: data), saved.upcoming.count <= 1000 {
            state = saved
        }
        player.onEnded = { [weak self] in self?.advance() }
        player.nextTrack = { [weak self] in
            guard let self, self.wrapper.ready, self.authenticated, let next = self.state.upcoming.first else { return nil }
            return (next.link, next.hint)
        }
        // A gapless transition: the title is already playing, only the queue moves on.
        player.onGaplessAdvance = { [weak self] id in
            guard let self else { return }
            guard self.state.upcoming.first?.catalogID == id else { self.advance(); return }   // queue changed at the last moment
            _ = self.state.next()
            if let stream = self.player.stream { self.adopt(stream) }
            self.save()
        }
        metadata = player.$stream.sink { [weak self] stream in
            guard let self, let stream else { return }
            self.adopt(stream); self.save()
        }
        next = $state.map { $0.upcoming.first }.removeDuplicates().sink { [weak self] entry in
            guard let self, let entry, self.state.current != nil, self.wrapper.ready, self.authenticated else { return }
            self.player.prefetch(link: entry.link, hint: entry.hint, service: self.wrapper.service)
        }
    }
    func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = error.localizedDescription }
    }
    func play(_ entry: QueueEntry) throws {
        try ready(); state.start(entry); start(entry)
    }
    /// Replaces the upcoming titles: the first entry plays, the rest follow in order.
    func playAll(_ entries: [QueueEntry]) throws {
        try ready(); guard let first = entries.first, entries.count <= 1001 else { throw ClientError.message("No playable songs, or more than 1,000 songs selected.") }
        state.clear()
        if entries.count > 1 { try state.add(Array(entries.dropFirst())) }
        state.start(first); start(first)
    }
    func enqueue(_ entries: [QueueEntry], first: Bool = false) throws { try ready(); try state.add(entries, first: first); save() }
    func advance() {
        guard player.airPlay == nil else { return }
        guard wrapper.ready, authenticated, let next = state.next() else { return }
        start(next)
    }
    func previous() {
        guard player.airPlay == nil else { return }
        if player.position > 3 { player.seek(0); return }
        if let previous = state.previous() { start(previous) } else if player.stream != nil { player.seek(0) }
    }
    func toggle() {
        if player.airPlay != nil { player.onAirPlayDisconnect?(); return }
        if player.stream == nil, !player.loading {
            if let current = state.current { start(current) } else { advance() }
        } else { player.toggle() }
    }
    func resume() {
        guard player.airPlay == nil else { return }
        if player.stream == nil, !player.loading { toggle() } else { player.resume() }
    }
    func playQueued(_ id: UUID) throws {
        try ready(); guard let entry = state.upcoming.first(where: { $0.id == id }) else { throw ClientError.message("This queue entry no longer exists.") }
        state.remove(id); state.start(entry); start(entry)
    }
    func move(_ id: UUID, to index: Int, revision: Int? = nil) throws { try state.move(id, to: index, revision: revision); save() }
    /// SwiftUI `onMove` offsets refer to positions before removal.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let from = source.first, from < state.upcoming.count else { return }
        let id = state.upcoming[from].id
        perform { try move(id, to: min(destination > from ? destination - 1 : destination, state.upcoming.count - 1)) }
    }
    func remove(_ id: UUID) { state.remove(id); save() }
    func remove(_ ids: Set<UUID>) { for id in ids { state.remove(id) }; save() }
    func clear() { state.clear(); save() }
    func interruptForAirPlay() { loadTask?.cancel(); loadTask = nil; player.stop(); failure = nil }
    func shutdown() { loadTask?.cancel(); player.stop() }
    private func ready() throws {
        guard wrapper.ready, authenticated else { throw ClientError.message("Please sign in to Apple Music in the Mac app first.") }
    }
    private func start(_ entry: QueueEntry) {
        beforeAppleMusicPlayback?()
        // The player fades the current title out itself; no hard stop here.
        loadTask?.cancel(); failure = nil; save()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await player.load(link: entry.link, service: wrapper.service, hint: entry.hint)
            // The following title gets warmed once this one is under way.
            if let next = state.upcoming.first { player.prefetch(link: next.link, hint: next.hint, service: wrapper.service) }
        }
    }
    private func adopt(_ stream: TrackStream) {
        guard state.current?.catalogID == stream.id else { return }
        // Only take real values: a fresh stream has no artwork yet, which
        // used to blank the cover for a moment.
        if stream.title != "Apple Music" { state.current?.title = stream.title; state.current?.artist = stream.artist }
        if let artwork = stream.artwork { state.current?.artwork = artwork }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { failure = "The queue could not be saved." }
    }
}
