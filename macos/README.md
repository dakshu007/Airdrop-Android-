# CrossDrop for macOS

Native SwiftUI menu-bar app plus a Swift package with the protocol engine.

```
macos/
  Package.swift              Swift package: CrossDropCore library, crossdrop-cli, tests
  Sources/CrossDropCore/     Protocol v1 engine (Foundation, CryptoKit, Network only)
  Sources/crossdrop-cli/     Headless sender/receiver for the CI interop job
  Tests/CrossDropCoreTests/  Test vectors + loopback tests over 127.0.0.1
  CrossDrop/                 SwiftUI app (App, MenuBar, UI, Pairing, Transfer, Storage, Resources)
  project.yml                XcodeGen spec for the app target
```

The app target compiles `Sources/CrossDropCore` directly, so the app and the
tests use the same engine source.

Minimum macOS: 13.0 (Ventura), because of `MenuBarExtra` and the `Window` scene.
Only the CI build has been verified so far. No real-hardware test has been
recorded in `docs/testing-matrix.md` yet. On macOS 26 the surfaces use SwiftUI's
public `glassEffect` API; earlier versions use layered materials.

## Build

Requirements: Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd macos
swift test                      # protocol vectors + loopback transfers
xcodegen generate
xcodebuild -project CrossDrop.xcodeproj -scheme CrossDrop -configuration Release \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
../scripts/build-dmg.sh build/Build/Products/Release/CrossDrop.app CrossDrop.dmg
```

Interop CLI (used by CI against the Kotlin implementation):

```sh
swift build -c release --product crossdrop-cli
.build/release/crossdrop-cli receive --port 47000 --dir /tmp/in --identity /tmp/r.key --once
.build/release/crossdrop-cli send --host 127.0.0.1 --port 47000 --identity /tmp/s.key file1 file2
```

It prints `LISTENING <port>`, `SAS <code>`, `RECEIVED <name> <sha256>` and
`COMPLETE <transferId>`. On failure it writes `ERROR <code>` to stderr and
exits 1.

## First launch of an unsigned build

The DMG is ad-hoc signed and not notarized, because there is no paid Apple
Developer account. macOS will refuse to open it the first time. To open it:

1. Drag CrossDrop to Applications and open it. macOS says it can't verify the developer.
2. Open **System Settings › Privacy & Security** and scroll to the message about CrossDrop.
3. Click **Open Anyway**, then confirm with your password or Touch ID.

CrossDrop never changes Gatekeeper or firewall settings.

Other prompts you may see:

- **Local Network**: macOS asks whether CrossDrop may find devices on your
  local network. Without it, discovery and receiving can't work. You can change
  this later in System Settings › Privacy & Security › Local Network.
- **Keychain**: the device identity key is stored in your login Keychain. An
  ad-hoc signature changes with every build, so after an update macOS may ask
  whether CrossDrop may keep using its key. Choose **Always Allow**. If you deny
  it, CrossDrop makes a new identity and paired devices must pair again.
- **Firewall**: if the macOS firewall is on with "Block all incoming
  connections", other devices can't send to this Mac.
