import Foundation
import Network

/// wrapper-v2's TCP decrypt protocol (versioned batch frames, big-endian):
///
///     magic "WV2D" · version u16 = 1 · kind u16 · request_id u32 · payload_len u32 · payload
///
/// kind 1 is a batch request, 2 a successful reply, 3 an error message, 9 close.
/// One persistent connection is reused; the wrapper closes it after an error,
/// so the next request simply connects again. Requests are sent one at a time.
actor DecryptChannel {
    static let shared = DecryptChannel()

    private static let magic: [UInt8] = Array("WV2D".utf8)
    private static let version: UInt16 = 1
    private enum Kind: UInt16 { case batch = 1, ok = 2, error = 3, close = 9 }

    private var connection: NWConnection?
    private var target: (host: String, port: Int)?
    private var nextID: UInt32 = 1
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func reset() {
        connection?.cancel(); connection = nil; target = nil
    }

    func decrypt(host: String, port: Int, trackID: String, keyURI: String, samples: [Data]) async throws -> [Data] {
        guard !samples.isEmpty else { return [] }
        let adam = Data(trackID.utf8), uri = Data(keyURI.utf8)
        guard adam.count <= Int(UInt16.max), uri.count <= Int(UInt16.max), samples.allSatisfy({ !$0.isEmpty }) else {
            throw ClientError.message("Invalid audio segment.")
        }
        var payload = Data()
        payload.append(be: UInt16(adam.count)); payload.append(be: UInt16(uri.count)); payload.append(be: UInt32(samples.count))
        for sample in samples { payload.append(be: UInt32(sample.count)) }
        payload.append(adam); payload.append(uri); for sample in samples { payload.append(sample) }

        // One request at a time on the shared connection.
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer { busy = false; if !waiting.isEmpty { waiting.removeFirst().resume() } }

        let id = nextID; nextID &+= 1
        do {
            let connection = try await open(host: host, port: port)
            var frame = Data(Self.magic)
            frame.append(be: Self.version); frame.append(be: Kind.batch.rawValue); frame.append(be: id); frame.append(be: UInt32(payload.count))
            frame.append(payload)
            try await send(frame, on: connection)
            let header = try await receive(16, on: connection)
            guard Array(header[0..<4]) == Self.magic, header.number(at: 4, 2) == UInt64(Self.version) else {
                throw ClientError.message("The wrapper speaks an unknown decrypt protocol. Please update wrapper-v2.")
            }
            let kind = UInt16(header.number(at: 6, 2)), replyID = UInt32(header.number(at: 8, 4)), length = Int(header.number(at: 12, 4))
            guard replyID == id, length <= 512 * 1024 * 1024 else { throw ClientError.message("Unexpected response from the wrapper.") }
            let body = length > 0 ? try await receive(length, on: connection) : Data()
            switch Kind(rawValue: kind) {
            case .ok: return try Self.samples(in: body, matching: samples)
            case .error:
                reset()
                let message = String(decoding: body, as: UTF8.self)
                throw ClientError.message(message.isEmpty ? "The wrapper could not unlock this segment." : "The wrapper could not unlock this segment: \(message)")
            default:
                reset(); throw ClientError.message("The wrapper closed the connection. Please start playback again.")
            }
        } catch let error as ClientError {
            throw error
        } catch {
            reset()
            throw ClientError.message("Cannot connect to the wrapper's decrypt port \(host):\(port).")
        }
    }

    private static func samples(in body: Data, matching input: [Data]) throws -> [Data] {
        guard body.count >= 4 else { throw ClientError.message("Incomplete audio response.") }
        let count = Int(body.number(at: 0, 4))
        guard count == input.count, body.count >= 4 + count * 4 else { throw ClientError.message("Incomplete audio response.") }
        var cursor = 4 + count * 4, result: [Data] = []
        for index in 0..<count {
            let length = Int(body.number(at: 4 + index * 4, 4))
            guard length == input[index].count, length <= body.count - cursor else { throw ClientError.message("Invalid audio response.") }
            result.append(body.subdata(in: (body.startIndex + cursor)..<(body.startIndex + cursor + length))); cursor += length
        }
        guard cursor == body.count else { throw ClientError.message("Invalid audio response.") }
        return result
    }

    // MARK: Network.framework plumbing

    private func open(host: String, port: Int) async throws -> NWConnection {
        if let connection, let target, target.host == host, target.port == port, connection.state == .ready { return connection }
        reset()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ClientError.message("Invalid decrypt port.") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.claim() { connection.cancel(); continuation.resume(throwing: error) }
                case .cancelled: if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        self.connection = connection; target = (host, port)
        return connection
    }
    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func receive(_ count: Int, on connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: ClientError.message("The wrapper closed the connection.")) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

/// Resumes a continuation exactly once from Network.framework's state callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func number(at offset: Int, _ bytes: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
