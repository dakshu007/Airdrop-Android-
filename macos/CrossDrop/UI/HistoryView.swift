import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CDSpacing.m) {
                HStack {
                    SectionHeader(title: "History", detail: "Stored only on this Mac")
                    if !model.history.isEmpty {
                        Button("Clear History…") { confirmClear = true }
                            .buttonStyle(GlassButtonStyle(destructive: true))
                    }
                }
                if model.history.isEmpty {
                    StateMessage(symbol: "clock", title: "No history yet",
                                 message: "Finished transfers are listed here. The list never leaves this Mac.")
                        .cdGlass(radius: CDRadius.medium)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry)
                            if entry.id != model.history.last?.id {
                                Divider().opacity(0.5).padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, CDSpacing.s)
                    .cdGlass(radius: CDRadius.medium)
                }
            }
            .padding(CDSpacing.xl)
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the list only. Received files stay where they were saved.")
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: CDSpacing.m) {
            Image(systemName: entry.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(entry.isIncoming ? CDPalette.mint : CDPalette.sky)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            statusChip
            if entry.isIncoming, entry.status == "completed", !savedURLs.isEmpty {
                Button {
                    model.reveal(savedURLs)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, CDSpacing.l)
        .padding(.vertical, CDSpacing.s)
        .accessibilityElement(children: .combine)
    }

    private var savedURLs: [URL] {
        entry.files.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
    }

    private var title: String {
        let first = entry.files.first?.name ?? "Files"
        return entry.files.count > 1 ? "\(first) and \(entry.files.count - 1) more" : first
    }

    private var subtitle: String {
        let direction = entry.isIncoming ? "From \(entry.peerName)" : "To \(entry.peerName)"
        return "\(direction) · \(Format.bytes(entry.totalBytes)) · \(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var statusChip: some View {
        let (text, color) = { () -> (String, Color) in
            switch entry.status {
            case "completed": return (entry.isIncoming ? "Received" : "Sent", CDPalette.mint)
            case "rejected": return ("Declined", Color.secondary)
            case "cancelled": return ("Cancelled", Color.secondary)
            default: return ("Failed", CDPalette.coral)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
