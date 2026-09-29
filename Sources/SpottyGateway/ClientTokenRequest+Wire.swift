import Foundation

// The client-token message is the only protobuf encoded by the Swift app. Keep its wire
// mechanics private to this operation rather than exporting a general codec from Domain.
extension ClientTokenRequest {
    /// ```
    /// ClientTokenRequest {
    ///   1 request_type = REQUEST_CLIENT_DATA_REQUEST (1)
    ///   2 client_data {
    ///       1 client_version
    ///       2 client_id
    ///       3 connectivity_sdk_data {
    ///           1 platform_specific_data { 3 mac {} }
    ///           2 device_id
    ///         }
    ///     }
    /// }
    /// ```
    /// The macOS submessage is sent empty, exactly as libspot does — Spotify grants the token
    /// without any of its optional hardware fields.
    static func encode(clientId: String, deviceId: String) -> Data {
        var writer = ClientTokenWriter()
        writer.varint(field: 1, 1)
        writer.message(field: 2) { clientData in
            clientData.string(field: 1, clientVersion)
            clientData.string(field: 2, clientId)
            clientData.message(field: 3) { sdk in
                sdk.message(field: 1) { platform in
                    platform.message(field: 3) { _ in }
                }
                sdk.string(field: 2, deviceId)
            }
        }
        return writer.data
    }

    /// ```
    /// ClientTokenResponse {
    ///   1 response_type   (1 = granted, 2 = challenges)
    ///   2 granted_token { 1 token, 2 expires_after_seconds }
    /// }
    /// ```
    static func decode(_ data: Data, now: Date = Date()) throws -> GrantedClientToken {
        guard let responseType = ClientTokenReader.firstVarint(field: 1, in: data) else {
            throw ClientTokenError.malformedResponse
        }

        if responseType == 2 {
            throw ClientTokenError.challenged
        }

        guard responseType == 1,
            let granted = ClientTokenReader.firstBytes(field: 2, in: data),
            let token = ClientTokenReader.firstString(field: 1, in: granted),
            !token.isEmpty
        else {
            throw ClientTokenError.malformedResponse
        }

        // Spotify sends a fortnight or so; treat a missing value as an hour rather than as
        // never-expiring, so a surprise cannot pin a stale token forever.
        //
        // Converted in a closure, not as `.map(TimeInterval.init)`: that reference resolves to
        // `Double(bitPattern:)`, which reinterprets the seconds as the bits of a float. 1209600
        // becomes a denormal around 6e-318, which disappears entirely when added to a Date — so
        // every token expired the instant it was granted, and each request fetched a new one.
        let lifetime = ClientTokenReader.firstVarint(field: 2, in: granted).map { TimeInterval($0) } ?? 3600

        return GrantedClientToken(token: token, expiresAt: now.addingTimeInterval(lifetime))
    }
}

private nonisolated struct ClientTokenWriter {
    private(set) var data = Data()

    init() {}

    private enum WireType: UInt64 {
        case varint = 0
        case lengthDelimited = 2
    }

    mutating func varint(field: Int, _ value: UInt64) {
        appendTag(field: field, wire: .varint)
        appendVarint(value)
    }

    mutating func string(field: Int, _ value: String) {
        bytes(field: field, Data(value.utf8))
    }

    mutating func bytes(field: Int, _ value: Data) {
        appendTag(field: field, wire: .lengthDelimited)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Nests a submessage, which the wire format expresses as length-prefixed bytes.
    mutating func message(field: Int, _ body: (inout ClientTokenWriter) -> Void) {
        var nested = ClientTokenWriter()
        body(&nested)
        bytes(field: field, nested.data)
    }

    private mutating func appendTag(field: Int, wire: WireType) {
        appendVarint(UInt64(field) << 3 | wire.rawValue)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
    }
}

// Only the token response consumes this cursor. First matching wire types win; a malformed
// field stops a search, while values found earlier remain usable by the response policy.
private nonisolated struct ClientTokenReader {
    private enum Value {
        case varint(UInt64)
        case bytes(Data)
        case skipped
    }

    private let data: Data
    private var index: Data.Index

    private init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    /// The next field, or nil at the end. Returns nil on malformed input too: a truncated
    /// message and a finished one are the same thing to every caller here.
    private mutating func next() -> (field: Int, value: Value)? {
        guard let tag = readVarint() else { return nil }

        let field = Int(tag >> 3)
        guard field > 0 else { return nil }

        switch tag & 0x07 {
        case 0:
            guard let value = readVarint() else { return nil }
            return (field, .varint(value))
        case 1:
            guard read(8) != nil else { return nil }
            return (field, .skipped)
        case 2:
            // A corrupt length can exceed what an Int can hold; converting it directly
            // would trap rather than fail the read.
            guard let length = readVarint(), let byteCount = Int(exactly: length),
                let payload = read(byteCount)
            else { return nil }
            return (field, .bytes(payload))
        case 5:
            guard read(4) != nil else { return nil }
            return (field, .skipped)
        default:
            // Groups (3, 4) are long gone from proto3 and nothing here emits them.
            return nil
        }
    }

    /// The bytes of the first occurrence of a length-delimited field, if present.
    static func firstBytes(field wanted: Int, in data: Data) -> Data? {
        var reader = ClientTokenReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .bytes(payload) = value {
                return payload
            }
        }
        return nil
    }

    /// The value of the first occurrence of a varint field, if present.
    static func firstVarint(field wanted: Int, in data: Data) -> UInt64? {
        var reader = ClientTokenReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .varint(number) = value {
                return number
            }
        }
        return nil
    }

    /// The UTF-8 contents of the first occurrence of a string field, if present.
    static func firstString(field wanted: Int, in data: Data) -> String? {
        guard let payload = firstBytes(field: wanted, in: data) else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0

        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)

            let payload = UInt64(byte & 0x7F)
            // A UInt64 holds 64 bits: nine 7-bit chunks, then one bit at shift 63.
            // Reject before shifting so a tenth-byte payload 2...127 cannot trap,
            // wrap, or decode as a truncated value. A continuation at shift 63
            // would need an eleventh byte and is likewise invalid.
            guard shift < 64, payload <= UInt64.max >> shift else {
                return nil
            }

            result |= payload << shift
            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift > 63 {
                return nil
            }
        }

        return nil
    }

    private mutating func read(_ count: Int) -> Data? {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else { return nil }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return data[index..<end]
    }
}
