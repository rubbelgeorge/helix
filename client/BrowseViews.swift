import SwiftUI

// MARK: - Search

/// Apple Music catalog search. The term comes from the toolbar search field.
struct SearchPage: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: SearchModel

    var body: some View {
        ScrollView {
            if model.term.isEmpty {
                CategoryGrid()
            } else {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(model.sections) { section in Shelf(section: section) }
                }
                .padding(.vertical, 22)
            }
        }
        .overlay {
            if model.sections.isEmpty && !model.term.isEmpty {
                if model.loading {
                    ProgressView("Searching …")
                } else if let failure = model.failure {
                    ContentUnavailableView {
                        Label("Search Failed", systemImage: "exclamationmark.icloud")
                    } description: { Text(failure) } actions: {
                        Button("Try Again") { app.refreshLibrary() }
                    }
                } else {
                    ContentUnavailableView.search(text: model.term)
                }
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(model.term.isEmpty ? "Apple Music" : "“\(model.term)”")
        .onAppear { model.update(app.searchText, service: app.wrapper.service) }
    }
}

/// Apple Music's search categories (genres, moods, charts), as on the Music app's search page.
private struct CategoryGrid: View {
    @EnvironmentObject private var app: AppModel
    @State private var categories: [BrowseCategory] = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse Categories").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            if categories.isEmpty {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.icloud").foregroundStyle(.secondary)
                    Button("Reload") { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)], spacing: 16) {
                    ForEach(categories) { category in CategoryTile(category: category) }
                }
            }
        }
        .padding(24)
        .task { await load() }
    }
    private func load() async {
        failure = nil
        do { categories = try await Editorial.categories() }
        catch { failure = (error as? LocalizedError)?.errorDescription ?? "The categories could not be loaded." }
    }
}

private struct CategoryTile: View {
    @EnvironmentObject private var app: AppModel
    let category: BrowseCategory
    @State private var hovering = false

    var body: some View {
        Button { app.openCategory(category) } label: {
            ZStack(alignment: .bottomLeading) {
                (Color(hex: category.color) ?? .gray)
                ArtworkView(url: category.artwork(width: 800, height: 450), symbol: "music.note.list", cornerRadius: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                Text(category.title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .padding(14)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 5, y: 3)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityLabel(category.title)
    }
}

// MARK: - Artist

struct ArtistView: View {
    @EnvironmentObject private var app: AppModel
    let artist: ArtistRef
    @ObservedObject var model: ArtistModel
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                if let page = model.page {
                    ForEach(page.sections) { section in Shelf(section: section) }
                    if let bio = page.bio, !bio.isEmpty { about(bio, name: page.name) }
                }
            }
            .padding(.bottom, 28)
        }
        .overlay {
            if model.page == nil {
                if model.loading { ProgressView("Loading artist …") }
                else if let failure = model.failure {
                    ContentUnavailableView {
                        Label("Artist page not available", systemImage: "exclamationmark.icloud")
                    } description: { Text(failure) } actions: {
                        Button("Reload") { model.load(id: artist.id, service: app.wrapper.service, refresh: true) }
                    }
                }
            }
        }
        .navigationTitle(model.page?.name ?? artist.name)
        .task(id: artist.id) { model.load(id: artist.id, service: app.wrapper.service) }
    }

    private var name: String { model.page?.name ?? artist.name }
    private var topSongs: [LibraryItem] { model.page?.topSongs ?? [] }

    @ViewBuilder private var header: some View {
        if let banner = Self.fill(model.page?.bannerTemplate, width: 2400, height: 800) {
            // Banner like the Music app: wide artwork, the name on a soft scrim.
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: banner, symbol: "music.mic", cornerRadius: 0)
                    .frame(maxWidth: .infinity).frame(height: 300).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                HStack(alignment: .bottom) {
                    Text(name).font(.system(size: 40, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    Spacer()
                    playButtons
                }
                .padding(24)
            }
            .frame(height: 300)
        } else {
            HStack(alignment: .center, spacing: 24) {
                ArtworkView(url: Self.fill(model.page?.artworkTemplate, width: 500, height: 500), symbol: "music.mic", cornerRadius: 90)
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 14) {
                    Text(name).font(.system(size: 34, weight: .bold)).lineLimit(2)
                    playButtons
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 24)
        }
    }

    private var playButtons: some View {
        HStack(spacing: 10) {
            Button { app.playAll(topSongs) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 90) }
                .buttonStyle(.borderedProminent)
            Button { app.playAll(topSongs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 90) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(topSongs.isEmpty)
        .help("Plays the top songs")
    }

    private func about(_ bio: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About \(name)").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(bio).font(.body).foregroundStyle(.secondary)
                .lineLimit(bioExpanded ? nil : 4)
                .frame(maxWidth: 760, alignment: .leading)
                .textSelection(.enabled)
            Button(bioExpanded ? "Less" : "More") { withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() } }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 24)
    }

    static func fill(_ template: String?, width: Int, height: Int) -> URL? {
        template.flatMap { URL(string: $0.replacingOccurrences(of: "{w}", with: "\(width)").replacingOccurrences(of: "{h}", with: "\(height)")
            .replacingOccurrences(of: "{c}", with: "cc").replacingOccurrences(of: "{f}", with: "jpg")) }
    }
}

/// Round artist card for search results and "Similar Artists".
struct ArtistCard: View {
    @EnvironmentObject private var app: AppModel
    let item: LibraryItem
    @State private var hovering = false

    var body: some View {
        Button { app.openArtist(ArtistRef(id: item.id, name: item.title)) } label: {
            VStack(spacing: 8) {
                ArtworkView(url: item.artwork(400), symbol: "music.mic", cornerRadius: 200)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(hovering ? 0.22 : 0.12), radius: hovering ? 9 : 6, y: 3)
                    .scaleEffect(hovering ? 1.02 : 1)
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help("Open artist page of \(item.title)")
        .accessibilityLabel("\(item.title), artist")
    }
}

/// Text that navigates when clicked, underlined on hover, like links in the Music app's player.
struct LinkText: View {
    let text: String
    let help: String
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { Text(text).underline(hovering) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help)
        } else {
            Text(text)
        }
    }
}
