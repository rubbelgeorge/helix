import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RemoteSettingsView(remote: AppModel.shared.remote)
                .tabItem { Label("Remote", systemImage: "iphone.radiowaves.left.and.right") }
            AirPlaySettingsView(receiver: AppModel.shared.airPlay, player: AppModel.shared.player)
                .tabItem { Label("AirPlay", systemImage: "airplay.audio") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "hifispeaker") }
            WrapperSettingsView(wrapper: AppModel.shared.wrapper)
                .tabItem { Label("Wrapper", systemImage: "server.rack") }
        }
        .frame(width: 540)
        .environmentObject(AppModel.shared)
    }
}

struct RemoteSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var remote: HTTPRemote

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { remote.running }, set: { app.setRemoteEnabled($0) })) {
                    Text("HTTP remote")
                    Text("Control playback from a phone or computer in the same network. The music plays on this Mac.")
                }
                if let failure = remote.failure { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if remote.running {
                Section("Connect") { RemotePairingView(remote: remote) }
                Section("Addresses") {
                    ForEach(remote.addresses, id: \.self) { address in
                        LabeledContent {
                            HStack {
                                Button("Copy") { copy(address) }
                                Button("Open") { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
                            }
                        } label: {
                            Text(address).font(.body.monospaced()).textSelection(.enabled)
                            if address.contains("127.0.0.1") { Text("Only on this Mac") }
                        }
                    }
                }
                Section {
                    LabeledContent("Active devices", value: remote.connectedDevices.formatted())
                } footer: {
                    Text("Any device in the same local network can control playback without a code. Access from the internet is refused.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .onAppear { remote.refreshAddresses() }
    }
}

/// QR code and address for opening the remote. Shared by Settings and the toolbar popover.
struct RemotePairingView: View {
    @ObservedObject var remote: HTTPRemote

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let address = remote.primaryAddress, let image = QRCode.image(for: address) {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 128, height: 128)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("QR code for \(address)")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan the code with your phone's camera or open the address in a browser in the same network.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let address = remote.primaryAddress {
                    Text(address).font(.title3.monospaced().weight(.medium)).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Toolbar popover for connecting a phone without opening Settings.
struct RemotePopover: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var remote: HTTPRemote
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Remote").font(.headline)
                Spacer()
                Toggle("Remote active", isOn: Binding(get: { remote.running }, set: { app.setRemoteEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if remote.running {
                RemotePairingView(remote: remote)
                if let address = remote.primaryAddress {
                    HStack {
                        Button { copy(address) } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                        Button { if let url = URL(string: address) { NSWorkspace.shared.open(url) } } label: { Label("Open in Browser", systemImage: "safari") }
                    }
                    .controlSize(.small)
                }
            } else {
                Text(remote.failure ?? "Turn on the remote to control playback from a phone in the same network.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(remote.connectedDevices == 1 ? "1 device active" : "\(remote.connectedDevices) devices active")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings …") { openSettings() }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { remote.refreshAddresses() }
    }
}

struct PlaybackSettingsView: View {
    @AppStorage("matchOutputSampleRate") private var matchRate = true
    @AppStorage(AnimatedArtworkService.settingKey) private var animatedArtwork = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $matchRate) {
                    Text("Match output device sample rate")
                    Text(matchRate
                         ? "Switches the output device to the song's sample rate (e.g. 96 kHz) when it supports it, so audio plays without resampling. This applies system-wide, including other apps. The previous rate is restored when playback stops."
                         : "Off: the output device keeps its sample rate. Audio goes through the system mixer and is resampled when needed, like in other apps.")
                }
            }
            Section("Appearance") {
                Toggle(isOn: $animatedArtwork) {
                    Text("Animated covers")
                    Text("Shows motion album covers in the full-screen player and on album pages when Apple offers them. With Reduce Motion in Accessibility the covers stay still.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }
}

/// The user's own wrapper-v2: address, status and the prefetch key.
struct WrapperSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var wrapper: WrapperConnection
    @AppStorage(PrefetchKey.defaultsKey) private var prefetchKey = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: wrapper.ready ? "checkmark.circle.fill" : wrapper.failure != nil ? "xmark.circle.fill" : "clock")
                            .foregroundStyle(wrapper.ready ? .green : wrapper.failure != nil ? .red : .secondary)
                        Text(wrapper.status)
                    }
                }
                if let failure = wrapper.failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
            }
            Section("Address") {
                WrapperEndpointForm(wrapper: wrapper)
            }
            Section {
                SecureField("Prefetch key", text: $prefetchKey, prompt: Text("32 hexadecimal characters"))
                if !prefetchKey.isEmpty && PrefetchKey.parse(prefetchKey) == nil {
                    Label("The key must consist of 32 hexadecimal characters.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Start of Songs")
            } footer: {
                Text("Apple encrypts the first seconds of each song with a shared prefetch key that wrapper-v2 does not handle. Helix does not include this key; enter it here yourself.")
            }
            Section {
                Text("Helix contains no Apple code and no wrapper. You run wrapper-v2 yourself and sign in with your own Apple Music subscription. Helix only plays; songs are never saved or exported.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(minHeight: 420)
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
}

struct AirPlaySettingsView: View {
    @ObservedObject var receiver: AirPlayReceiver
    @ObservedObject var player: AudioPlayer
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { receiver.enabled }, set: { receiver.setEnabled($0) })) {
                    Text("Enable AirPlay receiver")
                    Text("Choose Helix as the audio output on a device in the same network. An AirPlay connection stops Apple Music playback in Helix.")
                }
                if let failure = receiver.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if receiver.enabled { Button("Try Again") { receiver.start() } }
                }
            }
            if receiver.enabled {
                Section("Receiver") {
                    LabeledContent("Name", value: receiver.name)
                    LabeledContent("Status", value: player.airPlay != nil ? "Connected" : receiver.running ? "Ready" : "Not available")
                    if let track = player.airPlay {
                        if !track.sender.isEmpty { LabeledContent("Source", value: track.sender) }
                        LabeledContent("Quality", value: track.quality)
                        Button("Disconnect") { receiver.disconnect() }
                    }
                }
            }
            Section {
                Text("Receives AirPlay 1. AirPlay 2 and multiroom are not supported. Codec and quality are detected from the incoming audio stream. ALAC describes the transport; the original source may already be lossy.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Song info and artwork appear when the sending device provides them. Control pause, track changes and seeking on the sending device.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(minHeight: 360)
    }
}
