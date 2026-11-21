import Foundation
import CryptoKit
import Security

/// base64url without padding (RFC 4648 §5), decoded strictly.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil unless `text` is the canonical unpadded encoding of its bytes.
    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ isAlphabet($0) }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }

    private static func isAlphabet(_ c: UInt8) -> Bool {
        (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95
    }
}

/// A Drip Room (§9.9): temporary group trust for a meeting. Everyone holding the room
/// key can pair with everyone else in the room without comparing codes, and the trust
/// this creates ends at `expiresAt` (unix seconds).
public struct Room: Equatable {
    /// 16 random bytes, base64url without padding (22 characters).
    public let id: String
    /// 32 bytes.
    public let key: Data
    public let name: String
    /// Unix seconds.
    public let expiresAt: Int64

    public init?(id: String, key: Data, name: String, expiresAt: Int64) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Rooms.isValidId(id), key.count == 32, expiresAt > 0,
              !trimmed.isEmpty, name.unicodeScalars.count <= 64 else { return nil }
        self.id = id
        self.key = key
        self.name = name
        self.expiresAt = expiresAt
    }

    public var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }

    public func isActive(now: Date = Date()) -> Bool { now < expiryDate }

    /// The DNS-SD TXT `r` value devices in this room advertise (a hint only).
    public var hint: String { Rooms.hint(roomId: id) }

    /// `pair.request` proof: HMAC-SHA256(roomKey, "CrossDrop/1 room|" || TH).
    public func proof(transcriptHash: Data) -> Data {
        mac(Labels.room + transcriptHash)
    }

    /// `pair.confirm` proof from the receiver: HMAC-SHA256(roomKey, "CrossDrop/1 room-confirm|" || TH).
    public func confirmProof(transcriptHash: Data) -> Data {
        mac(Labels.roomConfirm + transcriptHash)
    }

    private func mac(_ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Compares without an early exit, so timing does not reveal how much of a proof was right.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// What a room QR code carries (§9.9):
/// `crossdrop://room?v=1&id=<roomId>&k=<roomKey>&n=<name>&exp=<unix>&h=<hosts>&p=<port>&fp=<fingerprint>`.
/// `hosts`, `port` and `fingerprint` describe the device that shows the code, so a joiner
/// can reach it where DNS-SD is blocked.
public struct RoomInvite: Equatable {
    public static let prefix = "crossdrop://room?"
    static let maxURI = 2048
    static let maxHosts = 8

    public let room: Room
    public let hosts: [String]
    public let port: UInt16
    /// SHA-256 of the showing device's identity key, lowercase hex.
    public let fingerprint: String

    public init?(room: Room, hosts: [String], port: UInt16, fingerprint: String) {
        guard !hosts.isEmpty, hosts.count <= Self.maxHosts, hosts.allSatisfy({ Self.isValidHost($0) }),
              port > 0, Hex.isLowerHex(fingerprint, length: 64) else { return nil }
        self.room = room
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
    }

    /// The URI to put in the QR code.
    public var uri: String {
        let pairs: [(String, String)] = [
            ("v", "\(ProtocolConstants.version)"),
            ("id", room.id),
            ("k", Base64URL.encode(room.key)),
            ("n", room.name),
            ("exp", "\(room.expiresAt)"),
            ("h", hosts.joined(separator: ",")),
            ("p", "\(port)"),
            ("fp", fingerprint),
        ]
        return Self.prefix + pairs.map { "\($0.0)=\(Self.percentEncode($0.1))" }.joined(separator: "&")
    }

    /// Parses a room QR code. Returns nil for anything malformed, a room that has expired,
    /// or one that claims to last longer than 4 hours (plus clock skew).
    public static func parse(_ raw: String, now: Date = Date()) -> RoomInvite? {
        guard raw.utf8.count <= maxURI, raw.hasPrefix(prefix) else { return nil }
        let body = String(raw.dropFirst(prefix.count))
        var query: [String: String] = [:]
        for part in body.split(separator: "&", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { return nil }
            let key = String(part[part.startIndex..<eq])
            guard let value = percentDecode(String(part[part.index(after: eq)...])) else { return nil }
            guard query[key] == nil else { return nil } // duplicate key
            query[key] = value
        }
        guard query["v"] == "\(ProtocolConstants.version)" else { return nil }
        guard let id = query["id"], Rooms.isValidId(id) else { return nil }
        guard let keyText = query["k"], keyText.utf8.count == 43,
              let key = Base64URL.decode(keyText), key.count == 32 else { return nil }
        guard let expText = query["exp"], isDigits(expText), let exp = Int64(expText) else { return nil }
        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        guard exp > nowSeconds,
              exp <= nowSeconds + ProtocolConstants.roomMaxTTL + ProtocolConstants.roomClockSkew else { return nil }
        guard let hostText = query["h"] else { return nil }
        let hosts = hostText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !hosts.isEmpty, hosts.count <= maxHosts, hosts.allSatisfy({ isValidHost($0) }) else { return nil }
        guard let portText = query["p"], isDigits(portText), let portValue = Int64(portText),
              (1...65535).contains(portValue) else { return nil }
        guard let fingerprint = query["fp"], Hex.isLowerHex(fingerprint, length: 64) else { return nil }
        guard let room = Room(id: id, key: key, name: Rooms.cleanName(query["n"]), expiresAt: exp) else { return nil }
        return RoomInvite(room: room, hosts: hosts, port: UInt16(portValue), fingerprint: fingerprint)
    }

    static func isValidHost(_ host: String) -> Bool {
        let utf8 = host.utf8
        guard (1...64).contains(utf8.count) else { return false }
        return utf8.allSatisfy { c in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c)
                || c == 46 || c == 58 || c == 37 || c == 95 || c == 45
        }
    }

    private static func isDigits(_ text: String) -> Bool {
        let utf8 = text.utf8
        return (1...12).contains(utf8.count) && utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isUnreserved(_ c: UInt8) -> Bool {
        (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c)
            || c == 45 || c == 46 || c == 95 || c == 126
    }

    private static let upperHex = Array("0123456789ABCDEF")

    /// Percent-encodes everything except RFC 3986 unreserved characters (identical to the Kotlin core).
    static func percentEncode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if isUnreserved(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(upperHex[Int(byte >> 4)])
                out.append(upperHex[Int(byte & 0x0f)])
            }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    /// Decodes %XX escapes (and `+` as a space); nil for a malformed escape, a raw
    /// non-printable or non-ASCII character, or invalid UTF-8.
    static func percentDecode(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let c = bytes[index]
            if c == 37 {
                guard index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else { return nil }
                out.append((high << 4) | low)
                index += 3
            } else if c == 43 {
                out.append(32)
                index += 1
            } else if c < 0x21 || c > 0x7e {
                return nil
            } else {
                out.append(c)
                index += 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }
}

/// The rooms this device is in (§9.9), shared by its receiver (to check `pair.request`
/// proofs) and its sender (to present them). Thread-safe. Expired rooms are dropped.
public final class Rooms {
    private let lock = NSLock()
    private var rooms: [String: Room] = [:]

    public init() {}

    /// Creates a room lasting `ttl` seconds (1 s to 4 h) and joins it. Nil for a bad `ttl`.
    public func create(name: String, ttl: Int64) -> Room? {
        guard (1...ProtocolConstants.roomMaxTTL).contains(ttl) else { return nil }
        var idBytes = [UInt8](repeating: 0, count: 16)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else { return nil }
        let now = Int64(Date().timeIntervalSince1970.rounded(.down))
        guard let room = Room(id: Base64URL.encode(Data(idBytes)), key: Data(keyBytes),
                              name: Self.cleanName(name), expiresAt: now + ttl),
              join(room) else { return nil }
        return room
    }

    /// Joins `room` (from a scanned code). False when it has expired or lasts implausibly long.
    @discardableResult
    public func join(_ room: Room) -> Bool {
        let now = Int64(Date().timeIntervalSince1970.rounded(.down))
        guard room.expiresAt > now,
              room.expiresAt <= now + ProtocolConstants.roomMaxTTL + ProtocolConstants.roomClockSkew else { return false }
        lock.lock()
        rooms[room.id] = room
        lock.unlock()
        return true
    }

    public func leave(id: String) {
        lock.lock()
        rooms[id] = nil
        lock.unlock()
    }

    public func leaveAll() {
        lock.lock()
        rooms.removeAll()
        lock.unlock()
    }

    /// Active rooms, soonest to expire first.
    public func active() -> [Room] {
        purgeExpired()
        lock.lock()
        defer { lock.unlock() }
        return rooms.values.sorted { $0.expiresAt < $1.expiresAt }
    }

    public func room(id: String) -> Room? {
        lock.lock()
        defer { lock.unlock() }
        guard let room = rooms[id], room.isActive() else { return nil }
        return room
    }

    public func purgeExpired() {
        let now = Date()
        lock.lock()
        rooms = rooms.filter { $0.value.isActive(now: now) }
        lock.unlock()
    }

    /// TXT `r` hints for the active rooms (at most `ProtocolConstants.maxRoomHints`).
    public func hints() -> [String] {
        active().prefix(ProtocolConstants.maxRoomHints).map { $0.hint }
    }

    /// The active room a discovered device's hint points at, if any. A hint is never proof.
    public func room(forHint hint: String) -> Room? {
        active().first(where: { $0.hint == hint })
    }

    /// The room whose key produced `proof` over this handshake, compared in constant time.
    func verify(id: String, proof: Data, transcriptHash: Data) -> Room? {
        guard let found = self.room(id: id) else { return nil }
        return Room.constantTimeEqual(found.proof(transcriptHash: transcriptHash), proof) ? found : nil
    }

    public static func isValidId(_ id: String) -> Bool {
        id.utf8.count == 22 && Base64URL.decode(id)?.count == 16
    }

    /// hex(SHA-256("CrossDrop/1 room|" + roomId)[0:8]).
    public static func hint(roomId: String) -> String {
        Hex.encode(CDCrypto.sha256(Labels.room + Data(roomId.utf8)).prefix(8))
    }

    /// Parses a TXT `r` value: comma-separated hints, invalid ones dropped.
    public static func parseHints(_ value: String?) -> [String] {
        guard let value = value else { return [] }
        let hints = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Hex.isLowerHex($0, length: 16) }
        return Array(hints.prefix(ProtocolConstants.maxRoomHints))
    }

    /// Display name: control characters removed, trimmed, at most 64 scalars, "Room" when empty.
    static func cleanName(_ raw: String?) -> String {
        let scalars = (raw ?? "").unicodeScalars.filter { !($0.value <= 0x1F || (0x7F...0x9F).contains($0.value)) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let trimmed = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        var capped = String.UnicodeScalarView()
        capped.append(contentsOf: trimmed.unicodeScalars.prefix(64))
        let result = String(capped).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Room" : result
    }
}
