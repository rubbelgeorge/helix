import AVFoundation
import Foundation

private actor ReferenceSamples {
    var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func next(_ encrypted: [Data]) throws -> [Data] {
        guard chunks.count >= encrypted.count else { throw ClientError.message("Test fixture exhausted") }
        let result = Array(chunks.prefix(encrypted.count)); chunks.removeFirst(encrypted.count)
        guard zip(result, encrypted).allSatisfy({ $0.count == $1.count }) else { throw ClientError.message("Ciphertext layout differs from reference") }
        return result
    }
}

/// Run against a real encrypted ALAC segment and an independently
/// verified clear segment. Fixtures stay outside source control.
@main struct MediaProbe {
    static func parts(_ data: Data) throws -> [(String, Range<Int>)] {
        var result: [(String, Range<Int>)] = []; var cursor = 0
        while cursor + 8 <= data.count {
            let n = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard n >= 8, n <= data.count - cursor else { throw ClientError.message("Invalid fixture") }
            result.append((String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self), cursor..<(cursor + n))); cursor += n
        }
        return result
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw ClientError.message("Usage: media-probe encrypted.mp4 reference.m4a") }
        let encrypted = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let top = try parts(encrypted); let start = top.first(where: { $0.0 == "moof" })!.1.lowerBound
        let media = try ALACMedia(initialization: encrypted.subdata(in: 0..<start))
        let samples = try media.samples(from: encrypted.subdata(in: start..<encrypted.count))
        let reference = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let range = try parts(reference).first(where: { $0.0 == "mdat" })!.1
        let plaintext = reference.subdata(in: (range.lowerBound + 8)..<range.upperBound)
        var cursor = 0; var expected: [Data] = []
        for sample in samples {
            expected.append(plaintext.subdata(in: cursor..<(cursor + sample.data.count))); cursor += sample.data.count
        }
        precondition(cursor == plaintext.count)
        let fake = ReferenceSamples(expected.map { $0.subdata(in: 0..<($0.count & ~15)) })
        let actual = try await media.decrypt(samples) { try await fake.next($0) }
        precondition(zip(actual, expected).allSatisfy { $0.data == $1 }, "Decryption reassembly does not match independent reference")
        let pcm = try media.pcm(actual)
        precondition(pcm.frameLength == AVAudioFrameCount(samples.reduce(0) { $0 + $1.duration }), "In-memory ALAC decode is incomplete")
        // The in-memory decode must equal Apple's file decoder on the clear reference.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]), commonFormat: .pcmFormatFloat32, interleaved: false)
        let expectedPCM = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: expectedPCM)
        precondition(expectedPCM.frameLength == pcm.frameLength, "Frame count differs from file decode")
        for channel in 0..<Int(pcm.format.channelCount) {
            let a = UnsafeBufferPointer(start: pcm.floatChannelData![channel], count: Int(pcm.frameLength))
            let b = UnsafeBufferPointer(start: expectedPCM.floatChannelData![channel], count: Int(pcm.frameLength))
            precondition(a.elementsEqual(b), "PCM differs from file decode")
        }
        let link = try TrackLink("https://music.apple.com/de/album/test/123?i=1076060806")
        precondition(link.id == "1076060806")
        for invalid in ["https://example.com/song/123", "https://music.apple.com/de/album/test/123", "https://music.apple.com.evil.test/song/123"] {
            do { _ = try TrackLink(invalid); throw ClientError.message("Invalid URL accepted") } catch let error as ClientError {
                if error.errorDescription == "Invalid URL accepted" { throw error }
            }
        }
        do { _ = try media.samples(from: Data(encrypted.suffix(3))); throw ClientError.message("Truncated MP4 accepted") }
        catch let error as ClientError { if error.errorDescription == "Truncated MP4 accepted" { throw error } }
        print("Native ALAC samples match independent reference:", samples.count, "samples,", media.sampleRate, "Hz,", media.bitDepth, "bit")
    }
}
