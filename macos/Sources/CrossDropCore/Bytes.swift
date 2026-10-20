import Foundation

/// Lowercase hexadecimal helpers.
public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    public static func encode<D: DataProtocol>(_ data: D) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) -> Data? {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            out.append((high << 4) | low)
            index += 2
        }
        return out
    }

    /// True when `string` is exactly `length` lowercase hex characters.
    public static func isLowerHex(_ string: String, length: Int) -> Bool {
        let utf8 = string.utf8
        guard utf8.count == length else { return false }
        return utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}

enum ByteCodec {
    static func u32be(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func u64be(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func readU32be<D: DataProtocol>(_ data: D) -> UInt32 {
        let bytes = [UInt8](data)
        precondition(bytes.count >= 4)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    /// Length-prefixed bytes: u32be(len) || bytes.
    static func lp(_ data: Data) -> Data {
        var out = u32be(UInt32(data.count))
        out.append(data)
        return out
    }
}

/// Monotonic seconds, unaffected by wall-clock changes.
func monotonicNow() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
