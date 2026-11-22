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
| Someone who sees a Drip Room code (§9.9) | Pair with room members without comparing codes | The code (a photo of the screen is enough) works only until the room ends (30 min to 4 h). Room pairing needs both sides to prove the room key, bound to that handshake. Room trust is temporary: it never sets auto-accept, every file is still approved, it ends when the room ends or is left, and both apps drop all room trust at start-up because rooms are kept only in memory. Room members can't ask for photos and don't appear in the Android widget or Direct Share; the Mac doesn't queue sends for them. |
| A paired device asking for photos (§9.7) | Make the phone take or send pictures | Only permanently paired devices may ask; room members are refused. The phone never takes or sends anything by itself: it shows a notification (or the in-app prompt), and the user takes or picks a photo. The answer goes only to the device that asked and is accepted there without a prompt once, within 10 minutes. The Mac app declines all photo requests. At most 4 open requests are kept. |
| Another device holding a remembered address | Receive a send meant for someone else | Both senders require the handshake to reach the chosen device ID and refuse with `peer_changed_identity` otherwise, before pairing or offering anything (Kotlin `expectedDeviceId`, Swift `OutgoingTransfer(peerId:)`). |

## Not protected / known limitations

* **Discovery is public on the LAN.** While Receiving is on, anyone on the same
  network can see the platform and a stable device ID (a hash of the public
  key), and in "Everyone" mode the device name. This allows tracking that device
  on that network. "My devices" mode hides the name (random instance name) but
  not the ID, because paired devices need it to recognise each other.
* **Remembered addresses.** For paired devices, each app keeps the last IPv4
  address and port that worked, and tries it when discovery can't find the
  device. The handshake still proves identity, so a stranger at that address
  can't pass as the device. A *different paired* device that now holds the
  address is a gap on the Mac side (see the table above). The address is stored
  locally with the trusted-device record.
* **Rooms and receiving.** Hosting a room needs receiving on (My devices is
  enough). On Android, hosting or joining a room turns receiving on in My
  devices mode if it was off, and off again when the room ends.
* **"This is my device"** (chosen while pairing, or in the QR sheet) turns on
  auto-accept for that device. It can be switched off per device in Devices.
* **Clipboard.** Android reads its clipboard only when the user taps
  Clipboard (the app, the tile or the widget), while the app is on screen.
  Text from a Mac is kept in memory for two minutes as a "Paste from …" pill and
  goes onto the clipboard only when the user taps Copy; the notification shows
  the Mac's name, not the text. On the Mac, "Send what I copy to my phone" is
  off by default. When on, it runs only while a phone marked "This is my
  device" is visible to discovery (which runs only while a CrossDrop window,
  the menu bar panel or the Drip Island is showing). It then checks the
  clipboard's change counter every 1.5 s and reads the contents once per
  change: plain text only, up to 64 KiB, skipping anything marked concealed,
  transient or auto-generated (password managers that follow
  nspasteboard.org) and anything carrying files or images. A password manager
  that doesn't mark its copies would have them sent to the phone. These sends
  leave no history entry.
* **Screenshots.** The suggestion is off by default; turning it on asks for
  photo access, and it only posts a notification. Sending needs a tap.
* **Expiring drops are a courtesy (§9.8).** The receiver's app is asked to
  delete files after 24 h; nothing enforces it. Android deletes its own
  MediaStore items from an inexact, non-wakeup alarm (it may run late, never
  early) and can't delete a file it no longer owns, for example after a
  reinstall. The Mac moves the files to the Trash, where they can be recovered,
  skips files that were moved or changed, and offers Keep. Either user can copy
  or share the files first. History only says a file was deleted when that was
  confirmed.
* **Room hints are visible.** Devices in a room add `r=` hints to their
  discovery record. They don't reveal the room key, but anyone on the network
  can see which devices share a room hint.
* **Drip Island** (Mac) uses a global mouse-drag monitor. While the button is
  held it checks the drag pasteboard's change counter and whether the drag
  carries file URLs; nothing is sent until files are dropped on a device.
* **Home-screen widget** (Android) shows the names of up to three paired
  devices to anyone who sees the unlocked home screen. It never updates on a
  timer and starts no networking.
* **Turbo** extra connections are full, separately authenticated sessions and
  must reach the same device; the join token ties them to one transfer. Both
  apps always accept Turbo joins when receiving, within the 3-connection limit;
  only sending with Turbo is a setting (off by default, experimental).
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
| Received files | `Download/CrossDrop` via MediaStore; with Smart arrival, images/videos/audio in `Pictures`/`Movies`/`Music/CrossDrop` | Chosen folder (default `~/Downloads`); with Smart arrival, photos in `~/Pictures/CrossDrop/From <device> – <date>`, documents in `~/Documents/CrossDrop` |
| Room trust (§9.9) | Trusted-device record with `expiresAt`; all of it dropped when the room ends or is left, and at start-up | Same, in the trust JSON; dropped when the room ends, and at launch |
| Rooms themselves (key, name, expiry) | Memory only | Memory only |
| "Send when nearby" queue | `send-queue.json` in app-private files: device, file references, link/text, expiry choice. Share-sheet files whose access would end are copied to app-private storage (max 512 MB in total, 50 items) and deleted once sent or cancelled | `send-queue.json` in Application Support (mode 0600): device, file paths (not copies), link/text |
| Pocket / Shelf | Pocket: last 30 received files (content URI, name, size, sender) in `pocket.json`; removing an item deletes the file only if asked | Shelf: paths of parked files and folders (max 200) in `shelf.json`, mode 0600 |
| Expiring drops (§9.8) | `expiring.json` (URIs and delete times) and `expiring-deleted.json` | `expiring-files.json` (paths, size, file number, modification date, delete time), mode 0600 |
| Photo taken for a Mac (§9.7) | App-private cache `capture/<requestId>/`, shared with the camera app only through a FileProvider URI; deleted once the answer is done or the request ends | Saved like any received file, and put on the clipboard |
| Text from a Mac (clipboard pill) | Memory only, two minutes | n/a |
| Settings (Smart arrival, Turbo, Drip Island, clipboard offer) | App-private SharedPreferences | UserDefaults |

Nothing is uploaded anywhere. There is no analytics, crash reporting, account,
or cloud relay; the only network traffic is mDNS on the local network and
direct TCP connections to the peer the user picked.

## Permissions (Android)

| Permission | Asked when | Why |
|---|---|---|
| Notifications | First time Receiving is turned on | Requests, results, Accept/Decline buttons |
| Camera | Scanning a pairing QR code | Frames are decoded on the phone (ZXing) and never stored or sent |
| Photos (`READ_MEDIA_IMAGES`) | Turning on "Offer to send screenshots" | To notice a new screenshot |
| Boot completed | Never asked (normal permission) | Brings back "My devices" after a restart, only if the user chose it, and re-arms the alarm for expiring drops |
| Vibrate | Never asked (normal permission) | Haptic heartbeat while CrossDrop is in the background; follows the in-app haptics setting and the system touch-feedback setting |

Camera is also asked for when the user taps **Take photo** for a Mac request
(Android requires it for the camera intent because CrossDrop declares it); if
it is refused, the Photo Picker opens instead. The photo itself is taken by the
system camera app into CrossDrop's private cache. **Pick photo** uses the
system Photo Picker, which needs no storage permission.

Components added for the new features, none exported to other apps:
`CaptureActivity` (camera or Photo Picker, no UI of its own), a `FileProvider`
limited to the private `cache/capture/` folder (`grantUriPermissions`, used
only for the camera app's output URI; Pocket's Share passes the MediaStore URI
with a one-off read grant),
`ExpiryReceiver` (deletes due expiring drops; boot and app-update broadcasts),
and the home-screen widget provider (`updatePeriodMillis` 0).

## macOS prompts

Local Network (discovery and transfers), Downloads (default receive folder),
Documents (only with Smart arrival, or when sending or parking files from
there) and Desktop (only when sending or parking files from there). The app is
not sandboxed and is ad-hoc signed. Drip Island's mouse monitor does not ask
for Accessibility access.

## Logging

Neither app logs file contents, file names, pairing codes, keys or signatures.
