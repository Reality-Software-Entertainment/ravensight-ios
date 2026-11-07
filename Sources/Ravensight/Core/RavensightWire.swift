import Compression
import CryptoKit
import Foundation

/// The pure pieces of the delivery contract (docs/sdk/DELIVERY_CONTRACT.md),
/// checked against the shared vectors in the tests: request signing, the
/// event size count the server uses, and gzip.
enum RavensightWire {
    /// A body this size or larger (before compression) is sent gzipped.
    static let gzipThreshold = 1024
    /// A typed error's message and stack caps, in UTF-16 units.
    static let typedMessageChars = 200
    static let typedStackChars = 2000
    static let typedTrailChars = 1500

    // MARK: Signing

    /// Lower case hex HMAC-SHA256 of message keyed with the UTF-8 bytes of
    /// secret (used as text, never base64 decoded).
    static func hmacHex(secret: String, message: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// "v1:<timestamp>:" followed by the exact body bytes.
    static func canonical(timestamp: Int64, body: Data) -> Data {
        var data = Data("v1:\(timestamp):".utf8)
        data.append(body)
        return data
    }

    /// The X-Ravensight-Signature value for a body, before compression.
    static func signatureHeader(secret: String, timestamp: Int64, body: Data) -> String {
        return "v1=" + hmacHex(secret: secret, message: canonical(timestamp: timestamp, body: body))
    }

    /// The signed beacon envelope (contract 7.4).
    static func beaconEnvelope(sessionToken: String, secret: String, timestamp: Int64, body: String) -> [String: Any] {
        let sig = hmacHex(secret: secret, message: canonical(timestamp: timestamp, body: Data(body.utf8)))
        return [
            "sessionToken": sessionToken,
            "signed": ["v": 1, "t": timestamp, "body": body, "sig": sig] as [String: Any],
        ]
    }

    // MARK: Event size

    /// The size the server's 8 KB ceiling counts for one event's data: its
    /// UTF-8 JSON bytes, except that an error event's rs_message (200),
    /// rs_stack (2,000) and rs_trail (1,500) within their caps count one byte
    /// a UTF-16 unit (docs/errors/CONTRACT.md defines the fields).
    static func countedBytes(_ data: [String: Any]) -> Int {
        let total = RavensightCore.eventBytes(data)
        guard total != Int.max, data["rs_kind"] as? String == "error" else { return total }
        var size = total
        for (key, cap) in [("rs_message", typedMessageChars), ("rs_stack", typedStackChars), ("rs_trail", typedTrailChars)] {
            guard let value = data[key] as? String, value.utf16.count <= cap else { continue }
            size -= jsonStringBytes(value) - value.utf16.count
        }
        return size
    }

    /// UTF-8 bytes of a string as JSON writes it, quotes included.
    static func jsonStringBytes(_ value: String) -> Int {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value], options: [.withoutEscapingSlashes]
        ) else { return value.utf8.count + 2 }
        return data.count - 2 // the array's brackets
    }

    /// Cuts text to at most max UTF-16 units without splitting a character.
    static func cut(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var out = ""
        var units = 0
        for character in text {
            let width = String(character).utf16.count
            if units + width > max { break }
            units += width
            out.append(character)
        }
        return out
    }

    // MARK: Compression

    /// gzip of data (RFC 1952), or nil when compression failed.
    static func gzip(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 2 + 64
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB writes raw DEFLATE, which gzip wraps.
                return compression_encode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(deflated.prefix(written))
        let crc = crc32(data)
        let size = UInt32(truncatingIfNeeded: data.count)
        for value in [crc, size] {
            for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
        }
        return out
    }

    /// The inverse of gzip, for the tests and nothing else.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let body = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        let sizeBytes = data.suffix(4)
        let size = sizeBytes.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        var out = Data(count: max(size, 1))
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, max(size, 1),
                    src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return out.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
