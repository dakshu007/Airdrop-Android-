import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// "Pair a phone": a QR code the phone scans in CrossDrop › Devices. The code holds a
/// one-time token (5 minutes) and this Mac's key fingerprint, so the phone pairs with
/// exactly this Mac and nobody has to compare numbers (protocol §9.4).
struct PairPhoneSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var mine = true
    @State private var uri: String?
    @State private var refresh = Date()
    private let timer = Timer.publish(every: 240, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: CDSpacing.l) {
            HStack {
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            VStack(spacing: 6) {
                Text("Pair a phone")
                    .font(CDFont.poppins(26, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                Text("On your phone, open CrossDrop › Devices › Scan pairing code.")
                    .font(CDFont.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .legibleText()

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color(hex: 0x185434, opacity: 0.12), radius: 18, x: 0, y: 8)
                if let uri = uri, let image = QRCode.image(for: uri) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .padding(22)
                        .accessibilityLabel("Pairing QR code. Scan it with CrossDrop on your phone.")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: model.receivingEnabled ? "wifi.exclamationmark" : "moon.zzz")
                            .font(.system(size: 30))
                            .foregroundColor(CDPalette.textTertiary)
                        Text(model.receivingEnabled ? "Waiting for the network…" : "Receiving is off")
                            .font(CDFont.callout)
                            .foregroundColor(CDPalette.textSecondary)
                        if !model.receivingEnabled {
                            Button("Turn On for My Devices") { model.setReceiveMode(.mine) }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding()
                }
            }
            .frame(width: 280, height: 280)

            Toggle(isOn: $mine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This is my phone")
                        .font(CDFont.headline)
                        .foregroundColor(CDPalette.textPrimary)
                    Text("Files from it arrive without asking.")
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textSecondary)
                }
            }
            .toggleStyle(GlassToggleStyle())
            .frame(maxWidth: 320)

            Label("The code works once and expires in 5 minutes. It only lets a phone that can see this screen pair; it can't be used to read files.",
                  systemImage: "lock.shield")
                .font(CDFont.caption)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .padding(28)
        .frame(width: 440)
        .background(MintBackdrop(mood: .idle))
        .environment(\.colorScheme, .light)
        .onAppear(perform: regenerate)
        .onChange(of: mine) { _ in regenerate() }
        .onChange(of: model.listeningPort) { _ in regenerate() }
        .onReceive(timer) { _ in regenerate() }
        .onDisappear { model.endPairingCodes() }
    }

    private func regenerate() {
        // A fresh one-time token each time (earlier ones are revoked, so only the code
        // on screen works).
        model.endPairingCodes()
        uri = model.pairingURI(mine: mine)
    }

    private func close() {
        model.showingPairSheet = false
    }
}

enum QRCode {
    /// A crisp QR image (medium error correction) for `text`.
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
