import AVFoundation
import CommonCrypto
import Foundation

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private struct MP4Box {
    let type: String
    let range: Range<Int>
    let payload: Range<Int>
}

private extension Data {
    func number(_ offset: Int, _ count: Int = 4) throws -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset + count <= self.count else {
            throw ClientError.message("The audio stream is incomplete.")
        }
        return self[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    func boxes(in range: Range<Int>? = nil) throws -> [MP4Box] {
        let bounds = range ?? 0..<count
        guard bounds.lowerBound >= 0, bounds.upperBound <= count else { throw ClientError.message("Invalid audio segment.") }
        var offset = bounds.lowerBound
        var result: [MP4Box] = []
        while offset < bounds.upperBound {
            guard offset + 8 <= bounds.upperBound else { throw ClientError.message("Incomplete audio metadata.") }
            let shortSize = try number(offset)
            let header = shortSize == 1 ? 16 : 8
            let size = shortSize == 0 ? bounds.upperBound - offset : Int(try shortSize == 1 ? number(offset + 8, 8) : shortSize)
            guard size >= header, size <= bounds.upperBound - offset else { throw ClientError.message("Invalid audio segment size.") }
            let type = String(decoding: self[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(MP4Box(type: type, range: offset..<(offset + size), payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return result
    }
    mutating func put(_ value: UInt64, at offset: Int, bytes: Int = 4) {
        for n in 0..<bytes { self[offset + n] = UInt8(truncatingIfNeeded: value >> (8 * (bytes - 1 - n))) }
    }
    mutating func appendNumber(_ value: UInt64, bytes: Int = 4) {
        for n in (0..<bytes).reversed() { append(UInt8(truncatingIfNeeded: value >> (n * 8))) }
    }
}

private func box(_ type: String, _ payload: Data) -> Data {
    var data = Data(); data.appendNumber(UInt64(payload.count + 8)); data.append(contentsOf: type.utf8); data.append(payload); return data
}
private func fullBox(_ type: String, _ fields: [UInt64]) -> Data {
    var data = Data(repeating: 0, count: 4)
    for field in fields { data.appendNumber(field) }
    return box(type, data)
}

struct ALACSample: Sendable {
    var data: Data
    let duration: Int
    let description: Int
    let iv: Data
    let subsamples: [(Int, Int)]
}

/// Parses only the ALAC rendition and decodes its samples in memory with
/// Apple's ALAC decoder. Decrypted audio never touches the disk.
struct ALACMedia: Sendable {
    let initialization: Data
    let timescale: Int
    let sampleRate: Int
    let bitDepth: Int
    let channels: Int
    private let trackID: UInt64
    private let trackBox: MP4Box
    private let moov: MP4Box
    private let entries: [Data]
    private let ivs: [Data]
    private let perSampleIVSizes: [Int]
    private let defaultDuration: Int
    private let defaultSize: Int

    init(initialization: Data) throws {
        self.initialization = initialization
        guard let moov = try initialization.boxes().first(where: { $0.type == "moov" }) else { throw ClientError.message("Audio metadata is missing.") }
        self.moov = moov
        let children = try initialization.boxes(in: moov.payload)
        var chosen: MP4Box?
        for trak in children where trak.type == "trak" {
            guard let mdia = try initialization.boxes(in: trak.payload).first(where: { $0.type == "mdia" }),
                  let hdlr = try initialization.boxes(in: mdia.payload).first(where: { $0.type == "hdlr" }) else { continue }
            let p = hdlr.payload.lowerBound
            if String(decoding: initialization[(p + 8)..<(p + 12)], as: UTF8.self) == "soun" { chosen = trak; break }
        }
        guard let trak = chosen else { throw ClientError.message("The stream has no audio track.") }
        self.trackBox = trak
        func child(_ parent: MP4Box, _ type: String) throws -> MP4Box {
            guard let result = try initialization.boxes(in: parent.payload).first(where: { $0.type == type }) else { throw ClientError.message("Audio metadata is missing: \(type).") }; return result
        }
        let tkhd = try child(trak, "tkhd")
        self.trackID = try initialization.number(tkhd.payload.lowerBound + (initialization[tkhd.payload.lowerBound] == 1 ? 20 : 12))
        let mdia = try child(trak, "mdia")
        let mdhd = try child(mdia, "mdhd")
        self.timescale = Int(try initialization.number(mdhd.payload.lowerBound + (initialization[mdhd.payload.lowerBound] == 1 ? 20 : 12)))
        guard timescale > 0 else { throw ClientError.message("Invalid sample rate.") }
        let stbl = try child(child(mdia, "minf"), "stbl")
        let stsd = try child(stbl, "stsd")
        let sampleEntries = try initialization.boxes(in: (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound)
        guard !sampleEntries.isEmpty else { throw ClientError.message("ALAC configuration is missing.") }
        var clearEntries: [Data] = []; var constants: [Data] = []; var ivSizes: [Int] = []
        var rate = timescale; var depth = 0; var channelCount = 0; var frameLength = 4096
        for entry in sampleEntries {
            let raw = initialization.subdata(in: entry.range)
            guard raw.count >= 36, try raw.number(16, 2) == 0 else { throw ClientError.message("This audio format is not supported yet.") }
            let nested = try raw.boxes(in: 36..<raw.count)
            guard let config = nested.first(where: { $0.type == "alac" }), config.payload.count >= 28 else { throw ClientError.message("This song has no ALAC stream.") }
            let c = config.payload.lowerBound + 4
            frameLength = Int(try raw.number(c)); depth = Int(raw[c + 5]); channelCount = Int(raw[c + 9]); rate = Int(try raw.number(c + 20))
            var header = raw.subdata(in: 0..<36)
            header.replaceSubrange(4..<8, with: Data("alac".utf8))
            var iv = Data(repeating: 0, count: 16); var ivSize = 0
            for item in nested {
                if item.type == "sinf" {
                    let sinf = try raw.boxes(in: item.payload)
                    if let schi = sinf.first(where: { $0.type == "schi" }), let tenc = try raw.boxes(in: schi.payload).first(where: { $0.type == "tenc" }) {
                        let t = raw.subdata(in: tenc.range)
                        guard t.count >= 32 else { throw ClientError.message("Incomplete encryption information.") }
                        guard t[8] == 0 || t[13] == 0 else { throw ClientError.message("This encryption pattern is not supported yet.") }
                        ivSize = Int(t[15]); guard [0, 8, 16].contains(ivSize) else { throw ClientError.message("Unknown encryption format.") }
                        if ivSize == 0, t.count > 32 {
                            let length = Int(t[32]); guard length <= 16, t.count >= 33 + length else { throw ClientError.message("Incomplete encryption information.") }
                            iv = t.subdata(in: 33..<(33 + length))
                            iv.append(Data(repeating: 0, count: 16 - iv.count))
                        }
                    }
                } else { header.append(raw.subdata(in: item.range)) }
            }
            header.put(UInt64(header.count), at: 0)
            clearEntries.append(header); constants.append(iv); ivSizes.append(ivSize)
        }
        entries = clearEntries; ivs = constants; perSampleIVSizes = ivSizes
        sampleRate = rate; bitDepth = depth; channels = channelCount
        guard rate > 0, [16, 20, 24, 32].contains(depth), channelCount == 2 || channelCount == 1 else { throw ClientError.message("Invalid ALAC configuration.") }
        var duration = frameLength; var size = 0
        if let mvex = children.first(where: { $0.type == "mvex" }) {
            for trex in try initialization.boxes(in: mvex.payload) where trex.type == "trex" {
                let p = trex.payload.lowerBound
                if try initialization.number(p + 4) == trackID { duration = Int(try initialization.number(p + 12)); size = Int(try initialization.number(p + 16)) }
            }
        }
        defaultDuration = duration == 0 || duration == 1024 ? frameLength : duration
        defaultSize = size
    }

    func samples(from fragment: Data) throws -> [ALACSample] {
        let top = try fragment.boxes(); var result: [ALACSample] = []
        for moof in top where moof.type == "moof" {
            guard let mdat = top.first(where: { $0.type == "mdat" && $0.range.lowerBound >= moof.range.upperBound }) else { throw ClientError.message("Audio data is missing.") }
            for traf in try fragment.boxes(in: moof.payload) where traf.type == "traf" {
                let boxes = try fragment.boxes(in: traf.payload)
                guard let tfhd = boxes.first(where: { $0.type == "tfhd" }) else { continue }
                var p = tfhd.payload.lowerBound
                let flags = try fragment.number(p) & 0xFFFFFF
                guard try fragment.number(p + 4) == trackID else { continue }
                p += 8
                var base = moof.range.lowerBound
                if flags & 1 != 0 { base = Int(try fragment.number(p, 8)); p += 8 }
                var description = 0
                if flags & 2 != 0 { description = Int(try fragment.number(p)) - 1; p += 4 }
                guard entries.indices.contains(description) else { throw ClientError.message("Unknown audio track configuration.") }
                var duration = defaultDuration; var size = defaultSize
                if flags & 8 != 0 { duration = Int(try fragment.number(p)); p += 4 }
                if duration == 0 || duration == 1024 { duration = defaultDuration }
                if flags & 16 != 0 { size = Int(try fragment.number(p)); p += 4 }
                var encryption: [(Data, [(Int, Int)])] = []
                if let senc = boxes.first(where: { $0.type == "senc" }) {
                    var q = senc.payload.lowerBound
                    let f = try fragment.number(q) & 0xFFFFFF; let count = Int(try fragment.number(q + 4)); q += 8
                    guard f & 1 == 0, count <= 100_000 else { throw ClientError.message("Unknown encryption information.") }
                    for _ in 0..<count {
                        let length = perSampleIVSizes[description]
                        guard q + length <= senc.range.upperBound else { throw ClientError.message("Incomplete audio segment.") }
                        let iv = length == 0 ? ivs[description] : fragment.subdata(in: q..<(q + length)); q += length
                        var runs: [(Int, Int)] = []
                        if f & 2 != 0 {
                            let n = Int(try fragment.number(q, 2)); q += 2
                            for _ in 0..<n { let clear = Int(try fragment.number(q, 2)); let cipher = Int(try fragment.number(q + 2)); q += 6; runs.append((clear, cipher)) }
                        }
                        encryption.append((iv, runs))
                    }
                    guard q <= senc.range.upperBound else { throw ClientError.message("Incomplete audio segment.") }
                }
                var offset = mdat.payload.lowerBound; var row = 0
                for trun in boxes where trun.type == "trun" {
                    var q = trun.payload.lowerBound
                    let f = try fragment.number(q) & 0xFFFFFF; let count = Int(try fragment.number(q + 4)); q += 8
                    guard count <= 100_000 else { throw ClientError.message("Audio segment too large.") }
                    if f & 1 != 0 { offset = base + Int(Int32(bitPattern: UInt32(try fragment.number(q)))); q += 4 }
                    if f & 4 != 0 { q += 4 }
                    for _ in 0..<count {
                        var d = duration; var n = size
                        if f & 0x100 != 0 { d = Int(try fragment.number(q)); q += 4 }
                        if f & 0x200 != 0 { n = Int(try fragment.number(q)); q += 4 }
                        if f & 0x400 != 0 { q += 4 }; if f & 0x800 != 0 { q += 4 }
                        guard d > 0, n > 0, offset >= mdat.payload.lowerBound, n <= mdat.payload.upperBound - offset, q <= trun.range.upperBound else { throw ClientError.message("Incomplete audio samples.") }
                        let enc = row < encryption.count ? encryption[row] : (ivs[description], [])
                        let runs = enc.1
                        guard runs.isEmpty || runs.reduce(0, { $0 + $1.0 + $1.1 }) <= n else { throw ClientError.message("Invalid encrypted audio segment.") }
                        result.append(ALACSample(data: fragment.subdata(in: offset..<(offset + n)), duration: d == 1024 ? defaultDuration : d, description: description, iv: enc.0, subsamples: runs))
                        offset += n; row += 1
                    }
                }
            }
        }
        guard !result.isEmpty else { throw ClientError.message("The audio segment is empty.") }
        return result
    }

    func decrypt(_ input: [ALACSample], using remote: @Sendable ([Data]) async throws -> [Data]) async throws -> [ALACSample] {
        var output = input
        var pending: [(Int, Data, Data)] = []
        func reassemble(_ sample: ALACSample, _ decrypted: Data) throws -> Data {
            if sample.subsamples.isEmpty { guard decrypted.count == sample.data.count else { throw ClientError.message("Invalid response from the wrapper.") }; return decrypted }
            var result = Data(); var cursor = 0; var plain = 0
            for (clear, encrypted) in sample.subsamples {
                result.append(sample.data.subdata(in: cursor..<(cursor + clear))); cursor += clear
                guard plain + encrypted <= decrypted.count else { throw ClientError.message("Invalid response from the wrapper.") }
                result.append(decrypted.subdata(in: plain..<(plain + encrypted))); plain += encrypted; cursor += encrypted
            }
            guard plain == decrypted.count else { throw ClientError.message("Invalid response from the wrapper.") }
            result.append(sample.data.subdata(in: cursor..<sample.data.count)); return result
        }
        for (index, sample) in input.enumerated() {
            var encrypted = Data()
            if sample.subsamples.isEmpty { encrypted = sample.data } else {
                var cursor = 0
                for (clear, cipher) in sample.subsamples { cursor += clear; encrypted.append(sample.data.subdata(in: cursor..<(cursor + cipher))); cursor += cipher }
            }
            let length = encrypted.count & ~15
            let aligned = encrypted.subdata(in: 0..<length); let tail = encrypted.subdata(in: length..<encrypted.count)
            if sample.description == 0 {
                // The track start uses Apple's shared prefetch key, which wrapper-v2
                // leaves to the client. Helix does not ship it; see PrefetchKey.
                guard let key = PrefetchKey.saved else { throw ClientError.message(PrefetchKey.missingMessage) }
                var iv = sample.iv; iv.append(Data(repeating: 0, count: max(0, 16 - iv.count)))
                var clear = Data(repeating: 0, count: length); var written = 0
                if length > 0 {
                    let status = aligned.withUnsafeBytes { source in clear.withUnsafeMutableBytes { destination in iv.withUnsafeBytes { vector in key.withUnsafeBytes { secret in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, secret.baseAddress, key.count, vector.baseAddress, source.baseAddress, length, destination.baseAddress, length, &written)
                    } } } }
                    guard status == kCCSuccess, written == length else { throw ClientError.message("The start of the song could not be decoded.") }
                }
                clear.append(tail); output[index].data = try reassemble(sample, clear)
            } else if length == 0 { output[index].data = try reassemble(sample, tail) }
            else { pending.append((index, aligned, tail)) }
        }
        // Keep batches bounded, while avoiding the old per-sample network requests.
        for start in stride(from: 0, to: pending.count, by: 256) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + 256, pending.count)])
            let plaintext = try await remote(batch.map { $0.1 })
            guard plaintext.count == batch.count else { throw ClientError.message("The wrapper returned an incomplete response.") }
            for (item, bytes) in zip(batch, plaintext) {
                guard bytes.count == item.1.count else { throw ClientError.message("Invalid response from the wrapper.") }
                output[item.0].data = try reassemble(input[item.0], bytes + item.2)
            }
        }
        return output
    }

    private func m4a(_ samples: [ALACSample]) throws -> Data {
        guard let first = samples.first, entries.indices.contains(first.description) else { throw ClientError.message("Audio samples are missing.") }
        let ticks = UInt64(samples.reduce(0) { $0 + $1.duration })
        let ftyp = box("ftyp", Data("M4A ".utf8) + Data(repeating: 0, count: 4) + Data("M4A mp42isom".utf8))
        func rewritten(_ current: MP4Box, dataOffset: UInt64) throws -> Data {
            let type = current.type
            if ["moov", "trak", "mdia", "minf", "stbl"].contains(type) {
                var result = Data()
                for child in try initialization.boxes(in: current.payload) {
                    if ["mvex", "senc", "saiz", "saio", "sbgp", "sgpd", "stss", "ctts"].contains(child.type) { continue }
                    if type == "moov", child.type == "trak", child.range != trackBox.range { continue }
                    result.append(try rewritten(child, dataOffset: dataOffset))
                }
                return box(type, result)
            }
            if type == "stsd" { return box(type, Data(repeating: 0, count: 4) + Data([0,0,0,1]) + entries[first.description]) }
            if type == "stts" {
                var groups: [(Int, Int)] = []
                for sample in samples { if let last = groups.last, last.1 == sample.duration { groups[groups.count - 1].0 += 1 } else { groups.append((1, sample.duration)) } }
                var fields: [UInt64] = [UInt64(groups.count)]; for group in groups { fields += [UInt64(group.0), UInt64(group.1)] }; return fullBox(type, fields)
            }
            if type == "stsc" { return fullBox(type, [1,1,UInt64(samples.count),1]) }
            if type == "stsz" { return fullBox(type, [0,UInt64(samples.count)] + samples.map { UInt64($0.data.count) }) }
            if type == "stco" || type == "co64" { return fullBox("stco", [1,dataOffset]) }
            var raw = initialization.subdata(in: current.range)
            if type == "mvhd" || type == "mdhd" {
                let version = raw[8]; raw.put(UInt64(timescale), at: version == 1 ? 28 : 20); raw.put(ticks, at: version == 1 ? 32 : 24, bytes: version == 1 ? 8 : 4)
            } else if type == "tkhd" { raw[11] = 7; raw.put(ticks, at: raw[8] == 1 ? 36 : 28, bytes: raw[8] == 1 ? 8 : 4) }
            return raw
        }
        let provisional = try rewritten(moov, dataOffset: 0)
        let metadata = try rewritten(moov, dataOffset: UInt64(ftyp.count + provisional.count + 8))
        var payload = Data(); for sample in samples { payload.append(sample.data) }
        return ftyp + metadata + box("mdat", payload)
    }

    /// Decodes clear samples to non-interleaved Float32 PCM. The M4A container
    /// is read by Apple's decoder straight from memory; decrypted audio is
    /// never written to disk.
    func pcm(_ samples: [ALACSample]) throws -> AVAudioPCMBuffer {
        try MemoryAudioFile.decode(m4a(samples))
    }
}

/// Reads an in-memory audio file through AudioFile callbacks and ExtAudioFile.
private final class MemoryAudioFile {
    private let data: Data
    private init(_ data: Data) { self.data = data }

    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        let source = MemoryAudioFile(data)
        let failure = ClientError.message("The lossless audio segment could not be decoded.")
        let read: AudioFile_ReadProc = { client, position, count, buffer, actual in
            let file = Unmanaged<MemoryAudioFile>.fromOpaque(client).takeUnretainedValue()
            guard position >= 0, position < Int64(file.data.count) else { actual.pointee = 0; return position == Int64(file.data.count) ? noErr : kAudioFileInvalidPacketOffsetError }
            let length = min(Int(count), file.data.count - Int(position))
            file.data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!.advanced(by: Int(position)), byteCount: length) }
            actual.pointee = UInt32(length); return noErr
        }
        let size: AudioFile_GetSizeProc = { client in Int64(Unmanaged<MemoryAudioFile>.fromOpaque(client).takeUnretainedValue().data.count) }
        var fileID: AudioFileID?
        let client = Unmanaged.passUnretained(source).toOpaque()
        guard AudioFileOpenWithCallbacks(client, read, nil, size, nil, kAudioFileM4AType, &fileID) == noErr, let fileID else { throw failure }
        defer { AudioFileClose(fileID) }
        var extFile: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(fileID, false, &extFile) == noErr, let extFile else { throw failure }
        defer { ExtAudioFileDispose(extFile) }
        var description = AudioStreamBasicDescription(), descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var frames: Int64 = 0, framesSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &descriptionSize, &description) == noErr,
              ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames) == noErr,
              frames > 0, frames <= 20_000_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate, channels: description.mChannelsPerFrame, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw failure }
        var clientFormat = format.streamDescription.pointee
        guard ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat) == noErr else { throw failure }
        var remaining = UInt32(frames), filled: UInt32 = 0
        while remaining > 0 {
            // Point the buffer list at the not yet filled part of each channel.
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = AudioBufferList.allocate(maximumBuffers: list.count)
            defer { free(target.unsafeMutablePointer) }
            for (index, channel) in list.enumerated() {
                let start = channel.mData!.assumingMemoryBound(to: Float.self).advanced(by: Int(filled))
                target[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: remaining * 4, mData: start)
            }
            var count = remaining
            guard ExtAudioFileRead(extFile, &count, target.unsafeMutablePointer) == noErr else { throw failure }
            if count == 0 { break }
            filled += count; remaining -= count
        }
        guard filled > 0 else { throw failure }
        buffer.frameLength = filled
        return withExtendedLifetime(source) { buffer }
    }
}

/// Apple's shared prefetch key for the first seconds of each track. It is
/// public knowledge but deliberately not part of this source code: users who
/// run wrapper-v2 enter it once in the settings (32 hexadecimal characters).
enum PrefetchKey {
    static let defaultsKey = "prefetchKey"
    static let missingMessage = "The prefetch key for the start of songs is missing. Enter it in Settings › Wrapper."
    static func parse(_ text: String) -> [UInt8]? {
        let hex = text.filter { !$0.isWhitespace }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = [], index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!); index = next
        }
        return bytes
    }
    static var saved: [UInt8]? { UserDefaults.standard.string(forKey: defaultsKey).flatMap(parse) }
}
