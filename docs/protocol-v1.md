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
| progress message rate | ≤ 2 per second per transfer |

## 8. Versioning

`v` is the protocol version, separate from the app version. Additive optional
fields keep `v = 1`. Any change to framing, crypto, the handshake or required
fields needs `v = 2` and a new section in a `protocol-v2.md`.
