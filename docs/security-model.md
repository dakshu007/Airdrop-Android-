# Security model

CrossDrop moves files directly between two devices on the same local network.
This page says what that protects, what it does not, and why. It does **not**
claim that a local-network design is "secure by default" — the protections
below are what the code actually implements.

## Assets

* File contents and names in transit.
* The integrity of received files.
* The receiver's storage (no overwrites, no writes outside the destination).
* Each device's long-term identity key.
* The list of devices a user decided to trust.

## Adversaries considered

| Adversary | Can | Mitigation |
|---|---|---|
| Passive observer on the Wi-Fi | Read all packets | All file data and control messages after the handshake are AES-256-GCM encrypted with per-connection keys from ephemeral ECDH (forward secrecy per connection). |
| Active attacker on the Wi-Fi (ARP spoofing, rogue mDNS) | Intercept, modify, impersonate | First contact needs both users to confirm the same 6-digit code derived from the full handshake transcript. The client commits to its ephemeral key before seeing the server's, so a man-in-the-middle gets one guess (1 in 10⁶) per pairing attempt. Later connections require a signature from the stored identity key. |
| A device advertising someone else's name | Appear as "Studio Mac" | Names are display hints. Trust is bound to the identity key; a new key always means pairing again. |
| A malicious paired device | Send hostile metadata or data | Strict frame/JSON limits, filename sanitising (no paths, no hidden files, no control characters), size limits, SHA-256 verification, temporary files, no overwrites, and the receiver still approves each transfer unless "auto-accept" was switched on for that device. |
| Random devices / port scans | Connect to the listening port | The listener only runs while Receiving is on, refuses with `not_receiving`/`busy`, and caps concurrent connections at 3. "Everyone" turns itself back to "My devices" (or off) after 10 minutes. In "My devices" mode, an unpaired device is refused with `not_receiving` right after the handshake unless it shows a valid QR token (protocol §9.5). |
| Someone who photographs a pairing QR code | Pair without comparing numbers | The token is single-use, expires after 5 minutes and is revoked when the Mac closes the "Pair a phone" sheet. The phone only pairs if the key it reaches matches the fingerprint in the code, so a fake QR code can't redirect it to another device (§9.4). |
| A paired device sending links or text | Make the receiver open something | Links are shown first; the Mac opens them only when they are `http`/`https`, Android only when the user taps Open. Nothing else is launched. Text goes to the clipboard only on the Mac, or on Android when the user taps Copy. Neither is written to storage. |

## Not protected / known limitations

* **Discovery is public on the LAN.** While Receiving is on, anyone on the same
  network can see the platform and a stable device ID (a hash of the public
  key), and in "Everyone" mode the device name. This allows tracking that device
  on that network. "My devices" mode hides the name (random instance name) but
  not the ID, because paired devices need it to recognise each other.
* **Remembered addresses.** For paired devices, each app keeps the last IPv4
  address and port that worked, and tries it when discovery can't find the
  device. The handshake still proves identity; a wrong address can only fail to
  connect. The address is stored locally with the trusted-device record.
* **"This is my device"** (chosen while pairing, or in the QR sheet) turns on
  auto-accept for that device. It can be switched off per device in Devices.
* **Clipboard and screenshots are opt-in actions.** CrossDrop reads the
  clipboard only when the user taps Clipboard / the "Send clipboard" tile, while
  the app is on screen (Android doesn't allow anything else). The screenshot
  suggestion is off by default; turning it on asks for photo access, and it only
  posts a notification — sending needs a tap.
* **The handshake is not hidden.** Identity public keys are sent in plaintext
  during the handshake (like TLS 1.2 client certificates). They are not secret,
  but a passive observer can link connections to devices.
* **Code comparison relies on people.** If both users tap "Codes match" without
  looking, an active attacker who is on the network at that exact moment has a
  one-in-a-million chance per attempt. The UI asks users to compare the codes.
* **Auto-accept** lets a paired device deliver files without a prompt. It is off
  by default and per device.
* **Not TLS.** v1 uses a custom handshake built from standard primitives (see
  `protocol-v1.md` §1.2 for why). It is tested against shared vectors and across
  implementations, but **it has not been reviewed by a cryptographer**. Treat it
  as pre-1.0.
* **macOS key storage:** the Mac identity key is stored as a generic password
  item in the login keychain. Ad-hoc-signed builds may trigger a keychain access
  prompt after each update, because the code signature changes.
* **Android key storage:** the identity key is generated inside the Android
  Keystore (hardware-backed where the device supports it) and never exported.
* A compromised device (malware, root) can impersonate that device.

## Data stored locally

| Data | Android | macOS |
|---|---|---|
| Identity private key | Android Keystore | Keychain (generic password) |
| Trusted devices (public keys, names, timestamps, auto-accept, last address that worked) | App-private SharedPreferences | Application Support (JSON) |
| Transfer history (names, sizes, peer name, status, time; the URL for sent/received links, never text content) | App-private file, max 200 | Application Support, max 200 |
| Partly received files kept for resuming (§9.3) | Pending MediaStore item, deleted after 24 h | Hidden `.crossdrop-resume-*.partial` in the destination, deleted after 24 h |
| Received files | `Download/CrossDrop` via MediaStore | Chosen folder (default `~/Downloads`) |

Nothing is uploaded anywhere. There is no analytics, crash reporting, account,
or cloud relay; the only network traffic is mDNS on the local network and
direct TCP connections to the peer the user picked.

## Permissions (Android)

| Permission | Asked when | Why |
|---|---|---|
| Notifications | First time Receiving is turned on | Requests, results, Accept/Decline buttons |
| Camera | Scanning a pairing QR code | Frames are decoded on the phone (ZXing) and never stored or sent |
| Photos (`READ_MEDIA_IMAGES`) | Turning on "Offer to send screenshots" | To notice a new screenshot |
| Boot completed | Never asked (normal permission) | Brings back "My devices" after a restart, only if the user chose it |

## Logging

Neither app logs file contents, file names, pairing codes, keys or signatures.
