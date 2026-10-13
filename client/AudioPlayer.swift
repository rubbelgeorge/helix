import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

struct DecodedChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

actor MediaPipeline {
    let stream: TrackStream
    let service: WrapperService
    private var codec: ALACMedia?
    private var cache: [Int: DecodedChunk] = [:]
    private var order: [Int] = []
    init(stream: TrackStream, service: WrapperService) { self.stream = stream; self.service = service }
    func chunk(_ index: Int) async throws -> DecodedChunk {
        if let existing = cache[index] { return existing }
        if codec == nil { codec = try ALACMedia(initialization: await MusicService.data(stream.initialization, range: stream.initializationRange)) }
        guard let codec, codec.sampleRate == stream.rate, codec.bitDepth == stream.depth else { throw ClientError.message("The audio format does not match the lossless stream.") }
        let segment = stream.segments[index]
        let fragment = try await MusicService.data(segment.url, range: segment.range)
        try Task.checkCancellation()
        let samples = try codec.samples(from: fragment)
        let service = self.service; let id = stream.id; let key = segment.keyURI.isEmpty ? stream.keyURI : segment.keyURI
        let plaintext = try await codec.decrypt(samples) { try await service.decrypt(trackID: id, keyURI: key, samples: $0) }
        try Task.checkCancellation()
        // Decoded in memory: decrypted audio is never written to disk.
        let buffer = try codec.pcm(plaintext)
        let result = DecodedChunk(buffer: buffer)
        cache[index] = result; order.append(index)
        while order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}

/// Match the output device's clock when it supports the source sample rate.
/// Restore the previous rate only if it is still the rate we set.
@MainActor
private final class OutputClock {
    private var change: (AudioObjectID, Float64, Float64)?
    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    /// Returns true when the device rate actually changed.
    @discardableResult
    func set(_ rate: Double) -> Bool {
        // Consecutive titles with the same rate keep the device as it is.
        if let change, change.2 == rate { return false }
        restore()
        guard AudioPlayer.matchesSampleRate else { return false }
        var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var ratesAddress = address(kAudioDevicePropertyAvailableNominalSampleRates); var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &ratesAddress, 0, nil, &bytes) == noErr else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(bytes) / MemoryLayout<AudioValueRange>.stride)
        guard !ranges.isEmpty, ranges.withUnsafeMutableBytes({ AudioObjectGetPropertyData(device, &ratesAddress, 0, nil, &bytes, $0.baseAddress!) }) == noErr,
              ranges.contains(where: { $0.mMinimum <= rate && rate <= $0.mMaximum }) else { return false }
        var a = address(kAudioDevicePropertyNominalSampleRate); var old: Float64 = 0; size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &old) == noErr, old != rate else { return false }
        var desired = rate
        guard AudioObjectSetPropertyData(device, &a, 0, nil, size, &desired) == noErr else { return false }
        change = (device, old, rate); return true
    }
    func restore() {
        guard let (device, old, set) = change else { return }; change = nil
        var a = address(kAudioDevicePropertyNominalSampleRate); var current: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &current) == noErr, current == set {
            var original = old; AudioObjectSetPropertyData(device, &a, 0, nil, size, &original)
        }
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var airPlay: AirPlayTrack?
    @Published var stream: TrackStream?
    @Published var playing = false
    @Published var loading = false
    @Published var position = 0.0
    @Published var buffered = 0.0
    @Published var outputRate = 0.0
    @Published var failure: String?
    @Published var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet { node.volume = volume; UserDefaults.standard.set(volume, forKey: "volume") }
    }
    var onEnded: (() -> Void)?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let clock = OutputClock()
    private var pipeline: MediaPipeline?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var anchor = 0.0
    private var queuedCount = 0
    /// The user's pause (not the short gaps while titles change); views react to this.
    @Published private(set) var paused = false
    private var pauseIntent = false { didSet { if paused != pauseIntent { paused = pauseIntent } } }
    private var connected = false
    private var connectedFormat: AVAudioFormat?
    private var rampGeneration = 0
    var duration: Double { airPlay?.duration ?? stream?.duration ?? 0 }
    var hasTrack: Bool { airPlay != nil || stream != nil }
    var canSeek: Bool { airPlay == nil && stream != nil }
    var displayTitle: String? { airPlay?.title ?? stream?.title }
    var displayArtist: String? { airPlay?.artist ?? stream?.artist }
    var displayArtwork: URL? { airPlay?.artwork ?? (airPlay == nil ? stream?.artwork : nil) }
    var onAirPlayDisconnect: (() -> Void)?
    private var airPlayFrames = 0
    /// Peak of received decoded audio, useful for receiver diagnostics.
    private(set) var airPlayPeak: Float = 0
    private var airPlayAnchorDate = Date()
    private var airPlayAnchorPosition = 0.0

    static let matchRateKey = "matchOutputSampleRate"
    static var matchesSampleRate: Bool { UserDefaults.standard.object(forKey: matchRateKey) as? Bool ?? true }
    private var matchRate = AudioPlayer.matchesSampleRate
    private var defaultsObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var configurationWaiter: CheckedContinuation<Void, Never>?

    init() {
        engine.attach(node)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The engine reports device changes (sample rate, output device). While a
        // title starts we wait for it; during playback the title resumes cleanly.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
        // Apply the sample-rate setting at once, not only from the next title.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sampleRateSettingChanged() }
        }
    }
    private func waitForConfigurationChange(timeout: Double) async {
        await withCheckedContinuation { continuation in
            configurationWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishConfigurationWait()
            }
        }
    }
    private func finishConfigurationWait() {
        configurationWaiter?.resume(); configurationWaiter = nil
    }
    private func configurationChanged() {
        if configurationWaiter != nil { finishConfigurationWait(); return }
        Self.log.notice("Audio device reconfigured, resuming playback")
        // AVAudioEngine stops itself after a configuration change; rebuild and continue.
        connectedFormat = nil
        if airPlay != nil { flushAirPlay() }
        else if stream != nil, !loading { begin(at: position) }
    }
    /// Switching off restores the device's own rate, so audio goes through the
    /// system mixer like any other app. The engine must be rebuilt after a device
    /// rate change, so playback resumes at the same position (paused stays paused).
    private func sampleRateSettingChanged() {
        let enabled = Self.matchesSampleRate
        guard enabled != matchRate else { return }   // ignore unrelated defaults such as volume
        matchRate = enabled
        guard let stream else { return }
        if enabled { clock.set(Double(stream.rate)) } else { clock.restore() }
        if !loading { seek(position) }
    }
    /// What the queue already knows about a title, shown until Apple's metadata arrives.
    struct Hint { var title: String; var artist: String; var artwork: URL? }
    private static let log = Logger(subsystem: "dev.helixplayer.helix", category: "playback")

    func load(link: String, service: WrapperService, hint: Hint? = nil) async {
        guard let id = try? TrackLink(link).id else { failure = "Please paste an Apple Music song URL."; return }
        self.service = service
        // Prepare the next title while the current one fades out.
        let reuse = takePrefetched(id), started = Date()
        let preparing = Task { () throws -> TrackStream in
            if let reuse { return reuse.stream }
            return try await MusicService.prepare(id, wrapper: service)
        }
        await fadeOut()
        guard !Task.isCancelled else { preparing.cancel(); return }
        stop(keepClock: true); failure = nil; loading = true
        let current = generation
        do {
            var track = try await withTaskCancellationHandler { try await preparing.value } onCancel: { preparing.cancel() }
            guard generation == current else { return }
            if reuse == nil, let hint {
                track.title = hint.title; track.artist = hint.artist; track.artwork = hint.artwork
            }
            stream = track; pipeline = reuse?.pipeline ?? MediaPipeline(stream: track, service: service)
            // A device rate change needs a moment before the engine starts.
            let rateChanged = clock.set(Double(track.rate))
            if rateChanged { await waitForConfigurationChange(timeout: 0.5) }
            guard generation == current else { return }
            begin(at: 0)
            Self.log.notice("Start \(id, privacy: .public): prefetched=\(reuse != nil), preparation \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(track.rate) Hz, device rate changed=\(rateChanged)")
            if reuse == nil {
                let metadataGeneration = generation
                Task { [weak self] in
                    guard let metadata = try? await MusicService.metadata(id, account: service.account()),
                          let self, self.generation == metadataGeneration else { return }
                    self.stream?.title = metadata.0; self.stream?.artist = metadata.1; self.stream?.artwork = metadata.2 ?? self.stream?.artwork
                }
            }
        } catch {
            guard generation == current else { return }
            failure = (error as? LocalizedError)?.errorDescription ?? "Playback could not be started."
            loading = false; clock.restore()
        }
    }

    /// Fades the mixer's output volume (the user's volume stays untouched) in
    /// ~4 ms steps along an S-curve, off the main thread so the steps stay even.
    /// Coarse steps sound like crackling themselves. A newer ramp cancels an older one.
    private func ramp(to target: Float, duration: Double) async {
        rampGeneration += 1
        let generation = rampGeneration, mixer = engine.mainMixerNode, start = mixer.outputVolume
        guard start != target else { return }
        let steps = max(2, Int(duration / 0.004))
        let isCurrent: @Sendable () async -> Bool = { [weak self] in await self?.rampGeneration == generation }
        await Task.detached(priority: .userInitiated) {
            for step in 1...steps {
                guard await isCurrent() else { return }
                let progress = Float(step) / Float(steps)
                mixer.outputVolume = start + (target - start) * progress * progress * (3 - 2 * progress)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }.value
    }
    private func fadeOut() async {
        guard playing, engine.isRunning else { return }
        await ramp(to: 0, duration: 0.12)
    }
    /// Starts the player node from silence with a short fade-in, so a start in
    /// the middle of a waveform (after seeking) does not click.
    private func startNode() {
        rampGeneration += 1
        engine.mainMixerNode.outputVolume = 0
        node.play(); playing = true
        Task { [weak self] in await self?.ramp(to: 1, duration: 0.06) }
    }

    // MARK: Prefetch

    private struct Prefetched { let id: String; let stream: TrackStream; let pipeline: MediaPipeline; let date: Date }
    /// Up to two prepared titles. Advancing the queue starts preparing the title
    /// after next at once; that must not discard the one about to start.
    private var prefetched: [String: Prefetched] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingID: String?

    /// Warms the next title: stream details, the first decoded audio segment,
    /// metadata, both artwork sizes and the animated cover's address. Starts
    /// three seconds after the current title so its first segment goes first.
    func prefetch(link: String, hint: Hint?, service: WrapperService) {
        guard let id = try? TrackLink(link).id, id != prefetchingID, id != stream?.id else { return }
        if let existing = prefetched[id], Date().timeIntervalSince(existing.date) < 1200 { return }
        prefetchTask?.cancel(); prefetchingID = id
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let item = try await self.prepare(id, hint: hint, service: service)
                try Task.checkCancellation()
                guard self.prefetchingID == id else { return }
                self.prefetched[id] = item
                // Keep the two newest; older ones belong to titles that were skipped.
                for old in self.prefetched.values.sorted(by: { $0.date > $1.date }).dropFirst(2) { self.prefetched[old.id] = nil }
                Self.log.notice("Prefetched \(id, privacy: .public): \(item.stream.title, privacy: .public)")
                if let artwork = item.stream.artwork {
                    _ = await ArtworkCache.shared.image(for: artwork)
                    if let large = NowPlayingArtwork.large(artwork) { _ = await ArtworkCache.shared.image(for: large) }
                }
                if let video = await AnimatedArtworkService.shared.video(forSong: id, service: service) {
                    _ = await AnimatedArtworkService.shared.localFile(for: video)
                }
            } catch {}
            if self.prefetchingID == id { self.prefetchingID = nil }
        }
    }
    /// Stream details, metadata and the first decoded segment of a title.
    private func prepare(_ id: String, hint: Hint?, service: WrapperService) async throws -> Prefetched {
        var track = try await MusicService.prepare(id, wrapper: service)
        if let metadata = try? await MusicService.metadata(id, account: service.account()) {
            track.title = metadata.0; track.artist = metadata.1; track.artwork = metadata.2 ?? hint?.artwork
        } else if let hint {
            track.title = hint.title; track.artist = hint.artist; track.artwork = hint.artwork
        }
        let pipeline = MediaPipeline(stream: track, service: service)
        _ = try await pipeline.chunk(0)
        return Prefetched(id: id, stream: track, pipeline: pipeline, date: Date())
    }
    private func takePrefetched(_ id: String) -> Prefetched? {
        guard let item = prefetched.removeValue(forKey: id), Date().timeIntervalSince(item.date) < 1200 else { return nil }
        return item
    }

    func toggle() { if playing || (loading && !pauseIntent) { pause() } else { resume() } }
    func pause() {
        if airPlay != nil { onAirPlayDisconnect?(); return }
        playing = false; pauseIntent = true
        Task { [weak self] in
            guard let self else { return }
            await self.ramp(to: 0, duration: 0.08)
            if self.pauseIntent { self.node.pause() }
        }
    }
    func resume() {
        guard airPlay == nil else { return }
        pauseIntent = false
        guard stream != nil else { return }
        if position >= duration, !loading { begin(at: 0) }
        else if queuedCount > 0, connected, engine.isRunning { startNode() }
        else if !loading { begin(at: position) }
    }
    /// Fades out briefly, then continues from the new position with a short fade-in.
    func seek(_ time: Double) {
        guard stream != nil else { return }
        let target = min(max(time, 0), max(0, duration - 0.01))
        position = target
        let token = UUID(); seekToken = token
        Task { [weak self] in
            guard let self else { return }
            if self.playing { await self.ramp(to: 0, duration: 0.08) }
            guard self.seekToken == token else { return }
            self.begin(at: target)
        }
    }
    private var seekToken = UUID()
    /// `keepClock` leaves the device rate for the next title instead of restoring it.
    func stop(keepClock: Bool = false) {
        generation = UUID(); seekToken = UUID(); task?.cancel(); task = nil
        if !keepClock { prefetchTask?.cancel(); prefetchTask = nil; prefetchingID = nil; prefetched.removeAll() }
        airPlay = nil; airPlayFrames = 0; airPlayPeak = 0
        node.stop(); engine.stop(); if !keepClock { clock.restore() }
        rampGeneration += 1; engine.mainMixerNode.outputVolume = 1
        playing = false; loading = false; position = 0; buffered = 0; queuedCount = 0; anchor = 0; pauseIntent = false
        chained = nil; trackStartFrame = 0; scheduledFrames = 0; lastRenderedFrame = 0
        pipeline = nil; stream = nil
    }
    // MARK: AirPlay

    func beginAirPlay() {
        stop(); failure = nil; airPlay = AirPlayTrack()
    }
    func endAirPlay() {
        guard airPlay != nil else { return }
        stop()
    }
    func setAirPlayProgress(position: Double, duration: Double) {
        guard airPlay != nil else { return }
        airPlay?.duration = duration; self.position = position
        airPlayAnchorPosition = position; airPlayAnchorDate = Date()
    }
    func flushAirPlay() {
        guard airPlay != nil else { return }
        generation = UUID(); node.stop(); airPlayFrames = 0; playing = false
        connectedFormat = nil
    }
    /// Fixed stdout contract from our bundled helper: S16_LE/44100/stereo.
    /// Backpressure bounds the scheduled PCM to half a second.
    func enqueueAirPlayPCM(_ data: Data) -> Bool {
        guard airPlay != nil else { return true }
        guard airPlayFrames < 22_050 else { return false }
        let frames = data.count / 4
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return true }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let offset = frame * 4 + channel * 2
                    let sample = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
                    let value = Float(sample) / 32768
                    channels[channel][frame] = value
                    airPlayPeak = max(airPlayPeak, abs(value))
                }
            }
        }
        do {
            if connectedFormat != format || !engine.isRunning {
                node.stop(); engine.stop(); engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                connected = true; connectedFormat = format
                node.volume = volume; engine.mainMixerNode.outputVolume = 1
                try engine.start()
                outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            }
            let token = generation
            airPlayFrames += frames
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.airPlayFrames = max(0, self.airPlayFrames - frames)
                }
            }
            if !node.isPlaying {
                node.play(); playing = true
                airPlayAnchorPosition = position; airPlayAnchorDate = Date()
            }
        } catch {
            failure = "Could not play AirPlay audio: \(error.localizedDescription)"
            onAirPlayDisconnect?()
        }
        return true
    }

    private func begin(at target: Double) {
        guard let stream, let pipeline else { return }
        generation = UUID(); let current = generation
        // The engine keeps running: pausing and restarting it replays stale
        // output for a few milliseconds, which was the audible crackle.
        task?.cancel(); node.stop(); chained = nil; queuedCount = 0; playing = false; loading = true; failure = nil
        position = target; anchor = target; buffered = target
        trackStartFrame = 0; scheduledFrames = 0; lastRenderedFrame = 0
        var segmentStart = 0.0; var first = 0
        for (index, segment) in stream.segments.enumerated() {
            if segmentStart + segment.duration > target { first = index; break }
            segmentStart += segment.duration
        }
        let skipSeconds = max(0, target - segmentStart)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await schedule(stream, pipeline, from: first, skipSeconds: skipSeconds, generation: current, chainedID: nil)
                // Gapless: while a title ends, the next one is already scheduled on
                // the same running player node; no stop, no fade between them.
                var last = stream
                while let next = await nextForGapless(after: last, generation: current) {
                    chained = Chain(id: next.id, stream: next.stream, pipeline: next.pipeline, startFrame: scheduledFrames)
                    Self.log.notice("Gapless prepared: \(next.id, privacy: .public)")
                    try await schedule(next.stream, next.pipeline, from: 0, skipSeconds: 0, generation: current, chainedID: next.id)
                    last = next.stream
                }
            } catch is CancellationError { }
            catch {
                guard generation == current else { return }
                failure = (error as? ClientError)?.errorDescription ?? "An audio segment could not be loaded. Please start again."
                loading = false; node.pause(); playing = false
            }
        }
    }

    /// Schedules a title's segments on the player node, at most 35 seconds ahead
    /// of what is audible. `chainedID` marks a following title (gapless), which
    /// becomes the current one when the previous title's last buffer has played.
    private func schedule(_ stream: TrackStream, _ pipeline: MediaPipeline, from first: Int, skipSeconds: Double, generation current: UUID, chainedID: String?) async throws {
        for index in first..<stream.segments.count {
            while secondsAhead > 35 {
                try await Task.sleep(nanoseconds: 250_000_000); try Task.checkCancellation()
            }
            let chunk = try await pipeline.chunk(index)
            try Task.checkCancellation(); guard generation == current else { throw CancellationError() }
            var buffer = chunk.buffer
            if index == first, skipSeconds > 0 {
                let skip = min(Int(skipSeconds * buffer.format.sampleRate), Int(buffer.frameLength) - 1)
                guard let cut = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - AVAudioFrameCount(skip)),
                      let source = buffer.floatChannelData, let destination = cut.floatChannelData else { throw ClientError.message("Could not load that position.") }
                cut.frameLength = buffer.frameLength - AVAudioFrameCount(skip)
                for channel in 0..<Int(buffer.format.channelCount) { destination[channel].update(from: source[channel].advanced(by: skip), count: Int(cut.frameLength)) }
                buffer = cut
            }
            if index == first, chainedID == nil {
                // Reconnect only for a stopped engine or another format;
                // rewiring a running graph clicks.
                if !engine.isRunning || connectedFormat != buffer.format {
                    if connected { engine.disconnectNodeOutput(node) }
                    engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
                    connected = true; connectedFormat = buffer.format
                }
                if !engine.isRunning { try engine.start() }
                outputRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
            }
            scheduledFrames += AVAudioFramePosition(buffer.frameLength)
            if chainedID == nil { buffered = min(duration, anchor + Double(scheduledFrames - trackStartFrame) / buffer.format.sampleRate) }
            let final = index == stream.segments.count - 1
            queuedCount += 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.queuedCount -= 1
                    if final { self.finishTitle(stream.id) }
                    else if self.queuedCount == 0 {
                        self.node.pause(); self.playing = false; self.loading = !self.pauseIntent
                    }
                }
            }
            if chainedID == nil { loading = false }
            node.volume = volume
            if !pauseIntent && !node.isPlaying { startNode() }
        }
    }

    /// The last buffer of a title has played: continue with the chained title
    /// (already playing, gapless) or report the end to the queue.
    private func finishTitle(_ id: String) {
        guard stream?.id == id || chained == nil else { return }
        guard let next = chained else {
            playing = false; position = duration; onEnded?(); return
        }
        chained = nil; prefetched[next.id] = nil
        stream = next.stream; pipeline = next.pipeline
        trackStartFrame = next.startFrame; anchor = 0; position = 0
        buffered = min(next.stream.duration, Double(scheduledFrames - next.startFrame) / (connectedFormat?.sampleRate ?? Double(next.stream.rate)))
        Self.log.notice("Gapless continue with \(next.id, privacy: .public)")
        onGaplessAdvance?(next.id)
    }

    private struct Chain { let id: String; let stream: TrackStream; let pipeline: MediaPipeline; let startFrame: AVAudioFramePosition }
    /// The following title, already scheduled behind the current one.
    private var chained: Chain?
    /// Positions on the player node's timeline (frames since the last start).
    private var trackStartFrame: AVAudioFramePosition = 0
    private var scheduledFrames: AVAudioFramePosition = 0
    private var lastRenderedFrame: AVAudioFramePosition = 0
    /// The queue's next title, for gapless playback.
    var nextTrack: (() -> (link: String, hint: Hint?)?)?
    /// The chained title has started; the queue moves on without loading it.
    var onGaplessAdvance: ((String) -> Void)?
    private var service: WrapperService?

    private var renderedFrame: AVAudioFramePosition {
        if let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) { lastRenderedFrame = time.sampleTime }
        return lastRenderedFrame
    }
    private var secondsAhead: Double {
        Double(scheduledFrames - renderedFrame) / (connectedFormat?.sampleRate ?? 44_100)
    }

    /// Waits until the scheduled audio runs out in under 20 seconds (so queue
    /// changes until then still count), then prepares the queue's next title.
    /// Titles with another sample rate are not chained: the device switches rate.
    private func nextForGapless(after current: TrackStream, generation: UUID) async -> Prefetched? {
        while secondsAhead > 20 || chained != nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, self.generation == generation else { return nil }
        }
        guard let next = nextTrack?(), let id = try? TrackLink(next.link).id, let service else { return nil }
        let item: Prefetched
        if let ready = prefetched[id] { item = ready }
        else {
            guard let prepared = try? await prepare(id, hint: next.hint, service: service) else { return nil }
            item = prepared; prefetched[id] = prepared
        }
        guard !Task.isCancelled, self.generation == generation, item.stream.rate == current.rate,
              let first = try? await item.pipeline.chunk(0), first.buffer.format == connectedFormat,
              // The queue may have changed while the title was prepared.
              nextTrack?()?.link == next.link else { return nil }
        return item
    }
    private func tick() {
        if airPlay != nil {
            if playing, duration > 0 { position = min(duration, airPlayAnchorPosition + Date().timeIntervalSince(airPlayAnchorDate)) }
            return
        }
        guard playing, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return }
        position = min(duration, max(0, anchor + Double(time.sampleTime - trackStartFrame) / time.sampleRate))
    }
}
