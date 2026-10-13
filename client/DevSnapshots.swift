#if SNAPSHOT
import AppKit

/// Development-only: renders the main window into PNG files for UI review.
/// Compiled only with `-D SNAPSHOT`; release builds do not contain it.
@MainActor
enum DevSnapshots {
    static func run(_ app: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["HELIX_SNAPSHOTS"] else { return }
        let steps: [(String, () -> Void)] = [
            ("home", { app.category = .home }),
            ("new", { app.category = .new }),
            ("recent", { app.category = .recentlyAdded }),
            ("songs", { app.category = .songs }),
            ("albums", { app.category = .albums }),
            ("album-detail", { if let first = app.library(LibraryCategory.albums.path).items.first { app.open(first) } }),
            ("home-detail", { app.category = .home; if let first = app.home.sections.first?.entries.first?.item { app.open(first) } }),
            ("playlists", { app.category = .playlists }),
            ("queue", { app.category = .songs; app.showingQueue = true }),
            ("search", { app.searchText = "love" }),
            ("link", { app.searchText = ""; app.showingQueue = false; app.showingLinkSheet = true }),
            ("prerelease-album", {
                let json = #"{"id":"6779714931","type":"albums","attributes":{"name":"Leben in einer Katze","artistName":"Tränen"}}"#
                if let item = try? JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8)) { app.category = .new; app.open(item) }
            }),
            ("album-play", {
                let json = #"{"id":"6779714931","type":"albums","attributes":{"name":"Leben in einer Katze","artistName":"Tränen"}}"#
                if let item = try? JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8)) { app.playCollection(item) }
            }),
            ("nowplaying-album", { NotificationCenter.default.post(name: .init("AMOpenNowPlaying"), object: nil) }),
            ("nowplaying-album-idle", { NotificationCenter.default.post(name: .init("AMHideControls"), object: nil) }),
            ("nowplaying-album-next", { app.queue.advance() }),
            ("album-stop", { app.queue.toggle(); app.closeNowPlaying() }),
            ("gapless-seek", { app.player.seek(max(0, app.player.duration - 15)) }),
            ("gapless-wait1", {}), ("gapless-wait2", {}), ("gapless-wait3", {}), ("gapless-wait4", {}), ("gapless-wait5", {}),
            ("gapless-after", { NotificationCenter.default.post(name: .init("AMOpenNowPlaying"), object: nil) }),
            ("search-categories", { app.category = .search; app.searchText = "" }),
            ("category-curator", { app.openCategory(BrowseCategory(id: "982308377", kind: .curator, title: "Deutschpop", artworkTemplate: nil, color: nil)) }),
            ("category-charts", { app.goBack(); app.openCategory(BrowseCategory(id: "charts", kind: .charts, title: "Charts", artworkTemplate: nil, color: nil)) }),
            ("search-results", { app.category = .search; app.searchText = "Danger Dan" }),
            ("artist", { app.openArtist(ArtistRef(id: "1213801726", name: "LOTTE")) }),
            ("library-album", { app.category = .albums; if let first = app.library(LibraryCategory.albums.path).items.first { app.open(first) } }),
            ("animated-a", {
                let json = #"{"id":"6794460856","type":"albums","attributes":{"name":"Unshatter Film Soundtrack","artistName":"LINKIN PARK"}}"#
                if let item = try? JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8)) { app.category = .new; app.open(item) }
            }),
            ("animated-b", {}),
            ("nowplaying", { app.showingLinkSheet = false; NotificationCenter.default.post(name: .init("AMOpenNowPlaying"), object: nil) }),
            ("nowplaying-idle", { NotificationCenter.default.post(name: .init("AMHideControls"), object: nil) }),
            ("nowplaying-rebuild", { app.category = .new; app.searchText = "" }),
            ("nowplaying-side", { UserDefaults.standard.set("side", forKey: NowPlayingAppearance.layoutKey); app.openNowPlaying() }),
            ("nowplaying-side-idle", { NotificationCenter.default.post(name: .init("AMHideControls"), object: nil) }),
            ("nowplaying-settings", { NotificationCenter.default.post(name: .init("AMOpenNowPlayingSettings"), object: nil) }),
            ("nowplaying-closed", { NowPlayingAppearance.reset(); app.closeNowPlaying() }),
        ]
        let only = ProcessInfo.processInfo.environment["HELIX_STEPS"].flatMap { $0.isEmpty ? nil : $0.split(separator: ",").map(String.init) }
        let selected = only.map { names in steps.filter { names.contains($0.0) } } ?? steps
        Task {
            for _ in 0..<120 where app.account != .signedIn { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            for (name, action) in selected {
                action()
                try? await Task.sleep(nanoseconds: name.hasPrefix("nowplaying") ? 9_000_000_000 : 5_000_000_000)
                capture(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
            app.showingLinkSheet = false
        }
    }
    /// Captures the app's own windows, including materials, sheets and popovers.
    static func capture(to url: URL) {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { return }
        let symbol = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW).flatMap { dlsym($0, "CGWindowListCreateImage") }
        let create: Create = symbol.map { unsafeBitCast($0, to: Create.self) } ?? { _, _, _, _ in nil }
        func write(_ window: NSWindow, _ url: URL) {
            // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
            guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
                // Fallback without materials when the system refuses window capture.
                guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("fallback.png"))
                return
            }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        write(window, url)
        if let sheet = window.attachedSheet { write(sheet, url.deletingPathExtension().appendingPathExtension("sheet.png")) }
        for other in NSApp.windows where other.isVisible && other != window && other != window.attachedSheet && other.frame.width > 120 {
            write(other, url.deletingPathExtension().appendingPathExtension("popover.png"))
        }
    }
}
#endif
