import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var wrapper: WrapperConnection
    @ObservedObject private var player = AppModel.shared.player

    var body: some View {
        Group {
            if player.airPlay != nil && app.account != .signedIn {
                NowPlayingFullView(player: player, queue: app.queue)
            } else if !wrapper.ready || app.account == .unknown {
                ConnectView(wrapper: wrapper)
            } else if app.account == .signedOut {
                SignInView()
            } else {
                ZStack {
                    MainView()
                    if app.showingNowPlaying {
                        NowPlayingFullView(player: app.player, queue: app.queue)
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                            .zIndex(1)
                    }
                }
            }
        }
        .tint(.pink)
        .frame(minWidth: 820, minHeight: 540)
    }
}

// MARK: - Wrapper connection

/// First screen until the user's wrapper-v2 answers. Helix ships no
/// playback runtime of its own.
private struct ConnectView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var wrapper: WrapperConnection

    var body: some View {
        VStack(spacing: 18) {
            AppMark(size: 72)
            VStack(spacing: 6) {
                Text(wrapper.failure == nil ? "Connect to Your Wrapper" : "Wrapper Not Reachable").font(.title2.weight(.semibold))
                Text(wrapper.failure ?? "Helix plays through a wrapper-v2 that you run yourself, on this Mac or on a device in your local network.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            }
            if wrapper.connecting || (wrapper.ready && app.account == .unknown) {
                VStack(spacing: 8) {
                    ProgressView().progressViewStyle(.linear).frame(width: 240)
                    Text(wrapper.ready ? "Checking sign-in …" : wrapper.status).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                WrapperEndpointForm(wrapper: wrapper, actionTitle: "Connect").frame(width: 360)
                Link("About wrapper-v2", destination: URL(string: "https://github.com/glomatico/wrapper-v2")!).font(.callout)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Helix")
    }
}

/// Address and ports of the user's wrapper-v2. Used on the connect screen and in Settings.
struct WrapperEndpointForm: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var wrapper: WrapperConnection
    var actionTitle = "Apply"
    @State private var host = ""
    @State private var httpPort = ""
    @State private var decryptPort = ""

    private var endpoint: WrapperEndpoint? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains("/"), !host.contains(" "),
              let http = Int(httpPort), (1...65535).contains(http), let decrypt = Int(decryptPort), (1...65535).contains(decrypt) else { return nil }
        return WrapperEndpoint(host: host, httpPort: http, decryptPort: decrypt)
    }

    var body: some View {
        Form {
            TextField("Address", text: $host, prompt: Text(WrapperEndpoint.defaultHost))
            TextField("HTTP port", text: $httpPort, prompt: Text(String(WrapperEndpoint.defaultHTTPPort)))
            TextField("Decrypt port", text: $decryptPort, prompt: Text(String(WrapperEndpoint.defaultDecryptPort)))
            HStack {
                Spacer()
                Button(actionTitle) {
                    guard let endpoint else { return }
                    Task { await wrapper.update(endpoint); await app.connectWrapper() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(endpoint == nil || wrapper.connecting)
            }
        }
        .onAppear {
            host = wrapper.endpoint.host; httpPort = String(wrapper.endpoint.httpPort); decryptPort = String(wrapper.endpoint.decryptPort)
        }
    }
}

// MARK: - Sign in

private struct SignInView: View {
    @EnvironmentObject private var app: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var awaitingCode = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case email, password, code }

    var body: some View {
        VStack(spacing: 22) {
            AppMark(size: 64)
            VStack(spacing: 6) {
                Text(awaitingCode ? "Enter Verification Code" : "Sign In to Apple Music").font(.title2.weight(.semibold))
                Text(awaitingCode ? "Apple sent a six-digit code to your trusted devices."
                                  : "Sign in with your Apple Account to listen to your library in lossless on this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)

            VStack(spacing: 10) {
                if awaitingCode {
                    TextField("000000", text: $code)
                        .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6)); if digits != value { code = digits }
                            if digits.count == 6 { submit() }
                        }
                        .onSubmit(submit)
                        .accessibilityLabel("Verification code")
                } else {
                    TextField("Apple Account", text: $email)
                        .textContentType(.username)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .frame(width: 300)
            .disabled(working)

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center).frame(maxWidth: 340).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if awaitingCode {
                    Button("Back") { awaitingCode = false; code = ""; error = nil; focus = .email }.disabled(working)
                }
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small) }
                        Text(awaitingCode ? "Verify" : "Sign In")
                    }
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || (awaitingCode ? code.count != 6 : email.isEmpty || password.isEmpty))
            }
            .controlSize(.large)

            Text("Helix does not store your password. It goes straight to your wrapper-v2, which signs in to Apple.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Helix")
        .onAppear { focus = .email }
    }

    private func submit() {
        guard !working else { return }
        if awaitingCode ? code.count != 6 : email.isEmpty || password.isEmpty { return }
        working = true; error = nil
        let service = app.wrapper.service
        Task {
            defer { working = false; password = "" }
            do {
                if awaitingCode { try await service.twoFactor(code); code = "" }
                else if try await !service.login(email: email, password: password) { awaitingCode = true; focus = .code; return }
                guard try await service.account().authenticated else { throw ClientError.message("Sign-in is not complete yet.") }
                app.setSignedIn(true)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Sign-in could not be completed."
                if awaitingCode { code = ""; focus = .code } else { focus = .password }
            }
        }
    }
}

/// The app icon in SwiftUI (the helix on the rose squircle), used in onboarding.
/// Proportions and colors follow `iconSVG` in `Remote/src/helix.js`.
struct AppMark: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.52), Color(red: 0.85, green: 0.08, blue: 0.29)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { LosslessMark().foregroundStyle(.white).frame(width: size * 0.8, height: size * 0.49) }
            .shadow(color: .pink.opacity(0.25), radius: size * 0.12, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

// MARK: - Main window

private struct MainView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingRemote = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $app.category) {
                ForEach([LibraryCategory.search, .home, .new]) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
                Section("Library") {
                    ForEach(LibraryCategory.library) { category in
                        Label(category.title, systemImage: category.symbol).tag(category)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            // A VStack instead of a safe-area inset: pushed album pages would otherwise cover the bar.
            VStack(spacing: 0) {
                LibraryDetailView()
                PlayerBar(player: app.player, queue: app.queue)
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: searchPrompt)
        .searchFocused($searchFocused)
        .onChange(of: app.searchText) { _, text in app.searchTextChanged(text) }
        .onChange(of: app.searchFocusRequest) { searchFocused = true }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.showingLinkSheet = true } label: { Label("Open Song Link", systemImage: "link") }
                    .help("Open an Apple Music song link (⌘L)")
                Button { showingRemote.toggle() } label: { Label("Remote", systemImage: "iphone.radiowaves.left.and.right") }
                    .help("Connect a remote")
                    .popover(isPresented: $showingRemote, arrowEdge: .bottom) { RemotePopover(remote: app.remote) }
                Button { app.showingQueue.toggle() } label: { Label("Playing Next", systemImage: "list.bullet") }
                    .help("Playing Next (⌥⌘U)")
                    .popover(isPresented: $app.showingQueue, arrowEdge: .bottom) {
                        QueuePanel(queue: app.queue).frame(width: 360, height: 520)
                    }
            }
        }
        .sheet(isPresented: $app.showingLinkSheet) { OpenLinkView() }
        .onDrop(of: [.url, .plainText], isTargeted: nil, perform: dropLink)
        #if SNAPSHOT
        .modifier(SnapshotOpener())
        #endif
    }

    private var searchPrompt: String {
        if app.category == .search { return "Search Apple Music" }
        if let collection = app.currentCollection { return "Search in “\(collection.title)”" }
        if app.category == .home || app.category == .new || !app.path.isEmpty { return "Search Apple Music" }
        return "Search \(app.category?.title ?? "Library")"
    }

    /// Dropping an Apple Music title link onto the window plays it.
    private func dropLink(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let link = url?.absoluteString, (try? TrackLink(link)) != nil else { return }
            Task { @MainActor in AppModel.shared.playLink(link) }
        }
        return true
    }
}

#if SNAPSHOT
private struct SnapshotOpener: ViewModifier {
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .init("AMOpenNowPlaying"))) { _ in AppModel.shared.openNowPlaying() }
    }
}
#endif
