//
//  Protobuf.swift
//  Spotty
//
//  Just enough protobuf for the handful of messages Spotify's own APIs speak.
//

import Foundation

/// Writes protobuf wire format.
///
/// Deliberately not a dependency. The messages this app encodes are tiny — the client-token
/// request is four scalar fields inside three nested messages — and a code-generation
/// toolchain for that would be more machinery than the thing it encodes. If the protobuf
/// surface grows past the spclient responses, revisit.
public struct ProtobufWriter {
    public private(set) var data = Data()

    public init() {}

    private enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
    }

    public mutating func varint(field: Int, _ value: UInt64) {
        appendTag(field: field, wire: .varint)
        appendVarint(value)
    }

    /// Writes an IEEE 754 double as a fixed-width field.
    public mutating func double(field: Int, _ value: Double) {
        appendTag(field: field, wire: .fixed64)
        withUnsafeBytes(of: value.bitPattern.littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    public mutating func string(field: Int, _ value: String) {
        bytes(field: field, Data(value.utf8))
    }

    public mutating func bytes(field: Int, _ value: Data) {
        appendTag(field: field, wire: .lengthDelimited)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Nests a submessage, which the wire format expresses as length-prefixed bytes.
    public mutating func message(field: Int, _ body: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
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

/// Reads protobuf wire format, field by field.
///
/// Unknown fields are skipped rather than rejected — Spotify adds fields to these messages
/// without warning, and a reader that insists on knowing every one of them would break on a
/// server change that costs us nothing.
public struct ProtobufReader {
    /// One decoded field. Fixed-width values keep their raw little-endian bit patterns;
    /// callers interpret them (floats, doubles) as needed.
    public struct Field {
        public let number: Int
        public let value: Value

        /// The payload when this is a length-delimited field.
        public var bytesPayload: Data? {
            if case let .bytes(payload) = value { payload } else { nil }
        }
    }

    public enum Value {
        case varint(UInt64)
        /// Raw IEEE 754 double bit pattern (wire type 1).
        case fixed64(UInt64)
        /// Raw fixed-width bit pattern (wire type 5).
        case fixed32(UInt32)
        case bytes(Data)
    }

    private let data: Data
    private var index: Data.Index

    private init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    /// Every top-level field in order — repeats of the same field number included,
    /// which is how proto3 expresses repeated fields.
    public static func fields(in data: Data) -> [Field] {
        var reader = ProtobufReader(data)
        var fields: [Field] = []
        while let (number, value) = reader.next() {
            fields.append(Field(number: number, value: value))
        }
        return fields
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
            guard let payload = read(8) else { return nil }
            return (field, .fixed64(Self.littleEndianUInt64(payload)))
        case 2:
            // A corrupt length can exceed what an Int can hold; converting it directly
            // would trap rather than fail the read.
            guard let length = readVarint(), let byteCount = Int(exactly: length),
                let payload = read(byteCount)
            else { return nil }
            return (field, .bytes(payload))
        case 5:
            guard let payload = read(4) else { return nil }
            return (field, .fixed32(Self.littleEndianUInt32(payload)))
        default:
            // Groups (3, 4) are long gone from proto3 and nothing here emits them.
            return nil
        }
    }

    /// The bytes of the first occurrence of a length-delimited field, if present.
    public static func firstBytes(field wanted: Int, in data: Data) -> Data? {
        var reader = ProtobufReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .bytes(payload) = value {
                return payload
            }
        }
        return nil
    }

    /// The value of the first occurrence of a varint field, if present.
    public static func firstVarint(field wanted: Int, in data: Data) -> UInt64? {
        var reader = ProtobufReader(data)
        while let (field, value) = reader.next() {
            if field == wanted, case let .varint(number) = value {
                return number
            }
        }
        return nil
    }

    /// The UTF-8 contents of the first occurrence of a string field, if present.
    public static func firstString(field wanted: Int, in data: Data) -> String? {
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

    private static func littleEndianUInt64(_ bytes: Data) -> UInt64 {
        var result: UInt64 = 0
        for (offset, byte) in bytes.enumerated() {
            result |= UInt64(byte) << (8 * UInt64(offset))
        }
        return result
    }

    private static func littleEndianUInt32(_ bytes: Data) -> UInt32 {
        var result: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            result |= UInt32(byte) << (8 * UInt32(offset))
        }
        return result
    }
}
