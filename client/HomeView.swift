import SwiftUI

// MARK: - Model

struct ShelfEntry: Identifiable {
    let id: String
    let item: LibraryItem
    var badge: String?
}

struct HomeSection: Identifiable {
    enum Style { case featured, hero, songs, covers, artists }
    let id: String
    let title: String?
    let style: Style
    let entries: [ShelfEntry]

    init(id: String, title: String?, style: Style, items: [LibraryItem], badges: [String?] = []) {
        self.id = id; self.title = title; self.style = style
        entries = items.enumerated().map { index, item in
            ShelfEntry(id: "\(index)-\(item.type)-\(item.id)", item: item, badge: index < badges.count ? badges[index] : nil)
        }
    }
    func filtered(_ text: String) -> HomeSection? {
        let kept = entries.filter { $0.item.matches(text) }
        guard !kept.isEmpty else { return nil }
        return HomeSection(id: id, title: title, style: style == .hero || style == .featured ? .covers : style,
                           items: kept.map(\.item), badges: kept.map(\.badge))
    }
}


@MainActor
class ShelfPageModel: ObservableObject {
    @Published fileprivate(set) var sections: [HomeSection] = []
    @Published fileprivate(set) var loading = false
    @Published fileprivate(set) var failure: String?
    private var loadedAt: Date?
    private var task: Task<Void, Never>?

    func load(service: WrapperService, refresh: Bool = false) {
        if loading && !refresh { return }
        if !refresh, let loadedAt, Date().timeIntervalSince(loadedAt) < 1800, !sections.isEmpty { return }
        task?.cancel(); loading = true; failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { loading = false } }
            do {
                let account = try await service.account()
                guard account.authenticated else { throw ClientError.message("Please sign in to Apple Music first.") }
                let api = LibraryService(wrapper: service)
                if let data = try? await api.data(URL(string: "https://api.music.apple.com/v1/me/storefront")!, account: account),
                   let item = try? JSONDecoder().decode(StorefrontPage.self, from: data).data.first, Storefront.valid(item.id) {
                    Storefront.current = item.id
                    Storefront.pickLanguage(default: item.attributes?.defaultLanguageTag, supported: item.attributes?.supportedLanguageTags ?? [])
                }
                try await fetch(api: api, account: account)
                loadedAt = Date()
            } catch is CancellationError {
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "The page could not be loaded."
            }
        }
    }
    func fetch(api: LibraryService, account: WrapperAccount) async throws {}
    private struct StorefrontPage: Decodable {
        struct Item: Decodable { let id: String; let attributes: Attributes? }
        struct Attributes: Decodable { let defaultLanguageTag: String?; let supportedLanguageTags: [String]? }
        let data: [Item]
    }
}

/// The account's personal recommendations, the same feed as the Music app's home page.
final class HomeModel: ShelfPageModel {
    override func fetch(api: LibraryService, account: WrapperAccount) async throws {
        sections = try await Editorial.home(api: api, account: account) { [weak self] page in self?.sections = page }
    }
}

/// Apple's editorial "New" page, as shown in the Music app.
final class BrowseModel: ShelfPageModel {
    override func fetch(api: LibraryService, account: WrapperAccount) async throws {
        sections = try await Editorial.new(api: api, account: account)
    }
}

/// A page behind one of the search page's category tiles.
final class CategoryModel: ShelfPageModel {
    let category: BrowseCategory
    init(category: BrowseCategory) { self.category = category }
    override func fetch(api: LibraryService, account: WrapperAccount) async throws {
        sections = try await Editorial.category(category, api: api, account: account)
    }
}

// MARK: - Page

struct ShelfPage: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ShelfPageModel
    let title: String
    let emptyTitle: String
    let emptyText: String

    private var sections: [HomeSection] {
        // On the search page the field holds the search term, not a filter.
        let text = app.category == .search ? "" : app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? model.sections : model.sections.compactMap { $0.filtered(text) }
    }

    var body: some View {
        let sections = sections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                ForEach(sections) { section in Shelf(section: section) }
            }
            .padding(.vertical, 22)
        }
        .overlay {
            if sections.isEmpty {
                if model.loading { ProgressView("Loading \(title) …") }
                else if let failure = model.failure {
                    ContentUnavailableView {
                        Label("\(title) not available", systemImage: "exclamationmark.icloud")
                    } description: { Text(failure) } actions: {
                        Button("Reload") { model.load(service: app.wrapper.service, refresh: true) }
                    }
                } else if !app.searchText.isEmpty { ContentUnavailableView.search(text: app.searchText) }
                else { ContentUnavailableView(emptyTitle, systemImage: "music.note.house", description: Text(emptyText)) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(model.loading && !model.sections.isEmpty ? "Updating …" : "")
        .task { model.load(service: app.wrapper.service) }
    }
}

/// One horizontally scrolling row with page buttons on hover, as in the Music app.
struct Shelf: View {
    @EnvironmentObject private var app: AppModel
    let section: HomeSection
    @State private var page = 0
    @State private var hovering = false
    @State private var width: CGFloat = 800
    private static let songRows = 4
    private static let start = "shelf-start"

    private var cardWidth: CGFloat {
        switch section.style {
        case .featured: 230
        case .hero: 0   // sized by containerRelativeFrame: three per row, like the Music app
        case .songs: 300
        case .covers: 168
        case .artists: 150
        }
    }
    private var spacing: CGFloat { section.style == .covers ? 18 : 20 }
    private var columnsPerPage: Int { section.style == .hero ? 3 : max(1, Int((width - 48 + spacing) / (cardWidth + spacing))) }
    /// Scroll targets: one per card, or one per column of four songs.
    private var targets: [String] {
        section.style == .songs ? stride(from: 0, to: section.entries.count, by: Self.songRows).map { section.entries[$0].id } : section.entries.map(\.id)
    }
    private var index: Int { min(page, max(0, targets.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title {
                Text(title).font(.title2.weight(.bold)).padding(.horizontal, 24).accessibilityAddTraits(.isHeader)
            }
            // Paging moves by explicit scroll targets. A bound scroll position with
            // view-aligned snapping started rows in the middle after the first layout.
            // Plain padding: contentMargins together with a default scroll anchor
            // made the banner row start at its end.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 0, height: 0).id(Self.start)   // offset zero, padding included
                        content.padding(.horizontal, 24)
                    }
                }
                .overlay { if hovering && targets.count > columnsPerPage { pager(proxy) } }
                // AppKit can keep a stale horizontal offset from the first layout pass,
                // so rows sometimes opened in the middle. Start each row at its beginning.
                .task(id: section.id) {
                    page = 0
                    for delay in [50_000_000, 400_000_000] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay)
                        if page == 0 { proxy.scrollTo(Self.start, anchor: .leading) }
                    }
                }
            }
            .background(GeometryReader { geometry in Color.clear.onAppear { width = geometry.size.width }.onChange(of: geometry.size.width) { width = geometry.size.width } })
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    @ViewBuilder private var content: some View {
        switch section.style {
        case .songs:
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(Array(stride(from: 0, to: section.entries.count, by: Self.songRows)), id: \.self) { start in
                    VStack(spacing: 0) {
                        ForEach(section.entries[start..<min(start + Self.songRows, section.entries.count)]) { entry in
                            SongTile(item: entry.item, queue: app.queue).frame(width: cardWidth)
                        }
                    }
                    .frame(width: cardWidth, alignment: .top)
                    .id(section.entries[start].id)
                }
            }
        case .hero:
            // A plain stack: lazy stacks estimate container-relative widths first and
            // kept a wrong scroll offset, so the banner row started at its end.
            HStack(alignment: .top, spacing: spacing) {
                ForEach(section.entries) { entry in
                    HeroCard(entry: entry)
                        .containerRelativeFrame(.horizontal) { length, _ in max(260, (length - 48 - 2 * spacing) / 3) }
                        .id(entry.id)
                }
            }
        default:
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(section.entries) { entry in
                    Group {
                        switch section.style {
                        case .featured: FeatureCard(item: entry.item)
                        case .artists: ArtistCard(item: entry.item)
                        default: CollectionCard(item: entry.item, symbol: entry.item.isAlbum ? "square.stack" : "music.note.list")
                        }
                    }
                    .frame(width: cardWidth)
                    .id(entry.id)
                }
            }
        }
    }

    private func pager(_ proxy: ScrollViewProxy) -> some View {
        HStack {
            pageButton("chevron.left", label: "Scroll back", target: max(0, index - columnsPerPage), proxy: proxy).opacity(index > 0 ? 1 : 0)
            Spacer()
            pageButton("chevron.right", label: "Scroll forward", target: min(targets.count - 1, index + columnsPerPage), proxy: proxy)
                .opacity(index + columnsPerPage < targets.count ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, section.style == .covers || section.style == .artists ? 40 : section.style == .featured ? 90 : 0)
        .padding(.top, section.style == .hero ? 70 : 0)
    }
    private func pageButton(_ symbol: String, label: String, target: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            page = target
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target == 0 ? Self.start : targets[target], anchor: .leading) }
        } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Cards

/// Large card for the home page's first row ("Playlists für dich"): artwork above a
/// panel in the artwork's own background color with title and description.
private struct FeatureCard: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    @State private var hovering = false
    private var background: Color { Color(hex: item.artworkColor) ?? Color(red: 0.35, green: 0.1, blue: 0.2) }
    private var lightBackground: Bool { luminance(item.artworkColor) > 0.6 }

    var body: some View {
        Button { app.open(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(url: item.artwork(600), symbol: "music.note.list", cornerRadius: 0)
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.summary ?? item.artist).font(.caption).lineLimit(3).opacity(0.8)
                }
                .foregroundStyle(lightBackground ? .black : .white)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                .background(background)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.14), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { if hovering { PlayBadge(item: item).padding(10) } }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .contextMenu { CollectionMenu(item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.artist)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.open(item) }
    }
}

/// Banner card of the "New" page, as in the Music app: badge, title and artist
/// above 3:2 editorial artwork with the description on the image and, for
/// albums, the cover in the corner.
private struct HeroCard: View {
    @EnvironmentObject private var app: AppModel
    let entry: ShelfEntry
    @State private var hovering = false
    private var item: LibraryItem { entry.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let badge = entry.badge { Text(badge.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            Text(item.title).font(.title3).lineLimit(1)
            Text(item.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
            Button { app.open(item) } label: { banner }
                .buttonStyle(.plain)
                .padding(.top, 10)
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .contextMenu { CollectionMenu(item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([entry.badge, item.title, item.artist, item.summary].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.open(item) }
    }

    private var banner: some View {
        Color.clear
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay { ArtworkView(url: item.wideArtwork(width: 1200) ?? item.artwork(1000), symbol: item.isAlbum ? "square.stack" : "music.note.list", cornerRadius: 0) }
            .overlay(alignment: .bottom) {
                // Scrim so the white description stays readable on light artwork.
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    if let summary = item.summary {
                        Text(summary).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                    Spacer(minLength: 0)
                    if item.isAlbum, item.wideArtworkTemplate != nil {
                        ArtworkView(url: item.artwork(300), cornerRadius: 4)
                            .frame(width: 72, height: 72)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                }
                .padding(14)
            }
            .overlay(alignment: .topTrailing) { if hovering { PlayBadge(item: item).padding(12) } }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.24 : 0.12), radius: hovering ? 12 : 6, y: 4)
    }
}

/// A song in a four-row grid: click plays it, the context menu queues it.
private struct SongTile: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    @ObservedObject var queue: PlaybackQueue
    @State private var hovering = false
    private var current: Bool { queue.state.current?.catalogID == item.catalogID }

    var body: some View {
        Button { app.play(item) } label: {
            HStack(spacing: 10) {
                ArtworkView(url: item.artwork(120), cornerRadius: 4)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if hovering || current {
                            Group {
                                if current { PlayingMark().frame(width: 22, height: 14) }
                                else { Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)) }
                            }
                            .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1).foregroundStyle(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(item.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5).padding(.leading, 54) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play") { app.play(item) }
            Button("Play Next") { app.playNext([item]) }
            Button("Play Last") { app.playLater([item]) }
            if let id = item.catalogID {
                Divider()
                Button("Go to Album") { app.goToAlbum(songID: id) }
                Button("Go to Artist") { app.goToArtist(songID: id) }
            }
            Divider()
            Button("Copy Link") { app.copyLink([item]) }
        }
        .help("Play \(item.title)")
        .accessibilityLabel("\(item.title), \(item.artist)\(current ? ", läuft gerade" : "")")
    }
}

private struct PlayBadge: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    var body: some View {
        Button { app.playCollection(item) } label: {
            Image(systemName: "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Circle().fill(.tint))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help("Play “\(item.title)”")
        .accessibilityLabel("Play \(item.title)")
        .transition(.opacity)
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

private func luminance(_ hex: String?) -> Double {
    guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return 0 }
    return 0.2126 * Double((value >> 16) & 0xff) / 255 + 0.7152 * Double((value >> 8) & 0xff) / 255 + 0.0722 * Double(value & 0xff) / 255
}
