import Foundation

/// A tile of Apple Music's search page ("Browse Categories"): a genre or
/// mood curator, a multi-room event page, or the charts.
struct BrowseCategory: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case curator, multiroom, charts }
    let id: String
    let kind: Kind
    let title: String
    let artworkTemplate: String?
    let color: String?
    func artwork(width: Int, height: Int) -> URL? {
        artworkTemplate.flatMap { URL(string: $0.replacingOccurrences(of: "{w}", with: "\(width)").replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{c}", with: "sr").replacingOccurrences(of: "{f}", with: "jpg")) }
    }
}

/// Apple Music's editorial pages: the personal home feed, "New", the search
/// categories and their pages, and the charts. Shared by the Mac app and the
/// remote. Groupings, curators and multi-rooms come from Apple's internal API
/// host, which accepts the embedded client's token; these endpoints are
/// undocumented and may change.
enum Editorial {
    static var language: String { Storefront.language }

    // MARK: Pages

    /// The account's recommendations, the same feed as the Music app's home page.
    static func home(api: LibraryService, account: WrapperAccount, page: (([HomeSection]) -> Void)? = nil) async throws -> [HomeSection] {
        var next: String? = "/v1/me/recommendations?limit=10"
        var result: [HomeSection] = []
        for _ in 0..<4 {
            guard let path = next, path.hasPrefix("/v1/me/recommendations"),
                  let url = URL(string: "https://api.music.apple.com" + path) else { break }
            let response = try JSONDecoder().decode(RecommendationPage.self, from: await api.data(Storefront.localized(url), account: account))
            try Task.checkCancellation()
            result += response.data.compactMap { recommendation in
                let items = (recommendation.relationships?.contents?.data ?? []).filter { $0.isCollection && $0.trackPath != nil }
                guard !items.isEmpty else { return nil }
                return HomeSection(id: recommendation.id, title: recommendation.attributes?.title?.stringForDisplay ?? "For You",
                                   style: result.isEmpty ? .featured : .covers, items: items)
            }
            page?(result)
            next = response.next
        }
        return result
    }
    /// Apple's editorial "New" page.
    static func new(api: LibraryService, account: WrapperAccount) async throws -> [HomeSection] {
        try await grouping([URLQueryItem(name: "name", value: "music")], api: api, account: account)
    }
    static func category(_ category: BrowseCategory, api: LibraryService, account: WrapperAccount) async throws -> [HomeSection] {
        switch category.kind {
        case .charts:
            return try await charts(api: api, account: account)
        case .multiroom:
            let data = try await api.data(ampURL("editorial", "multirooms/\(category.id)"), account: account)
            return rows(try JSONDecoder().decode(Resources.self, from: data).data.first?.relationships?.children?.data ?? [])
        case .curator:
            // A curator (genre or mood) has its own grouping, built like "New".
            let data = try await api.data(ampURL("catalog", "apple-curators/\(category.id)", [URLQueryItem(name: "views", value: "grouping")]), account: account)
            guard let grouping = try JSONDecoder().decode(CuratorResponse.self, from: data).data.first?.relationships?.grouping?.data.first?.id,
                  CatalogService.validID(grouping) else { throw ClientError.message("This category has no content.") }
            return try await self.grouping([URLQueryItem(name: "ids", value: grouping)], api: api, account: account)
        }
    }
    static func charts(api: LibraryService, account: WrapperAccount) async throws -> [HomeSection] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(Storefront.current)/charts")!
        components.queryItems = [URLQueryItem(name: "types", value: "songs,albums,playlists"), URLQueryItem(name: "limit", value: "50"),
                                 URLQueryItem(name: "l", value: Storefront.language)]
        let response = try JSONDecoder().decode(ChartsResponse.self, from: await api.data(components.url!, account: account))
        var sections: [HomeSection] = []
        for (key, style) in [("songs", HomeSection.Style.songs), ("albums", .covers), ("playlists", .covers)] {
            for chart in response.results[key] ?? [] {
                let items = chart.data.filter { style == .songs ? $0.playable : $0.trackPath != nil }
                if !items.isEmpty { sections.append(HomeSection(id: "chart-\(key)-\(chart.chart ?? "")", title: chart.name ?? "Charts", style: style, items: items)) }
            }
        }
        return sections
    }

    // MARK: Search categories

    @MainActor private static var cachedCategories: (date: Date, storefront: String, items: [BrowseCategory])?
    /// The category tiles of Apple Music's search page. The API offers no list of
    /// them, so they are read from the data embedded in the public search page.
    @MainActor
    static func categories() async throws -> [BrowseCategory] {
        let storefront = Storefront.current
        if let cached = cachedCategories, cached.storefront == storefront, Date().timeIntervalSince(cached.date) < 6 * 3600 { return cached.items }
        guard let url = URL(string: "https://music.apple.com/\(storefront)/search") else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000, let page = String(data: data, encoding: .utf8) else {
            throw ClientError.message("The categories could not be loaded.")
        }
        let items = try parseCategories(page)
        cachedCategories = (Date(), storefront, items)
        return items
    }
    static func parseCategories(_ page: String) throws -> [BrowseCategory] {
        guard let start = page.range(of: #"<script[^>]*id="serialized-server-data"[^>]*>"#, options: .regularExpression),
              let end = page.range(of: "</script>", range: start.upperBound..<page.endIndex) else {
            throw ClientError.message("Apple changed the search page; the categories cannot be read.")
        }
        let json = unescapeHTML(String(page[start.upperBound..<end.lowerBound]))
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let section = findSections(root)?.first(where: { ($0["id"] as? String)?.hasPrefix("browse-category-bricks") == true }),
              let items = section["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let title = item["title"] as? String, let descriptor = item["contentDescriptor"] as? [String: Any] else { return nil }
            let artwork = (item["artwork"] as? [String: Any])?["dictionary"] as? [String: Any]
            let destination = (item["segue"] as? [String: Any])?["destination"] as? [String: Any]
            let target = ((destination?["intent"] as? [String: Any])?["contentDescriptor"] ?? destination?["contentDescriptor"]) as? [String: Any]
            let kind: BrowseCategory.Kind, id: String
            switch (descriptor["kind"] as? String, target?["kind"] as? String) {
            case ("appleCurator", _):
                kind = .curator; id = (descriptor["identifiers"] as? [String: Any])?["storeAdamID"] as? String ?? ""
            case (_, "multiroom"?):
                kind = .multiroom; id = (target?["identifiers"] as? [String: Any])?["storeAdamID"] as? String ?? ""
            case (_, "topCharts"?):
                kind = .charts; id = "charts"
            default:
                return nil   // concerts and pages the player cannot use
            }
            guard kind == .charts || CatalogService.validID(id) else { return nil }
            return BrowseCategory(id: id, kind: kind, title: title.replacingOccurrences(of: "\u{00a0}", with: " "),
                                  artworkTemplate: artwork?["url"] as? String, color: artwork?["bgColor"] as? String)
        }
    }
    private static func findSections(_ value: Any) -> [[String: Any]]? {
        if let object = value as? [String: Any] {
            if let sections = object["sections"] as? [[String: Any]] { return sections }
            for child in object.values { if let found = findSections(child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findSections(child) { return found } }
        }
        return nil
    }
    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Groupings

    private static func ampURL(_ realm: String, _ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/\(realm)/\(Storefront.current)/\(path)")!
        components.queryItems = query + [
            URLQueryItem(name: "platform", value: "web"), URLQueryItem(name: "l", value: language),
            URLQueryItem(name: "extend", value: "editorialArtwork,editorialNotes"), URLQueryItem(name: "art[url]", value: "f"),
        ]
        return components.url!
    }
    private static func grouping(_ query: [URLQueryItem], api: LibraryService, account: WrapperAccount) async throws -> [HomeSection] {
        let response = try JSONDecoder().decode(GroupingResponse.self, from: await api.data(ampURL("editorial", "groupings", query), account: account))
        try Task.checkCancellation()
        return rows(response.data.first?.relationships?.tabs?.data.first?.relationships?.children?.data ?? [])
    }
    /// Editorial rows to shelves. Only what the Lossless player can use stays:
    /// songs, albums, playlists and artists; radio, videos and curators are left out.
    static func rows(_ rows: [Element]) -> [HomeSection] {
        rows.compactMap { row in
            if row.attributes?.editorialElementKind == "316" {
                // Banner carousel: each child wraps one album or playlist and carries a badge.
                let pairs = (row.relationships?.children?.data ?? []).compactMap { child -> (LibraryItem, String?)? in
                    guard let item = child.relationships?.contents?.data.first, item.isCollection, item.trackPath != nil else { return nil }
                    return (item, child.attributes?.designBadge)
                }
                guard !pairs.isEmpty else { return nil }
                return HomeSection(id: row.id, title: nil, style: .hero, items: pairs.map(\.0), badges: pairs.map(\.1))
            }
            guard let title = row.attributes?.name, !title.isEmpty else { return nil }
            let contents = row.relationships?.contents?.data ?? []
            let artists = contents.filter { $0.type == "artists" }
            if !artists.isEmpty, artists.count == contents.count {
                return HomeSection(id: row.id, title: title, style: .artists, items: artists)
            }
            let items = contents.filter { $0.playable || ($0.isCollection && $0.trackPath != nil) }
            guard !items.isEmpty else { return nil }
            return HomeSection(id: row.id, title: title, style: items.allSatisfy(\.isSong) ? .songs : .covers, items: items)
        }
    }

    // MARK: Decoding

    struct Children: Decodable { let data: [Element] }
    struct Element: Decodable {
        let id: String
        let attributes: Attributes?
        let relationships: Relationships?
        struct Attributes: Decodable { let name: String?; let editorialElementKind: String?; let designBadge: String? }
        struct Relationships: Decodable { let contents: Contents?; let children: Children? }
        struct Contents: Decodable { let data: [LibraryItem] }
    }
    private struct GroupingResponse: Decodable {
        let data: [Grouping]
        struct Grouping: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let tabs: Tabs? }
        struct Tabs: Decodable { let data: [Tab] }
        struct Tab: Decodable { let relationships: TabRelationships? }
        struct TabRelationships: Decodable { let children: Children? }
    }
    private struct Resources: Decodable {
        let data: [Resource]
        struct Resource: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let children: Children? }
    }
    private struct CuratorResponse: Decodable {
        let data: [Curator]
        struct Curator: Decodable { let relationships: Relationships? }
        struct Relationships: Decodable { let grouping: Grouping? }
        struct Grouping: Decodable { let data: [Reference] }
        struct Reference: Decodable { let id: String }
    }
    private struct ChartsResponse: Decodable {
        let results: [String: [Chart]]
        struct Chart: Decodable { let name: String?; let chart: String?; let data: [LibraryItem] }
    }
    private struct RecommendationPage: Decodable {
        let data: [Recommendation]
        let next: String?
        struct Recommendation: Decodable {
            let id: String
            let attributes: Attributes?
            let relationships: Relationships?
            struct Attributes: Decodable { let title: Title? }
            struct Title: Decodable { let stringForDisplay: String? }
            struct Relationships: Decodable { let contents: Contents? }
            struct Contents: Decodable { let data: [LibraryItem] }
        }
    }
}
