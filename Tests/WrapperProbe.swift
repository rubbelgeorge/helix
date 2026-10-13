import AVFoundation
import Foundation

/// Integration check against a running, signed-in wrapper-v2: fetches one
/// track's stream, decrypts two segments over the TCP decrypt port and decodes
/// them in memory. Prints counts only; no tokens, URLs or audio leave memory.
///
///     wrapper-probe <host> <http-port> <decrypt-port> <song-id>
///
/// Set PREFETCH_KEY to also check the first segment (Apple's prefetch key).
@main struct WrapperProbe {
    static func main() async throws {
        setbuf(stdout, nil)
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let http = Int(arguments[2]), let decrypt = Int(arguments[3]) else {
            throw ClientError.message("Usage: wrapper-probe <host> <http-port> <decrypt-port> <song-id>")
        }
        if let key = ProcessInfo.processInfo.environment["PREFETCH_KEY"] { UserDefaults.standard.set(key, forKey: PrefetchKey.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: PrefetchKey.defaultsKey) }
        let wrapper = WrapperService(endpoint: WrapperEndpoint(host: arguments[1], httpPort: http, decryptPort: decrypt))
        let account = try await wrapper.account()
        print("Wrapper:", account.state, "playback ready:", account.ready)
        guard account.authenticated, account.ready else { throw ClientError.message("Sign into the wrapper first.") }
        let stream = try await MusicService.prepare(arguments[4], wrapper: wrapper)
        print("Stream:", stream.segments.count, "segments,", stream.rate, "Hz,", stream.depth, "bit")
        let codec = try ALACMedia(initialization: await MusicService.data(stream.initialization, range: stream.initializationRange))
        for index in [1, 2, 0] where stream.segments.indices.contains(index) {
            let segment = stream.segments[index]
            let samples = try codec.samples(from: await MusicService.data(segment.url, range: segment.range))
            let key = segment.keyURI.isEmpty ? stream.keyURI : segment.keyURI
            do {
                let clock = ContinuousClock.now
                let clear = try await codec.decrypt(samples) { try await wrapper.decrypt(trackID: stream.id, keyURI: key, samples: $0) }
                let pcm = try codec.pcm(clear)
                let peak = (0..<Int(pcm.frameLength)).reduce(Float(0)) { max($0, abs(pcm.floatChannelData![0][$1])) }
                print("Segment \(index):", samples.count, "samples ->", pcm.frameLength, "frames, peak", String(format: "%.3f", peak), "in", ContinuousClock.now - clock)
                precondition(pcm.frameLength > 0 && peak <= 1.0001, "Decoded audio out of range")
            } catch let error as ClientError where index == 0 && ProcessInfo.processInfo.environment["PREFETCH_KEY"] == nil {
                precondition(error.errorDescription == PrefetchKey.missingMessage, "Unexpected error without prefetch key: \(error.errorDescription ?? "")")
                print("Segment 0: refused without prefetch key, as expected")
            }
        }
    }
}
