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
opens it); send the **clipboard** from the Mac panel, the app, the "Send
clipboard" Quick Settings tile or the home-screen widget. Optional: a
notification offering to send each new screenshot to the device you used last.

### Newer features (written, not yet tried on real devices)

These are in the code and build in CI. Their protocol parts pass the Kotlin and
Swift tests and the Kotlin↔Swift interop, and the Android screens pass render
tests, but nothing here has been used on a physical phone and Mac yet.

* **Send when nearby.** Sending to a paired device that isn't around offers to
  wait: the send is kept and goes as soon as the device shows up (Activity tab on
  Android, queue on the Mac, with Retry and Cancel). No background scanning: the
  phone looks for one minute at app start and when Wi‑Fi changes; the Mac tries
  at launch, wake, network changes and whenever discovery is already running.
* **Take a photo with the phone** (Mac menu bar or Send page): asks a paired phone for a new
  or existing photo. The phone shows a notification (or a full-screen prompt if
  CrossDrop is open); the photo comes back without a prompt and lands on the
  Mac's clipboard and in its receive folder.
* **Drip Island** (Mac): while you drag files anywhere, a glass island drops
  from the top of the screen with nearby devices and the Shelf. Can be switched off.
* **Shelf** (Mac): park files and folders for later, then send them or drag
  them out again. **Pocket** (Android): your last 30 received files with Open,
  Share and Remove.
* **Clipboard.** Mac, opt-in "Send what I copy to my phone": text you copy goes
  to a phone marked "This is my device" while the Mac can see it. Android shows
  text from a Mac as a "Paste from …" pill for two minutes; nothing touches the
  phone's clipboard until you tap Copy.
* **Drip Rooms:** start a room (30 min to 4 h) and show its QR code. Phones
  scan it, Macs paste the code; members then pair with each other without
  comparing codes until the room ends. Each file is still approved, and room
  trust ends with the room.
* **Expiring drops:** ask the receiver to delete files 24 h after they arrive.
  Android deletes its copies (possibly a little late); the Mac moves them to the
  Trash and offers Keep. This is a courtesy the receiver can ignore or work around.
* **Smart arrival** (off by default): sort received files by type. Android:
  Pictures / Movies / Music / Download › CrossDrop. Mac: photos to
  Pictures › CrossDrop › From *device* – *date*, documents to Documents › CrossDrop.
* **Haptic heartbeat** (Android): a light tick every 10% of a transfer, following
  the in-app and system haptics settings. On a Force Touch trackpad the Mac
  gives one tap when a transfer finishes.
* **Home-screen widget** (Android): up to three paired devices and a Clipboard
  button. There is no Mac widget: it needs a signed App Group, which the free unsigned
  build can't have.
* **Turbo (experimental, off by default):** a multi-file send asks for up to 4
  parallel connections. Any speed gain is unmeasured.

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
stay on your device. There is no analytics or telemetry. The Mac only looks at
the clipboard if you turn on "Send what I copy to my phone", and the phone
never reads its clipboard in the background. What each feature stores, and its
limits, is in [docs/security-model.md](docs/security-model.md).
