import Foundation

/// A decoded JSON control message (docs/protocol-v1.md §3.3).
public struct WireMessage {
    public let type: String
    public let version: Int64
    public let fields: [String: Any]

    public static func parse(_ data: Data) throws -> WireMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              let version = JSONValue.int(dict["v"]) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "malformed message")
        }
        return WireMessage(type: type, version: version, fields: dict)
    }

    public static func encode(_ dict: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes])
        } catch {
            throw CrossDropError.local(ErrorCode.internalError, "json encoding failed")
        }
    }

    /// Builds a message dictionary with `type` and `v`.
    public static func make(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var dict = fields
        dict["type"] = type
        dict["v"] = ProtocolConstants.version
        return dict
    }

    public static func error(_ code: String, _ message: String? = nil) -> [String: Any] {
        var fields: [String: Any] = ["code": code]
        if let message = message { fields["message"] = message }
        return make("error", fields)
    }

    // MARK: Field access

    public func string(_ key: String) -> String? { fields[key] as? String }
    public func int(_ key: String) -> Int64? { JSONValue.int(fields[key]) }
    public func bool(_ key: String) -> Bool? { JSONValue.bool(fields[key]) }

    func requireString(_ key: String, maxBytes: Int = 4096) throws -> String {
        guard let value = string(key), value.utf8.count <= maxBytes else {
            throw CrossDropError.violation(ErrorCode.badMessage, "missing or invalid \(key)")
        }
        return value
    }

    func requireInt(_ key: String) throws -> Int64 {
        guard let value = int(key) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "missing or invalid \(key)")
        }
        return value
    }

    func requireBool(_ key: String) throws -> Bool {
        guard let value = bool(key) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "missing or invalid \(key)")
        }
        return value
    }

    /// Base64 field, optionally of an exact decoded length.
    func requireBase64(_ key: String, length: Int? = nil, maxLength: Int = 1024) throws -> Data {
        guard let text = string(key), text.utf8.count <= maxLength * 2,
              let data = Data(base64Encoded: text),
              length == nil || data.count == length!,
              data.count <= maxLength else {
            throw CrossDropError.violation(ErrorCode.badMessage, "missing or invalid \(key)")
        }
        return data
    }

    func requireDeviceId(_ key: String = "deviceId") throws -> String {
        let value = try requireString(key)
        guard Hex.isLowerHex(value, length: 32) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "invalid \(key)")
        }
        return value
    }

    /// Display name: trimmed, 1–64 scalars (longer names are truncated, not rejected).
    func requireName(_ key: String = "name") throws -> String {
        let raw = try requireString(key, maxBytes: 1024)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars.filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) })
        guard !scalars.isEmpty else {
            throw CrossDropError.violation(ErrorCode.badMessage, "empty \(key)")
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.prefix(64))
        return String(view)
    }

    func requirePlatform(_ key: String = "platform") throws -> String {
        let value = try requireString(key)
        guard value == "android" || value == "macos" else {
            throw CrossDropError.violation(ErrorCode.badMessage, "invalid \(key)")
        }
        return value
    }

    /// Converts a received `error` message into a peer error.
    func peerError() -> CrossDropError {
        let code = string("code") ?? ErrorCode.internalError
        let safeCode = code.utf8.count <= 64 ? code : ErrorCode.internalError
        return CrossDropError.peer(safeCode, string("message").map { String($0.prefix(200)) })
    }
}

enum JSONValue {
    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              abs(double) <= Double(ProtocolConstants.maxSafeInteger) else { return nil }
        return number.int64Value
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }
}

// MARK: - Transfer offer

public struct OfferedFile: Equatable {
    public let fileId: Int64
    public let name: String
    public let size: Int64
    public let mime: String?
    public let sha256: String

    public init(fileId: Int64, name: String, size: Int64, mime: String?, sha256: String) {
        self.fileId = fileId
        self.name = name
        self.size = size
        self.mime = mime
        self.sha256 = sha256
    }
}

public struct TransferOffer: Equatable {
    public let transferId: String
    public let files: [OfferedFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static func isValidTransferId(_ id: String) -> Bool {
        let utf8 = id.utf8
        guard (8...64).contains(utf8.count) else { return false }
        return utf8.allSatisfy { c in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45
        }
    }

    static func parse(_ message: WireMessage) throws -> TransferOffer {
        let bad = { (why: String) in CrossDropError.violation(ErrorCode.badMessage, why) }
        let transferId = try message.requireString("transferId")
        guard isValidTransferId(transferId) else { throw bad("invalid transferId") }
        guard let list = message.fields["files"] as? [Any],
              (1...ProtocolConstants.maxFilesPerOffer).contains(list.count) else {
            throw bad("invalid files")
        }
        var seen = Set<Int64>()
        var files: [OfferedFile] = []
        var total: Int64 = 0
        for item in list {
            guard let entry = item as? [String: Any] else { throw bad("invalid file entry") }
            guard let fileId = JSONValue.int(entry["fileId"]), (0..<1000).contains(fileId),
                  !seen.contains(fileId) else { throw bad("invalid fileId") }
            seen.insert(fileId)
            guard let name = entry["name"] as? String, (1...1024).contains(name.utf8.count) else {
                throw bad("invalid name")
            }
            guard let size = JSONValue.int(entry["size"]), size >= 0,
                  size <= ProtocolConstants.maxSafeInteger else { throw bad("invalid size") }
            var mime: String? = nil
            if let rawMime = entry["mime"], !(rawMime is NSNull) {
                guard let text = rawMime as? String, text.utf8.count <= 255 else { throw bad("invalid mime") }
                mime = text
            }
            guard let sha = entry["sha256"] as? String, Hex.isLowerHex(sha, length: 64) else {
                throw bad("invalid sha256")
            }
            total += size
            guard total <= ProtocolConstants.maxSafeInteger else { throw bad("total too large") }
            files.append(OfferedFile(fileId: fileId, name: name, size: size, mime: mime, sha256: sha))
        }
        return TransferOffer(transferId: transferId, files: files)
    }

    func toMessage() -> [String: Any] {
        let list: [[String: Any]] = files.map { (file: OfferedFile) -> [String: Any] in
            var entry: [String: Any] = [
                "fileId": file.fileId,
                "name": file.name,
                "size": file.size,
                "sha256": file.sha256,
            ]
            if let mime = file.mime { entry["mime"] = mime }
            return entry
        }
        return WireMessage.make("transfer.offer", ["transferId": transferId, "files": list])
    }
}
