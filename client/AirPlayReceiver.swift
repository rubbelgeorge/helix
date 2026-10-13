import Combine
import Darwin
import Foundation

/// Owns only the bundled receiver process. Audio output stays in AudioPlayer,
/// so volume, output-device changes and source ownership use the app's engine.
@MainActor
final class AirPlayReceiver: ObservableObject {
    /// The physical CPU, even when a universal app runs its Intel slice under
    /// Rosetta; the bundled helper is a native binary per architecture.
    static var hostArchitecture: String {
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1 ? "arm64" : "x86_64"
    }
    static let enabledKey = "airPlayReceiverEnabled"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    let name = "Helix – " + (Host.current().localizedName ?? "Mac")
    private let player: AudioPlayer
    private let queue: PlaybackQueue
    private let helperURL: URL?
    private var process: Process?
    private var retiring: Process?
    private var restartTask: Task<Void, Never>?
    private var reader: AirPlayFIFOReader?
    private var audioTask: Task<Void, Never>?
    private var session = UUID()
    private var folder: URL?
    private var stopping = false
    private var pendingMetadata: [String: String]?
    private var pendingProgress: String?

    init(player: AudioPlayer, queue: PlaybackQueue, helperURL: URL? = nil, enabled: Bool? = nil) {
        self.player = player; self.queue = queue; self.helperURL = helperURL
        if let enabled { self.enabled = enabled }
        queue.beforeAppleMusicPlayback = { [weak self] in self?.disconnect() }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if value { start() } else { stop() }
    }
    func start() {
        guard enabled, process == nil, restartTask == nil else { return }
        if let retiring, retiring.isRunning {
            let token = session
            restartTask = Task { [weak self] in
                await Task.detached { retiring.waitUntilExit() }.value
                guard !Task.isCancelled, let self, self.session == token else { return }
                self.retiring = nil; self.restartTask = nil
                self.start()
            }
            return
        }
        retiring = nil
        failure = nil
        guard let resources = Bundle.main.resourceURL else { fail("The AirPlay helper is missing."); return }
        let executable = helperURL ?? resources.appendingPathComponent("AirPlay/\(Self.hostArchitecture)/shairport-sync")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("The AirPlay receiver is missing from the app bundle. Please use the fully packaged app."); return
        }
        let token = UUID(); session = token
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-airplay-\(token.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            folder = directory
            let fifo = directory.appendingPathComponent("metadata")
            guard mkfifo(fifo.path, 0o600) == 0 else { throw ClientError.message("Could not prepare AirPlay metadata.") }
            reader = try AirPlayFIFOReader(url: fifo) { [weak self] events in
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    for event in events { self.receive(event) }
                }
            }
            let configuration = directory.appendingPathComponent("receiver.conf")
            let text = """
            general = {
                name = "\(Self.quote(String(name.prefix(50))))";
                port = 5099;
                output_backend = "stdout";
                mdns_backend = "dns-sd";
                interpolation = "basic";
                output_format = "S16_LE";
                output_rate = 44100;
                output_channels = 2;
            };
            stdout = { output_format = "S16_LE"; output_rate = 44100; output_channels = 2; };
            metadata = { enabled = "yes"; include_cover_art = "yes"; pipe_name = "\(Self.quote(fifo.path))"; };
            sessioncontrol = { session_timeout = 60; };
            """
            try text.write(to: configuration, atomically: true, encoding: .utf8)
            let child = Process(), audio = Pipe(), errors = Pipe()
            child.executableURL = executable; child.arguments = ["-c", configuration.path, "-p", "5099"]
            child.standardOutput = audio; child.standardError = errors
            // Drain errors without exposing sender metadata or unbounded logs.
            errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            child.terminationHandler = { [weak self] child in
                errors.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    self.process = nil; self.cleanup()
                    self.player.endAirPlay()
                    if !self.stopping { self.fail("AirPlay receiver stopped (\(child.terminationStatus)). Check network access and whether port 5099 is free.") }
                }
            }
            process = child
            try child.run()
            running = true
            audioTask = Task.detached(priority: .userInitiated) { [weak self] in
                let handle = audio.fileHandleForReading
                defer { try? handle.close() }
                var remainder = Data()
                do {
                    while !Task.isCancelled, let data = try handle.read(upToCount: 8192), !data.isEmpty {
                        remainder.append(data)
                        let count = remainder.count / 4 * 4
                        guard count > 0 else { continue }
                        let pcm = Data(remainder.prefix(count)); remainder.removeFirst(count)
                        while !Task.isCancelled {
                            guard let self else { return }
                            let consumed = await self.consume(pcm, session: token)
                            if consumed { break }
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                    }
                } catch {}
            }
        } catch {
            stop(); fail(error.localizedDescription)
        }
    }
    private static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
    private func consume(_ data: Data, session token: UUID) -> Bool {
        guard session == token, running else { return true }
        guard player.airPlay != nil else { return true }
        return player.enqueueAirPlayPCM(data)
    }
    private func takeOver() {
        guard player.airPlay == nil else { return }
        queue.interruptForAirPlay(); player.beginAirPlay()
    }
    func receive(_ event: AirPlayMetadataEvent) {
        if event.type == "ssnc" {
            switch event.code {
            case "conn", "pbeg": takeOver()
            case "pend": player.endAirPlay(); pendingMetadata = nil; pendingProgress = nil
            case "sdsc":
                takeOver()
                player.airPlay?.format = AirPlayFormat(event.text)
                if let pendingProgress { updateProgress(pendingProgress) }
            case "snam": takeOver(); player.airPlay?.sender = event.text
            case "mdst": pendingMetadata = [:]
            case "mden":
                if let values = pendingMetadata { applyMetadata(values) }; pendingMetadata = nil
            case "PICT":
                if let url = ArtworkCache.shared.receiveAirPlayArtwork(event.data) { player.airPlay?.artwork = url }
            case "prgr": pendingProgress = event.text; updateProgress(event.text)
            case "pfls", "paus": player.flushAirPlay()
            default: break
            }
        } else if event.type == "core", ["minm", "asar", "asal"].contains(event.code) {
            takeOver()
            if pendingMetadata != nil { pendingMetadata?[event.code] = event.text }
            else { applyMetadata([event.code: event.text]) }
        }
    }
    private func applyMetadata(_ values: [String: String]) {
        if let title = values["minm"] {
            if player.airPlay?.title != title { player.airPlay?.artwork = nil }
            player.airPlay?.title = title.isEmpty ? "AirPlay" : title
        }
        if let artist = values["asar"] { player.airPlay?.artist = artist }
        if let album = values["asal"] { player.airPlay?.album = album }
    }
    private func updateProgress(_ text: String) {
        guard let format = player.airPlay?.format, let progress = airPlayProgress(text, rate: format.rate) else { return }
        player.setAirPlayProgress(position: progress.position, duration: progress.duration)
    }
    /// A locally selected Apple Music title explicitly releases the sender.
    func disconnect() {
        guard player.airPlay != nil else { return }
        stop()
        if enabled { start() }
    }
    func stop() {
        stopping = true; session = UUID()
        restartTask?.cancel(); restartTask = nil
        audioTask?.cancel(); audioTask = nil
        if let child = process, child.isRunning {
            retiring = child
            child.terminate()
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
        }
        process = nil; cleanup(); player.endAirPlay(); stopping = false
    }
    private func cleanup() {
        running = false; reader?.stop(); reader = nil
        pendingMetadata = nil; pendingProgress = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    private func fail(_ message: String) { running = false; failure = message }
}

/// Nonblocking FIFO reads keep process shutdown cancellable, including idle receivers.
private final class AirPlayFIFOReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    init(url: URL, receive: @escaping @Sendable ([AirPlayMetadataEvent]) -> Void) throws {
        let fd = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ClientError.message("Could not open AirPlay metadata.") }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.helixplayer.helix.airplay.metadata"))
        var parser = AirPlayMetadataParser()
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 16384)
            var events: [AirPlayMetadataEvent] = []
            while true {
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { break }
                events += parser.feed(Data(bytes.prefix(count)))
            }
            if !events.isEmpty { receive(events) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    func stop() { source.cancel() }
    deinit { source.cancel() }
}
