import Foundation

struct TrackLink: Sendable {
    let id: String
    init(_ text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "music.apple.com" else {
            throw ClientError.message("Please paste an Apple Music song URL.")
        }
        let paths = url.pathComponents
        let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value
        let candidate = queryID ?? (paths.contains("song") ? paths.last : nil)
        guard let candidate, !candidate.isEmpty, candidate.allSatisfy(\.isNumber), UInt64(candidate) != nil else {
            throw ClientError.message("The URL must point to a single song. For an album, copy the song's link.")
        }
        id = candidate
    }
}

struct WrapperAccount: Sendable {
    let state: String
    let ready: Bool
    let developerToken: String
    let musicToken: String
    var authenticated: Bool { state == "authenticated" }
}

/// The HTTP API of the user's wrapper-v2 (account, sign-in, playback info).
/// Sample decryption goes through `DecryptChannel` on the wrapper's TCP port.
struct WrapperService: Sendable {
    let endpoint: WrapperEndpoint

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = endpoint.httpBase.flatMap({ URLComponents(url: $0.appendingPathComponent(path), resolvingAgainstBaseURL: false) }) else {
            throw ClientError.message("The wrapper address is invalid.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.message("The wrapper address is invalid.") }
        return url
    }
    func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 90) async throws -> (Data, Int) {
        var request = URLRequest(url: try url(path, query: query)); request.timeoutInterval = timeout
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    func account() async throws -> WrapperAccount {
        let (data, status) = try await request("me", timeout: 8)
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.message("The wrapper at \(endpoint.label) does not respond as expected.") }
        let auth = object["auth"] as? [String: Any] ?? [:]; let runtime = object["runtime"] as? [String: Any] ?? [:]
        return WrapperAccount(state: auth["state"] as? String ?? "logged_out", ready: runtime["playback_ready"] as? Bool ?? false,
                              developerToken: auth["dev_token"] as? String ?? "", musicToken: auth["music_user_token"] as? String ?? "")
    }
    func login(email: String, password: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["username": email, "password": password])
        let (_, status) = try await request("login", body: body)
        if status == 202 { return false }
        guard status == 200 else { throw ClientError.message(status == 401 ? "Apple rejected the sign-in. Please check your Apple Account and password." : "Sign-in could not be completed. Please try again.") }
        return true
    }
    func twoFactor(_ code: String) async throws {
        let (_, status) = try await request("login/2fa", body: JSONSerialization.data(withJSONObject: ["code": code]))
        guard status == 200 else { throw ClientError.message("The verification code was not accepted.") }
    }
    func playback(_ id: String) async throws -> [String: Any] {
        let (data, status) = try await request("playback", query: [URLQueryItem(name: "adam_id", value: id)])
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = object["songList"] as? [[String: Any]], let song = songs.first else {
            throw ClientError.message("Apple could not release this song for playback.")
        }
        return song
    }
    func decrypt(trackID: String, keyURI: String, samples: [Data]) async throws -> [Data] {
        try await DecryptChannel.shared.decrypt(host: endpoint.host, port: endpoint.decryptPort, trackID: trackID, keyURI: keyURI, samples: samples)
    }
}

struct MediaRange: Sendable { let offset: Int; let length: Int }
struct MediaSegment: Sendable { let url: URL; let range: MediaRange?; let duration: Double; let keyURI: String }
struct TrackStream: Sendable {
    let id: String
    var title: String = "Apple Music"
    var artist: String = ""
    var artwork: URL?
    let initialization: URL
    let initializationRange: MediaRange?
    let segments: [MediaSegment]
    let keyURI: String
    let rate: Int
    let depth: Int
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

enum MusicService {
    static func attributes(_ line: String) -> [String: String] {
        let text = String(line.split(separator: ":", maxSplits: 1).last ?? "")
        let pattern = #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString; var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: value)
        }
        return result
    }
    static func data(_ url: URL, range: MediaRange? = nil) async throws -> Data {
        guard url.scheme == "https", let host = url.host,
              host.hasSuffix(".apple.com") || host.hasSuffix(".mzstatic.com") else { throw ClientError.message("Apple returned an unknown stream address.") }
        var request = URLRequest(url: url); request.timeoutInterval = 45
        if let range { request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else { throw ClientError.message("The audio segment could not be loaded (\(status)).") }
        if let range {
            if status == 200 {
                guard range.offset + range.length <= bytes.count else { throw ClientError.message("Incomplete audio segment.") }
                return bytes.subdata(in: range.offset..<(range.offset + range.length))
            }
            guard bytes.count == range.length else { throw ClientError.message("Incomplete audio segment.") }
        }
        return bytes
    }
    static func prepare(_ id: String, wrapper: WrapperService) async throws -> TrackStream {
        let playback = try await wrapper.playback(id)
        guard let address = playback["hls-playlist-url"] as? String, let masterURL = URL(string: address) else { throw ClientError.message("Apple did not return a lossless stream.") }
        let master = String(decoding: try await data(masterURL), as: UTF8.self).components(separatedBy: .newlines)
        var options: [(URL, Int, Int)] = []
        for (index, line) in master.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let a = attributes(line)
            guard a["CODECS"] == "alac", let group = a["AUDIO"], index + 1 < master.count else { continue }
            let parts = group.split(separator: "-"); guard parts.count >= 2, let rate = Int(parts[parts.count - 2]), let depth = Int(parts.last!), let url = URL(string: master[index + 1].trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: masterURL)?.absoluteURL else { continue }
            options.append((url, rate, depth))
        }
        guard let best = options.max(by: { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }) else { throw ClientError.message("No lossless stream is available for this song.") }
        let lines = String(decoding: try await data(best.0), as: UTF8.self).components(separatedBy: .newlines)
        var initialization: URL?; var initRange: MediaRange?; var key = ""
        var segments: [MediaSegment] = []; var duration = 0.0; var pendingRange: String?
        var ends: [URL: Int] = [:]
        func parseRange(_ value: String, fallback: Int) throws -> MediaRange {
            let parts = value.split(separator: "@"); guard let first = parts.first, let length = Int(first), length > 0, length < 128_000_000 else { throw ClientError.message("Invalid audio segment.") }
            let offset = parts.count == 2 ? Int(parts[1]) : fallback
            guard let offset, offset >= 0, offset <= Int.max - length else { throw ClientError.message("Invalid audio segment.") }; return MediaRange(offset: offset, length: length)
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line)
                if let uri = a["URI"] { initialization = URL(string: uri, relativeTo: best.0)?.absoluteURL }
                if let r = a["BYTERANGE"] { initRange = try parseRange(r, fallback: 0) }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(line)
                if a["KEYFORMAT"] == "com.apple.streamingkeydelivery", let uri = a["URI"], !uri.contains("P000000000") { key = uri }
            } else if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0 }
            else if line.hasPrefix("#EXT-X-BYTERANGE:") { pendingRange = String(line.dropFirst(17)) }
            else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: best.0)?.absoluteURL {
                let r = try pendingRange.map { try parseRange($0, fallback: ends[url] ?? 0) }
                if let r { ends[url] = r.offset + r.length }
                guard duration > 0 else { throw ClientError.message("Invalid song duration.") }
                segments.append(MediaSegment(url: url, range: r, duration: duration, keyURI: key)); pendingRange = nil
            }
        }
        guard let initialization, !segments.isEmpty, key.hasPrefix("skd://") else { throw ClientError.message("The lossless stream is incomplete.") }
        return TrackStream(id: id, initialization: initialization, initializationRange: initRange, segments: segments, keyURI: key, rate: best.1, depth: best.2)
    }
    static func metadata(_ id: String, account: WrapperAccount) async throws -> (String, String, URL?) {
        func json(_ url: String) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 8
            request.setValue("Bearer " + account.developerToken, forHTTPHeaderField: "Authorization")
            request.setValue(account.musicToken, forHTTPHeaderField: "Music-User-Token")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.message("Song data is missing.") }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        let storefront = try await json("https://api.music.apple.com/v1/me/storefront")
        let country = (storefront["data"] as? [[String: Any]])?.first?["id"] as? String ?? Storefront.current
        let song = try await json("https://api.music.apple.com/v1/catalog/\(country)/songs/\(id)")
        let attributes = (song["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any] ?? [:]
        let art = (attributes["artwork"] as? [String: Any])?["url"] as? String
        let url = art.flatMap { URL(string: $0.replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600")) }
        return (attributes["name"] as? String ?? "Apple Music", attributes["artistName"] as? String ?? "", url)
    }
}
