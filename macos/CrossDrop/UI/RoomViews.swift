import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

// Drip Rooms (§9.9): everyone at a meeting can pair with each other without comparing
// codes, until the room ends (at most 4 hours). Trust from a room is temporary and never
// accepts files automatically. These views show the room; AppModel runs it.

// MARK: - Clock

enum RoomClock {
    static func secondsLeft(_ room: Room, now: Date) -> Int {
        max(0, Int(room.expiryDate.timeIntervalSince(now).rounded(.down)))
    }

    /// "1:42:05" or "41:23".
    static func digits(_ room: Room, now: Date) -> String {
        let left = secondsLeft(room, now: now)
        let hours = left / 3600, minutes = (left % 3600) / 60, seconds = left % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
    }

    /// "Ends in 42 min", "Ends in 1 h 5 min", "Ends in under a minute".
    static func short(_ room: Room, now: Date) -> String {
        let left = secondsLeft(room, now: now)
        if left < 60 { return "Ends in under a minute" }
        let hours = left / 3600, minutes = (left % 3600) / 60
        if hours == 0 { return "Ends in \(minutes) min" }
        return minutes == 0 ? "Ends in \(hours) h" : "Ends in \(hours) h \(minutes) min"
    }

    /// For VoiceOver: "Ends in 1 hour, 42 minutes".
    static func spoken(_ room: Room, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        let left = TimeInterval(max(60, secondsLeft(room, now: now)))
        return "Ends in " + (formatter.string(from: left) ?? "")
    }

    /// The end time as a clock time: "15:30".
    static func endTime(_ room: Room) -> String {
        room.expiryDate.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Devices page card

/// Devices page: start a room, or the room in progress with its countdown and members.
/// Hosts the room sheet (also opened from the menu bar's quick menu).
struct RoomCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var confirmEnd = false

    var body: some View {
        Group {
            if let room = model.currentRoom {
                active(room)
            } else {
                idle
            }
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .sheet(isPresented: $model.showingRoomSheet) {
            RoomSheet()
                .environmentObject(model)
                .environment(\.cdScale, ui.fitting(height: 840))
        }
    }

    private var idle: some View {
        HStack(spacing: ui.l) {
            RoomEmblem(active: false, size: 50)
            VStack(alignment: .leading, spacing: ui(4)) {
                Text("Drip Rooms")
                    .font(ui.headline)
                    .foregroundColor(CDPalette.textPrimary)
                Text("At a meeting? Start a room and show its code. Everyone who scans it can swap files with each other without comparing codes, until the room ends.")
                    .font(ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Start a Room") { model.showingRoomSheet = true }
                .buttonStyle(PrimaryButtonStyle())
                .help("Choose a name and how long it lasts, then show the code")
        }
    }

    private func active(_ room: Room) -> some View {
        let members = model.roomMembers.count
        let memberText = members == 1 ? "1 member" : "\(members) members"
        return HStack(spacing: ui.l) {
            RoomEmblem(active: true, size: 50)
            VStack(alignment: .leading, spacing: ui(4)) {
                HStack(spacing: ui.s) {
                    Text(room.name)
                        .font(ui.headline)
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Chip(text: model.roomIsHosted ? "Hosting" : "Joined",
                         symbol: model.roomIsHosted ? "dot.radiowaves.left.and.right" : "person.2.fill",
                         tint: CDPalette.mint)
                }
                // A coarse countdown here; the sheet shows the seconds.
                TimelineView(.periodic(from: Date(), by: 15)) { context in
                    Text(RoomClock.short(room, now: context.date) + " · " + memberText)
                        .font(ui.callout.monospacedDigit())
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel(RoomClock.spoken(room, now: context.date) + ", " + memberText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show Code") { model.showingRoomSheet = true }
                .buttonStyle(PrimaryButtonStyle())
            Button("End") { confirmEnd = true }
                .buttonStyle(GlassButtonStyle(destructive: true))
                .help("Ends the room now. Its members stop being trusted on this Mac.")
                .accessibilityLabel("End room \(room.name)")
        }
        .endRoomConfirmation(isPresented: $confirmEnd, room: room) { model.endRoom() }
    }
}

extension View {
    /// "End <room> now?" before ending a room: its members lose their trust on this Mac.
    func endRoomConfirmation(isPresented: Binding<Bool>, room: Room, end: @escaping () -> Void) -> some View {
        confirmationDialog("End \u{201C}\(room.name)\u{201D} now?", isPresented: isPresented, titleVisibility: .visible) {
            Button("End Room", role: .destructive, action: end)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its members stop being trusted on this Mac, and the code stops working here.")
        }
    }
}

/// Three soft discs: the room symbol. Static; a mint rim marks a live room.
struct RoomEmblem: View {
    let active: Bool
    var size: CGFloat = 50
    @Environment(\.cdScale) private var ui

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? LinearGradient(colors: [CDPalette.mintLight, CDPalette.mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                             : LinearGradient(colors: [Color(hex: 0xF4FBF6), Color(hex: 0xE3F5E8)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(active ? 0.6 : 1), lineWidth: 1)
            Image(systemName: "person.3.fill")
                .font(ui.system(size * 0.34, .semibold))
                .foregroundColor(active ? .white : CDPalette.sky)
        }
        .frame(width: ui(size), height: ui(size))
        .shadow(color: CDPalette.mint.opacity(active ? 0.28 : 0), radius: ui(8), x: 0, y: ui(3))
        .accessibilityHidden(true)
    }
}

// MARK: - Sheet

/// Start a room (name, duration) or show the live one: big QR code, countdown, members, End.
struct RoomSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: ui.l) {
            HStack {
                Spacer()
                Button {
                    model.showingRoomSheet = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, -ui(8))

            if let room = model.currentRoom {
                RoomLiveContent(room: room)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            } else {
                RoomSetupContent()
                    .transition(.opacity)
            }
        }
        .padding(ui(28))
        .frame(width: ui(480))
        .background(MintBackdrop(mood: model.currentRoom == nil ? .idle : .done))
        .environment(\.colorScheme, .light)
        .animation(CDMotion.layout(reduceMotion), value: model.currentRoom)
    }
}

/// No room yet: name it, pick how long it lasts, start. Or join one from a pasted code.
private struct RoomSetupContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var name = ""
    @State private var duration = RoomDuration.oneHour
    @State private var joinCode = ""
    @State private var showingJoin = false
    @FocusState private var focus: Field?

    private enum Field { case name, code }

    var body: some View {
        VStack(spacing: ui.l) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xBEF5AA, opacity: 0.6), Color(hex: 0xBEF5AA, opacity: 0)],
                                         center: .center, startRadius: 0, endRadius: ui(80)))
                    .frame(width: ui(170), height: ui(170))
                DripView(pose: .nearby, size: 130, motion: .bob)
            }
            .frame(height: ui(120))
            .accessibilityHidden(true)

            VStack(spacing: ui(6)) {
                Text("Start a Drip Room")
                    .font(ui.font(24, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                Text("Everyone who scans the room's code can send files to each other without comparing codes, until it ends.")
                    .font(ui.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: ui.m) {
                VStack(alignment: .leading, spacing: ui(6)) {
                    Text("Room name")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                    TextField("\(model.deviceName)\u{2019}s room", text: $name)
                        .textFieldStyle(.plain)
                        .font(ui.body)
                        .foregroundColor(CDPalette.textPrimary)
                        .focused($focus, equals: .name)
                        .padding(.horizontal, ui(12))
                        .frame(height: ui(36))
                        .glassPanel(cornerRadius: CDRadius.field, style: .inset)
                        .modifier(FieldFocusBorder(focused: focus == .name, radius: CDRadius.field))
                        .onSubmit(start)
                        .accessibilityLabel("Room name")
                }
                VStack(alignment: .leading, spacing: ui(6)) {
                    Text("Lasts")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                    SegmentedGlass(choices: RoomDuration.allCases.map { SegmentChoice(id: Int($0.rawValue), label: $0.title) },
                                   selection: Binding(get: { Int(duration.rawValue) },
                                                      set: { duration = RoomDuration(rawValue: Int64($0)) ?? .oneHour }),
                                   accessibilityName: "How long the room lasts",
                                   fillsWidth: true)
                }
            }
            .padding(ui.l)
            .glassPanel(cornerRadius: CDRadius.card)

            if !model.canHostRoom {
                HStack(alignment: .center, spacing: ui.m) {
                    Image(systemName: "moon.zzz.fill")
                        .font(ui.system(15, .semibold))
                        .foregroundColor(CDPalette.amber)
                        .accessibilityHidden(true)
                    Text("Receiving is off. A room needs it on; My Devices is enough, and room members can still reach you.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Use My Devices") { model.setReceiveMode(.mine) }
                        .buttonStyle(GlassButtonStyle())
                }
                .padding(ui.m)
                .glassPanel(cornerRadius: CDRadius.tile, style: .inset)
            }

            Button(action: start) {
                Label("Start Room", systemImage: "person.3.fill")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canHostRoom)

            joinSection

            Label("Anyone who can see the code can join until the room ends, so treat it like a meeting password. Room members are trusted only until then, and you still approve every file they send.",
                  systemImage: "lock.shield")
                .font(ui.caption)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ui(380))
        }
        .onAppear { focus = .name }
    }

    @ViewBuilder
    private var joinSection: some View {
        if showingJoin {
            VStack(alignment: .leading, spacing: ui(6)) {
                HStack(spacing: ui.s) {
                    TextField("Paste a crossdrop://room code", text: $joinCode)
                        .textFieldStyle(.plain)
                        .font(ui.callout)
                        .foregroundColor(CDPalette.textPrimary)
                        .focused($focus, equals: .code)
                        .padding(.horizontal, ui(12))
                        .frame(height: ui(32))
                        .glassPanel(cornerRadius: CDRadius.field, style: .inset)
                        .modifier(FieldFocusBorder(focused: focus == .code, radius: CDRadius.field))
                        .onSubmit(join)
                        .accessibilityLabel("Room code")
                    Button("Join", action: join)
                        .buttonStyle(GlassButtonStyle())
                        .disabled(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("This Mac finds room members through discovery on your network. Networks that keep devices from seeing each other can stop it from finding them.")
                    .font(ui.font(10.5))
                    .foregroundColor(CDPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        } else {
            Button("Have a room code? Join instead") {
                showingJoin = true
                focus = .code
            }
            .buttonStyle(TextLinkButtonStyle())
        }
    }

    private func start() {
        guard model.canHostRoom else { return }
        model.startRoom(name: name, duration: duration)
    }

    private func join() {
        let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if model.joinRoom(inviteURI: code) { joinCode = "" }
    }
}

/// The live room: QR code, seconds-accurate countdown, members, Copy Code and End Room.
private struct RoomLiveContent: View {
    let room: Room
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var confirmEnd = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: ui.l) {
            VStack(spacing: ui(6)) {
                HStack(spacing: ui.s) {
                    Text(room.name)
                        .font(ui.font(24, .bold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Chip(text: model.roomIsHosted ? "Hosting" : "Joined",
                         symbol: model.roomIsHosted ? "dot.radiowaves.left.and.right" : "person.2.fill",
                         tint: CDPalette.mint)
                }
                Text("Others scan this with CrossDrop to join. Until \(RoomClock.endTime(room)), you can swap files without comparing codes.")
                    .font(ui.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            qrTile

            countdown

            HStack(spacing: ui.s) {
                Button {
                    copyCode()
                } label: {
                    Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.roomInviteURI() == nil)
                .help("Copies the room code as text, marked private so clipboard managers skip it")
                Button("End Room") { confirmEnd = true }
                    .buttonStyle(GlassButtonStyle(destructive: true))
            }

            members

            Label("Anyone who can see this code can join until the room ends. Treat it like a meeting password. You still approve every file a member sends.",
                  systemImage: "lock.shield")
                .font(ui.caption)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ui(380))
        }
        .endRoomConfirmation(isPresented: $confirmEnd, room: room) { model.endRoom() }
    }

    private var qrTile: some View {
        ZStack {
            // A soft mint halo behind the code: static, so nothing moves while it's shown.
            RoundedRectangle(cornerRadius: ui(CDRadius.panel + 8), style: .continuous)
                .fill(RadialGradient(colors: [CDPalette.mintLight.opacity(0.45), CDPalette.mintLight.opacity(0)],
                                     center: .center, startRadius: ui(100), endRadius: ui(200)))
                .frame(width: ui(330), height: ui(330))
                .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: ui(CDRadius.panel), style: .continuous)
                .fill(Color.white)
                .shadow(color: CDPalette.shadow.opacity(0.12), radius: ui(16), x: 0, y: ui(8))
                .frame(width: ui(272), height: ui(272))
            RoundedRectangle(cornerRadius: ui(CDRadius.panel), style: .continuous)
                .strokeBorder(CDPalette.controlBorder, lineWidth: 1)
                .frame(width: ui(272), height: ui(272))
            if let uri = model.roomInviteURI(), let image = QRCode.image(for: uri) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: ui(228), height: ui(228))
                    .accessibilityLabel("Room code for \(room.name). Others scan it with CrossDrop to join.")
            } else {
                VStack(spacing: ui(10)) {
                    Image(systemName: model.receivingEnabled ? "wifi.exclamationmark" : "moon.zzz")
                        .font(ui.system(30))
                        .foregroundColor(CDPalette.textTertiary)
                    Text(model.receivingEnabled ? "Waiting for the network…" : "Receiving is off, so no one can reach this Mac")
                        .font(ui.callout)
                        .foregroundColor(CDPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.receivingEnabled {
                        Button("Turn On for My Devices") { model.setReceiveMode(.mine) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(ui.l)
                .frame(width: ui(250))
            }
        }
        .frame(height: ui(300))
    }

    private var countdown: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let left = RoomClock.secondsLeft(room, now: context.date)
            HStack(spacing: ui(8)) {
                Image(systemName: "timer")
                    .font(ui.system(13, .semibold))
                    .foregroundColor(left < 300 ? CDPalette.amber : CDPalette.mint)
                Text(RoomClock.digits(room, now: context.date))
                    .font(ui.font(20, .semibold).monospacedDigit())
                    .foregroundColor(CDPalette.textPrimary)
                Text("left · ends \(RoomClock.endTime(room))")
                    .font(ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
            }
            .padding(.horizontal, ui(16))
            .padding(.vertical, ui(8))
            .background(Capsule().fill(Color.white.opacity(0.85)))
            .overlay(Capsule().strokeBorder(left < 300 ? Color(hex: 0xF0DFB0) : CDPalette.controlBorder, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RoomClock.spoken(room, now: context.date))
        }
    }

    @ViewBuilder
    private var members: some View {
        let joined = model.roomMembers
        let joinedIds = Set(joined.map { $0.deviceId })
        let nearbyOnly = model.roomDevicesNearby.filter { !joinedIds.contains($0.deviceId) && !model.isTrusted($0.deviceId) }
        let shown = Array(joined.prefix(4))
        VStack(alignment: .leading, spacing: ui(6)) {
            SectionHeader(title: "Members", detail: joined.isEmpty ? nil : "\(joined.count)")
            if joined.isEmpty && nearbyOnly.isEmpty {
                HStack(spacing: ui.m) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(ui.system(18))
                        .foregroundColor(CDPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text("No one yet. Members appear here once they've joined and connected to this Mac.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, ui(6))
            }
            ForEach(shown) { record in
                memberRow(name: record.name, platform: record.platform, detail: "Trusted until \(RoomClock.endTime(room))", joined: true)
            }
            if joined.count > shown.count {
                Text("+\(joined.count - shown.count) more")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
            }
            ForEach(nearbyOnly.prefix(3)) { device in
                memberRow(name: device.name, platform: device.platform, detail: "Nearby in this room · not connected yet", joined: false)
            }
        }
        .padding(ui.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .accessibilityElement(children: .contain)
    }

    private func memberRow(name: String, platform: String?, detail: String, joined: Bool) -> some View {
        HStack(spacing: ui.m) {
            DeviceAvatar(platform: platform, size: 30)
            VStack(alignment: .leading, spacing: ui(1)) {
                Text(name)
                    .font(ui.font(12.5, .medium))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(ui.font(10.5))
                    .foregroundColor(CDPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if joined {
                Image(systemName: "checkmark.seal.fill")
                    .font(ui.system(13))
                    .foregroundColor(CDPalette.mint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, ui(4))
        .accessibilityElement(children: .combine)
    }

    /// The code as text, marked concealed so clipboard managers (and CrossDrop's own
    /// "Send what I copy to my phone") leave it alone: it is the room's password.
    private func copyCode() {
        guard let uri = model.roomInviteURI() else { return }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(uri, forType: .string)
        pasteboard.setString("", forType: concealed)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

/// A quiet text link in the accent green, with the focus ring for keyboard navigation.
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.cdScale) private var ui
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(ui.font(12, .medium))
                .foregroundColor(CDPalette.sky)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .padding(.horizontal, ui(6))
                .padding(.vertical, ui(3))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Capsule()))
        }
    }
}
