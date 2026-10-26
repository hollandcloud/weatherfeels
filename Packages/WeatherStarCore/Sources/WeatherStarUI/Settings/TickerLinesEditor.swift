import SwiftUI
import WeatherStarKit

/// The ticker messages typed in the app itself.
///
/// The ones that need no server: a line about the shop, the club, the family. The server's own
/// lines join them in the ticker; these come first.
struct TickerLinesEditor: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    /// The server's limit for a ticker line, kept here too so a line moves between the two.
    static let maximumLength = 120

    var body: some View {
        Form {
            Section {
                ForEach(Array(settings.tickerAdLines.enumerated()), id: \.offset) { index, line in
                    // A context menu rather than swipe actions, which tvOS does not have: a long
                    // press on the remote, a right-click on a Mac, a touch and hold on iOS.
                    Text(line)
                        .contextMenu {
                            Button("Delete", role: .destructive) { remove(at: index) }
                        }
                }
                .onDelete { offsets in
                    settings.tickerAdLines.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    settings.tickerAdLines.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                if settings.tickerAdLines.isEmpty {
                    Text("No messages yet.")
                }
            }

            Section {
                TextField("VISIT GULF COAST MARINE  555-0142", text: $draft)
                    .onSubmit(add)
                Button("Add message", action: add)
                    .disabled(trimmedDraft.isEmpty)
            } footer: {
                Text("Up to \(Self.maximumLength) characters. A long message runs over several ticker pages.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ticker Messages")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private var trimmedDraft: String {
        String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
    }

    private func add() {
        guard !trimmedDraft.isEmpty else { return }
        settings.tickerAdLines.append(trimmedDraft)
        draft = ""
    }

    private func remove(at index: Int) {
        guard settings.tickerAdLines.indices.contains(index) else { return }
        settings.tickerAdLines.remove(at: index)
    }
}
