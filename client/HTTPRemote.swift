import AppKit
import Combine
import Darwin
import Foundation
import Network

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    /// One request per connection. Ambiguous framing and chunked bodies are rejected.
    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw HTTPFailure(413, "Request too large.") }; return nil
        }
        guard boundary.lowerBound <= 16_384, let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw HTTPFailure(400, "Invalid request.") }
        let lines = head.components(separatedBy: "\r\n"); let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw HTTPFailure(400, "Invalid request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw HTTPFailure(400, "Invalid header.") }
            let name = line[..<colon].lowercased(); let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { throw HTTPFailure(400, "Duplicate header.") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPFailure(400, "Chunked requests are not supported.") }
        let length: Int
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), let size = Int(text), size <= 131_072 else { throw HTTPFailure(413, "Request too large.") }
            length = size
        } else { length = 0 }
        let end = boundary.upperBound + length
        guard data.count >= end else { return nil }
        guard data.count == end else { throw HTTPFailure(400, "Multiple requests are not allowed.") }
        return HTTPRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: Data(data[boundary.upperBound..<end]))
    }
}
struct HTTPFailure: Error { let status: Int; let message: String; init(_ status: Int, _ message: String) { self.status = status; self.message = message } }
struct HTTPResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body: Data
    var extra: [String: String] = [:]
    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    var wire: Data {
        let reason = [200:"OK",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",409:"Conflict",413:"Payload Too Large",429:"Too Many Requests",500:"Internal Server Error",503:"Service Unavailable"][status] ?? "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' https://*.mzstatic.com; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n"
        for (key, value) in extra { header += "\(key): \(value)\r\n" }
        var data = Data((header + "\r\n").utf8); data.append(body); return data
    }
}

@MainActor
private final class HTTPPeer {
    let id = UUID()
    let connection: NWConnection
    var bytes = Data()
    var timeout: Task<Void, Never>?
    var work: Task<Void, Never>?
    var finished = false
    let handler: (HTTPRequest) async -> HTTPResponse
    let closed: (UUID) -> Void
    init(_ connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse, closed: @escaping (UUID) -> Void) {
        self.connection = connection; self.handler = handler; self.closed = closed
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in if case .failed = state { self?.close() }; if case .cancelled = state { self?.close() } }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        timeout = Task { [weak self] in try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { self?.close() } }
        receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if let data { self.bytes.append(data) }
                do {
                    guard self.bytes.count <= 147_456 else { throw HTTPFailure(413, "Request too large.") }
                    if let request = try HTTPRequest.parse(self.bytes) {
                        self.timeout?.cancel()
                        self.timeout = Task { [weak self] in try? await Task.sleep(nanoseconds: 95_000_000_000); if !Task.isCancelled { self?.close() } }
                        self.work = Task { [weak self] in
                            guard let self else { return }; let response = await self.handler(request)
                            guard !self.finished else { return }; self.reply(response)
                        }
                    } else if complete || error != nil { self.close() } else { self.receive() }
                } catch { let failure = error as? HTTPFailure; self.reply(.json(["error": failure?.message ?? "Invalid request."], status: failure?.status ?? 400)) }
            }
        }
    }
    func reply(_ response: HTTPResponse) {
        connection.send(content: response.wire, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close() } })
    }
    func close() {
        guard !finished else { return }; finished = true; timeout?.cancel(); work?.cancel(); connection.cancel(); closed(id)
    }
}

@MainActor
final class HTTPRemote: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var addresses: [String] = []
    /// Devices that polled the remote during the last 30 seconds.
    @Published private(set) var connectedDevices = 0
    let port: UInt16 = 8765
    private let queue: PlaybackQueue
    private var listener: NWListener?
    private var peers: [UUID: HTTPPeer] = [:]
    private var lastSeen: [String: Date] = [:]
    private var requests: [String: (Date, Int)] = [:]
    private var pages: [String: (Date, LibraryPage)] = [:]
    private var editorialCache: [String: (Date, [HomeSection])] = [:]
    private var pendingPages: [String: Task<LibraryPage, Error>] = [:]
    private var epoch = UUID()
    init(queue: PlaybackQueue) { self.queue = queue }
    func start() {
        guard listener == nil else { return }; failure = nil; refreshAddresses()
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener; let generation = epoch
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                switch state {
                case .ready: self.running = true
                case .failed: self.stop(); self.failure = "The remote could not open port \(self.port)."
                default: break
                }
            }}
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                guard let self, self.epoch == generation, self.peers.count < 32, Self.localPeer(connection.endpoint) else { connection.cancel(); return }
                let peerKey = Self.peerKey(connection.endpoint)
                let peer = HTTPPeer(connection, handler: { [weak self] request in
                    guard let self else { return .json(["error":"Remote stopped."], status: 503) }
                    return await self.respond(request, peer: peerKey)
                }, closed: { [weak self] id in self?.peers.removeValue(forKey: id) })
                self.peers[peer.id] = peer; peer.start()
            }}
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        } catch { failure = "Port \(port) is in use or not available."; listener = nil }
    }
    func stop() {
        epoch = UUID(); listener?.cancel(); listener = nil; running = false
        for peer in Array(peers.values) { peer.close() }; peers = [:]; lastSeen = [:]; connectedDevices = 0; requests = [:]
        for task in pendingPages.values { task.cancel() }; pendingPages = [:]; pages = [:]
    }
    /// The LAN address a phone should open; loopback only when no network is available.
    var primaryAddress: String? { addresses.first }
    func refreshAddresses() {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        var ips: [String] = []
        if getifaddrs(&pointer) == 0 {
            defer { freeifaddrs(pointer) }; var cursor = pointer
            while let item = cursor {
                defer { cursor = item.pointee.ifa_next }
                guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), (item.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host); if Self.privateIP(ip), ip != "127.0.0.1" { ips.append(ip) }
                }
            }
        }
        addresses = Array(Set(ips)).sorted().map { "http://\($0):\(port)" } + ["http://127.0.0.1:\(port)"]
    }
    private static func privateIP(_ input: String) -> Bool {
        let ip = input.lowercased().replacingOccurrences(of: "::ffff:", with: "")
        if ip == "::1" || ip.hasPrefix("fc") || ip.hasPrefix("fd") || ip.hasPrefix("fe80:") { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
    private static func peerKey(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }; return "unknown"
    }
    private static func localPeer(_ endpoint: NWEndpoint) -> Bool { privateIP(peerKey(endpoint)) }
    private func limit(_ key: String, table: inout [String: (Date, Int)], count: Int) -> Bool {
        let now = Date(); table = table.filter { now.timeIntervalSince($0.value.0) < 60 }
        let previous = table[key] ?? (now, 0); table[key] = (previous.0, previous.1 + 1); return previous.1 < count
    }
    private func seen(_ peer: String) {
        let now = Date(); lastSeen[peer] = now
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < 30 }
        if connectedDevices != lastSeen.count { connectedDevices = lastSeen.count }
    }
    private func respond(_ request: HTTPRequest, peer: String) async -> HTTPResponse {
        do {
            refreshAddresses()
            let hosts = Set(addresses.compactMap { URLComponents(string: $0).map { "\($0.host!):\(port)" } } + ["localhost:\(port)"])
            guard let host = request.headers["host"], hosts.contains(host) else { throw HTTPFailure(403, "Unknown remote address.") }
            if let origin = request.headers["origin"], origin != "http://\(host)" { throw HTTPFailure(403, "Access from another website is not allowed.") }
            if let site = request.headers["sec-fetch-site"], site == "cross-site" { throw HTTPFailure(403, "Access from another website is not allowed.") }
            guard limit(peer, table: &requests, count: 240) else { throw HTTPFailure(429, "Please wait a moment.") }
            guard let components = URLComponents(string: request.target), let path = components.path.removingPercentEncoding else { throw HTTPFailure(400, "Invalid path.") }
            if request.method == "POST" {
                guard request.headers["content-type"]?.split(separator: ";").first == "application/json", request.headers["x-am-remote"] == "1" else { throw HTTPFailure(403, "Invalid remote request.") }
                guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw HTTPFailure(400, "Invalid input.") }
                guard path == "/api/command" else { throw HTTPFailure(404, "Not found.") }
                try command(object); return .json(snapshot())
            }
            // No pairing: every device in the local network may control playback.
            // Requests from public addresses are refused when the connection opens.
            if path.hasPrefix("/api/") {
                if path.hasPrefix("/api/airplay-artwork/"), let url = queue.player.airPlay?.artwork,
                   path == "/api/airplay-artwork/" + url.lastPathComponent,
                   let data = ArtworkCache.shared.airPlayArtworkData(url) {
                    return HTTPResponse(contentType: data.starts(with: [137, 80, 78, 71]) ? "image/png" : "image/jpeg", body: data)
                }
                if path == "/api/state" { seen(peer); return .json(snapshot()) }
                if path == "/api/library" {
                    guard queue.authenticated, queue.wrapper.ready else { throw HTTPFailure(409, "Please sign in in the Mac app first.") }
                    let query = components.queryItems ?? []; let address = query.first { $0.name == "path" }?.value ?? "/v1/me/library/songs"
                    _ = try LibraryService.url(for: address)
                    let page = try await libraryPage(address)
                    return .json(["items":page.data.map(Self.libraryJSON), "next":page.next as Any? ?? NSNull()])
                }
                if let response = try await catalog(path, query: components.queryItems ?? []) { return response }
                throw HTTPFailure(404, "Not found.")
            }
            return try asset(path)
        } catch {
            let failure = error as? HTTPFailure
            return .json(["error":failure?.message ?? error.localizedDescription], status: failure?.status ?? 400)
        }
    }
    /// Catalog browsing for the remote: search, artist pages and the links from
    /// titles and albums to their album and artists. Same services as the Mac app.
    private func catalog(_ path: String, query: [URLQueryItem]) async throws -> HTTPResponse? {
        let catalogPaths = ["/api/search", "/api/artist", "/api/song-links", "/api/album-artists", "/api/catalog-album",
                            "/api/home", "/api/new", "/api/categories", "/api/category"]
        guard catalogPaths.contains(path) else { return nil }
        guard queue.authenticated, queue.wrapper.ready else { throw HTTPFailure(409, "Please sign in in the Mac app first.") }
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func id(_ name: String = "id") throws -> String {
            guard let id = value(name), CatalogService.validID(id) else { throw HTTPFailure(400, "Invalid ID.") }
            return id
        }
        let service = queue.wrapper.service, catalog = CatalogService.shared
        func sectionsJSON(_ sections: [HomeSection]) -> [[String: Any]] {
            sections.map { section in
                let style: String = switch section.style {
                case .songs: "songs"; case .artists: "artists"; case .hero: "hero"; case .featured: "featured"; case .covers: "covers"
                }
                return ["id": section.id, "title": section.title ?? "", "style": style, "items": section.entries.map { entry in
                    var json = Self.libraryJSON(entry.item)
                    json["badge"] = entry.badge as Any? ?? NSNull()
                    json["summary"] = entry.item.summary as Any? ?? NSNull()
                    json["color"] = entry.item.artworkColor as Any? ?? NSNull()
                    json["wideArtwork"] = entry.item.wideArtwork(width: 900)?.absoluteString as Any? ?? NSNull()
                    return json
                }]
            }
        }
        /// Editorial pages change slowly; keep them a few minutes for all remote devices.
        func editorial(_ key: String, _ load: (LibraryService, WrapperAccount) async throws -> [HomeSection]) async throws -> HTTPResponse {
            if let cached = editorialCache[key], Date().timeIntervalSince(cached.0) < 600 { return .json(["sections": sectionsJSON(cached.1)]) }
            let account = try await service.account()
            let sections = try await load(LibraryService(wrapper: service), account)
            editorialCache[key] = (Date(), sections)
            return .json(["sections": sectionsJSON(sections)])
        }
        func artistsJSON(_ artists: [ArtistRef]) -> [[String: String]] { artists.map { ["id": $0.id, "name": $0.name] } }
        switch path {
        case "/api/home":
            return try await editorial("home") { api, account in try await Editorial.home(api: api, account: account) }
        case "/api/new":
            return try await editorial("new") { api, account in try await Editorial.new(api: api, account: account) }
        case "/api/categories":
            let categories = try await Editorial.categories()
            return .json(["categories": categories.map { category in
                ["id": category.id, "kind": category.kind.rawValue, "title": category.title, "color": category.color as Any? ?? NSNull(),
                 "artwork": category.artwork(width: 640, height: 360)?.absoluteString as Any? ?? NSNull()]
            }])
        case "/api/category":
            guard let kind = value("kind").flatMap(BrowseCategory.Kind.init(rawValue:)) else { throw HTTPFailure(400, "Invalid category.") }
            let categoryID = kind == .charts ? "charts" : try id()
            let category = BrowseCategory(id: categoryID, kind: kind, title: String((value("title") ?? "").prefix(200)), artworkTemplate: nil, color: nil)
            return try await editorial("category-\(kind.rawValue)-\(categoryID)") { api, account in try await Editorial.category(category, api: api, account: account) }
        case "/api/search":
            guard let term = value("term")?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty, term.count <= 200 else {
                return .json(["sections": []])
            }
            return .json(["term": term, "sections": sectionsJSON(try await catalog.search(term, service: service))])
        case "/api/artist":
            let page = try await catalog.artistPage(id: try id(), service: service)
            return .json(["name": page.name, "bio": page.bio as Any? ?? NSNull(),
                          "artwork": ArtistView.fill(page.artworkTemplate, width: 600, height: 600)?.absoluteString as Any? ?? NSNull(),
                          "banner": ArtistView.fill(page.bannerTemplate, width: 1600, height: 640)?.absoluteString as Any? ?? NSNull(),
                          "sections": sectionsJSON(page.sections)])
        case "/api/song-links":
            let links = try await catalog.links(song: try id(), service: service)
            return .json(["album": links.album.map(Self.libraryJSON) as Any? ?? NSNull(), "artists": artistsJSON(links.artists)])
        case "/api/album-artists":
            let type = value("type") == "library-albums" ? "library-albums" : "albums"
            let json = #"{"id":"\#(try id())","type":"\#(type)"}"#
            let album = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
            return .json(["artists": artistsJSON(try await catalog.artists(album: album, service: service))])
        default:
            let album = try await catalog.catalogAlbum(library: try id(), service: service)
            return .json(["album": album.map(Self.libraryJSON) as Any? ?? NSNull()])
        }
    }
    private func libraryPage(_ address: String) async throws -> LibraryPage {
        if let cached = pages[address], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        if let pending = pendingPages[address] { return try await pending.value }
        let service = queue.wrapper.service
        let task = Task { try await LibraryService(wrapper: service).page(address, account: service.account()) }
        pendingPages[address] = task; defer { pendingPages.removeValue(forKey: address) }
        let page = try await task.value
        if pages.count >= 100 { pages = [:] }; pages[address] = (Date(), page); return page
    }
    private static func entryJSON(_ entry: QueueEntry) -> [String: Any] {
        ["id":entry.id.uuidString,"catalogID":entry.catalogID,"title":entry.title,"artist":entry.artist,"artwork":entry.artwork?.absoluteString as Any? ?? NSNull()]
    }
    private static func libraryJSON(_ entry: LibraryItem) -> [String: Any] {
        ["id":entry.id,"type":entry.type,"catalogID":entry.catalogID as Any? ?? NSNull(),"title":entry.title,"artist":entry.artist,"album":entry.album,"artwork":entry.artwork?.absoluteString as Any? ?? NSNull(),"artworkLarge":entry.artwork(600)?.absoluteString as Any? ?? NSNull(),"trackCount":entry.trackCount as Any? ?? NSNull(),"duration":entry.duration as Any? ?? NSNull(),"trackPath":entry.trackPath as Any? ?? NSNull(),"playable":entry.playable]
    }
    private func snapshot() -> [String: Any] {
        let player = queue.player; var current = queue.state.current.map(Self.entryJSON)
        if let stream = player.stream { current?["title"] = stream.title; current?["artist"] = stream.artist; current?["artwork"] = stream.artwork?.absoluteString as Any? ?? NSNull() }
        if let track = player.airPlay {
            current = ["id":"airplay", "catalogID":NSNull(), "title":track.title, "artist":track.artist,
                       "artwork":track.artwork.map { "/api/airplay-artwork/" + $0.lastPathComponent } as Any? ?? NSNull()]
        }
        return ["source":player.airPlay == nil ? "appleMusic" : "airPlay", "quality":player.airPlay?.quality as Any? ?? NSNull(),
                "canSeek":player.canSeek, "canControl":player.airPlay != nil || queue.wrapper.ready && queue.authenticated,
                "current":current as Any? ?? NSNull(),"queue":queue.state.upcoming.map(Self.entryJSON),"revision":queue.state.revision,
                "playing":player.playing,"loading":player.loading,"position":player.position,"duration":player.duration,"volume":player.volume,
                "rate":player.airPlay?.format?.rate ?? player.stream?.rate ?? 0,"depth":player.airPlay?.format?.depth ?? player.stream?.depth ?? 0,"outputRate":player.outputRate,"ready":queue.wrapper.ready && queue.authenticated,
                "error":(queue.failure ?? player.failure) as Any? ?? NSNull()]
    }
    private func command(_ object: [String: Any]) throws {
        let action = object["action"] as? String ?? ""
        let airPlayControl = queue.player.airPlay != nil && ["toggle", "pause", "volume"].contains(action)
        guard airPlayControl || (queue.authenticated && queue.wrapper.ready) else { throw HTTPFailure(409, "Please sign in in the Mac app first.") }
        if queue.player.airPlay != nil, ["next", "previous", "seek", "play"].contains(action) {
            throw HTTPFailure(409, "Control AirPlay playback on the sending device.")
        }
        func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw HTTPFailure(400, "Invalid value.") }; return value.doubleValue
        }
        func identifier() throws -> UUID { guard let text = object["id"] as? String, let id = UUID(uuidString: text) else { throw HTTPFailure(400, "Invalid queue entry.") }; return id }
        switch object["action"] as? String {
        case "toggle": queue.toggle()
        case "play": queue.resume()
        case "pause": queue.player.pause()
        case "next": queue.advance()
        case "previous": queue.previous()
        case "seek": queue.player.seek(try number("position", range: 0...max(0, queue.player.duration)))
        case "volume": queue.player.volume = Float(try number("volume", range: 0...1))
        case "playURL", "enqueueURL":
            guard let link = object["url"] as? String, link.count < 4096 else { throw HTTPFailure(400, "Please enter an Apple Music song link.") }
            let entry = try QueueEntry(link: link)
            if object["action"] as? String == "playURL" { try queue.play(entry) } else { try queue.enqueue([entry], first: object["first"] as? Bool == true) }
        case "playItem", "enqueueItem":
            let entry = try Self.remoteEntry(object)
            if object["action"] as? String == "playItem" { try queue.play(entry) } else { try queue.enqueue([entry], first: object["first"] as? Bool == true) }
        case "playItems", "enqueueItems":
            // Album and playlist playback from the remote; same validation as single titles.
            guard let list = object["items"] as? [[String: Any]], !list.isEmpty, list.count <= 1000 else { throw HTTPFailure(400, "Invalid song list.") }
            var entries = try list.map(Self.remoteEntry)
            if object["shuffle"] as? Bool == true { entries.shuffle() }
            if object["action"] as? String == "playItems" { try queue.playAll(entries) } else { try queue.enqueue(entries, first: object["first"] as? Bool == true) }
        case "playQueued": try queue.playQueued(identifier())
        case "remove": queue.remove(try identifier())
        case "clear": queue.clear()
        case "move":
            let id = try identifier(); let index = try number("index", range: 0...999); let revision = try number("revision", range: 0...Double(Int32.max))
            guard index.rounded() == index, revision.rounded() == revision else { throw HTTPFailure(400, "Invalid order.") }
            guard Int(revision) == queue.state.revision else { throw HTTPFailure(409, "The queue has changed in the meantime. Please try again.") }
            try queue.move(id, to: Int(index), revision: Int(revision))
        default: throw HTTPFailure(400, "Unknown command.")
        }
    }
    private static func remoteEntry(_ object: [String: Any]) throws -> QueueEntry {
        guard let catalogID = object["catalogID"] as? String else { throw HTTPFailure(400, "Invalid song.") }
        var entry = try QueueEntry(link: "https://music.apple.com/song/\(catalogID)")
        entry.title = String((object["title"] as? String ?? entry.title).prefix(500)); entry.artist = String((object["artist"] as? String ?? "").prefix(500))
        if let art = object["artwork"] as? String, let url = URL(string: art), url.scheme == "https", url.host?.hasSuffix(".mzstatic.com") == true { entry.artwork = url }
        return entry
    }
    private func asset(_ path: String) throws -> HTTPResponse {
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        guard !relative.isEmpty, !relative.contains(".."), !relative.contains("\\"), !relative.contains("\0"), relative.count < 200,
              let root = Bundle.main.resourceURL?.appendingPathComponent("Remote"),
              let data = try? Data(contentsOf: root.appendingPathComponent(relative)), data.count < 2_000_000 else { throw HTTPFailure(404, "Not found.") }
        let type = ["html":"text/html; charset=utf-8","js":"text/javascript; charset=utf-8","css":"text/css; charset=utf-8","woff2":"font/woff2","woff":"font/woff","svg":"image/svg+xml","ico":"image/x-icon","png":"image/png","webmanifest":"application/manifest+json"][URL(fileURLWithPath: relative).pathExtension]
        guard let type else { throw HTTPFailure(404, "Not found.") }
        return HTTPResponse(contentType: type, body: data)
    }
}
