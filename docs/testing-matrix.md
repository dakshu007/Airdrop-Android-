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
| React Native: typecheck, lint, 64 unit/render tests | Jest (Linux) | Pass (2026-10-20) |
| Android release APK build (arm64-v8a, armeabi-v7a, x86_64) | GitHub ubuntu-24.04 runner | Pass (2026-10-20) |
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
| TalkBack / VoiceOver, text scaling, reduced motion, dark mode | Not yet | Not yet |
| Throughput, memory, battery | Not measured | Not measured |

No performance numbers are claimed until they are measured on real hardware.
