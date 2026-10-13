import AppKit
import SwiftUI

/// Plays or queues a single Apple Music title link. A link on the clipboard is
/// offered automatically, so ⌘L then Return is enough.
struct OpenLinkView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    private var trimmed: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Song Link").font(.headline)
            Text("Paste the link of a single song from Apple Music, for example via “Share > Copy Link”.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://music.apple.com/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit { app.playLink($0) } }
                .accessibilityLabel("Apple Music song link")
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Menu("Add to Queue") {
                    Button("Play Next") { submit { app.enqueueLink($0, first: true) } }
                    Button("Play Last") { submit { app.enqueueLink($0, first: false) } }
                }
                .fixedSize()
                .disabled(trimmed.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Play") { submit { app.playLink($0) } }
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if link.isEmpty, let clip = NSPasteboard.general.string(forType: .string), (try? TrackLink(clip)) != nil {
                link = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            focused = true
        }
        .onChange(of: link) { error = nil }
    }

    private func submit(_ action: (String) -> Void) {
        do { _ = try TrackLink(trimmed) } catch { self.error = (error as? LocalizedError)?.errorDescription; return }
        action(trimmed); dismiss()
    }
}
