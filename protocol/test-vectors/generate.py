#!/usr/bin/env python3
"""Generates protocol/test-vectors/v1.json.

Reference implementation of the deterministic parts of docs/protocol-v1.md.
Requires the `cryptography` package. Fixed private keys make every value
reproducible except ECDSA signatures, which are randomised; those vectors are
"must verify" checks, not byte-for-byte outputs.

Usage: python3 -I protocol/test-vectors/generate.py > protocol/test-vectors/v1.json
"""
import base64
import hashlib
import json
import struct
import sys
import unicodedata

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def priv(hexd: str) -> ec.EllipticCurvePrivateKey:
    return ec.derive_private_key(int(hexd, 16), ec.SECP256R1())


def x963(key) -> bytes:
    pub = key.public_key() if hasattr(key, "public_key") else key
    return pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def lp(b: bytes) -> bytes:
    return struct.pack(">I", len(b)) + b


def hkdf(ikm: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def nonce(seq: int) -> bytes:
    return b"\x00\x00\x00\x00" + struct.pack(">Q", seq)


def seal(key: bytes, seq: int, kind: int, body: bytes) -> bytes:
    return AESGCM(key).encrypt(nonce(seq), bytes([kind]) + body, None)


def sign(key, data: bytes) -> bytes:
    return key.sign(data, ec.ECDSA(hashes.SHA256()))


def device_id(identity_pub: bytes) -> str:
    return hashlib.sha256(identity_pub).hexdigest()[:32]


FORBIDDEN = set('<>:"|?*')


def sanitize(name: str) -> str:
    s = unicodedata.normalize("NFC", name)
    cut = max(s.rfind("/"), s.rfind("\\"))
    s = s[cut + 1:]
    s = "".join(c for c in s if not (ord(c) <= 0x1F or 0x7F <= ord(c) <= 0x9F))
    s = "".join("_" if c in FORBIDDEN else c for c in s)
    s = s.strip().lstrip(".")
    if not s:
        return "file"
    if len(s.encode()) <= 200:
        return s
    dot = s.rfind(".")
    ext = s[dot:] if dot > 0 and len(s[dot:].encode()) <= 16 else ""
    stem = s[: len(s) - len(ext)]
    budget = 200 - len(ext.encode())
    out = ""
    for ch in stem:
        if len((out + ch).encode()) > budget:
            break
        out += ch
    return out + ext


def main() -> None:
    client_id = priv("6c1f7a1b4e9a2d3c5f80e1b27c9d4a6f3e2b1c0d9a8f7e6d5c4b3a2918273645")
    server_id = priv("2b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfe")
    client_eph = priv("a5c1d3e7f90b2c4d6e8f0a1b3c5d7e9f1a2b3c4d5e6f708192a3b4c5d6e7f809")
    server_eph = priv("0f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0")

    cid, sid = x963(client_id), x963(server_id)
    cep, sep = x963(client_eph), x963(server_eph)

    hello = json.dumps({
        "type": "hello", "v": 1, "minV": 1, "deviceId": device_id(cid), "name": "Pixel 8",
        "platform": "android", "appVersion": "0.1.0", "ephCommit": b64(hashlib.sha256(cep).digest()),
    }, separators=(",", ":")).encode()
    challenge = json.dumps({
        "type": "auth.challenge", "v": 1, "deviceId": device_id(sid), "name": "Studio Mac",
        "platform": "macos", "appVersion": "0.1.0", "ephPub": b64(sep), "identityKey": b64(sid),
    }, separators=(",", ":")).encode()

    th = hashlib.sha256(b"CrossDrop/1 transcript" + lp(hello) + lp(challenge) + lp(cep) + lp(cid)).digest()
    shared = client_eph.exchange(ec.ECDH(), server_eph.public_key())
    assert shared == server_eph.exchange(ec.ECDH(), client_eph.public_key())
    k_c2s = hkdf(shared, th, b"CrossDrop/1 c2s")
    k_s2c = hkdf(shared, th, b"CrossDrop/1 s2c")
    sas_int = struct.unpack(">I", hashlib.sha256(b"CrossDrop/1 sas" + th).digest()[:4])[0] % 1000000
    sas = f"{sas_int:06d}"

    client_sig = sign(client_id, b"CrossDrop/1 client-proof" + th)
    server_sig = sign(server_id, b"CrossDrop/1 server-proof" + th)

    control = json.dumps({"type": "pair.request", "v": 1}, separators=(",", ":")).encode()
    data = bytes(range(256)) * 4
    records = []
    for direction, key, seq, kind, body in [
        ("c2s", k_c2s, 0, 1, control),
        ("c2s", k_c2s, 1, 2, data),
        ("s2c", k_s2c, 0, 1, json.dumps({"type": "auth.proof", "v": 1, "signature": "AA=="}, separators=(",", ":")).encode()),
        ("s2c", k_s2c, 7, 2, b"x"),
    ]:
        payload = seal(key, seq, kind, body)
        records.append({
            "direction": direction, "seq": seq, "kind": kind, "bodyHex": body.hex(),
            "payloadHex": payload.hex(), "frameHex": (struct.pack(">I", len(payload)) + payload).hex(),
        })

    hkdf_rfc = {  # RFC 5869 test case 1
        "ikmHex": "0b" * 22, "saltHex": "000102030405060708090a0b0c", "infoHex": "f0f1f2f3f4f5f6f7f8f9",
        "length": 42,
        "okmHex": "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
    }

    long_name = "é" * 150 + ".jpeg"
    sanitize_cases = [
        "photo.jpg", "../../etc/passwd", "C:\\Users\\me\\secret.txt", "..", ".hidden", "   spaced  .pdf  ",
        "a<b>c:d\"e|f?g*h.txt", "tab\there\nnewline.txt", "e\u0301cole.txt", "", "/", "日本語のファイル.png",
        "emoji 🎉 party.mov", long_name, "x" * 250, "noext" + "y" * 300, "report.final." + "z" * 40,
    ]

    vectors = {
        "description": "CrossDrop protocol v1 test vectors. Generated by generate.py; see docs/protocol-v1.md.",
        "identity": {
            "clientIdentityPrivHex": "6c1f7a1b4e9a2d3c5f80e1b27c9d4a6f3e2b1c0d9a8f7e6d5c4b3a2918273645",
            "clientIdentityPubHex": cid.hex(),
            "clientFingerprint": hashlib.sha256(cid).hexdigest(),
            "clientDeviceId": device_id(cid),
            "serverIdentityPrivHex": "2b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfe",
            "serverIdentityPubHex": sid.hex(),
            "serverFingerprint": hashlib.sha256(sid).hexdigest(),
            "serverDeviceId": device_id(sid),
        },
        "handshake": {
            "clientEphPrivHex": "a5c1d3e7f90b2c4d6e8f0a1b3c5d7e9f1a2b3c4d5e6f708192a3b4c5d6e7f809",
            "clientEphPubHex": cep.hex(),
            "serverEphPrivHex": "0f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0",
            "serverEphPubHex": sep.hex(),
            "ephCommitB64": b64(hashlib.sha256(cep).digest()),
            "helloUtf8": hello.decode(),
            "challengeUtf8": challenge.decode(),
            "transcriptHashHex": th.hex(),
            "sharedSecretHex": shared.hex(),
            "keyC2sHex": k_c2s.hex(),
            "keyS2cHex": k_s2c.hex(),
            "sas": sas,
            "clientSignatureDerHex": client_sig.hex(),
            "serverSignatureDerHex": server_sig.hex(),
            "tamperedClientSignatureNote": "flip any byte of TH: clientSignatureDerHex must then fail to verify",
        },
        "records": records,
        "hkdfRfc5869Case1": hkdf_rfc,
        "sha256": [
            {"utf8": "", "hex": hashlib.sha256(b"").hexdigest()},
            {"utf8": "hello", "hex": hashlib.sha256(b"hello").hexdigest()},
        ],
        "sanitize": [{"input": n, "output": sanitize(n)} for n in sanitize_cases],
        "frames": {
            "maxPlaintextPayload": 65536,
            "maxEncryptedPayload": 262161,
            "maxDataBody": 262144,
            "invalidLengthPrefixesHex": ["00000000", "00010001"],
            "invalidLengthNote": "both are invalid in the plaintext phase: zero length, and 65537 > 64 KiB",
        },
    }
    json.dump(vectors, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
