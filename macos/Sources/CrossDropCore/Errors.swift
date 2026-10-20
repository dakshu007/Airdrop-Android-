import Foundation

/// Protocol error codes (docs/protocol-v1.md §6.4) plus local-only codes.
public enum ErrorCode {
    public static let badFrame = "bad_frame"
    public static let frameTooLarge = "frame_too_large"
    public static let badMessage = "bad_message"
    public static let unexpectedMessage = "unexpected_message"
    public static let unsupportedVersion = "unsupported_version"
    public static let authFailed = "auth_failed"
    public static let pairingRequired = "pairing_required"
    public static let pairingRejected = "pairing_rejected"
    public static let busy = "busy"
    public static let notReceiving = "not_receiving"
    public static let integrityFailed = "integrity_failed"
    public static let insufficientStorage = "insufficient_storage"
    public static let storageError = "storage_error"
    public static let timeout = "timeout"
    public static let internalError = "internal"

    // Local codes, never sent on the wire.
    public static let unreachable = "unreachable"
    public static let connectionLost = "connection_lost"
    public static let fileUnreadable = "file_unreadable"
    public static let cancelled = "cancelled"
    public static let peerChangedIdentity = "peer_changed_identity"
    public static let noNetwork = "no_network"
}

public struct CrossDropError: Error, Equatable, CustomStringConvertible {
    /// Code shown to the user / used by the UI.
    public var code: String
    /// Diagnostic text. Never contains file names, codes or keys.
    public var message: String?
    /// True when the peer reported this error (or cancelled).
    public var fromPeer: Bool
    /// When set, an `error` frame with this code is sent to the peer before closing.
    public var peerCode: String?

    public init(_ code: String, _ message: String? = nil, fromPeer: Bool = false, peerCode: String? = nil) {
        self.code = code
        self.message = message
        self.fromPeer = fromPeer
        self.peerCode = peerCode
    }

    /// A local protocol violation or failure that the peer should be told about.
    public static func violation(_ code: String, _ message: String? = nil) -> CrossDropError {
        CrossDropError(code, message, peerCode: code)
    }

    /// A local condition (network, timeout) that does not produce an error frame.
    public static func local(_ code: String, _ message: String? = nil) -> CrossDropError {
        CrossDropError(code, message)
    }

    public static func peer(_ code: String, _ message: String? = nil) -> CrossDropError {
        CrossDropError(code, message, fromPeer: true)
    }

    public var description: String {
        if let message = message { return "\(code) (\(message))" }
        return code
    }

    public var isCancellation: Bool { code == ErrorCode.cancelled }
}
