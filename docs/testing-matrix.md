# Testing matrix

Only results that were actually run are recorded here. "Not yet" means not
tested, not "expected to fail".

## Automated (CI and local)

| Area | Where | Result |
|---|---|---|
| Protocol vectors: keys, ECDH, transcript, HKDF (incl. RFC 5869), SAS, signatures, record encryption, SHA-256, filename sanitising | Kotlin `VectorsTest` (JVM 21, Linux) | Pass (2026-10-20) |
| Strict JSON parsing and message validation | Kotlin `JsonTest` | Pass (2026-10-20) |
| Loopback transfer with pairing (empty + 1 MB file), trust reuse, duplicate name → `name (1)`, declined offer, declined pairing, receiver forgot sender, not receiving, integrity failure cleanup, receiver cancel, oversized frame, unsupported version | Kotlin `LoopbackTest` (real sockets, 127.0.0.1) | Pass (2026-10-20) |
| CLI transfer Kotlin→Kotlin (5 MB random, Unicode name, empty file; hashes compared) | `integration-tests/interop.sh` on Linux | Pass (2026-10-20) |
| Protocol vectors and loopback in Swift | `swift test`, GitHub macos-15 runner, Xcode 16.4 | Pass (2026-10-20) |
| Kotlin↔Swift interop over TCP: Kotlin→Swift, Swift→Kotlin, Swift→Swift, Kotlin→Kotlin (6 files incl. empty, 5 MB, Unicode, duplicate name; pairing codes match) | `integration-tests/interop.sh`, GitHub macos-15 runner | Pass (2026-10-20) |
| React Native: typecheck, lint, 68 unit/render tests (Mint Air screens: welcome, napping, searching, no Wi‑Fi, device chips, pairing tiles, incoming, transfer progress, failure + retry; run with Reduce Motion on) | Jest (Linux) | Pass (2026-10-20) |
| Mint Air Android screens rendered in a browser (react-native-web harness, 412×892) and compared with the design canvas | Local, Chromium | Looked right (2026-10-20); not a substitute for a device |
| Release APK walked on an Android 14 emulator (Pixel 6 profile, 1080×2400, x86_64; software GPU via SwiftShader and via ANGLE): welcome, napping, notification explainer and permission, searching, all tabs, font scale 1.3, Wi‑Fi off/on, share sheet, then a real incoming transfer from the Kotlin CLI acting as a Mac (pairing code, offer, progress, done) and a sender that disappears mid-transfer (failure screen) | `integration-tests/emulator/run.sh`, GitHub ubuntu-24.04 runner | All steps pass, no seams found by `check_shots.py`, no app crashes in logcat (2026-10-20, run 24). Frame timings are not meaningful on a software GPU; with motion paused the screens render no frames at all (nothing redraws while idle) |
| Android Kotlin bridge changes (preferences, haptics, done sound, Wi‑Fi panel) typecheck | Local, Kotlin JVM against android-all stubs | Pass (2026-10-20) |
| Android release APK build (arm64-v8a, armeabi-v7a, x86_64) | GitHub ubuntu-24.04 runner | Pass (2026-10-20) |
| v1 extensions (§9) in Kotlin: folders (structure kept, hostile paths flattened), link/text handoff (not saved, size limit), QR token pairing without prompts + "mine" stored, QR for another device refused, My devices only (stranger refused, token or paired device allowed), dropped transfer resumes | Kotlin `LoopbackTest`, 15 tests (28 with JSON + vectors) | Pass (2026-11-21) |
| v1 extensions in Swift: folders, link arrives as text and isn't saved, oversized/unknown kind refused, QR pairing without prompts + mine, QR for another device refused, private mode, pair-only session closes quietly | `swift test`, GitHub macos-15 runner | Pass (2026-11-21, run 26) |
| Kotlin↔Swift interop of the extensions, both directions and Kotlin→Kotlin: link (TEXT line, no file written), folder `Trip/Day 1`, QR + My devices only (stranger gets `not_receiving`, QR token pairs with no codes shown), resume after the sender dies at 2.5 MB of 5 MB (`RESUMED`, final hash matches) | `integration-tests/interop.sh`, GitHub macos-15 runner | Pass (2026-11-21, run 26) |
| §9.7–§9.9 in Kotlin: capture request accepted / declined / unpaired refused (no pairing), answer with `requestId` auto-accepted once and only from the device asked, request registry expiry; `expiresAfter` round-trips, out-of-range and bad `requestId` refused (`bad_message`); room URI build/parse against a shared vector + 20 malformed codes, hint/proof vectors, room pairing with no prompts and temporary trust ending at the room expiry, expired trust pairs again with codes, wrong room key falls back to codes, My devices only accepts a room proof, room code for another device refused | Kotlin `LoopbackTest` (24) + `RoomsTest` (5); 42 tests in total with JSON + vectors, Linux JVM | Pass (2026-11-21) |
| Kotlin→Kotlin interop of §9.7–§9.9: `capture` CLI asks, receiver prints `CAPTURE photo <id>` and answers with a file that arrives as `REPLY <id>` with no `PROMPT`; `--expires-after 3600` shows `EXPIRES 3600`; room pairing into a My-devices-only receiver with no `SAS` lines | `integration-tests/interop.sh` extras, Linux | Pass (2026-11-21) |
| §9.10 Turbo in Kotlin: 5 files (incl. empty and 1-byte) over 3 connections, every hash verified, no `.partial` left, all connections closed; receiver with Turbo off → one connection; one-file offer gets no `join`; bad `parallel` values refused (`bad_message`); sender cancel and receiver cancel mid-transfer close every connection, reported once as cancelled, nothing left on disk; join for an unknown transfer → `unexpected_message`, wrong token → `auth_failed`, the transfer carries on and nothing is reported as failed; a capture answer refused with `not_receiving` keeps its `requestId` and the retry is accepted without a prompt; room host lists are not trimmed (space / newline refused), hints trim ASCII spaces only, `roomHint` vector | Kotlin `LoopbackTest` (30) + `RoomsTest` (5) + `VectorsTest` (10); 49 tests in total with JSON, Linux JVM | Pass (2026-11-22) |
| Kotlin→Kotlin interop of §9.10: `send --turbo 3` with 4 files (5 MB random, 300 KB, 1 byte, empty) prints `STREAMS 3`; receiver's `RECEIVED` hashes and the files on disk match the sender's | `integration-tests/interop.sh` extras, Linux | Pass (2026-11-22) |
| §9.7–§9.10 in Swift (`swift test`) and Kotlin↔Swift interop of them | GitHub macos-15 runner | Not yet run — Swift can't be built on the Linux dev box |
| React Native: 73 unit/render tests incl. "This is my device", receive-mode sheet, shared link sent as a link, received link waits for Open/Copy, send to several devices | Jest (Linux) | Pass (2026-11-21) |
| macOS universal app (arm64 + x86_64), ad-hoc signature verified, DMG | GitHub macos-15 runner | Pass (2026-10-20) |

## Manual, on real devices

| Scenario | Android → Mac | Mac → Android |
|---|---|---|
| First-time pairing (codes match on both) | Not yet | Not yet |
| Trusted device, no pairing prompt | Not yet | Not yet |
| Revoked (forgotten) device must pair again | Not yet | Not yet |
| Rejected transfer | Not yet | Not yet |
| Single / multiple / empty / 1 GB file | Not yet | Not yet |
| Unicode and duplicate file names | Not yet | Not yet |
| Cancel on sender / on receiver | Not yet | Not yet |
| Wi-Fi off mid-transfer, peer disappears | Not yet | Not yet |
| Guest network / client isolation message | Not yet | Not yet |
| Insufficient storage | Not yet | Not yet |
| Mac sleep/wake, Android background/foreground | Not yet | Not yet |
| Share sheet entry, Quick Settings tile | Not yet | n/a |
| QR pairing (Mac shows code, phone scans) | Not yet | Not yet |
| My devices mode: always reachable after app close / reboot, invisible to strangers | Not yet | Not yet |
| Direct Share targets in the Android share sheet | Not yet | n/a |
| Link opens on the Mac / link on the phone via Open | Not yet | Not yet |
| Clipboard: Mac panel, ⇧⌘V, Android tile and in-app button | Not yet | Not yet |
| Screenshot suggestion notification | Not yet | n/a |
| Resume a large transfer after Wi‑Fi drops | Not yet | Not yet |
| Folders with structure | Not yet | Not yet |
| Send to several devices at once | Not yet | Not yet |
| Drag onto the menu bar icon; Finder › Services | n/a | Not yet |
| Notification Accept / Decline | Not yet | Not yet |
| HEIC → JPEG copy on the Mac | n/a | Not yet |
| Last-known address when discovery is blocked | Not yet | Not yet |
| No-router mode (phone hotspot, Android 13+) | Not yet | Not yet |
| TalkBack / VoiceOver, text scaling, reduced motion | Not yet | Not yet |
| Mint Air UI on a phone and a Mac (layout on small/large screens, motion, haptics, done sound) | Not yet | Not yet |
| Throughput, memory, battery | Not measured | Not measured |

No performance numbers are claimed until they are measured on real hardware.
