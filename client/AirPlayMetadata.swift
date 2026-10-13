import Foundation

struct AirPlayFormat: Equatable, Sendable {
    let codec: String
    let rate: Int
    let depth: Int?
    let channels: Int

    /// Shairport's input description, never the decoded stdout/output format.
    init?(_ description: String) {
        let parts = description.split(separator: "/").map(String.init)
        guard parts.count == 4, ["ALAC", "AAC", "PCM"].contains(parts[0]),
              let rate = Int(parts[1]), (8_000...192_000).contains(rate),
              let channels = Int(parts[3]), (1...8).contains(channels) else { return nil }
        codec = parts[0]; self.rate = rate; self.channels = channels
        // Floating-point decoder precision is not an AAC source bit depth.
        depth = parts[2].hasPrefix("S") ? Int(parts[2].dropFirst().prefix(while: { $0.isNumber })) : nil
    }
    var quality: String {
        let khz = Double(rate) / 1000
        let rateText = khz.formatted(.number.precision(.fractionLength(0...1))) + " kHz"
        let precision = depth.map { "\($0)-bit / " } ?? ""
        return "AirPlay · \(codec) · \(precision)\(rateText) · \(channels == 2 ? "Stereo" : "\(channels) Kanäle")"
    }
}

struct AirPlayTrack: Sendable {
    var title = "AirPlay"
    var artist = ""
    var album = ""
    var sender = ""
    var artwork: URL?
    var format: AirPlayFormat?
    var duration = 0.0
    var quality: String { format?.quality ?? "AirPlay · Detecting format …" }
}

struct AirPlayMetadataEvent: Equatable, Sendable {
    let type: String
    let code: String
    let data: Data
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

/// The FIFO is a sequence of XML items, with arbitrary read boundaries.
/// Bound the input and validate base64 against the declared decoded length.
struct AirPlayMetadataParser {
    private var pending = Data()
    private static let end = Data("</item>".utf8)
    static let maximumSize = 8 * 1024 * 1024
    mutating func feed(_ data: Data) -> [AirPlayMetadataEvent] {
        pending.append(data)
        guard pending.count <= Self.maximumSize else { pending.removeAll(); return [] }
        var events: [AirPlayMetadataEvent] = []
        while let range = pending.range(of: Self.end) {
            let item = pending.subdata(in: pending.startIndex..<range.upperBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            if let event = Self.decode(item) { events.append(event) }
        }
        return events
    }
    private static func decode(_ item: Data) -> AirPlayMetadataEvent? {
        guard let xml = String(data: item, encoding: .utf8) else { return nil }
        func value(_ tag: String) -> String? {
            guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
            return String(xml[start.upperBound..<end.lowerBound])
        }
        func fourCC(_ tag: String) -> String? {
            guard let hex = value(tag), let code = UInt32(hex, radix: 16) else { return nil }
            return String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii)
        }
        guard let type = fourCC("type"), let code = fourCC("code"),
              let lengthText = value("length"), let length = Int(lengthText), length >= 0, length <= maximumSize else { return nil }
        var data = Data()
        if length > 0 {
            guard let start = xml.range(of: "<data encoding=\"base64\">"), let end = xml.range(of: "</data>", range: start.upperBound..<xml.endIndex),
                  let decoded = Data(base64Encoded: String(xml[start.upperBound..<end.lowerBound]).filter { !$0.isWhitespace }), decoded.count == length else { return nil }
            data = decoded
        }
        return AirPlayMetadataEvent(type: type, code: code, data: data)
    }
}

/// RTP counters wrap at 2^32; subtraction must preserve that wrapping.
func airPlayProgress(_ text: String, rate: Int) -> (position: Double, duration: Double)? {
    let counters = text.split(separator: "/").compactMap { UInt32($0) }
    guard counters.count == 3, rate > 0 else { return nil }
    let duration = Double(counters[2] &- counters[0]) / Double(rate)
    let position = Double(counters[1] &- counters[0]) / Double(rate)
    guard duration < 24 * 60 * 60, position <= duration else { return nil }
    return (position, duration)
}
