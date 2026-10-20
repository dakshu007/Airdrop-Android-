# Release process

## Every push (automatic)

`.github/workflows/build.yml` runs on each push:

1. Kotlin core tests and a check that the test vectors are current.
2. Android: `npm ci`, typecheck, lint, Jest, then `assembleRelease`.
3. macOS: `swift test`, Kotlin↔Swift interop, XcodeGen + `xcodebuild` (universal,
   ad-hoc signed), DMG.
4. A GitHub release `v0.1.0-build.<run>` with `CrossDrop.apk`, `CrossDrop.dmg` and
   `SHA256SUMS.txt`, marked as latest. Stable links:
   * `https://github.com/<owner>/<repo>/releases/latest/download/CrossDrop.apk`
   * `https://github.com/<owner>/<repo>/releases/latest/download/CrossDrop.dmg`

## Android signing

Without secrets the APK is signed with the React Native template's **public
debug key**. That is fine for side-loading test builds, but every user would
trust the same public key, so it must never be used for the Play Store.

For real releases add these repository secrets (Settings › Secrets › Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.keystore` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Switching from the debug key to a release key changes the signature, so test
installs must be uninstalled first. For the Play Store, build an App Bundle
(`./gradlew bundleRelease`) with the same secrets; the application ID is
`com.crossdrop.app` and cannot change after the first upload.

`versionCode` comes from the CI run number; `versionName` is in
`android/android/app/build.gradle`.

## macOS

The DMG contains an ad-hoc-signed, **not notarized** app (no paid Apple
Developer account). Gatekeeper blocks the first launch; users open it via
System Settings › Privacy & Security › **Open Anyway**. The app never tries to
bypass this. Notarization later needs a Developer ID certificate and
`notarytool`; the workflow has a clear place to add both.

## Before calling something a release

* Fill in `docs/testing-matrix.md` with real-device results.
* Check the SHA-256 sums in the release against local downloads.
