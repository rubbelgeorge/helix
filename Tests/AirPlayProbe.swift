import AppKit
import Foundation
import SwiftUI

@main
struct AirPlayProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        let alac = AirPlayFormat("ALAC/44100/S16/2")!
        check(alac.codec == "ALAC" && alac.depth == 16 && alac.rate == 44100, "ALAC input format")
        let aac = AirPlayFormat("AAC/48000/F24/2")!
        check(aac.depth == nil && aac.quality.contains("AAC") && !aac.quality.contains("Bit"), "AAC decoder precision must not become source bit depth")
        check(AirPlayFormat("garbage") == nil && AirPlayFormat("ALAC/0/S16/2") == nil, "invalid formats")
        check(AirPlayFormat("ALAC/48000/S24_LE/2")?.depth == 24, "sample format suffix")
        func xml(_ code: String, _ text: String) -> Data {
            let fourCC = code.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let data = Data(text.utf8)
            return Data("<item><type>73736e63</type><code>\(String(fourCC, radix:16))</code><length>\(data.count)</length><data encoding=\"base64\">\n\(data.base64EncodedString())\n</data></item>\n".utf8)
        }
        var parser = AirPlayMetadataParser(), events: [AirPlayMetadataEvent] = []
        let feed = xml("sdsc", "ALAC/44100/S16/2") + xml("snam", "Küche 🎵")
        for byte in feed { events += parser.feed(Data([byte])) }
        check(events.count == 2 && events[1].text == "Küche 🎵", "byte-fragmented metadata")
        check(parser.feed(Data("<item><type>73736e63</type><code>73647363</code><length>999</length><data encoding=\"base64\">YQ==</data></item>".utf8)).isEmpty, "incorrect length")
        check(parser.feed(Data(repeating: 0, count: AirPlayMetadataParser.maximumSize + 1)).isEmpty, "bounded parser")
        check(parser.feed(xml("sdsc", "PCM/44100/S16/2")).count == 1, "recover after invalid input")
        let wrapped = airPlayProgress("4294967000/145/43804", rate: 44100)!
        check(abs(wrapped.position - 0.01) < 0.0001 && abs(wrapped.duration - 1) < 0.0001, "RTP wraparound")
        check(airPlayProgress("0/200/100", rate: 44100) == nil, "invalid progress")

        let player = AudioPlayer(), runtime = LocalRuntime()
        let queue = PlaybackQueue(player: player, runtime: runtime)
        let helper = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        let receiver = AirPlayReceiver(player: player, queue: queue, helperURL: helper, enabled: true)
        player.onAirPlayDisconnect = { receiver.disconnect() }
        player.stream = TrackStream(id: "123", title: "Old Apple Music", artist: "Old artist", artwork: nil,
                                   initialization: URL(string: "https://example.invalid/init")!, initializationRange: nil,
                                   segments: [], keyURI: "", rate: 96000, depth: 24)
        player.playing = true
        func event(_ code: String, _ text: String = "", type: String = "ssnc") {
            receiver.receive(AirPlayMetadataEvent(type: type, code: code, data: Data(text.utf8)))
        }
        event("conn")
        check(player.stream == nil && !player.playing && player.airPlay != nil, "connection takes ownership before audio")
        event("mdst"); event("minm", "AirPlay track", type: "core"); event("asar", "Sender artist", type: "core"); event("asal", "Sender album", type: "core")
        check(player.displayTitle == "AirPlay", "atomic metadata transaction")
        event("mden"); event("pbeg"); event("sdsc", "ALAC/44100/S16/2")
        check(player.displayTitle == "AirPlay track" && player.displayArtist == "Sender artist", "play events preserve metadata")
        check(player.airPlay?.format?.codec == "ALAC", "receiver input codec")
        event("sdsc", "AAC/44100/F24/2")
        check(player.airPlay?.quality.contains("AAC") == true && player.airPlay?.format?.depth == nil, "AAC not lossless")
        event("prgr", "0/44100/441000")
        check(player.position == 1 && player.duration == 10 && !player.canSeek, "source-owned timeline")
        event("sdsc", "invalid")
        check(player.airPlay?.format == nil && player.airPlay?.quality.contains("erkannt") == true, "unknown format is honest")
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus(); NSColor.blue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 20)).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let url = ArtworkCache.shared.receiveAirPlayArtwork(png)!
        check(ArtworkCache.shared.cached(url) != nil && ArtworkCache.shared.airPlayArtworkData(url) == png, "received artwork")
        check(ArtworkCache.shared.receiveAirPlayArtwork(Data("bad image".utf8)) == nil, "invalid artwork")
        if let directory = ProcessInfo.processInfo.environment["AIRPLAY_SNAPSHOTS"] {
            player.airPlay?.format = alac; player.airPlay?.artwork = url
            AppModel.shared.player.airPlay = player.airPlay
            func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) async throws {
                let frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                let host = NSHostingView(rootView: view.environmentObject(AppModel.shared))
                window.contentView = host; window.orderFront(nil)
                try await Task.sleep(nanoseconds: 300_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await capture(AirPlaySettingsView(receiver: receiver, player: player), "settings", width: 540, height: 500)
            try await capture(NowPlayingFullView(player: player, queue: queue), "now-playing", width: 1000, height: 720)
        }
        event("pend")
        check(player.airPlay == nil && player.stream == nil && !player.playing, "disconnect never auto-resumes Apple Music")
        print("PASS: formats, fragmented metadata, AAC precision, RTP wrap, source takeover, metadata persistence, timeline, artwork, teardown")
        if helper != nil {
            receiver.start()
            check(receiver.running, receiver.failure ?? "receiver start")
            print("RECEIVER_READY"); fflush(stdout)
            // Allow the external RTSP probe to exercise the actual helper and FIFO.
            for _ in 0..<200 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if player.airPlay?.format != nil && player.displayTitle == "Receiver integration" {
                    print("LIVE_FORMAT: \(player.airPlay!.format!.codec) LIVE_TITLE: \(player.displayTitle!)")
                    fflush(stdout)
                    if player.playing && player.airPlayPeak > 0 { print("LIVE_AUDIO_OUTPUT"); fflush(stdout); break }
                }
            }
            let live = player.airPlay?.format?.codec == (CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "PCM") && player.displayTitle == "Receiver integration" && player.playing && player.airPlayPeak > 0
            receiver.stop()
            check(live, "real RTSP + FIFO + native audio integration")
            receiver.start()
            for _ in 0..<50 where !receiver.running { try await Task.sleep(nanoseconds: 100_000_000) }
            check(receiver.running && receiver.failure == nil, "receiver restarts after teardown")
            receiver.stop(); receiver.start(); receiver.stop(); receiver.start()
            for _ in 0..<50 where !receiver.running { try await Task.sleep(nanoseconds: 100_000_000) }
            check(receiver.running && receiver.failure == nil, "rapid receiver restarts serialize port ownership")
            receiver.stop()
            print("PASS: real receiver lifecycle, restart and native decoded audio playback")
        }
    }
}
