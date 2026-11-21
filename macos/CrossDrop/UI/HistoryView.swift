import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false
    @State private var query = ""

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
        PageScroll {
            HStack(alignment: .bottom) {
                PageTitle(title: "History", subtitle: "Stored only on this Mac.")
                if !model.history.isEmpty {
                    Button("Clear History…") { confirmClear = true }
                        .buttonStyle(GlassButtonStyle(destructive: true))
                }
            }
            if model.history.isEmpty {
                StateMessage(symbol: "clock.arrow.circlepath", title: "Nothing here yet",
                             message: "Finished transfers are listed here. The list never leaves this Mac.")
                    .glassPanel(cornerRadius: CDRadius.card)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(CDPalette.textTertiary)
                    TextField("Search files, links or devices", text: $query)
                        .textFieldStyle(.plain)
                        .font(CDFont.body)
                        .accessibilityLabel("Search history")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(CDPalette.textTertiary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, CDSpacing.m)
                .frame(height: 38)
                .glassPanel(cornerRadius: 14, style: .inset)
                .frame(maxWidth: 420)

                let rows = filtered
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("Nothing matches \u{201C}\(query)\u{201D}.")
                            .font(CDFont.callout)
                            .foregroundColor(CDPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CDSpacing.l)
                    }
                    ForEach(rows) { entry in
                        HistoryRow(entry: entry)
                        if entry.id != rows.last?.id {
                            GlassDivider().padding(.leading, 64)
                        }
                    }
                }
                .padding(.vertical, 6)
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
    let entry: HistoryEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: CDSpacing.m) {
            ZStack(alignment: .bottomTrailing) {
                FileIcon(url: savedURLs.first, name: entry.files.first?.name ?? "", size: 32)
                Image(systemName: entry.isIncoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(entry.isIncoming ? CDPalette.mint : CDPalette.ink))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CDFont.body.weight(.medium))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: CDSpacing.s)
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
        .padding(.horizontal, CDSpacing.l)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CDRadius.row, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.7 : 0))
                .padding(.horizontal, 6)
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
