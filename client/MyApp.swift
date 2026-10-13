import AppKit
import SwiftUI

@main struct HelixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        Window("Helix", id: "main") {
            ContentView(wrapper: app.wrapper).environmentObject(app)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(app: app) }

        Settings { SettingsView().environmentObject(app) }
    }
}

/// Menu bar commands in the order of the Music app: File, View, Controls.
private struct AppCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Song Link …") { app.showingLinkSheet = true }
                .keyboardShortcut("l")
                .disabled(app.account != .signedIn)
        }
        CommandGroup(before: .sidebar) {
            Group {
            Button("Search") { app.focusSearch() }
                .keyboardShortcut("f")
            ForEach(Array(LibraryCategory.allCases.filter { $0 != .search }.enumerated()), id: \.element) { index, category in
                Button(category.title) { app.category = category }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Playing Next") { app.showingQueue.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button("Reload Library") { app.refreshLibrary() }
                .keyboardShortcut("r")
            }
            .disabled(app.account != .signedIn)
            Divider()
        }
        CommandMenu("Controls") { PlaybackMenu(app: app, player: app.player, queue: app.queue) }
    }
}

private struct PlaybackMenu: View {
    let app: AppModel
    @AppStorage(AudioPlayer.matchRateKey) private var matchRate = true
    @ObservedObject var player: AudioPlayer
    @ObservedObject var queue: PlaybackQueue

    var body: some View {
        Button(player.airPlay != nil ? "Disconnect AirPlay" : player.playing ? "Pause" : "Play") { queue.toggle() }
            .disabled(!app.canControlPlayback)
        Button("Next Song") { queue.advance() }
            .keyboardShortcut(.rightArrow)
            .disabled(player.airPlay != nil || queue.state.upcoming.isEmpty)
        Button("Previous Song") { queue.previous() }
            .keyboardShortcut(.leftArrow)
            .disabled(!player.canSeek)
        Divider()
        Button("Forward 15 Seconds") { app.skip(by: 15) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!player.canSeek)
        Button("Back 15 Seconds") { app.skip(by: -15) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!player.canSeek)
        Divider()
        Button(app.showingNowPlaying ? "Close Full-Screen Player" : "Full-Screen Player") { app.toggleNowPlaying() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(app.account != .signedIn && player.airPlay == nil)
        Divider()
        Toggle("Match Device Sample Rate", isOn: $matchRate)
        Divider()
        Button("Volume Up") { app.changeVolume(by: 0.1) }
            .keyboardShortcut(.upArrow)
        Button("Volume Down") { app.changeVolume(by: -0.1) }
            .keyboardShortcut(.downArrow)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitting = false
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = AppModel.shared
        Task { await app.start() }
        #if SNAPSHOT
        DevSnapshots.run(app)
        #endif
        // Space toggles playback like in the Music app, except while typing.
        // A menu key equivalent would swallow spaces in text fields.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc leaves the full-screen player.
            if event.keyCode == 53, app.showingNowPlaying, event.window?.attachedSheet == nil,
               event.window?.identifier?.rawValue.hasPrefix("main") == true {
                app.closeNowPlaying(); return nil
            }
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = event.window, window.attachedSheet == nil, !(window.firstResponder is NSText),
                  window.identifier?.rawValue.hasPrefix("main") == true,
                  app.canControlPlayback else { return event }
            app.queue.toggle()
            return nil
        }
    }
    /// Like the Music app, closing the window keeps the music and the remote running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }; quitting = true
        let app = AppModel.shared
        app.airPlay.stop(); app.remote.stop(); app.queue.shutdown()
        return .terminateNow
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let app = AppModel.shared, menu = NSMenu()
        if let title = app.player.displayTitle {
            let artist = app.player.displayArtist ?? ""
            let item = NSMenuItem(title: artist.isEmpty ? title : "\(title) – \(artist)", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        }
        guard app.canControlPlayback else { return menu }
        menu.addItem(DockAction(app.player.airPlay != nil ? "Disconnect AirPlay" : app.player.playing ? "Pause" : "Play") { app.queue.toggle() })
        if app.player.airPlay == nil, !app.queue.state.upcoming.isEmpty { menu.addItem(DockAction("Next Song") { app.queue.advance() }) }
        if app.player.stream != nil { menu.addItem(DockAction("Previous Song") { app.queue.previous() }) }
        return menu
    }
}

private final class DockAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}
