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
}
