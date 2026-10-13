import Combine
import Foundation

enum LibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case search, home, new, recentlyAdded = "recently-added", songs, albums, playlists
    static let library: [LibraryCategory] = [.recentlyAdded, .songs, .albums, .playlists]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "Search"; case .home: "Home"; case .new: "New"; case .recentlyAdded: "Recently Added"
        case .songs: "Songs"; case .albums: "Albums"; case .playlists: "Playlists"
        }
    }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"; case .home: "house"; case .new: "square.grid.2x2"; case .recentlyAdded: "clock"
        case .songs: "music.note"; case .albums: "square.stack"; case .playlists: "music.note.list"
        }
    }
    var path: String {
        switch self {
        case .search: "/v1/catalog/search"
        case .home: "/v1/me/recommendations"
        case .new: "/v1/editorial/groupings/music"
        default: "/v1/me/library/\(rawValue)"
        }
    }
}

/// The account's Apple Music storefront and content language, used for catalog
/// and editorial requests.
enum Storefront {
    /// Written once per home page load on the main thread; read for track paths.
    nonisolated(unsafe) static var current = "us"
    /// The user's preferred language if the storefront supports it, else the storefront's default.
    nonisolated(unsafe) static var language = "en-US"
    static func valid(_ code: String) -> Bool { code.count == 2 && code.allSatisfy { $0.isASCII && $0.isLowercase } }
    /// Adds the content language (`l`) to an Apple Music API URL that has none.
    static func localized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name == "l" }) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "l", value: language)]
        return components.url ?? url
    }
    static func pickLanguage(default fallback: String?, supported: [String]) {
        for preferred in Locale.preferredLanguages {
            if let match = supported.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) { language = match; return }
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = supported.first(where: { $0.lowercased().hasPrefix(base.lowercased() + "-") || $0.lowercased() == base.lowercased() }) { language = match; return }
        }
        if let fallback, !fallback.isEmpty { language = fallback }
    }
}

struct LibraryItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let title: String
    let artist: String
    let album: String
    let artworkTemplate: String?
    let duration: Double?
    let trackCount: Int?
    let catalogID: String?
    /// Background color Apple supplies with the artwork, as hex, for cards.
    let artworkColor: String?
    let summary: String?
    /// Editorial banner artwork for the "New" page. Apple's templates use smart
    /// cropping (`sr`), so any aspect ratio can be requested.
    let wideArtworkTemplate: String?
    var artwork: URL? { artwork(300) }
    /// Apple artwork URLs carry a `{w}x{h}` (and sometimes `{f}`) template; request the size the view needs.
    func artwork(_ pixels: Int) -> URL? { Self.fill(artworkTemplate, width: pixels, height: pixels) }
    func wideArtwork(width: Int) -> URL? { Self.fill(wideArtworkTemplate, width: width, height: width * 2 / 3) }
    private static func fill(_ template: String?, width: Int, height: Int) -> URL? {
        template.flatMap { URL(string: $0.replacingOccurrences(of: "{w}", with: "\(width)").replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{f}", with: "jpg").replacingOccurrences(of: "{c}", with: "cc")) }
    }
    var isSong: Bool { type == "library-songs" || type == "songs" }
    var playable: Bool { isSong && catalogID != nil }
    var isCollection: Bool { ["library-albums", "library-playlists", "albums", "playlists"].contains(type) }
    var isAlbum: Bool { type == "library-albums" || type == "albums" }
    /// Library collections use the library API; catalog albums and playlists
    /// from the home page use the catalog in the account's storefront.
    var trackPath: String? {
        guard isCollection, !id.isEmpty, id.count < 100,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        switch type {
        case "library-albums": return "/v1/me/library/albums/\(id)/tracks"
        case "library-playlists": return "/v1/me/library/playlists/\(id)/tracks"
        default: return "/v1/catalog/\(Storefront.current)/\(type)/\(id)/tracks"
        }
    }
    private struct Attributes: Decodable {
        var name: String?; var artistName: String?; var albumName: String?; var durationInMillis: Double?; var trackCount: Int?
        var artwork: Artwork?; var playParams: PlayParams?; var curatorName: String?; var description: Description?; var editorialNotes: Description?
        var editorialArtwork: EditorialArtwork?
    }
    private struct EditorialArtwork: Decodable { var subscriptionHero: Artwork?; var superHeroWide: Artwork?; var superHeroTall: Artwork? }
    private struct Artwork: Decodable { var url: String?; var bgColor: String? }
    private struct Description: Decodable { var short: String?; var standard: String? }
    private struct PlayParams: Decodable { var catalogId: String? }
    private struct Relationships: Decodable { var catalog: Catalog? }
    private struct Catalog: Decodable { var data: [CatalogItem]? }
    private struct CatalogItem: Decodable { var id: String; var type: String }
    private enum CodingKeys: String, CodingKey { case id, type, attributes, relationships }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); type = try container.decode(String.self, forKey: .type)
        let a = try container.decodeIfPresent(Attributes.self, forKey: .attributes)
        let r = try container.decodeIfPresent(Relationships.self, forKey: .relationships)
        title = a?.name ?? "Unknown Song"; artist = a?.artistName ?? a?.curatorName ?? ""; album = a?.albumName ?? ""
        artworkColor = a?.artwork?.bgColor.flatMap { $0.count == 6 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        summary = (a?.editorialNotes ?? a?.description).flatMap { $0.short ?? $0.standard }
        // The Music app's banners use the subscription hero, cropped to 3:2.
        wideArtworkTemplate = (a?.editorialArtwork).flatMap { $0.subscriptionHero?.url ?? $0.superHeroWide?.url ?? $0.superHeroTall?.url }
        duration = a?.durationInMillis.map { $0 / 1000 }; trackCount = a?.trackCount
        artworkTemplate = a?.artwork?.url
        // Catalog songs without play parameters are not playable (yet), e.g. the
        // unreleased titles of an upcoming album; Apple Music greys them out.
        let candidate = a?.playParams?.catalogId ?? r?.catalog?.data?.first(where: { $0.type == "songs" })?.id ?? (type == "songs" && a?.playParams != nil ? id : nil)
        catalogID = candidate.flatMap { value in
            !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }) && UInt64(value) != nil ? value : nil
        }
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || artist.localizedStandardContains(query) || album.localizedStandardContains(query)
    }
}

struct LibraryPage: Decodable, Sendable { var data: [LibraryItem]; var next: String? }

struct LibraryService: Sendable {
    let wrapper: WrapperService
    static func url(for path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: URL(string: "https://api.music.apple.com")!)?.absoluteURL,
              url.scheme == "https", url.host == "api.music.apple.com", url.port == nil,
              url.user == nil, url.password == nil, url.path.hasPrefix("/v1/me/library/") || Self.catalogTracks(url.path) else {
            throw ClientError.message("Apple returned an invalid library address.")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        // Apple's next link may omit these parameters. Keep catalog identifiers
        // on every page; library IDs cannot be used by the Lossless player.
        query.removeAll { $0.name == "limit" || $0.name == "include" }
        // Large playlist pages with catalog expansion can time out upstream.
        // Collections need only their library IDs; request catalog mappings
        // exclusively for playable songs and collection track lists.
        let small = url.path == "/v1/me/library/playlists" || url.path == "/v1/me/library/recently-added"
        query.append(URLQueryItem(name: "limit", value: small ? "25" : "100"))
        if url.path == "/v1/me/library/songs" || (url.path.hasPrefix("/v1/me/library/") && url.path.hasSuffix("/tracks")) {
            query.append(URLQueryItem(name: "include", value: "catalog"))
        }
        components.queryItems = query
        guard let result = components.url else { throw ClientError.message("Invalid library address.") }; return result
    }
    /// `/v1/catalog/{storefront}/albums|playlists/{id}/tracks`, nothing else from the catalog.
    static func catalogTracks(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0].isEmpty, parts[1] == "v1", parts[2] == "catalog", Storefront.valid(String(parts[3])),
              parts[4] == "albums" || parts[4] == "playlists", parts[6] == "tracks", !parts[5].isEmpty, parts[5].count < 100,
              parts[5].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return false }
        return true
    }
    func page(_ path: String, account: WrapperAccount) async throws -> LibraryPage {
        try JSONDecoder().decode(LibraryPage.self, from: await data(Self.url(for: path), account: account))
    }
    /// Authorized GET against the Apple Music API with retries for server errors.
    func data(_ url: URL, account: WrapperAccount) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("Bearer " + account.developerToken, forHTTPHeaderField: "Authorization")
        request.setValue(account.musicToken, forHTTPHeaderField: "Music-User-Token")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (500...599).contains(status), attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000); continue
            }
            switch status {
            case 200: return data
            case 401, 403: throw ClientError.message("Apple denied access to the library. Please check your sign-in and reload.")
            case 429: throw ClientError.message("Apple is receiving too many requests right now. Please reload the library shortly.")
            default: throw ClientError.message("The library could not be loaded. Please try again.")
            }
        }
        throw ClientError.message("The library could not be loaded. Please try again.")
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private struct Snapshot {
        var items: [LibraryItem]
        var next: String?
        var visited: Set<String>
    }
    private var cache: [String: Snapshot] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var currentPath = ""
    var finished: Bool { !loading && failure == nil && cache[currentPath]?.next == nil && !currentPath.isEmpty }
    /// Loads every page of a collection, for playing an album or playlist from its cover.
    static func fetchAll(_ path: String, service: WrapperService) async throws -> [LibraryItem] {
        let account = try await service.account()
        guard account.authenticated else { throw ClientError.message("Please sign in to Apple Music first.") }
        let library = LibraryService(wrapper: service)
        var next: String? = path; var visited = Set<String>(); var items: [LibraryItem] = []
        while let address = next, items.count < 1000 {
            guard visited.insert(address).inserted else { break }
            let page = try await library.page(address, account: account)
            items.append(contentsOf: page.data); next = page.next
        }
        return items
    }
    func load(_ path: String, service: WrapperService, refresh: Bool = false) {
        generation = UUID(); let current = generation
        task?.cancel(); currentPath = path; failure = nil
        if refresh { cache.removeValue(forKey: path) }
        let cached = cache[path]
        items = cached?.items ?? []
        if let cached, cached.next == nil { loading = false; return }
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { loading = false } }
            do {
                let account = try await service.account()
                guard account.authenticated else { throw ClientError.message("Please sign in to Apple Music first.") }
                let library = LibraryService(wrapper: service)
                var next: String? = cached?.next ?? path
                var visited = cached?.visited ?? Set<String>()
                var seen = Set(items.map { $0.type + ":" + $0.id })
                while let address = next {
                    try Task.checkCancellation()
                    guard visited.insert(address).inserted else { throw ClientError.message("Apple returned a repeated library page. Please reload.") }
                    let page = try await library.page(address, account: account)
                    guard generation == current else { return }
                    // Playlist ordering and intentionally repeated tracks are preserved.
                    items.append(contentsOf: page.data.filter { path.hasSuffix("/tracks") || seen.insert($0.type + ":" + $0.id).inserted })
                    next = page.next
                    cache[path] = Snapshot(items: items, next: next, visited: visited)
                }
            } catch is CancellationError { }
            catch {
                guard generation == current else { return }
                failure = (error as? ClientError)?.errorDescription ?? "The library could not be loaded. Please try again."
            }
        }
    }
}
