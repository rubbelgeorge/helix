import SwiftUI

/// The detail column: a category root plus album and playlist pages.
struct LibraryDetailView: View {
    @EnvironmentObject private var app: AppModel

    // Explicit navigation instead of NavigationStack: inside a split view the
    // stack's destination would replace the whole column, player bar included.
    var body: some View {
        // The stack is only a container (it gives the table its own layout host);
        // collections are shown without pushing.
        NavigationStack {
            if let route = app.path.last {
                Group {
                    switch route {
                    case .collection(let collection):
                        if let path = collection.trackPath { CollectionDetailView(collection: collection, model: app.library(path)) }
                    case .artist(let artist):
                        ArtistView(artist: artist, model: app.artistModel(artist.id))
                    case .category(let category):
                        ShelfPage(model: app.categoryModel(category), title: category.title, emptyTitle: "No Content",
                                  emptyText: "This category has nothing that can be played here right now.")
                    }
                }
                .id(route)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { app.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                            .help("Back")
                            .keyboardShortcut("[", modifiers: .command)
                    }
                }
            } else {
                switch app.category {
                case .search?: SearchPage(model: app.search)
                case .home?: ShelfPage(model: app.home, title: "Home", emptyTitle: "No Recommendations Yet",
                                       emptyText: "Listen to some music and Apple Music will put together recommendations for you here.")
                case .new?: ShelfPage(model: app.browse, title: "New", emptyTitle: "Nothing New",
                                      emptyText: "Apple Music has no new releases for your country right now.")
                case .songs?: SongsView(model: app.library(LibraryCategory.songs.path))
                case let category?: CollectionGrid(category: category, model: app.library(category.path))
                case nil: ContentUnavailableView("No Selection", systemImage: "music.note.house", description: Text("Choose a library section on the left."))
                }
            }
        }
    }
}

// MARK: - Songs

private struct SongsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: LibraryModel
    private let path = LibraryCategory.songs.path

    var body: some View {
        TrackTable(model: model, queue: app.queue, style: .library, query: app.searchText)
            .navigationTitle("Songs")
            .navigationSubtitle(subtitle(count: model.items.count, loading: model.loading, unit: "songs"))
            .task { model.load(path, service: app.wrapper.service) }
    }
}

func subtitle(count: Int, loading: Bool, unit: String) -> String {
    let number = count.formatted()
    return loading ? "\(number) \(unit), loading more …" : "\(number) \(unit)"
}

/// Row wrapper with a positional identity: playlists may repeat a title.
struct TrackRow: Identifiable, Hashable {
    let id: Int
    let item: LibraryItem
    var title: String { item.title }
    var artist: String { item.artist }
    var album: String { item.album }
    var duration: Double { item.duration ?? 0 }
}

struct TrackTable: View {
    enum Style { case library, album, playlist }
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: LibraryModel
    @ObservedObject var queue: PlaybackQueue
    let style: Style
    let query: String
    @State private var selection = Set<TrackRow.ID>()
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = []

    private var rows: [TrackRow] {
        let all = model.items.enumerated().map { TrackRow(id: $0.offset, item: $0.element) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = text.isEmpty ? all : all.filter { $0.item.matches(text) }
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }
    private var currentID: String? { queue.state.current?.catalogID }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            if let failure = model.failure, !model.items.isEmpty {
                InlineNotice(message: failure, actionTitle: "Reload") { model.load(model.currentPath, service: app.wrapper.service, refresh: true) }
            }
            tableWithMenus(rows)
        }
    }

    private func tableWithMenus(_ rows: [TrackRow]) -> some View {
        table(rows)
            .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
                let items = selected(ids, in: rows)
                Button("Play") { play(ids, in: rows) }.disabled(!items.contains(where: \.playable))
                Button("Play Next") { app.playNext(items) }.disabled(!items.contains(where: \.playable))
                Button("Play Last") { app.playLater(items) }.disabled(!items.contains(where: \.playable))
                if items.count == 1, let id = items.first?.catalogID {
                    Divider()
                    if style != .album { Button("Go to Album") { app.goToAlbum(songID: id) } }
                    Button("Go to Artist") { app.goToArtist(songID: id) }
                }
                Divider()
                Button(items.count > 1 ? "Copy Links" : "Copy Link") { app.copyLink(items) }.disabled(!items.contains(where: \.playable))
            } primaryAction: { ids in play(ids, in: rows) }
            .onKeyPress(.return) { play(selection, in: rows); return .handled }
            .overlay { overlay(isEmpty: rows.isEmpty) }
    }

    @ViewBuilder private func table(_ rows: [TrackRow]) -> some View {
        switch style {
        case .library, .playlist:
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in TitleCell(row: row, playing: row.item.catalogID == currentID, artwork: true) }
                    .width(min: 160, ideal: 280)
                TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { row in Text(row.artist).foregroundStyle(row.item.playable ? .primary : .secondary) }
                    .width(min: 100, ideal: 180)
                TableColumn("Album", value: \.album, comparator: .localizedStandard) { row in Text(row.album).foregroundStyle(.secondary) }
                    .width(min: 100, ideal: 200)
                TableColumn("Time", value: \.duration) { row in DurationCell(duration: row.item.duration) }
                    .width(min: 48, ideal: 56, max: 72)
            }
        case .album:
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Nr.", value: \.id) { row in
                    Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 28, ideal: 32, max: 40)
                TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in TitleCell(row: row, playing: row.item.catalogID == currentID, artwork: false) }
                    .width(min: 160, ideal: 320)
                TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { row in Text(row.artist).foregroundStyle(row.item.playable ? .secondary : .tertiary) }
                    .width(min: 100, ideal: 180)
                TableColumn("Time", value: \.duration) { row in DurationCell(duration: row.item.duration) }
                    .width(min: 48, ideal: 56, max: 72)
            }
        }
    }

    @ViewBuilder private func overlay(isEmpty: Bool) -> some View {
        if isEmpty {
            if model.loading {
                ProgressView("Loading library …").controlSize(.regular)
            } else if let failure = model.failure {
                ContentUnavailableView {
                    Label("Library not available", systemImage: "exclamationmark.icloud")
                } description: { Text(failure) } actions: {
                    Button("Reload") { model.load(model.currentPath, service: app.wrapper.service, refresh: true) }
                }
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("Songs from your Apple Music library appear here."))
            }
        }
    }

    private func selected(_ ids: Set<TrackRow.ID>, in rows: [TrackRow]) -> [LibraryItem] {
        rows.filter { ids.contains($0.id) }.map(\.item)
    }
    /// One title in the song list plays alone. In an album or playlist the
    /// following titles become "Playing Next", as in the Music app.
    private func play(_ ids: Set<TrackRow.ID>, in rows: [TrackRow]) {
        guard !ids.isEmpty else { return }
        if ids.count > 1 { app.playAll(selected(ids, in: rows)); return }
        guard let index = rows.firstIndex(where: { ids.contains($0.id) }), rows[index].item.playable else { return }
        if style == .library { app.play(rows[index].item) }
        else { app.playAll(Array(rows[index...].prefix(1000)).map(\.item)) }
    }
}

private struct TitleCell: View {
    let row: TrackRow
    let playing: Bool
    let artwork: Bool
    var body: some View {
        HStack(spacing: 8) {
            if artwork {
                ArtworkView(url: row.item.artwork(80), cornerRadius: 4)
                    .frame(width: 28, height: 28)
                    .overlay { if playing { NowPlayingBadge().background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4)) } }
            } else if playing {
                NowPlayingBadge().foregroundStyle(.tint).frame(width: 16)
            }
            Text(row.title).lineLimit(1)
                .fontWeight(playing ? .semibold : .regular)
                .foregroundStyle(playing ? AnyShapeStyle(.tint) : row.item.playable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        // Greyed out like in the Music app: unreleased catalog titles and library
        // entries without a catalog version cannot be played.
        .help(row.item.playable ? "" : row.item.type == "songs" ? "Not yet available on Apple Music"
              : "Not an available Apple Music catalog song. Only catalog songs can be streamed in lossless.")
        .accessibilityValue(row.item.playable ? "" : "Not available")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(playing ? .isSelected : [])
    }
}

private struct NowPlayingBadge: View {
    var body: some View {
        PlayingMark().frame(width: 16, height: 10).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Now Playing")
    }
}

private struct DurationCell: View {
    let duration: Double?
    var body: some View {
        Text(duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

func formatTime(_ value: Double) -> String {
    let seconds = max(0, Int(value.isFinite ? value : 0))
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct InlineNotice: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Albums and playlists

private struct CollectionGrid: View {
    @EnvironmentObject private var app: AppModel
    let category: LibraryCategory
    @ObservedObject var model: LibraryModel
    private var filtered: [LibraryItem] {
        let text = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? model.items : model.items.filter { $0.matches(text) }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
        if let failure = model.failure, !items.isEmpty { InlineNotice(message: failure, actionTitle: "Reload") { app.refreshLibrary() } }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
                ForEach(items) { item in CollectionCard(item: item, symbol: item.isAlbum ? "square.stack" : category == .recentlyAdded ? "music.note.list" : category.symbol) }
            }
            .padding(20)
            if model.loading && !items.isEmpty { ProgressView().controlSize(.small).padding(.bottom, 20) }
        }
        }
        .overlay {
            if items.isEmpty {
                if model.loading { ProgressView("Loading library …") }
                else if let failure = model.failure {
                    ContentUnavailableView {
                        Label("Library not available", systemImage: "exclamationmark.icloud")
                    } description: { Text(failure) } actions: {
                        Button("Reload") { app.refreshLibrary() }
                    }
                } else if !app.searchText.isEmpty { ContentUnavailableView.search(text: app.searchText) }
                else if category == .recentlyAdded { ContentUnavailableView("Nothing Added", systemImage: category.symbol, description: Text("Albums and playlists you recently added to your library appear here.")) }
                else { ContentUnavailableView("No \(category.title)", systemImage: category.symbol, description: Text("\(category.title) from your Apple Music library appear here.")) }
            }
        }
        .navigationTitle(category.title)
        .navigationSubtitle(subtitle(count: model.items.count, loading: model.loading, unit: category == .recentlyAdded ? "items" : category.title.lowercased()))
        .task(id: category) { model.load(category.path, service: app.wrapper.service) }
    }
}

struct CollectionCard: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    let symbol: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { app.open(item) } label: {
                ArtworkView(url: item.artwork(400), symbol: symbol, cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomLeading) {
                if hovering && item.trackPath != nil {
                    Button { app.playCollection(item) } label: {
                        Image(systemName: "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Circle().fill(.tint))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain).padding(10)
                    .help("Play “\(item.title)”")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.artist.isEmpty ? (item.trackCount.map { "\($0) songs" } ?? "Playlist") : item.artist)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { CollectionMenu(item: item) }
        .disabled(item.trackPath == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.artist)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.open(item) }
    }
}

struct CollectionMenu: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    var body: some View {
        Button("Open") { app.open(item) }
        Divider()
        Button("Play") { app.playCollection(item) }
        Button("Shuffle") { app.playCollection(item, shuffled: true) }
        Button("Play Next") { app.playCollection(item, next: true) }
        Button("Play Last") { app.playCollection(item, later: true) }
        if item.isAlbum {
            Divider()
            Button("Go to Artist") { app.goToArtist(album: item) }
        }
    }
}

private struct CollectionDetailView: View {
    @EnvironmentObject private var app: AppModel
    let collection: LibraryItem
    @ObservedObject var model: LibraryModel
    private var isAlbum: Bool { collection.isAlbum }
    private var totalDuration: Double { model.items.compactMap(\.duration).reduce(0, +) }
    @State private var video: URL?
    /// For library albums: the catalog album, when it has more titles than the library.
    @State private var fullAlbum: LibraryItem?
    private var catalogTotal: Int? { fullAlbum?.trackCount }
    private var showsFullAlbumButton: Bool { !model.loading && (catalogTotal ?? 0) > model.items.count }
    /// On the search page the toolbar field holds the search term, not a filter.
    private var query: String { app.category == .search ? "" : app.searchText }
    /// Catalog albums carry their ID; for library albums the first catalog track leads to the album.
    private var videoKey: String? { collection.type == "albums" ? "album:\(collection.id)" : model.items.first(where: \.playable)?.catalogID.map { "song:\($0)" } }

    var body: some View {
        VStack(spacing: 0) {
            header
            TrackTable(model: model, queue: app.queue, style: isAlbum ? .album : .playlist, query: query)
        }
            .navigationTitle(collection.title)
            .navigationSubtitle(collection.artist)
            .task(id: collection.id) { if let path = collection.trackPath { model.load(path, service: app.wrapper.service) } }
            .task(id: collection.id) {
                guard collection.type == "library-albums" else { return }
                fullAlbum = try? await CatalogService.shared.catalogAlbum(library: collection.id, service: app.wrapper.service)
            }
            .task(id: videoKey) {
                guard isAlbum, let videoKey else { return }
                let service = app.wrapper.service, id = String(videoKey.split(separator: ":")[1])
                video = videoKey.hasPrefix("album:") ? await AnimatedArtworkService.shared.video(forAlbum: id, service: service)
                                                     : await AnimatedArtworkService.shared.video(forSong: id, service: service)
            }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 22) {
            AnimatedCover(video: isAlbum ? video : nil) {
                ArtworkView(url: collection.artwork(600), symbol: isAlbum ? "square.stack" : "music.note.list", cornerRadius: 10)
            }
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(isAlbum ? "Album" : "Playlist").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(collection.title).font(.title.weight(.bold)).lineLimit(2).textSelection(.enabled)
                if !collection.artist.isEmpty {
                    if isAlbum {
                        Button { app.goToArtist(album: collection) } label: { Text(collection.artist).font(.title3).foregroundStyle(.tint).lineLimit(1) }
                            .buttonStyle(.plain)
                            .help("Go to Artist")
                    } else {
                        Text(collection.artist).font(.title3).foregroundStyle(.tint).lineLimit(1)
                    }
                }
                Text(details).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 10) {
                    Button { app.playAll(model.items) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 96) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.items.contains(where: \.playable))
                    Button { app.playAll(model.items, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 96) }
                        .buttonStyle(.bordered)
                        .disabled(!model.items.contains(where: \.playable))
                    if showsFullAlbumButton, let fullAlbum {
                        Button { app.open(fullAlbum) } label: { Label("Full Album", systemImage: "square.stack") }
                            .buttonStyle(.bordered)
                            .help("Show all \(catalogTotal ?? 0) songs of the album from Apple Music")
                    }
                }
                .controlSize(.large)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)
        .background(.background)
    }
    private var details: String {
        let available = model.items.filter(\.playable).count
        let count = showsFullAlbumButton ? "\(model.items.count.formatted()) of \((catalogTotal ?? 0).formatted()) songs in your library"
            : !model.loading && available < model.items.count ? "\(available.formatted()) of \(model.items.count.formatted()) songs available"
            : "\(model.items.count.formatted()) songs"
        if model.loading { return count + ", loading more …" }
        let minutes = Int(totalDuration / 60)
        return minutes > 0 ? "\(count), \(minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min")" : count
    }
}
