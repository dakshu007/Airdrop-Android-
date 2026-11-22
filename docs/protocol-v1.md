# CrossDrop Protocol v1

Status: **draft, implemented by both apps, not externally reviewed.**

This document is the single source of truth for how CrossDrop devices find each
other, authenticate, pair, and move files. The Android (Kotlin) and macOS
(Swift) implementations are written against it independently and are checked
against the shared vectors in `protocol/test-vectors/v1.json` and against each
other by the interop job in CI.

Conventions: `u32be` is a 4-byte unsigned big-endian integer, `u64be` is 8
bytes. `||` is concatenation. `b64` is standard Base64 with padding (RFC 4648 §4).
`hex` is lowercase hexadecimal. `SHA256` is SHA-256. Strings are UTF-8.

---

## 1. Cryptographic building blocks

| Purpose | Primitive |
|---|---|
| Long-term device identity | ECDSA P-256 (secp256r1) key pair, SHA-256 digest |
| Per-connection key agreement | Ephemeral ECDH P-256 |
| Key derivation | HKDF-SHA256 (RFC 5869) |
| Record protection | AES-256-GCM, 96-bit nonce, 128-bit tag |
| File integrity | SHA-256 over the complete file bytes |

These are available natively on both platforms (Android: `java.security` /
Android Keystore; macOS: CryptoKit), so no third-party crypto library is used.

**Public key encoding**: uncompressed X9.63 point, 65 bytes: `0x04 || X(32) || Y(32)`.
**Signature encoding**: ASN.1 DER `ECDSA-Sig-Value` (what `SHA256withECDSA` and
CryptoKit's `derRepresentation` produce).
**ECDH output**: the 32-byte big-endian X coordinate of the shared point.

### 1.1 Device identity

* Each install generates one identity key pair on first launch and keeps the
  private key in platform secure storage (Android Keystore / macOS Keychain).
* `fingerprint = hex(SHA256(identityPublicKeyX963))` — 64 hex chars.
* `deviceId = fingerprint[0:32]` — the first 16 bytes, 32 hex chars.

Trust is bound to the identity public key (and therefore the deviceId), never
to an IP address, port, or display name.

### 1.2 Why not TLS?

The product brief asks for TLS 1.3 where supported. Interoperable TLS between
Android's JSSE and Apple's Network framework would require each device to mint a
self-signed X.509 certificate, and on macOS to build a `SecIdentity` from a
generated key — which needs keychain certificate import paths that are hard to
make reliable for an unsigned app. TLS also gives no built-in way to show a
short comparison code for pairing.

v1 therefore uses a small, conventional authenticated key exchange (SIGMA-style:
ephemeral ECDH, signatures over the transcript, HKDF, AEAD records) built
only from standard primitives, plus a commitment so the pairing code cannot be
brute-forced by a man-in-the-middle. This is a deliberate trade-off and **should
be reviewed by a cryptographer before a 1.0 release**. See
`docs/security-model.md` for the threat model.

---

## 2. Discovery (DNS-SD / Bonjour / Android NSD)

* Service type: `_crossdrop._tcp` in the `local.` domain.
* Instance name: the user-visible device name, truncated to 63 bytes of UTF-8.
  Instance names are display hints only; they are not trusted.
* Port: any free TCP port, published via the SRV record.
* TXT record keys (all required):

  | key | value |
  |---|---|
  | `v` | highest protocol version supported, decimal (`1`) |
  | `id` | `deviceId` (32 hex chars) |
  | `p` | platform: `android` or `macos` |

  Optional: `m=1` means the device is in "My devices only" mode (§9.5); its
  instance name is then random and browsers should list it only when its `id`
  belongs to a paired device.
  Optional: `r=<hint>[,<hint>…]` lists up to 4 Drip Room hints (§9.9) for the
  rooms the device is in. A hint is not a secret and not proof of anything.

* No secrets, no account data and no file metadata are ever put in DNS-SD records.
* Discovery is **not** authentication. A device that advertises a trusted
  `id` is only considered trusted after the handshake proves possession of the
  matching identity key (§4).
* Devices only browse while a discovery screen or a send flow is visible, and
  only advertise while "Receiving" is switched on.

---

## 3. Framing

A connection is a single TCP stream. Everything on it is a **frame**:

```
frame = u32be(length) || payload        ; 1 <= length <= MAX
```

There are two phases.

### 3.1 Plaintext phase (handshake only)

`payload` is one UTF-8 JSON object. `MAX = 65536` (64 KiB).

Exactly four plaintext frames are exchanged: `hello` (client → server),
`auth.challenge` (server → client), `auth.proof` (client → server) and
`auth.proof` (server → client). A plaintext `error` frame may replace any server
frame in this phase (for example `busy` instead of `auth.challenge`). Every later
frame, in both directions, is encrypted.

### 3.2 Encrypted phase (records)

```
payload   = AES-256-GCM-Seal(key_dir, nonce, plaintext, aad = empty)   ; ciphertext || 16-byte tag
plaintext = kind(1 byte) || body
nonce     = 0x00000000 || u64be(seq)
```

* `seq` is a per-direction counter that starts at 0 and increments by one per
  record. Each side tracks its own send `seq` and the expected receive `seq`;
  a record that fails to decrypt is fatal (connection closed, no error frame).
* `kind = 0x01` **control**: `body` is one UTF-8 JSON object, at most 65536 bytes.
* `kind = 0x02` **data**: `body` is raw file bytes, 1 to 262144 bytes (256 KiB).
* Any other `kind` is fatal (`bad_frame`).
* `MAX` for the outer frame is `1 + 262144 + 16 = 262161`.

Receivers MUST check the length prefix before allocating, and MUST reject
`length == 0` or `length > MAX` for the current phase with `frame_too_large` /
`bad_frame` and close.

### 3.3 JSON rules

* Every JSON message has `"type"` (string) and `"v"` (integer protocol version, `1`).
* Unknown **fields** are ignored (forward compatibility). A missing required
  field, a wrong JSON type, or a value outside its limits is `bad_message`.
* An unknown `type`, or a known `type` arriving in the wrong state, is
  `unexpected_message`.
* Implementations never log file names, pairing codes, keys or signatures.

---

## 4. Handshake

The connecting side is the **client** (always the sender of files); the
listening side is the **server** (the receiver).

```
C → S  hello            (plaintext)  commits to client ephemeral key
S → C  auth.challenge   (plaintext)  server ephemeral + identity key
C → S  auth.proof       (plaintext)  reveals client ephemeral, identity, signature
S → C  auth.proof       (plaintext)  server signature
        -- both sides switch to encrypted records --
```

### 4.1 `hello` (C → S)

```json
{"type":"hello","v":1,"minV":1,"deviceId":"<32 hex>","name":"Pixel 8",
 "platform":"android","appVersion":"0.1.0","ephCommit":"<b64 SHA256(clientEphPub)>"}
```

* `v` is the highest version the client supports, `minV` the lowest.
  The server answers `error{code:"unsupported_version"}` and closes if
  `[minV, v]` does not contain a version it supports. v1 servers support `1` only.
* `name`: 1–64 Unicode scalar values after trimming. Display only.
* `platform`: `android` | `macos`.
* `ephCommit`: 32 bytes. The commitment stops a man-in-the-middle from choosing
  its own ephemeral key after seeing the client's, which would let it search for
  a pairing code that collides on both sides.

### 4.2 `auth.challenge` (S → C)

```json
{"type":"auth.challenge","v":1,"deviceId":"<32 hex>","name":"MacBook Air",
 "platform":"macos","appVersion":"0.1.0","ephPub":"<b64 65 bytes>","identityKey":"<b64 65 bytes>"}
```

The client MUST check `deviceId == hex(SHA256(identityKey))[0:32]`. If the client
already trusts a device with this `deviceId`, the identity key MUST be identical
to the stored one. Otherwise: `auth_failed`.

### 4.3 `auth.proof` (C → S, plaintext)

```json
{"type":"auth.proof","v":1,"ephPub":"<b64 65 bytes>","identityKey":"<b64 65 bytes>","signature":"<b64 DER>"}
```

The server MUST check, in this order, and answer `error{code:"auth_failed"}` on any failure:

1. `SHA256(ephPub) == ephCommit` from `hello`.
2. `hello.deviceId == hex(SHA256(identityKey))[0:32]`, and if that deviceId is
   trusted, `identityKey` equals the stored key.
3. `signature` verifies under `identityKey` over `"CrossDrop/1 client-proof" || TH`.

### 4.4 Transcript hash and key schedule

```
lp(x) = u32be(len(x)) || x
TH    = SHA256( "CrossDrop/1 transcript"
                || lp(helloBytes)          ; exact payload bytes of the hello frame
                || lp(challengeBytes)      ; exact payload bytes of the auth.challenge frame
                || lp(clientEphPub)        ; 65 bytes
                || lp(clientIdentityKey) ) ; 65 bytes

shared  = ECDH(ephemeral private, peer ephemeral public)                  ; 32 bytes
k_c2s   = HKDF-SHA256(ikm = shared, salt = TH, info = "CrossDrop/1 c2s", L = 32)
k_s2c   = HKDF-SHA256(ikm = shared, salt = TH, info = "CrossDrop/1 s2c", L = 32)
SAS     = u32be(SHA256("CrossDrop/1 sas" || TH)[0:4]) mod 1000000, zero-padded to 6 digits
```

Labels are ASCII without terminators. The client's signature covers
`"CrossDrop/1 client-proof" || TH`; the server's covers `"CrossDrop/1 server-proof" || TH`.
The hello and challenge are hashed as the exact bytes received, so JSON key order
and whitespace do not need to be canonical.

After verifying the client's proof the server answers with its own plaintext proof
(or a plaintext `error{code:"auth_failed"}`):

```json
{"type":"auth.proof","v":1,"signature":"<b64 DER>"}
```

The client verifies it under the server's `identityKey` and closes on failure.
From here on every frame is an encrypted record; the first `c2s` and `s2c`
records use seq 0. Because both signatures cover `TH`, which is the HKDF salt,
a successful first decryption also confirms both sides derived the same keys.

### 4.5 Timeouts

* TCP connect: 10 s. Each handshake step: 15 s.
* Waiting for a human (pairing confirmation, transfer approval): 120 s.
* Any read during an active file stream: 30 s without progress.

---

## 5. Pairing

After the handshake both sides know each other's verified identity key. If the
**client** does not trust the server, it sends `pair.request` as its first
message. If the client trusts the server but the server does not trust the
client, the server answers the client's first `transfer.offer` with
`error{code:"pairing_required"}` and keeps the connection open, and the client
may then send `pair.request` on the same connection.

```json
{"type":"pair.request","v":1}
{"type":"pair.confirm","v":1,"accepted":true}
```

1. On `pair.request` the server shows the 6-digit SAS and the client's name.
   The client shows the same SAS and the server's name.
2. Each user compares the codes and taps **Codes match** or **Cancel**.
3. Each side sends `pair.confirm` with its user's decision. The server sends
   it from the moment its user decides; the client likewise.
4. A side stores the peer as trusted **only after** both its own user
   accepted and it received the peer's `accepted: true`.
5. If either side declines, it sends `accepted:false`; both sides then close
   with no trust stored. Timeout (120 s) behaves like decline.

Stored trust record (local only): `deviceId`, `identityKey`, last known name,
platform, paired-at timestamp, last-used timestamp, `autoAccept` (default
false). "Forget" deletes the record; the next connection has to pair again.

---

## 6. Transfer

### 6.1 `transfer.offer` (C → S)

```json
{"type":"transfer.offer","v":1,"transferId":"<uuid>",
 "files":[{"fileId":0,"name":"IMG_0042.jpg","size":2481631,"mime":"image/jpeg","sha256":"<64 hex>"}]}
```

| field | rule |
|---|---|
| `transferId` | 8–64 chars of `[A-Za-z0-9-]`. Correlates all later messages. |
| `files` | 1–1000 entries. |
| `fileId` | integer, unique in the offer, `0 <= fileId < 1000`. Files are sent in array order. |
| `name` | display name, 1–1024 bytes before sanitising (§6.5). Never a path. |
| `size` | integer `0 <= size <= 2^53 - 1`. |
| `mime` | optional, at most 255 bytes. Receivers treat it as a hint only. |
| `sha256` | required, 64 lowercase hex chars: SHA-256 of the complete file content. |

The sender hashes each file before sending the offer ("Preparing…" in the UI).

### 6.2 Decision (S → C)

```json
{"type":"transfer.accept","v":1,"transferId":"…"}
{"type":"transfer.reject","v":1,"transferId":"…","reason":"declined"}
```

`reason`: `declined` | `busy` | `insufficient_storage` | `timeout` | `not_receiving`.
Senders from a trusted device with `autoAccept` on are accepted without a prompt.
Otherwise the receiver asks its user. After `transfer.reject` both sides close.

### 6.3 Streaming

For each file in offer order:

```
C → S  {"type":"transfer.start","v":1,"transferId":"…","fileId":0}
C → S  data record × n     ; exactly `size` bytes in total, each record 1..262144 bytes
```

* A zero-byte file is a `transfer.start` followed by no data records.
* The receiver writes into a temporary file, hashing as it goes, and never
  holds more than one record in memory.
* When `size` bytes have arrived the receiver compares the SHA-256. On mismatch
  it deletes the temporary file and sends `error{code:"integrity_failed"}`.
  On match it moves the file into the destination (§6.5).
* A data record arriving outside a file, or more bytes than `size`, is `bad_message`.

The receiver reports progress at most every 500 ms (and once per finished file):

```json
{"type":"transfer.progress","v":1,"transferId":"…","fileId":0,"bytes":1048576}
```

`bytes` counts bytes received for that file. Senders use it to show the receiver's
progress; it is not an acknowledgement and senders do not wait for it.

After every file has been verified and saved:

```json
S → C  {"type":"transfer.complete","v":1,"transferId":"…"}
```

The client then closes the connection. Files that were saved before a later
failure stay saved; the UI reports which ones made it.

### 6.4 Cancel and errors

Either side may send at any time after the offer:

```json
{"type":"transfer.cancel","v":1,"transferId":"…","reason":"user"}
{"type":"error","v":1,"code":"integrity_failed","message":"optional human-readable text"}
```

After sending or receiving either, both sides stop, the receiver deletes any
partial file, and the connection closes. `message` is for logs; UIs map `code`.

| code | meaning |
|---|---|
| `bad_frame` | invalid length prefix or record kind |
| `frame_too_large` | length above the phase maximum |
| `bad_message` | malformed JSON or field validation failure |
| `unexpected_message` | unknown type or wrong state |
| `unsupported_version` | no common protocol version |
| `auth_failed` | commitment, identity or signature check failed |
| `pairing_required` | receiver does not trust the sender |
| `pairing_rejected` | user declined pairing |
| `busy` | receiver at its concurrent-connection limit (3) |
| `not_receiving` | receiver has receiving switched off |
| `integrity_failed` | SHA-256 mismatch |
| `insufficient_storage` | not enough free space at the destination |
| `storage_error` | could not write the destination |
| `timeout` | a §4.5 timeout elapsed |
| `internal` | anything else |

### 6.5 Receiver file handling

Sanitising `name` (same rules on both platforms; vectors in `v1.json`):

1. Unicode NFC normalisation.
2. Keep only the part after the last `/` or `\`.
3. Remove C0 controls (U+0000–U+001F), U+007F and C1 controls (U+0080–U+009F).
4. Replace each of `<>:"|?*` with `_`.
5. Trim leading/trailing whitespace; strip leading `.` characters
   (no hidden files, no `..`).
6. If the result is empty, use `file`.
7. If longer than 200 bytes of UTF-8, shorten the stem (keeping an extension
   of up to 16 bytes, including the dot) at a scalar-value boundary.

Then:

* Write to a temporary location on the destination volume, never to the final name.
* Verify size and SHA-256 before the file becomes visible under its real name.
* Never overwrite. If `name` exists, use `stem (1).ext`, `stem (2).ext`, … The
  user can rename afterwards; asking replace/skip is planned, not in v1.
* Before accepting, check that the free space is at least the offer total plus
  a margin of 64 MiB; otherwise reject with `insufficient_storage`.

---

## 7. Limits summary

| item | limit |
|---|---|
| plaintext / control frame body | 64 KiB |
| data record body | 256 KiB |
| files per offer | 1000 |
| concurrent inbound connections | 3 |
| handshake step timeout | 15 s |
| human decision timeout | 120 s |
| stream inactivity timeout | 30 s |
| progress message rate | ≤ 2 per second per connection (one transfer, except Turbo §9.10), plus one per finished file |

## 8. Versioning

`v` is the protocol version, separate from the app version. Additive optional
fields keep `v = 1`. Any change to framing, crypto, the handshake or required
fields needs `v = 2` and a new section in a `protocol-v2.md`.

---

## 9. Optional extensions (still `v = 1`)

Everything here is additive and optional (§8): an implementation that ignores
these fields still interoperates, it just doesn't get the feature. Both
reference cores (Kotlin and Swift) implement all of it, and
`integration-tests/interop.sh` exercises each item across them.

### 9.1 Folders

A `transfer.offer` file entry may carry `path`: the folders to recreate on the
receiver, outermost first, joined with `/` (for example `"Trip/Day 1"`).

* The string is at most 1024 bytes of UTF-8. It is split on `/` **and** `\`;
  each part is trimmed, `""`, `"."` and `".."` are dropped, and every remaining
  part is sanitised exactly like a file name (§6.5). More than 16 parts is
  `bad_message`.
* The receiver creates the folders under its destination one at a time and
  refuses (`storage_error`) any existing item on the way that is a symlink or
  not a folder. The file itself then follows the normal §6.5 rules inside that
  folder (temporary file, verify, never overwrite).
* Because every part is sanitised and dot parts are dropped, a path can never
  name anything outside the destination.

### 9.2 Links and text

`transfer.offer` may carry `kind`: `"files"` (default, same as absent),
`"link"` or `"text"`. Any other value is `bad_message`.

* `link` / `text` offers have exactly one file entry of at most 65536 bytes;
  anything else is `bad_message`. The bytes are the UTF-8 text; the sender uses
  `mime: "text/plain; charset=utf-8"`.
* The receiver keeps the payload in memory, checks its SHA-256 as usual,
  rejects invalid UTF-8 (`bad_message`) and **never writes it to storage**.
* What happens next is up to the receiving app and must stay explicit: the Mac
  app opens `http`/`https` links in the default browser and copies text to the
  clipboard; nothing is executed or opened for any other scheme.
* Approval rules are the same as for files: an unpaired device must pair, and a
  paired device without auto-accept gets a prompt.

### 9.3 Resuming an interrupted transfer

When a connection drops (`connection_lost` or a stream `timeout`) in the middle
of a file, the receiver may keep the bytes received so far for 24 hours. It
does not keep them after a cancel, an integrity failure or any other error.

* The kept part is indexed by
  `resumeKey = hex(SHA-256("CrossDrop/1 resume|" + senderDeviceId + "|" + fileSha256 + "|" + fileSize))`,
  so only the same file (same content and size) from the same sender can
  continue it.
* `transfer.accept` may carry `resume: [{"fileId": n, "offset": k}, …]`, one
  entry per file the receiver holds `k` bytes of, with `0 < k < size`. The
  sender rejects a malformed list with `bad_message`.
* `transfer.start` may then carry `offset`. The sender either sends the offered
  offset and skips that many bytes of the file, or omits it (or sends `0`) and
  sends the whole file, in which case the receiver discards its kept part. Any
  other value is `bad_message`.
* The receiver re-hashes the kept bytes before appending, so the final SHA-256
  check still covers the whole file.

### 9.4 Pairing with a QR code

The receiver can show a QR code instead of asking both people to compare
numbers. The code holds a URI:

```
crossdrop://pair?v=1&id=<deviceId>&fp=<fingerprint>&t=<token>&n=<name>&p=<port>&h=<host1>,<host2>
```

* `fp` is the lowercase hex SHA-256 of the receiver's identity key; `t` is a
  one-time token (16 random bytes, base64url without padding) that the receiver
  issued and accepts once, within 5 minutes. `h` lists the receiver's current
  addresses, so the scanner can connect even where DNS-SD is blocked.
* The scanner runs the normal handshake (§4), then checks that the peer's
  identity-key fingerprint equals `fp`; a mismatch ends the connection with
  `auth_failed`. It then sends `pair.request` with `"token": t`.
* A receiver that redeems a valid token skips its prompt; the scanner skips its
  prompt too, because it has just verified the key it was shown. Both sides
  still exchange `pair.confirm` (§5). An invalid or reused token falls back to
  the normal numeric comparison.
* Seeing the receiver's screen is the out-of-band check here: the QR code binds
  the exact identity key, so a device in the middle cannot substitute its own.
* Each side may record a local "This is my device" choice with the new trust
  entry; apps use it to auto-accept that device's transfers. It never goes on
  the wire.
* A connection made only to pair simply closes after `pair.confirm`; the
  receiver treats that close as normal, not as an error.

### 9.5 "My devices only"

A receiver in this mode accepts connections only from devices it has already
paired with, or from a device presenting a valid QR token (§9.4).

* After the handshake, `pair.request` without a valid token and
  `transfer.offer` from an unpaired device are answered with `error`
  `not_receiving` and the connection is closed.
* It advertises with a random instance name and `m=1` (§2), so people nearby
  don't see the device's name. The `id` key is still present so paired devices
  can recognise it.
* Paired devices may remember the address that last worked and try it directly
  when discovery doesn't find the receiver (networks that block multicast).
  To keep that address useful, both reference apps listen on TCP port 47100
  when it is free and fall back to any free port otherwise; the port is still
  announced over DNS-SD and in the QR code, so nothing depends on it.
  The handshake still authenticates the device, so a stale address can at worst
  fail to connect.

### 9.6 Limits added by this section

Covers §9.1–§9.10.

| item | limit |
|---|---|
| link / text payload | 64 KiB |
| `path` length | 1024 bytes |
| `path` depth | 16 folders |
| QR pairing token lifetime | 5 minutes, single use |
| kept partial file for resume | 24 hours |
| capture `requestId` | 8–64 chars of `[A-Za-z0-9-]` |
| outstanding capture request | 10 minutes, single use, one device |
| requester waiting for `capture.ack` | human decision timeout (120 s) + 5 s |
| `expiresAfter` | 60 s – 2 592 000 s (30 days) |
| Drip Room lifetime | at most 4 hours (+ 5 minutes clock skew when checking a code) |
| room code URI | 2048 bytes, at most 8 hosts |
| room hints in TXT `r` | 4 |
| room joiner waiting for the room-proved `pair.confirm` | 5 s, then codes |
| Turbo `parallel` / `join.max` | 2–4 connections per transfer, main one included |
| Turbo connections vs. the inbound limit | each one counts (reference cores: 3 in total) |
| Turbo join token | 16 random bytes, one transfer, until it ends |

### 9.7 Capture requests ("Take a photo with your phone")

A device can ask a paired device to take a photo (or pick files) and send the
result back. Typical use: the Mac asks the phone.

* The requester connects as a client, completes the handshake (§4) and sends
  (instead of `transfer.offer`):

  ```json
  {"type":"capture.request","v":1,"requestId":"<id>","kind":"photo","port":47100}
  ```

  `requestId` follows the `transferId` rules (8–64 chars of `[A-Za-z0-9-]`);
  `kind` is `"photo"` (take a new photo) or `"pick"` (choose existing items);
  the optional `port` (1–65535) is the requester's own listening port for the
  answer. Anything else in those fields is `bad_message`.
* The receiver answers `{"type":"capture.ack","v":1,"requestId":"<id>","accepted":true|false}`
  and the connection closes. Its app decides (it may ask the user first; the
  requester waits up to the human decision timeout).
* `capture.request` itself never pairs. The receiver checks trust when the
  message arrives: a client it does not trust gets
  `error{code:"pairing_required"}` and the connection closes; in "My devices
  only" mode (§9.5) it gets `not_receiving` as usual.
* A requester that does not trust the other device yet may first send a normal
  `pair.request` on the same connection (§5, codes compared on both screens, or
  a QR token / room proof as in §9.4 / §9.9) and then `capture.request` once
  pairing succeeded; the receiver re-reads its trust store for every message,
  so the request then counts as coming from a paired device. The reference
  requesters do this only when the app passes a pairing delegate / listener
  (`CaptureClient.request(..., pairing:)` in Kotlin, `pairingDelegate:` in
  Swift); without one they refuse to ask a device they do not trust
  (`pairing_required`, nothing sent).
* The answer is a normal transfer (§6) from the phone to the requester, sent to
  the address the request came from (the remote IP of that connection) and
  `port` (or wherever discovery finds the requester when `port` is absent). Its
  `transfer.offer` carries the optional `"requestId": "<id>"`.
* The requester keeps the set of requestIds it issued, each bound to the
  `deviceId` it was sent to, valid for 10 minutes and usable once. An offer
  whose `requestId` matches one of them **from that same device** is accepted
  without a prompt, even when that device is not set to auto-accept. A
  `requestId` that does not match (unknown, expired, used, or presented by a
  different device) is ignored: the offer follows the normal rules. A
  mismatched presentation does not use the entry up, and neither does an offer
  the requester rejects for a local reason before accepting it
  (`not_receiving`, `insufficient_storage`): the entry is used up only when the
  offer is accepted, so the phone can send the answer again. Apps only see
  `requestId` on an incoming transfer when it matched.
* An unpaired device still cannot send anything: `transfer.offer` from an
  untrusted client gets `pairing_required` before `requestId` is looked at.

### 9.8 Expiring drops

`transfer.offer` may carry `expiresAfter`: an integer number of seconds, 60 to
2 592 000 (30 days). Any other value or type is `bad_message`.

* It is the sender's request that the receiver delete what it saved from this
  transfer that long after it was received. The protocol only carries the
  number; both cores expose it on the incoming offer/transfer and do nothing
  else.
* Deleting is the receiving **app's** job: it records what it saved and when,
  and removes those files once the time is up. Approval and verification work
  exactly as for any other offer.
* This is a courtesy, not a security feature. The receiver can copy, forward or
  back up the items before they are deleted, and an app that ignores the field
  keeps them forever. Senders must not treat it as a guarantee.

### 9.9 Drip Rooms (temporary group trust)

A room lets everyone at a meeting pair with each other without comparing codes,
for a limited time. One device creates the room and shows its QR code; others
scan it.

* A room is `{roomId, roomKey, name, expiresAt}`: `roomId` is 16 random bytes
  and `roomKey` 32 random bytes, both base64url without padding (canonical
  encoding only), `name` is display text, and `expiresAt` is unix seconds, at
  most 4 hours after creation. The QR code holds:

  ```
  crossdrop://room?v=1&id=<roomId>&k=<roomKey>&n=<name>&exp=<unix>&h=<host1>,<host2>&p=<port>&fp=<fingerprint>
  ```

  `h`, `p` and `fp` (lowercase hex SHA-256 of the showing device's identity
  key) let a joiner reach the device that shows the code where DNS-SD is
  blocked, like §9.4. Values are percent-encoded (everything except RFC 3986
  unreserved characters); `+` decodes as a space. Parsers reject: a URI over
  2048 bytes, a duplicate key, a malformed escape, invalid UTF-8, `v` ≠ 1, a bad
  `id`/`k`, `exp` not in the future or more than 4 hours + 5 minutes ahead, a
  missing or invalid host list (1–8 comma-separated entries of
  `[0-9A-Za-z.:%_-]`, 1–64 chars each; entries are not trimmed, so any
  whitespace makes the code invalid), a port outside 1–65535, or a bad `fp`.
  Unknown keys are ignored; a missing name becomes "Room".
* Devices in an active room may advertise
  `r = hex(SHA-256("CrossDrop/1 room|" || roomId)[0:8])` (16 hex chars, §2),
  where `roomId` is the 22-character base64url **text** as ASCII bytes, not the
  16 bytes it decodes to (shared vector `roomHint` in
  `protocol/test-vectors/v1.json`: `AAECAwQFBgcICQoLDA0ODw` →
  `da19855d5fe9499b`). Several hints are comma-separated; parsers ignore ASCII
  spaces (U+0020 only) around each one and drop entries that are not 16
  lowercase hex characters. It only helps a joiner pick which room to use with
  which device; discovery remains a hint.
* **Pairing by room.** A client that holds the room sends
  `pair.request` with `"room": {"id": "<roomId>", "proof": "<b64>"}` where
  `proof = HMAC-SHA256(roomKey, "CrossDrop/1 room|" || TH)` and `TH` is the
  handshake transcript hash (§4.4). The receiver looks the id up among its
  active rooms and compares the proof in constant time. A malformed `room`
  object is `bad_message`; an unknown room or a wrong proof is not an error:
  pairing simply falls back to the normal code comparison (§5).
* If the proof is valid, the receiver answers at once, without a prompt, with
  `{"type":"pair.confirm","v":1,"accepted":true,"room":{"id":"<roomId>","proof":"<b64>"}}`,
  `proof = HMAC-SHA256(roomKey, "CrossDrop/1 room-confirm|" || TH)`. The client
  accepts without a prompt only if that proof is valid, so **both** sides have
  shown they hold the room key. A client that sees no such answer within 5
  seconds, or a `pair.confirm` without a valid room proof, shows the normal
  code comparison instead. Each side then stores **temporary** trust that ends
  at the room's `expiresAt`; once it has passed, the device is untrusted again
  and the next connection pairs again (with codes, or with a new room). Room
  trust never sets auto-accept.
* A receiver that already holds permanent trust for the client keeps it (it
  still sends its room proof, so the client can skip codes). A QR token (§9.4)
  takes precedence over a room proof.
* "My devices only" receivers (§9.5) accept a valid room proof like a QR token.
* Only trust stores that can expire trust take part: an implementation whose
  store cannot honour `expiresAt` must not send or accept room proofs (the
  reference cores check `supportsTrustExpiry`), so a room can never silently
  create permanent trust.
* Security notes: the proofs bind the room key to this exact handshake (`TH`
  covers both ephemeral keys and both identities), so a captured proof cannot be
  replayed on another connection, and a device in the middle cannot pass the
  check without the key. Anyone who holds the room code — a photo of the screen
  is enough — can join until it expires; treat the code like a meeting
  password and keep rooms short. Trust from a room is temporary by design.
  Transfers between room members still go through the normal approval rules
  (no auto-accept).

### 9.10 Turbo (parallel connections)

A multi-file transfer may be spread over several TCP connections to the same
receiver, so one slow file or one congested connection does not hold up the
rest. It is opt-in on both sides; without agreement the transfer runs exactly
as in §6.

* **Asking.** A sender with at least two files may add `"parallel": n` to
  `transfer.offer`, `n` an integer 2–4 (the total number of connections it
  would like, the main one included). Any other value or type is
  `bad_message`. Receivers ignore it on `link` / `text` offers and on
  one-file offers.
* **Granting.** A receiver that supports Turbo and accepts the offer may add
  to `transfer.accept`:

  ```json
  "join": {"token": "<16 random bytes, base64url, no padding>", "max": m}
  ```

  with `2 <= m <= n`. `m` is the total number of connections it allows, main
  one included. Every connection counts toward the receiver's inbound
  connection limit (§7), so the reference receivers grant at most
  `min(n, 4, files, 3 − open connections + 1)` and omit `join` when that is
  below 2. A sender that asked rejects a malformed `join` (token not 22
  characters of `[A-Za-z0-9_-]`, `max` outside 2…`n`) with `bad_message`; a
  sender that did not ask ignores the field. Old receivers ignore `parallel`
  and old senders never see `join`.
* **Joining.** The sender may then open up to `m − 1` extra connections to the
  address the main connection reached. Each runs the full handshake (§4). The
  peer must already be trusted **on both sides** (the main connection paired
  them if needed): no pairing happens on an extra connection, and a sender
  checks that the handshake reached the same `deviceId` with the same identity
  key before going on. Its first message is

  ```json
  {"type":"transfer.join","v":1,"transferId":"…","token":"…"}
  ```

  and the receiver answers `{"type":"transfer.joined","v":1,"transferId":"…"}`
  or an `error` and closes that connection:

  | case | code |
  |---|---|
  | client not trusted | `pairing_required` (`not_receiving` in "My devices only") |
  | unknown or finished transfer, or a transfer of another device | `unexpected_message` |
  | wrong token (compared in constant time) | `auth_failed` |
  | `m` connections already in use | `busy` |

  A refused join never affects the transfer; the sender simply carries on with
  fewer connections. The token is valid for that one transfer until it ends.
* **Files.** The sender assigns each file to one connection and streams it
  whole there: `transfer.start` (with `offset` when resuming, §9.3) followed by
  its data records, exactly as in §6.3. On a Turbo transfer `transfer.start`
  may arrive on any of its connections and files may arrive in any order (the
  "array order" rule of §6.1 does not apply); a `transfer.start` for a file
  that was already started, or for an unknown `fileId`, is `bad_message`. The
  reference senders hand out files in offer order from one shared queue, each
  connection taking the next file when it is free, and give the extra
  connections up to 1 s to join before the first file starts.
* **Receiving.** The receiver verifies each file's SHA-256 and saves it as
  today (§6.5; parallel saves never overwrite each other). It sends
  `transfer.progress` on the connection that carries that file, throttled per
  connection (≤ 2 per second on each, plus one per finished file, §7), so a
  Turbo transfer may produce up to 2 × `m` progress messages per second in
  total, and
  `transfer.complete` on the **main** connection once every file is verified.
  The sender then closes the extra connections; the receiver closes any that
  are still open shortly afterwards. Inactivity (§4.5) is judged over all the
  transfer's connections together: one connection may be idle while another is
  busy.
* **Failure.** `transfer.cancel` or `error` on any connection, or a failed file,
  ends the whole transfer: every one of its connections is closed. When it is
  the receiver's own error (or cancel) it says so on each connection that is
  still open (`error`, or `transfer.cancel`); the sender reports its own error
  on the main connection and closes the others (a cancel goes out on the main
  connection and on every extra connection that has joined; one still in its
  handshake or waiting for `transfer.joined` is just closed). Partial files follow
  §9.3 (kept for a resume only when the reason is a dropped connection or a
  timeout).
* **Dropped connections.** The receiver cannot tell whether a file was on its
  way, so any of the transfer's connections closing before `transfer.complete`
  ends the transfer there. The sender ends it when a connection drops in the
  middle of a file (after waiting up to 1 s for the receiver's reason on the
  other connections, so the user sees the real cause), and ignores an extra
  connection that drops when it has nothing left to send: the receiver's
  verdict still arrives on the main connection.
* **Refused joins** are not failed transfers: the reference receivers do not
  report them to the app, and the sender carries on with the connections it
  has.
* **Security notes.** Every connection is a fully authenticated, encrypted
  session of its own (§4); the token only links it to the transfer and is
  checked against the device that made the offer, so another paired device
  cannot attach itself to someone else's transfer. Turbo changes neither the
  approval rules nor the trust model. It can be switched off on the receiver
  (the reference servers take a `turbo` setting); a sender that is refused
  falls back to one connection.
