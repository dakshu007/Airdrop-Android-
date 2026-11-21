import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var confirmClear = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.history }
        return model.history.filter { entry in
            entry.peerName.lowercased().contains(q)
                || (entry.link ?? "").lowercased().contains(q)
                || entry.files.contains { $0.name.lowercased().contains(q) }
        }
    }

    var body: some View {
        PageScroll(allowsWide: true) {
            PageTitle(title: "History", subtitle: "Stored only on this Mac.",
                      trailing: model.history.isEmpty ? nil : AnyView(
                        Button("Clear History…") { confirmClear = true }
                            .buttonStyle(GlassButtonStyle(destructive: true))
                      ))
            if model.history.isEmpty {
                StateMessage(symbol: "clock.arrow.circlepath", title: "Nothing here yet",
                             message: "Finished transfers are listed here. The list never leaves this Mac.")
                    .glassPanel(cornerRadius: CDRadius.card)
            } else {
                HStack(spacing: ui(8)) {
                    Image(systemName: "magnifyingglass")
                        .font(ui.system(13))
                        .foregroundColor(CDPalette.textTertiary)
                        .accessibilityHidden(true)
                    TextField("Search files, links or devices", text: $query)
                        .textFieldStyle(.plain)
                        .font(ui.body)
                        .focused($searchFocused)
                        .accessibilityLabel("Search history")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ui.system(13))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(CDPalette.textTertiary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, ui.m)
                .frame(height: ui(38))
                .glassPanel(cornerRadius: 14, style: .inset)
                .modifier(FieldFocusBorder(focused: searchFocused, radius: 14))
                .frame(maxWidth: ui(420))

                let rows = filtered
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("Nothing matches \u{201C}\(query)\u{201D}.")
                            .font(ui.callout)
                            .foregroundColor(CDPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ui.l)
                    }
                    ForEach(rows) { entry in
                        HistoryRow(entry: entry)
                        if entry.id != rows.last?.id {
                            // From the text column to the card's inner edge.
                            GlassDivider()
                                .padding(.leading, ui(CDLayout.cardPadding) + ui(32) + ui.m)
                                .padding(.trailing, ui(CDLayout.cardPadding))
                        }
                    }
                }
                // With the rows' own 10pt, the top and bottom match the side inset.
                .padding(.vertical, ui(CDLayout.cardPadding - 10))
                .glassPanel(cornerRadius: CDRadius.card)
            }
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
    @Environment(\.cdScale) private var ui
    let entry: HistoryEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ui.m) {
            ZStack(alignment: .bottomTrailing) {
                FileIcon(url: savedURLs.first, name: entry.files.first?.name ?? "", size: 32)
                Image(systemName: entry.isIncoming ? "arrow.down" : "arrow.up")
                    .font(ui.system(8, .heavy))
                    .foregroundColor(.white)
                    .frame(width: ui(15), height: ui(15))
                    .background(Circle().fill(entry.isIncoming ? CDPalette.mint : CDPalette.ink))
                    .offset(x: ui(3), y: ui(3))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .font(ui.font(13, .medium))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: ui.s)
            statusChip
            if entry.isIncoming, entry.status == "completed", !savedURLs.isEmpty {
                Button {
                    model.reveal(savedURLs)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            if canSendAgain {
                Button {
                    model.sendAgain(entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Send again")
                .accessibilityLabel("Send \(title) again")
            }
        }
        .padding(.horizontal, ui(CDLayout.cardPadding))
        .padding(.vertical, ui(10))
        .background(
            RoundedRectangle(cornerRadius: ui(CDRadius.row), style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.7 : 0))
                .padding(.horizontal, ui(8))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var savedURLs: [URL] {
        entry.files.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
    }

    /// Outgoing links, and outgoing files that are still where they were.
    private var canSendAgain: Bool {
        guard !entry.isIncoming else { return false }
        if entry.kind == "link" { return entry.link != nil }
        if entry.kind == "text" { return false }
        return !entry.files.isEmpty && entry.files.allSatisfy { $0.path != nil }
    }

    private var title: String {
        if entry.kind == "link" { return entry.link ?? "Link" }
        if entry.kind == "text" { return "Text" }
        let first = entry.files.first?.name ?? "Files"
        return entry.files.count > 1 ? "\(first) + \(entry.files.count - 1) more" : first
    }

    private var subtitle: String {
        let direction = entry.isIncoming ? "From \(entry.peerName)" : "To \(entry.peerName)"
        return "\(direction) · \(Format.bytes(entry.totalBytes)) · \(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var statusChip: some View {
        switch entry.status {
        case "completed": return Chip(text: entry.isIncoming ? "Received" : "Sent", tint: CDPalette.mint)
        case "rejected": return Chip(text: "Declined")
        case "cancelled": return Chip(text: "Cancelled")
        default: return Chip(text: "Failed", tint: CDPalette.coral)
        }
    }
}
