# CrossDrop

Send files between an Android phone and a Mac over your local network, the way
AirDrop works between Apple devices. No account, no cloud, no tracking: files go
directly from one device to the other, encrypted, after you pair them once by
comparing a 6-digit code.

> **Status: early test builds (0.1.0).** Both apps build in CI, the protocol is
> tested against shared vectors in Kotlin and Swift, and CI moves real files
> Kotlin↔Swift over TCP. Nothing has been verified on a physical phone and Mac
> yet. See [docs/testing-matrix.md](docs/testing-matrix.md).

## Download (test builds)

* Android APK: [CrossDrop.apk](https://github.com/dakshu007/Airdrop-Android-/releases/latest/download/CrossDrop.apk) (Android 10+)
* macOS DMG: [CrossDrop.dmg](https://github.com/dakshu007/Airdrop-Android-/releases/latest/download/CrossDrop.dmg) (macOS 13+, Apple silicon and Intel)

The Mac app is not notarized. On first launch macOS blocks it: open
**System Settings › Privacy & Security** and click **Open Anyway**, then allow
**Local Network** access when asked. The APK is signed with a public test key
unless a release key is configured; see [docs/release-process.md](docs/release-process.md).

## How it works

1. Pair once: on the Mac choose **Pair a phone** and scan the QR code with
   CrossDrop on the phone, or send something and compare the 6-digit code on
   both screens. Tick **This is my device** and its files arrive without asking.
2. Choose who can send to you: **My devices** (always ready for paired devices,
   invisible to everyone else), **Everyone** (anyone nearby, for 10 minutes on
   Android) or **Off**.
3. Send: Android share sheet (recent devices appear right in it), drag onto the
   Mac window or onto the menu bar icon, Finder › Services › Send with CrossDrop,
   or pick files and folders in the app. Send to several devices at once.
4. Each file is checked with SHA-256 before it appears in Downloads; nothing is
   ever overwritten. A transfer that drops mid-way continues where it stopped
   when you send it again.

Beyond files: send a **link** and it opens on the Mac (on the phone, one tap
opens it); send the **clipboard** from the Mac panel, the app, or the "Send
clipboard" Quick Settings tile. Optional: a notification offering to send each
new screenshot to the device you used last.

Both devices must be on the same Wi-Fi network and that network must allow
devices to talk to each other (many guest networks don't). QR pairing carries
the Mac's address, and paired devices remember the last address that worked,
so they can often still connect where discovery is blocked.
[More on network limitations](docs/macos-networking-limitations.md).

## Repository

| | |
|---|---|
| [docs/protocol-v1.md](docs/protocol-v1.md) | Wire protocol: discovery, framing, handshake, pairing, transfer |
| [docs/security-model.md](docs/security-model.md) | Threat model and honest limitations |
| [docs/architecture.md](docs/architecture.md) | How the pieces fit, repository layout |
| [docs/testing-matrix.md](docs/testing-matrix.md) | What has actually been tested |
| [docs/release-process.md](docs/release-process.md) | CI builds, signing, publishing |
| `android/` | React Native app (TypeScript UI, Kotlin native modules) |
| `android/core/` | Protocol engine in pure Kotlin + `crossdrop-cli` test tool |
| `macos/` | SwiftUI app and the Swift protocol engine |
| `protocol/test-vectors/` | Shared test vectors (Python reference generator) |
| `integration-tests/` | Kotlin↔Swift interop tests |

## Building

**Android** (Node 22, JDK 17, Android SDK):

```sh
cd android && npm ci
npm run typecheck && npm run lint && npm test
cd android && ./gradlew assembleRelease     # APK in app/build/outputs/apk/release/
```

**macOS** (Xcode 16+, `brew install xcodegen`):

```sh
cd macos && swift test
xcodegen generate
xcodebuild -project CrossDrop.xcodeproj -scheme CrossDrop -configuration Release -derivedDataPath build build
```

**Protocol core only** (any JDK 17+): `android/android/gradlew -p android/core test`

`scripts/dev-checks.sh` runs the checks that need neither the Android SDK nor Xcode.

## Privacy

CrossDrop has no servers. It uses mDNS/Bonjour to find devices on your network
and a direct TCP connection to send files. Transfer history and trusted devices
stay on your device. There is no analytics or telemetry.
