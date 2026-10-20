# CrossDrop — Claude Code Project Brief

> Build CrossDrop as a polished, privacy-first, AirDrop-inspired file-transfer app between Android and macOS. UI/UX quality is a core requirement, not a finishing task.
>
> **Important scope boundary:** Do not build a landing page, website, download page, or marketing site in this project. We will build those only after the apps have been tested and proven reliable.

## 1. Product vision

CrossDrop lets people send files wirelessly between an Android phone and a Mac on a local network, with a frictionless experience inspired by AirDrop.

- Android → Mac: share files from Android's native Share Sheet, discover a nearby Mac, choose it, and send.
- Mac → Android: drag files from Finder into CrossDrop on the Mac, select a paired Android device, and send.
- Receive on either platform with clear approval, progress, cancellation, and completion feedback.
- Keep the core experience free and avoid paid APIs, cloud storage, accounts, analytics services, or a backend.
- Be honest about platform constraints: same-network transfer is the reliable initial path. Router-free/direct Wi-Fi operation is an experimental later milestone, not a launch guarantee.

## 2. Non-negotiable principles

1. **Exceptional UI/UX:** premium, intentional, native-feeling, carefully animated, and polished across every screen and state.
2. **Liquid Glass-inspired design:** translucent layered surfaces, subtle blur, depth, specular highlights, soft gradients, and fluid motion. Use these effects tastefully and maintain legibility. Do not copy Apple's UI pixel-for-pixel or claim to use Apple's private design APIs.
3. **Local-first privacy:** file payloads are transferred directly between paired devices over the local network. No cloud file-transfer relay or account is required.
4. **Security by design:** authenticated pairing, encrypted transport, explicit approval, safe file handling, integrity checks, and least-privilege permissions.
5. **Reliable transfers:** streaming I/O, bounded memory, cancellation, timeouts, clear error recovery, and integrity verification.
6. **Battery-conscious:** no endless high-frequency scans or polling while idle.
7. **Zero-cost development/distribution target:** use available free/open-source tools and avoid paid services. macOS builds may be unsigned and may trigger Gatekeeper warnings. Never attempt to bypass or disable macOS security globally.
8. **Accessibility:** adequate contrast, scalable text, VoiceOver/TalkBack labels, reduced-motion support, keyboard navigation on Mac, and clear focus states.
9. **No fake functionality:** controls must work. If a capability is not implemented, show a clear disabled/coming-later state instead of pretending it works.
10. **Test before claiming:** do not claim a transfer speed, security guarantee, or router-free compatibility without verification.

## 3. Architecture and stack

### Android

- React Native + TypeScript for the application UI.
- Kotlin native modules for networking, service discovery, file access, Android Share Sheet integration, notifications, and transfer lifecycle.
- Keep bulk file bytes out of the JavaScript bridge. Stream payloads natively.
- Android NSD/DNS-SD for local service discovery.
- Android `TileService` for an optional Quick Settings tile.
- Use the Android Sharesheet so CrossDrop appears as a share target for supported files.
- Use platform-supported foreground-service and background execution behavior only when needed and permitted by the OS.
- Keep UI and native networking layers separated behind well-defined interfaces.

### macOS

- Native Swift + SwiftUI app.
- `MenuBarExtra` for the menu-bar experience, with a focused main window when useful.
- Apple Network framework (`NWListener`/`NWConnection` or suitable equivalent) for TCP/TLS transport.
- Bonjour service advertisement and browsing.
- Native Finder drag-and-drop support into a CrossDrop window/drop zone.
- Native file panels, notifications, progress UI, and destination selection.
- Support macOS versions actually available for development/testing; document the minimum version once decided. Do not invent support for untested versions.

### Shared protocol

Document a platform-neutral protocol in `docs/protocol-v1.md`, with shared test vectors and fixtures. Keep Android and macOS implementations interoperable.

## 4. Core user journeys

### A. Android → Mac

1. User selects one or more files in any Android app and opens the native Share Sheet.
2. User chooses CrossDrop.
3. CrossDrop opens a premium nearby-device screen and discovers available paired/approvable Macs.
4. User chooses a Mac.
5. For a new device, both sides show a clear pairing confirmation and verification code/phrase. Never trust a new device silently.
6. The receiver approves the transfer if required by the configured trust policy.
7. Show transfer progress, bytes sent, rate if measured, estimated time only when meaningful, and Cancel.
8. Verify received content and show a clear success state with an action to open or locate the file.
9. Record a minimal local transfer-history entry without uploading it anywhere.

### B. Mac → Android

1. User opens CrossDrop from the menu bar or main window.
2. User drags files from Finder into the CrossDrop drop zone, or uses a file picker.
3. CrossDrop displays the selected items and their total size.
4. User chooses a nearby paired Android device.
5. A new device goes through explicit pairing. The Android receiver shows an incoming-transfer prompt unless the user has explicitly configured trusted-device behavior.
6. Show live progress, pause only if safely supported, Cancel, and clear failure recovery.
7. Verify file integrity and show completion on both devices.

### C. Receive and device management

- Clear receive-availability control on Mac and Android.
- Explicit incoming-transfer accept/reject for untrusted senders.
- Trusted devices list with device name, platform, last-used information if stored, and Remove/Forget action.
- Transfer history with status, filename, size, timestamp, and retry where safe.
- Notifications for meaningful events, without exposing sensitive filenames on the lock screen by default.
- Clear states for no devices found, permission denied, Wi-Fi disconnected, peer unreachable, transfer cancelled, storage full, and verification failed.

## 5. Required Android features

- Premium home / nearby devices screen.
- Android native Share Sheet integration.
- Discover Macs on the same local network.
- Pair, trust, rename locally where appropriate, and forget devices.
- Send one or multiple files.
- Receive files with accept/reject controls.
- Incoming and outgoing transfer progress, cancellation, and clear results.
- Transfer history.
- Destination/download-folder handling using Android-supported storage APIs and scoped storage.
- Notifications with appropriate permission handling.
- Optional Quick Settings tile using `TileService` to open CrossDrop or toggle receive availability.
  - The user must add the tile through Android's system UI; the app cannot silently insert it into Quick Settings.
  - Do not use the tile as a pretext for permanent background scanning.
- Battery-conscious discovery: scan only during an active discovery/receive session or transfer, use system discovery callbacks, and stop promptly when no longer needed.
- Correct handling of Android versions, runtime permissions, content URIs, MIME types, large files, and temporary URI grants.

## 6. Required macOS features

- Polished menu-bar app and a deliberate main-window experience.
- Bonjour advertisement and discovery while receive availability is enabled.
- Receive-availability toggle.
- Nearby Android device list with pairing status.
- Finder drag-and-drop into a large, beautiful drop zone.
- File picker as an alternative to drag-and-drop.
- Send multiple files; support folders only if implemented and tested safely.
- Incoming transfer approval, progress, cancellation, and completion.
- Choose destination folder and remember the user's local choice.
- Trusted-device management and local transfer history.
- Native notifications and helpful errors.
- Reconnect/recovery behavior after Wi-Fi changes, sleep/wake, or app relaunch.
- Clear handling of macOS Local Network privacy prompts and firewall/network permissions when relevant.
- No attempt to silently change system security settings.

## 7. Visual design system — very high priority

The UI should feel like a premium modern Apple-platform utility, while remaining distinctly CrossDrop.

### Visual direction

- Liquid Glass-inspired surfaces: translucent panels, restrained backdrop blur, layered depth, fine borders, specular highlights, and soft light reflections.
- Calm, spacious layouts with a strong hierarchy and purposeful negative space.
- Smooth, spring-like transitions and subtle motion; no gratuitous animation or excessive glow.
- A coherent icon system and consistent corner radii, spacing, and typography.
- Light and dark appearance, following system appearance by default.
- Use native platform conventions where they improve usability. Android should feel at home on Android, and macOS should feel at home on macOS.
- Avoid a generic dashboard template. This is a focused, tactile, file-transfer product.

### Core visual components

- Nearby-device cards/rows with platform icon, device name, connection state, and trust state.
- Prominent discovery state with tasteful animation and a static reduced-motion alternative.
- Large drag-and-drop target on Mac with clear hover/drop feedback.
- Transfer cards with filename, file type icon/thumbnail where safe, size, progress, rate, and cancel action.
- Distinct empty, loading, connecting, pairing, receiving, sending, success, and failure states.
- Pairing confirmation with a prominent matching code/phrase.
- A concise local privacy indicator, without overclaiming security.
- Toasts/alerts that are actionable and do not obscure the main workflow.

### UX quality bar

- Every screen must be designed for real content, empty state, loading state, errors, and accessibility.
- Avoid layout shifts, clipped text, tiny tap targets, unexplained icons, and excessive nested dialogs.
- Respect reduced motion and text scaling.
- On Mac, support keyboard navigation and visible focus.
- Keep important actions obvious: Send, Receive, Approve, Reject, Cancel, Retry, Forget device.
- Ask for permissions only at the point they are needed and explain why.
- Use confirmation for destructive actions where appropriate.
- Include polished app icon, splash/launch presentation where platform-appropriate, and cohesive release visuals.

## 8. Protocol v1

Write and test the protocol before building separate platform implementations.

### Discovery

- Advertise/browse a versioned Bonjour/mDNS service on the local network.
- Define service name/type, port negotiation, protocol version, and a minimal discovery payload.
- Do not put secrets or sensitive user data in broadcast metadata.
- Discovery is not authentication; every connection must authenticate separately.

### Control framing

- TCP stream with each control frame prefixed by a 4-byte unsigned big-endian length.
- Follow with UTF-8 JSON.
- Maximum control frame size: 64 KiB.
- Reject malformed JSON, unknown required fields, oversized frames, invalid lengths, and unsupported protocol versions safely.
- Binary file payloads must use a clearly defined streaming framing format separate from JSON control frames.

### Initial message types

- `hello`
- `auth.challenge`
- `auth.proof`
- `transfer.offer`
- `transfer.accept`
- `transfer.reject`
- `transfer.start`
- `transfer.progress` (throttled; avoid flooding)
- `transfer.complete`
- `transfer.cancel`
- `error`

Every message should include protocol version and request/transfer correlation IDs as appropriate. Define schemas, required/optional fields, validation rules, maximum sizes, and error codes in documentation and tests.

### Transfer offer

Include at least:
- transfer ID
- sanitized display filename
- file size
- MIME type when known
- SHA-256 digest, using a clearly documented method
- optional folder/relative-path metadata only if folder transfer is supported and safe

Use a documented chunking/streaming strategy. Do not load a whole file into RAM. Apply bounded buffers and backpressure. Ensure progress is accurate enough for the UI without generating excessive control messages.

## 9. Security and privacy requirements

- Use TLS 1.3 where supported by the selected native networking stack; validate peer identity rather than accepting any certificate blindly.
- Design pairing so devices establish trusted identities. Avoid shared hardcoded secrets and unauthenticated trust-on-first-use.
- Use a short verification code/phrase or equivalent out-of-band confirmation during initial pairing.
- Persist credentials/keys in platform-appropriate secure storage (Android Keystore and macOS Keychain).
- Require explicit approval for unknown senders. Allow user-configured trusted-device behavior with a clear way to revoke trust.
- Bind trust to a stable device identity, not just an IP address or device name.
- Prevent path traversal, unsafe absolute paths, symlink attacks, and filename collisions.
- Write to a temporary file, verify size and SHA-256, then atomically move into the chosen destination when possible.
- Never overwrite existing files silently. Offer safe rename/skip/replace choices.
- Add connection/transfer timeouts, maximum metadata sizes, limits for concurrent transfers, and protection against malformed input.
- Handle cancellation and partial-file cleanup safely.
- Avoid logging file contents, secrets, pairing codes, or sensitive metadata.
- No telemetry by default. Transfer history stays local.
- Clearly document network behavior and permissions. Do not claim “zero security risk”; explain the real trust model.
- Do not disable Gatekeeper, firewall, certificate validation, or platform security features.

## 10. Performance and battery requirements

- Stream file data natively with bounded buffers and backpressure.
- Use asynchronous/event-driven networking.
- No busy loops, tight polling, or permanent high-frequency scanning.
- Stop discovery when the user exits discovery/receive mode or when it is no longer required.
- Avoid keeping the CPU awake unnecessarily. Use wake locks/background execution only when justified and allowed by Android.
- Make large transfers resilient to app lifecycle changes where the OS permits.
- Benchmark on actual devices, including large files (target tests include a 1 GB file where hardware/storage permits).
- Measure throughput, peak memory, CPU, battery impact, failure rate, and verification results. Do not invent performance claims.
- Treat QUIC or alternative transports as future experiments only after TCP/TLS has a reliable baseline.

## 11. Connectivity and platform constraints

- MVP target: both devices are on a compatible local network and can reach each other.
- Bonjour/NSD discovery may be blocked by network isolation, guest Wi-Fi, router client isolation, firewall settings, or permissions. Explain these errors in product language.
- Do not assume every Wi-Fi network allows peer-to-peer connections.
- Bluetooth may be considered for discovery assistance only; do not use it for large file payloads.
- Router-free/direct Wi-Fi operation using Android Wi-Fi Direct and a compatible macOS connection path is a later research milestone. Do not advertise it as working until proven on real hardware.
- Android Quick Settings tile must be manually added by the user.
- An unsigned macOS DMG can be distributed without paying for an Apple Developer account, but macOS may show Gatekeeper warnings and the first-launch experience is less smooth. Do not try to bypass these warnings in code.
- Do not implement a website/landing page in this repository.

## 12. Suggested repository layout

Adapt only when the chosen build tooling makes a better structure necessary; keep platform boundaries clear.

```text
crossdrop/
  README.md
  CLAUDE.md
  LICENSE
  docs/
    architecture.md
    protocol-v1.md
    security-model.md
    macos-networking-limitations.md
    testing-matrix.md
    release-process.md
  protocol/
    schemas/
      hello.schema.json
      transfer-offer.schema.json
      error.schema.json
    test-vectors/
  android/
    app/
      src/main/
        java/.../crossdrop/
          ui/
          share/
          discovery/
          pairing/
          transport/
          transfer/
          storage/
          notifications/
          tiles/
    core/
    build.gradle
  macos/
    CrossDrop/
      App/
      MenuBar/
      UI/
      Discovery/
      Pairing/
      Transport/
      Transfer/
      Storage/
    CrossDropTests/
    Package.swift
  integration-tests/
    protocol/
    scenarios/
  scripts/
    dev-checks.sh
```

Do not force a monorepo layout if the build tools require a different arrangement. Explain the reason and document the final layout.

## 13. Development milestones

### M0 — Repository and architecture
- Inspect the existing repository before changing anything.
- Record OS/toolchain versions and existing project status.
- Create app skeletons and shared protocol documentation.
- Add formatting, linting, unit-test setup, and a short development guide.
- Confirm the native TCP/TLS feasibility with a small local proof of concept.

### M1 — Discovery and pairing
- Discover devices on a real Android phone and real Mac.
- Implement version negotiation, authenticated pairing, trust storage, and revocation.
- Test denied permissions, no devices, network changes, and duplicate device names.

### M2 — Reliable transfer engine
- Implement streaming in both directions.
- Add file-size limits, progress, cancellation, timeouts, SHA-256 verification, safe temp files, and collision handling.
- Build protocol unit tests and cross-platform integration tests.
- Verify that Android and Mac implementations can exchange files in both directions.

### M3 — Product-quality UI/UX
- Implement the visual design system and polished Android screens.
- Implement native macOS menu-bar/window UI and Finder drop target.
- Add share-sheet flow, incoming approval, notifications, history, and device management.
- Test accessibility, reduced motion, light/dark mode, text scaling, and keyboard navigation.

### M4 — Reliability and battery
- Test large files, many files, interrupted connections, Wi-Fi changes, sleep/wake, app backgrounding, storage-full conditions, and cancellation.
- Profile memory, CPU, throughput, and battery on real devices.
- Investigate router-free transfer only after the shared-network path is stable.

### M5 — Packaging and release readiness
- Prepare Android build suitable for the existing Play Store release workflow.
- Produce a macOS DMG build and documented manual first-launch steps for an unsigned build.
- Add versioning, checksums, release notes, and reproducible build guidance where practical.
- Do not build the landing page until the apps have passed testing.

## 14. Testing matrix

At minimum, test:

- Android → Mac and Mac → Android.
- First-time pairing, trusted device, revoked device, rejected transfer.
- Single file, multiple files, empty file, large file, unusual Unicode filename, duplicate filename.
- Unsupported/unknown MIME type.
- Network disconnected, peer disappears, IP changes, Wi-Fi changes, router client isolation.
- Transfer cancellation on sender and receiver.
- Storage permission denial, insufficient storage, destination unavailable.
- Corrupt/truncated payload and checksum mismatch.
- Malformed/oversized protocol frames and unsupported protocol version.
- Mac sleep/wake and Android app background/foreground.
- Quick Settings tile permission/availability and user-managed tile addition.
- VoiceOver/TalkBack labels, keyboard navigation, text scaling, reduced motion, light/dark mode.
- Verify no file bytes are sent to any cloud endpoint and no telemetry is emitted by default.

## 15. Definition of done

A milestone is complete only when:

- Its code builds successfully on the intended toolchain.
- Relevant unit/integration tests pass.
- The actual Android device and Mac have been used for the applicable end-to-end flow.
- Errors, loading states, empty states, and cancellation are handled.
- No fake/mock data remains in a feature represented as complete.
- Security-sensitive behavior has tests and documentation.
- UI is visually coherent, accessible, and polished—not just functional.
- README and docs reflect what actually works and clearly identify remaining limitations.

## 16. Instructions for Claude Code

1. **Start by inspecting the repository.** Do not overwrite existing work or assume the repository is empty.
2. If the repo is empty, scaffold the project in small, verifiable steps. If code already exists, map the architecture and preserve working behavior.
3. Before major implementation, summarize the proposed architecture, assumptions, toolchain requirements, and milestone plan. Then proceed unless blocked by a genuine decision.
4. Build vertical slices end-to-end. Prefer a working discovery/pairing/transfer path over many disconnected screens.
5. Keep TypeScript UI separate from Kotlin native services and keep the macOS app native in SwiftUI.
6. Define the protocol and test vectors before implementing both ends independently.
7. Run available build, lint, and tests after meaningful changes. Fix failures rather than merely reporting them.
8. Do not fabricate successful builds, test results, benchmarks, signing, notarization, or platform compatibility.
9. Use free/open-source dependencies where possible. Explain any dependency that adds cost, accounts, telemetry, or external network requirements.
10. Do not add a landing page, website, analytics, ads, account system, cloud transfer relay, or paid API.
11. Keep Liquid Glass-inspired UI/UX quality central throughout implementation. Do not postpone all design work until the end.
12. If an API or platform behavior is uncertain, inspect the official documentation and test a minimal proof of concept before building around it.
13. Keep a concise `docs/testing-matrix.md` updated with what has actually been tested, on which devices/OS versions, and the result.
14. Never claim that local-network architecture alone makes an app completely secure. Implement and document the threat model.

## 17. First task

Inspect the repository and report:
- what files and projects already exist,
- the available Android/macOS build toolchains,
- missing prerequisites,
- the proposed initial directory structure,
- the smallest end-to-end proof of concept to validate first.

Then start **M0** and implement the first verifiable slice. Do not build the landing page.
