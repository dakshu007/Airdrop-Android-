import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

// The Shelf ("Pocket"): files and folders kept for later. Only their paths are remembered;
// the files stay where they are. Items can be dragged out to any app, added to the Send
// tray, or sent straight to a nearby device.

/// Send page: the Shelf as a glass card with a horizontal strip of items. Files dropped on
/// the card are stashed.
struct ShelfCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    var body: some View {
        let missing = model.missingShelfIds.count
        VStack(alignment: .leading, spacing: ui.m) {
            HStack(spacing: ui.s) {
                SectionHeader(title: "Shelf", detail: "\(Format.items(model.shelf.count)) kept for later")
                Button("Add All to Send") { model.addShelfToSelection() }
                    .buttonStyle(GlassButtonStyle())
                    .help("Put everything on the Shelf in Ready to send")
                Button("Clear") { model.clearShelf() }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .help("Empties the Shelf. The files themselves stay where they are.")
                    .accessibilityLabel("Clear Shelf")
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ui.s) {
                    ForEach(model.shelf) { item in
                        ShelfTile(item: item)
                    }
                }
                // Room for hover lift and focus rings inside the scroll view's clip.
                .padding(ui(4))
            }
            .scrollIndicators(.automatic)
            .padding(.horizontal, -ui(4))

            HStack(alignment: .firstTextBaseline, spacing: ui.s) {
                Text("Click to add to Ready to send, drag out to any app, or right-click to send straight to a device. Only the location is remembered; nothing is copied.")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if missing > 0 {
                    Button(missing == 1 ? "Remove 1 Missing" : "Remove \(missing) Missing") {
                        model.removeMissingFromShelf()
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Removes items whose file was moved or deleted")
                }
            }
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .overlay(ShelfDropHighlight(targeted: targeted, radius: CDRadius.card))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            model.stash(providers: providers)
            return true
        }
        .animation(reduceMotion ? nil : CDMotion.quick, value: targeted)
        .animation(CDMotion.layout(reduceMotion), value: model.shelf)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf, \(Format.items(model.shelf.count))")
        .accessibilityHint("Drop files here to keep them for later.")
    }
}

/// Menu bar panel: a slim Shelf row. Always present so it can be dropped on; the strip of
/// items appears once something is kept.
struct MenuBarShelf: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: ui.s) {
            HStack(spacing: ui.s) {
                Image(systemName: model.shelf.isEmpty ? "tray" : "tray.full.fill")
                    .font(ui.system(12, .semibold))
                    .foregroundColor(CDPalette.mint)
                    .accessibilityHidden(true)
                Text("Shelf")
                    .font(ui.font(12.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                if !model.shelf.isEmpty {
                    Text("\(model.shelf.count)")
                        .font(ui.font(10, .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, ui(6))
                        .padding(.vertical, ui(1))
                        .background(Capsule().fill(CDPalette.ink))
                        .accessibilityLabel(Format.items(model.shelf.count))
                }
                Spacer(minLength: 0)
                if model.shelf.isEmpty {
                    Text(targeted ? "Release to keep" : "Drop files to keep for later")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .lineLimit(1)
                } else {
                    Button("Add to Send") { model.addShelfToSelection() }
                        .buttonStyle(GlassButtonStyle())
                        .help("Put everything on the Shelf in the send list")
                }
            }
            if !model.shelf.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ui(6)) {
                        ForEach(model.shelf) { item in
                            ShelfTile(item: item, compact: true)
                        }
                    }
                    .padding(ui(3))
                }
                .scrollIndicators(.never)
                .padding(.horizontal, -ui(3))
            }
        }
        .padding(ui.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .overlay(ShelfDropHighlight(targeted: targeted, radius: CDRadius.card))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            model.stash(providers: providers)
            return true
        }
        .animation(reduceMotion ? nil : CDMotion.quick, value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf")
        .accessibilityHint("Drop files here to keep them for later.")
    }
}

/// One kept file or folder. Click adds it to the send list; drag it out to use it anywhere.
struct ShelfTile: View {
    @EnvironmentObject private var model: AppModel
    let item: ShelfItem
    var compact = false
    @Environment(\.cdScale) private var ui
    @State private var hovering = false

    var body: some View {
        let present = model.isPresent(item)
        Button {
            if present {
                model.addShelfToSelection([item])
            } else {
                model.removeFromShelf(item)
            }
        } label: {
            VStack(spacing: ui(compact ? 3 : 6)) {
                ZStack(alignment: .bottomTrailing) {
                    FileIcon(url: present ? item.url : nil, name: item.name, size: compact ? 30 : 42)
                        .opacity(present ? 1 : 0.35)
                    if !present {
                        Image(systemName: "questionmark.circle.fill")
                            .font(ui.system(compact ? 10 : 13, .bold))
                            .foregroundColor(CDPalette.amber)
                            .background(Circle().fill(Color.white))
                            .offset(x: ui(3), y: ui(3))
                    }
                }
                .frame(height: ui(compact ? 32 : 44))
                Text(item.name)
                    .font(ui.font(compact ? 9.5 : 11, .medium))
                    .foregroundColor(present ? CDPalette.textPrimary : CDPalette.textTertiary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if !compact {
                    Text(detail(present: present))
                        .font(ui.font(10).monospacedDigit())
                        .foregroundColor(present ? CDPalette.textTertiary : CDPalette.amberText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, ui(compact ? 5 : 8))
            .padding(.vertical, ui(compact ? 6 : 10))
            .frame(width: ui(compact ? 66 : 104))
        }
        .buttonStyle(TileButtonStyle())
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    model.removeFromShelf(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: compact ? 18 : 22))
                .offset(x: ui(5), y: -ui(5))
                .help("Remove from the Shelf (the file stays where it is)")
                .accessibilityLabel("Remove \(item.name) from the Shelf")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { present ? item.itemProvider : NSItemProvider() }
        .contextMenu { menu(present: present) }
        .help(present ? "\(item.name)\nClick to add to the send list, or drag it out to any app."
                      : "\(item.name) was moved or deleted. Click to remove it from the Shelf.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(detail(present: present))
        .accessibilityHint(present ? "Adds it to the files ready to send" : "Removes it from the Shelf")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if present { model.addShelfToSelection([item]) } else { model.removeFromShelf(item) }
        }
        .accessibilityAction(named: "Remove from Shelf") { model.removeFromShelf(item) }
        .accessibilityAction(named: "Show in Finder") { model.revealShelfItems([item]) }
    }

    private func detail(present: Bool) -> String {
        guard present else { return "Moved or deleted" }
        return item.isFolder ? "Folder" : Format.bytes(item.size)
    }

    @ViewBuilder
    private func menu(present: Bool) -> some View {
        if present {
            Button("Add to Send") { model.addShelfToSelection([item]) }
            let devices = model.nearby
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Button("Send to \(device.name)") { model.sendShelf([item], to: device) }
                }
            }
            Divider()
            Button("Show in Finder") { model.revealShelfItems([item]) }
        }
        Button("Remove from Shelf") { model.removeFromShelf(item) }
    }
}

/// Mint rim while files hover over a Shelf drop target.
struct ShelfDropHighlight: View {
    let targeted: Bool
    let radius: CGFloat
    @Environment(\.cdScale) private var ui

    var body: some View {
        RoundedRectangle(cornerRadius: ui(radius), style: .continuous)
            .strokeBorder(CDPalette.mint.opacity(targeted ? 0.85 : 0), lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: ui(radius), style: .continuous)
                    .fill(CDPalette.mintLight.opacity(targeted ? 0.12 : 0))
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension Format {
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
