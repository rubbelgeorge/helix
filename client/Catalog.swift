import Foundation
import SwiftUI

/// A catalog artist, enough to open the artist page.
struct ArtistRef: Hashable, Sendable {
    let id: String
    let name: String
}

/// One step of the detail column's navigation: album/playlist pages and artist pages.
enum Route: Hashable {
    case collection(LibraryItem)
    case artist(ArtistRef)
    case category(BrowseCategory)
}

/// Apple Music catalog browsing: search, artist pages and the links from a song
/// or album to its album and artists. Search and links use the public API; the
/// artist page uses Apple's internal host, which adds the biography and the
/// banner artwork for the token of the embedded client.
@MainActor
final class CatalogService {
    static let shared = CatalogService()
    struct SongLinks { var album: LibraryItem?; var artists: [ArtistRef] }
    struct ArtistPage {
        let name: String
        let artworkTemplate: String?
        let bannerTemplate: String?
        let bio: String?
        let sections: [HomeSection]
        var topSongs: [LibraryItem] { sections.first { $0.id == "top-songs" }?.entries.map(\.item) ?? [] }
    }
    private var songLinks: [String: SongLinks] = [:]
    private var albumArtists: [String: [ArtistRef]] = [:]
    private var libraryAlbums: [String: LibraryItem?] = [:]

    nonisolated static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    private func get(_ url: URL?, service: WrapperService) async throws -> Data {
        guard let url, url.scheme == "https", url.host == "api.music.apple.com" || url.host == "amp-api.music.apple.com" else {
            throw ClientError.message("Invalid Apple Music address.")
        }
        let account = try await service.account()
        guard account.authenticated else { throw ClientError.message("Please sign in to Apple Music first.") }
        return try await LibraryService(wrapper: service).data(url, account: account)
    }
    private func catalogURL(_ path: String, host: String = "api.music.apple.com", query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: "https://\(host)/v1/catalog/\(Storefront.current)/\(path)")
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url
    }

    // MARK: Links

    /// Album and artists of a catalog song, in one request.
    func links(song id: String, service: WrapperService) async throws -> SongLinks {
        guard Self.validID(id) else { throw ClientError.message("This song is not in the Apple Music catalog.") }
        if let cached = songLinks[id] { return cached }
        let data = try await get(catalogURL("songs/\(id)", query: [URLQueryItem(name: "include", value: "albums,artists")]), service: service)
        let resource = try JSONDecoder().decode(Resources.self, from: data).data.first
        let links = SongLinks(album: resource?.relationships?.albums?.data.first,
                              artists: resource?.relationships?.artists?.data.map(\.ref) ?? [])
        songLinks[id] = links
        return links
    }
    /// The catalog version of a library album: full track list and catalog ID.
    func catalogAlbum(library id: String, service: WrapperService) async throws -> LibraryItem? {
        guard Self.validID(id) else { return nil }
        if let cached = libraryAlbums[id] { return cached }
        var components = URLComponents(string: "https://api.music.apple.com/v1/me/library/albums/\(id)")
        components?.queryItems = [URLQueryItem(name: "include", value: "catalog")]
        let data = try await get(components?.url, service: service)
        let album = try JSONDecoder().decode(LibraryResources.self, from: data).data.first?.relationships?.catalog?.data.first
        libraryAlbums[id] = album
        return album
    }
    func artists(album: LibraryItem, service: WrapperService) async throws -> [ArtistRef] {
        var catalogID: String?
        if album.type == "albums" { catalogID = album.id }
        else if album.type == "library-albums" { catalogID = try await catalogAlbum(library: album.id, service: service)?.id }
        guard let catalogID, Self.validID(catalogID) else { throw ClientError.message("This album has no catalog entry.") }
        if let cached = albumArtists[catalogID] { return cached }
        let data = try await get(catalogURL("albums/\(catalogID)", query: [URLQueryItem(name: "include", value: "artists")]), service: service)
        let artists = try JSONDecoder().decode(Resources.self, from: data).data.first?.relationships?.artists?.data.map(\.ref) ?? []
        albumArtists[catalogID] = artists
        return artists
    }

    // MARK: Album

    /// A catalog album with track and disc numbers, for the album view of the full-window player.
    struct AlbumDetail: Equatable, Sendable {
        struct Track: Identifiable, Equatable, Sendable {
            let item: LibraryItem
            let number: Int?
            let disc: Int
            var id: String { item.id }
        }
        let album: LibraryItem
        let genre: String?
        let releaseDate: Date?
        let copyright: String?
        let tracks: [Track]
        /// Catalog IDs of the playable titles, in album order.
        var playableIDs: [String] { tracks.compactMap { $0.item.playable ? $0.item.catalogID : nil } }
        var discs: [Int] { Array(Set(tracks.map(\.disc))).sorted() }
        var totalDuration: Double { tracks.compactMap(\.item.duration).reduce(0, +) }
    }
    private var albumDetails: [String: AlbumDetail] = [:]
    func albumDetail(id: String, service: WrapperService) async throws -> AlbumDetail {
        guard Self.validID(id) else { throw ClientError.message("Invalid album ID.") }
        if let cached = albumDetails[id] { return cached }
        let data = try await get(catalogURL("albums/\(id)", query: [URLQueryItem(name: "include", value: "tracks")]), service: service)
        guard let album = try JSONDecoder().decode(AlbumItems.self, from: data).data.first else { throw ClientError.message("This album does not exist.") }
        let meta = try JSONDecoder().decode(AlbumResponse.self, from: data).data.first
        let numbers = meta?.relationships?.tracks?.data ?? []
        let items = album.relationships?.tracks?.data ?? []
        let tracks = zip(items, numbers).compactMap { item, number -> AlbumDetail.Track? in
            guard item.isSong else { return nil }
            return AlbumDetail.Track(item: item, number: number.attributes?.trackNumber, disc: number.attributes?.discNumber ?? 1)
        }
        let attributes = meta?.attributes
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let detail = AlbumDetail(album: album.item, genre: attributes?.genreNames?.first { $0 != "Musik" && $0 != "Music" },
                                 releaseDate: attributes?.releaseDate.flatMap(formatter.date(from:)),
                                 copyright: attributes?.copyright, tracks: tracks)
        albumDetails[id] = detail
        return detail
    }

    // MARK: Search

    func search(_ term: String, service: WrapperService) async throws -> [HomeSection] {
        let data = try await get(catalogURL("search", query: [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "types", value: "artists,songs,albums,playlists"),
            URLQueryItem(name: "limit", value: "25"),
        ]), service: service)
        let results = try JSONDecoder().decode(SearchResponse.self, from: data).results
        var sections: [HomeSection] = []
        if let artists = results.artists?.data, !artists.isEmpty {
            sections.append(HomeSection(id: "artists", title: "Artists", style: .artists, items: artists))
        }
        if let songs = results.songs?.data.filter(\.playable), !songs.isEmpty {
            sections.append(HomeSection(id: "songs", title: "Songs", style: .songs, items: songs))
        }
        if let albums = results.albums?.data.filter({ $0.trackPath != nil }), !albums.isEmpty {
            sections.append(HomeSection(id: "albums", title: "Albums", style: .covers, items: albums))
        }
        if let playlists = results.playlists?.data.filter({ $0.trackPath != nil }), !playlists.isEmpty {
            sections.append(HomeSection(id: "playlists", title: "Playlists", style: .covers, items: playlists))
        }
        return sections
    }

    // MARK: Artist page

    private static let views: [(id: String, title: String, style: HomeSection.Style)] = [
        ("latest-release", "Latest Release", .covers), ("top-songs", "Top Songs", .songs),
        ("full-albums", "Albums", .covers), ("singles", "Singles & EPs", .covers),
        ("appears-on-albums", "Appears On", .covers), ("featured-playlists", "Playlists", .covers),
        ("similar-artists", "Similar Artists", .artists),
    ]
    func artistPage(id: String, service: WrapperService) async throws -> ArtistPage {
        guard Self.validID(id) else { throw ClientError.message("Invalid artist ID.") }
        let data = try await get(catalogURL("artists/\(id)", host: "amp-api.music.apple.com", query: [
            URLQueryItem(name: "views", value: Self.views.map(\.id).joined(separator: ",")),
            URLQueryItem(name: "extend", value: "artistBio,editorialArtwork"), URLQueryItem(name: "l", value: Storefront.language),
        ]), service: service)
        guard let artist = try JSONDecoder().decode(ArtistResponse.self, from: data).data.first else {
            throw ClientError.message("This artist page does not exist.")
        }
        let sections: [HomeSection] = Self.views.compactMap { view in
            guard let content = artist.views?[view.id] else { return nil }
            let items = content.data.filter { view.style == .songs ? $0.playable : view.style == .artists ? $0.type == "artists" : $0.trackPath != nil }
            guard !items.isEmpty else { return nil }
            return HomeSection(id: view.id, title: content.attributes?.title ?? view.title, style: view.style, items: items)
        }
        let attributes = artist.attributes
        return ArtistPage(name: attributes?.name ?? "Artist", artworkTemplate: attributes?.artwork?.url,
                          bannerTemplate: attributes?.editorialArtwork?.bannerUber?.url ?? attributes?.editorialArtwork?.subscriptionHero?.url,
                          bio: attributes?.artistBio.map(Self.plainText), sections: sections)
    }
    /// Apple's biographies can contain simple HTML markup.
    private static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Decoding

    private struct ArtistResource: Decodable {
        let id: String
        let attributes: Attributes?
        struct Attributes: Decodable { let name: String? }
        var ref: ArtistRef { ArtistRef(id: id, name: attributes?.name ?? "Artist") }
    }
    private struct Resources: Decodable {
        let data: [Resource]
        struct Resource: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let albums: Albums?; let artists: Artists? }
        struct Albums: Decodable { let data: [LibraryItem] }
        struct Artists: Decodable { let data: [ArtistResource] }
    }
    private struct LibraryResources: Decodable {
        let data: [Resource]
        struct Resource: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let catalog: Catalog? }
        struct Catalog: Decodable { let data: [LibraryItem] }
    }
    /// The album as a `LibraryItem` and its tracks as items.
    private struct AlbumItems: Decodable {
        let data: [Album]
        struct Album: Decodable {
            let relationships: Relationships?
            let item: LibraryItem
            init(from decoder: Decoder) throws {
                item = try LibraryItem(from: decoder)
                relationships = try decoder.container(keyedBy: Keys.self).decodeIfPresent(Relationships.self, forKey: .relationships)
            }
            enum Keys: String, CodingKey { case relationships }
        }
        struct Relationships: Decodable { let tracks: Tracks? }
        struct Tracks: Decodable { let data: [LibraryItem] }
    }
    /// Album metadata and track numbers, which `LibraryItem` does not keep.
    private struct AlbumResponse: Decodable {
        let data: [Album]
        struct Album: Decodable { let attributes: Attributes?; let relationships: Relationships? }
        struct Attributes: Decodable { let genreNames: [String]?; let releaseDate: String?; let copyright: String? }
        struct Relationships: Decodable { let tracks: Tracks? }
        struct Tracks: Decodable { let data: [Track] }
        struct Track: Decodable { let attributes: TrackAttributes? }
        struct TrackAttributes: Decodable { let trackNumber: Int?; let discNumber: Int? }
    }
    private struct SearchResponse: Decodable {
        let results: Results
        struct Results: Decodable { let artists: Group?; let songs: Group?; let albums: Group?; let playlists: Group? }
        struct Group: Decodable { let data: [LibraryItem] }
    }
    private struct ArtistResponse: Decodable {
        let data: [Artist]
        struct Artist: Decodable { let attributes: Attributes?; let views: [String: View]? }
        struct Attributes: Decodable {
            let name: String?; let artistBio: String?; let artwork: Artwork?; let editorialArtwork: EditorialArtwork?
        }
        struct Artwork: Decodable { let url: String? }
        struct EditorialArtwork: Decodable { let bannerUber: Artwork?; let subscriptionHero: Artwork? }
        struct View: Decodable { let attributes: ViewAttributes?; let data: [LibraryItem] }
        struct ViewAttributes: Decodable { let title: String? }
    }
}

// MARK: - Models

/// Catalog search with a short debounce, so typing does not send a request per key.
@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var sections: [HomeSection] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private(set) var term = ""
    private var task: Task<Void, Never>?

    func update(_ text: String, service: WrapperService, force: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || text != term else { return }
        term = text; task?.cancel(); failure = nil
        guard !text.isEmpty else { sections = []; loading = false; return }
        loading = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let result = try await CatalogService.shared.search(text, service: service)
                guard !Task.isCancelled else { return }
                self.sections = result
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.failure = (error as? LocalizedError)?.errorDescription ?? "The search failed."
            }
            if !Task.isCancelled { self.loading = false }
        }
    }
}

@MainActor
final class ArtistModel: ObservableObject {
    @Published private(set) var page: CatalogService.ArtistPage?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private var loadedAt: Date?

    func load(id: String, service: WrapperService, refresh: Bool = false) {
        if loading || (!refresh && page != nil && Date().timeIntervalSince(loadedAt ?? .distantPast) < 1800) { return }
        loading = true; failure = nil
        Task { [weak self] in
            do {
                let page = try await CatalogService.shared.artistPage(id: id, service: service)
                self?.page = page; self?.loadedAt = Date()
            } catch {
                self?.failure = (error as? LocalizedError)?.errorDescription ?? "The artist page could not be loaded."
            }
            self?.loading = false
        }
    }
}
