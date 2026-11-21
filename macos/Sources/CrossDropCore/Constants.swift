import Foundation

public enum ProtocolConstants {
    public static let version = 1
    public static let serviceType = "_crossdrop._tcp"
    public static let maxPlaintextPayload = 65_536
    public static let maxDataBody = 262_144
    public static let maxEncryptedPayload = 1 + 262_144 + 16
    public static let maxFilesPerOffer = 1000
    public static let maxInboundConnections = 3
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public static let connectTimeout: TimeInterval = 10
    public static let handshakeTimeout: TimeInterval = 15
    public static let humanTimeout: TimeInterval = 120
    public static let streamTimeout: TimeInterval = 30
    public static let progressInterval: TimeInterval = 0.5
    public static let freeSpaceMargin: Int64 = 64 * 1024 * 1024

    // v1 extensions (docs/protocol-v1.md §9).
    /// Largest link / text payload (§9.2).
    public static let maxTextPayload: Int64 = 65_536
    /// Folder depth and length limits for a file's `path` (§9.1).
    public static let maxPathComponents = 16
    public static let maxPathBytes = 1024
    /// How long a QR pairing token stays valid (§9.4).
    public static let pairingTokenTTL: TimeInterval = 5 * 60
    /// How long an interrupted file is kept for resuming (§9.3).
    public static let resumeKeep: TimeInterval = 24 * 60 * 60
    /// How long a capture request stays answerable (§9.7).
    public static let captureRequestTTL: TimeInterval = 10 * 60
    /// Range of `expiresAfter` on an offer, in seconds (§9.8): 1 minute to 30 days.
    public static let minExpiresAfter: Int64 = 60
    public static let maxExpiresAfter: Int64 = 2_592_000
    /// Longest lifetime of a Drip Room, in seconds (§9.9).
    public static let roomMaxTTL: Int64 = 4 * 60 * 60
    /// Clock difference tolerated when checking a room's expiry from another device (§9.9).
    public static let roomClockSkew: Int64 = 5 * 60
    /// How long a room joiner waits for the receiver's room-proved `pair.confirm` before showing codes (§9.9).
    public static let roomAnswerWait: TimeInterval = 5
    /// Room hints advertised in one TXT record (§9.9).
    public static let maxRoomHints = 4

    public static let recordKindControl: UInt8 = 0x01
    public static let recordKindData: UInt8 = 0x02
}

enum Labels {
    static let transcript = Data("CrossDrop/1 transcript".utf8)
    static let c2s = Data("CrossDrop/1 c2s".utf8)
    static let s2c = Data("CrossDrop/1 s2c".utf8)
    static let sas = Data("CrossDrop/1 sas".utf8)
    static let clientProof = Data("CrossDrop/1 client-proof".utf8)
    static let serverProof = Data("CrossDrop/1 server-proof".utf8)
    static let room = Data("CrossDrop/1 room|".utf8)
    static let roomConfirm = Data("CrossDrop/1 room-confirm|".utf8)
}
