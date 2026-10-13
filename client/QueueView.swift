import SwiftUI

/// "Playing Next" in a toolbar popover. Rows show play and remove buttons on
/// hover, can be dragged to reorder, removed with the Delete key and have a
/// context menu for moving them.
struct QueuePanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var queue: PlaybackQueue
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if let current = queue.state.current {
                    Section("Now Playing") {
                        QueueRow(entry: current, playing: true).selectionDisabled()
                            .contextMenu {
                                Button("Go to Album") { app.goToAlbum(songID: current.catalogID); app.showingQueue = false }
                                Button("Go to Artist") { app.goToArtist(songID: current.catalogID); app.showingQueue = false }
                            }
                    }
                }
                Section {
                    ForEach(Array(queue.state.upcoming.enumerated()), id: \.element.id) { index, entry in
                        QueueRow(entry: entry, playing: false,
                                 play: { queue.perform { try queue.playQueued(entry.id) } },
                                 remove: { queue.remove(entry.id); selection.remove(entry.id) })
                            .tag(entry.id)
                            .contextMenu { menu(for: entry, at: index) }
                    }
                    .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in queue.remove(Set(offsets.map { queue.state.upcoming[$0].id })) }
                } header: {
                    HStack {
                        Text("Playing Next")
                        if !queue.state.upcoming.isEmpty { Text("\(queue.state.upcoming.count)").foregroundStyle(.tertiary) }
                        Spacer()
                        if !queue.state.upcoming.isEmpty {
                            Button("Clear") { queue.clear(); selection = [] }
                                .buttonStyle(.link).font(.callout)
                        }
                    }
                }
            }
            .onDeleteCommand { queue.remove(selection); selection = [] }
            .overlay {
                if queue.state.current == nil && queue.state.upcoming.isEmpty {
                    ContentUnavailableView("Nothing in the Queue", systemImage: "list.bullet",
                                           description: Text("Choose “Play Next” or “Play Last” in a song's context menu."))
                } else if queue.state.upcoming.isEmpty {
                    Text("No more songs").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                }
            }
            if queue.state.upcoming.count > 1 {
                Divider()
                Text("Drag to reorder. Remove with ⌫ or the cross.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder private func menu(for entry: QueueEntry, at index: Int) -> some View {
        let last = queue.state.upcoming.count - 1
        Button("Play Now") { queue.perform { try queue.playQueued(entry.id) } }
        Divider()
        Button("Move to Top") { queue.perform { try queue.move(entry.id, to: 0) } }.disabled(index == 0)
        Button("Move Up") { queue.perform { try queue.move(entry.id, to: index - 1) } }.disabled(index == 0)
        Button("Move Down") { queue.perform { try queue.move(entry.id, to: index + 1) } }.disabled(index >= last)
        Button("Move to Bottom") { queue.perform { try queue.move(entry.id, to: last) } }.disabled(index >= last)
        Divider()
        Button("Go to Album") { app.goToAlbum(songID: entry.catalogID); app.showingQueue = false }
        Button("Go to Artist") { app.goToArtist(songID: entry.catalogID); app.showingQueue = false }
        Divider()
        Button("Remove", role: .destructive) { queue.remove(entry.id); selection.remove(entry.id) }
    }
}

private struct QueueRow: View {
    let entry: QueueEntry
    let playing: Bool
    var play: (() -> Void)?
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: entry.artwork, cornerRadius: 4)
                .frame(width: 36, height: 36)
                .overlay {
                    if hovering, let play {
                        Button(action: play) {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Play Now")
                        .accessibilityLabel("Play \(entry.title) now")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                if !entry.artist.isEmpty { Text(entry.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove \(entry.title)")
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
