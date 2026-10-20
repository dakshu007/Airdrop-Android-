# macOS implementation notes

## Layout decisions
- `macos/Package.swift` builds the `CrossDropCore` library, the `crossdrop-cli` executable and `CrossDropCoreTests`.
- The Xcode app target (`macos/project.yml`) compiles `Sources/CrossDropCore` **directly** instead of
  referencing the local package. That avoids a local-package reference to the directory that also holds the
  generated `.xcodeproj`. App files use `#if canImport(CrossDropCore) import CrossDropCore #endif` and only
  public core API, so switching to a package dependency later needs no code changes.
- `AppIcon.appiconset` must exist in `macos/CrossDrop/Resources/Assets.xcassets/` before building, because
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set. Without it, actool fails the build.

## Protocol interpretation choices
- §4.1 `name`: names longer than 64 scalars are **truncated** (not rejected). Empty after trimming → `bad_message`.
- `hello.minV` missing → treated as equal to `v`.
- Challenge/hello `platform` other than `android`/`macos` → `bad_message` (as the doc lists only those two).
- Client-side identity mismatch with a stored key: local code `peer_changed_identity`, wire `error{auth_failed}`.
- If the server already trusts the client and receives `pair.request`, it auto-confirms (no prompt on the server).
- On `pairing_required`, the client pairs on the same connection, showing its code too, then re-sends the
  same offer (same transferId).
- After `transfer.complete` the receiver waits up to 5 s for the sender to close before closing itself.
- Decrypt failure closes silently (no error frame), per §3.2.
- Busy (>3 inbound) → plaintext `error{busy}` instead of `auth.challenge`. Receiving off → `error{not_receiving}`.
