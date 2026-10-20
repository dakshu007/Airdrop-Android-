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
| Random devices / port scans | Connect to the listening port | The listener only runs while Receiving is on (auto-off after 10 minutes on Android), refuses with `not_receiving`/`busy`, and caps concurrent connections at 3. |

## Not protected / known limitations

* **Discovery is public on the LAN.** While Receiving is on, anyone on the same
  network can see the device name, platform and a stable device ID (a hash of
  the public key). This allows tracking that device on that network.
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
| Trusted devices (public keys, names, timestamps, auto-accept) | App-private SharedPreferences | Application Support (JSON) |
| Transfer history (names, sizes, peer name, status, time) | App-private file, max 200 | Application Support, max 200 |
| Received files | `Download/CrossDrop` via MediaStore | Chosen folder (default `~/Downloads`) |

Nothing is uploaded anywhere. There is no analytics, crash reporting, account,
or cloud relay; the only network traffic is mDNS on the local network and
direct TCP connections to the peer the user picked.

## Logging

Neither app logs file contents, file names, pairing codes, keys or signatures.
