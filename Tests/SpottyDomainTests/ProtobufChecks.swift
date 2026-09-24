import Foundation
import SpottyDomain
import Testing

@Suite("Protobuf")
struct ProtobufTests {
    @Test(arguments: [0, 1, 127, 128, 16_383, 16_384, UInt64.max] as [UInt64])
    func varintsRoundTrip(value: UInt64) {
        var writer = ProtobufWriter()
        writer.varint(field: 1, value)
        #expect(ProtobufReader.firstVarint(field: 1, in: writer.data) == value)
    }

    @Test
    func mixedFieldsAndNestedMessages() throws {
        var writer = ProtobufWriter()
        writer.string(field: 1, "granted")
        writer.varint(field: 2, 3_600)
        writer.message(field: 3) { nested in
            nested.bytes(field: 1, Data([0xAA, 0xBB]))
        }
        #expect(ProtobufReader.firstString(field: 1, in: writer.data) == "granted")
        #expect(ProtobufReader.firstBytes(field: 1, in: writer.data) == Data("granted".utf8))
        #expect(ProtobufReader.firstVarint(field: 2, in: writer.data) == 3_600)
        let embedded = try #require(ProtobufReader.firstBytes(field: 3, in: writer.data))
        #expect(ProtobufReader.firstBytes(field: 1, in: embedded) == Data([0xAA, 0xBB]))
        #expect(ProtobufReader.firstVarint(field: 9, in: writer.data) == nil)
    }

    @Test
    func repeatedFieldsRetainWireOrder() {
        let uris = ["spotify:track:a", "spotify:track:b", "spotify:track:c"]
        var writer = ProtobufWriter()
        for uri in uris {
            writer.string(field: 2, uri)
        }
        let fields = ProtobufReader.fields(in: writer.data)
        #expect(fields.map(\.number) == [2, 2, 2])
        #expect(fields.compactMap(\.bytesPayload).map { String(decoding: $0, as: UTF8.self) } == uris)
        #expect(ProtobufReader.firstString(field: 2, in: writer.data) == uris[0])
    }

    @Test(
        arguments: [
            0x0000_0000_0000_0000, 0x8000_0000_0000_0000, 0x405E_DD2F_1A9F_BE77,
            0x7FF0_0000_0000_0000, 0xFFF0_0000_0000_0000, 0x7FF8_0000_0000_0042,
        ] as [UInt64])
    func fixed64PreservesExactBits(bitPattern: UInt64) throws {
        var writer = ProtobufWriter()
        writer.double(field: 1, Double(bitPattern: bitPattern))
        let fields = ProtobufReader.fields(in: writer.data)
        #expect(fields.count == 1)
        let field = try #require(fields.first)
        #expect(field.number == 1)
        guard case let .fixed64(decoded) = field.value else {
            Issue.record("Expected a fixed64 field")
            return
        }
        #expect(decoded == bitPattern, "Includes signed zero, infinities, and a NaN payload")
    }

    @Test
    func fixedWidthWireOrderIsLittleEndian() throws {
        var writer = ProtobufWriter()
        writer.double(field: 1, 123.456)
        #expect(writer.data == Data([0x09, 0x77, 0xBE, 0x9F, 0x1A, 0x2F, 0xDD, 0x5E, 0x40]))
        let field = try #require(ProtobufReader.fields(in: Data([0x0D, 0x78, 0x56, 0x34, 0x12])).first)
        guard case let .fixed32(bits) = field.value else {
            Issue.record("Expected a fixed32 field")
            return
        }
        #expect(bits == 0x1234_5678)
    }

    @Test(arguments: [
        Data([0x09, 0x00, 0x00, 0x00, 0x00]),  // Truncated fixed64.
        Data([0x0D, 0x00, 0x00]),  // Truncated fixed32.
        Data([0x08, 0xAC]),  // Varint cut off mid-continuation.
        Data([0x12, 0x05, 0x61]),  // Declared length exceeds remaining bytes.
        Data([0x00]),  // Field zero is invalid.
        Data([0x0B]), Data([0x0C]), Data([0x0E]), Data([0x0F]),  // Unsupported wire types.
    ])
    func malformedFieldsStopTheRead(data: Data) {
        #expect(ProtobufReader.fields(in: data).isEmpty)
    }

    @Test
    func tenthVarintByteMayUseOnlyItsLowBit() {
        #expect(ProtobufReader.firstVarint(field: 1, in: field1Varint([0x01])) == UInt64.max)
        #expect(ProtobufReader.firstVarint(field: 1, in: field1Varint([0x00])) == UInt64.max >> 1)
    }

    @Test(arguments: UInt8(0x02)...UInt8(0x7F))
    func overflowingTenthVarintByteIsRejected(payload: UInt8) {
        #expect(ProtobufReader.firstVarint(field: 1, in: field1Varint([payload])) == nil)
    }

    @Test(arguments: [0x80, 0x81, 0xFF] as [UInt8])
    func varintsCannotContinuePastTenBytes(continuation: UInt8) {
        #expect(ProtobufReader.fields(in: field1Varint([continuation])).isEmpty)
        #expect(ProtobufReader.fields(in: field1Varint([continuation, 0x00])).isEmpty)
    }

    @Test
    func overflowingTagsAndLengthsStopTheRead() {
        let overflowing = Data(repeating: 0xFF, count: 9) + Data([0x02])
        #expect(ProtobufReader.fields(in: overflowing).isEmpty)
        #expect(ProtobufReader.fields(in: Data([0x0A]) + overflowing).isEmpty)
        let exceedsInt = Data(repeating: 0xFF, count: 9) + Data([0x01])
        #expect(ProtobufReader.fields(in: Data([0x0A]) + exceedsInt).isEmpty)
    }

    @Test
    func accessorsSkipFieldsWithDifferentWireTypes() {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 5)
        #expect(ProtobufReader.firstBytes(field: 1, in: writer.data) == nil)
        writer.string(field: 1, "matching bytes")
        #expect(ProtobufReader.firstString(field: 1, in: writer.data) == "matching bytes")
        #expect(ProtobufReader.firstVarint(field: 1, in: writer.data) == 5)
    }

    private func field1Varint(_ trailing: [UInt8]) -> Data {
        Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data(trailing)
    }
}
