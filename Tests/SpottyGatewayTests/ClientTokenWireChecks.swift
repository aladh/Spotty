import Foundation
import SpottyTestSupport
import Testing
@testable import SpottyGateway

@Suite("Client Token Wire")
struct ClientTokenWireTests {
    @Test
    func requestMatchesIndependentWireFixture() {
        // request_type=1; client_data contains version, client ID, and SDK data.
        // SDK data contains platform { mac {} } followed by device ID.
        let expected = Data([
            0x08, 0x01, 0x12, 0x2C, 0x0A, 0x14,
            0x31, 0x2E, 0x32, 0x2E, 0x38, 0x34, 0x2E, 0x34, 0x37, 0x36,
            0x2E, 0x67, 0x61, 0x31, 0x66, 0x66, 0x36, 0x36, 0x30, 0x37,
            0x12, 0x06, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
            0x1A, 0x0C, 0x0A, 0x02, 0x1A, 0x00,
            0x12, 0x06, 0x64, 0x65, 0x76, 0x69, 0x63, 0x65,
        ])
        #expect(ClientTokenRequest.encode(clientId: "client", deviceId: "device") == expected)
    }

    @Test
    func requestLengthsCountUTF8BytesAndUseMultibyteVarints() {
        let prefix = Data([
            0x08, 0x01, 0x12, 0xA4, 0x01, 0x0A, 0x14,
            0x31, 0x2E, 0x32, 0x2E, 0x38, 0x34, 0x2E, 0x34, 0x37, 0x36,
            0x2E, 0x67, 0x61, 0x31, 0x66, 0x66, 0x36, 0x36, 0x30, 0x37,
            0x12, 0x02, 0xC3, 0xA9, 0x1A, 0x87, 0x01,
            0x0A, 0x02, 0x1A, 0x00, 0x12, 0x80, 0x01,
        ])
        #expect(
            ClientTokenRequest.encode(clientId: "é", deviceId: String(repeating: "x", count: 128))
                == prefix + Data(repeating: 0x78, count: 128))
    }

    @Test(
        arguments: [
            ([0x00], UInt64(0)), ([0x01], 1), ([0x7F], 127), ([0x80, 0x01], 128),
            ([0xFF, 0x7F], 16_383), ([0x80, 0x80, 0x01], 16_384),
            ([0x80, 0xEA, 0x49], 1_209_600),
            (Array(repeating: UInt8(0xFF), count: 9) + [0x00], UInt64.max >> 1),
            (Array(repeating: UInt8(0xFF), count: 9) + [0x01], UInt64.max),
        ] as [([UInt8], UInt64)])
    func expiryUsesNumericSeconds(bytes: [UInt8], seconds: UInt64) throws {
        let value = try decode(grantFields: [0x0A, 0x01, 0x74, 0x10] + bytes)
        #expect(value.token == "t")
        #expect(value.expiresAt == HarnessDates.fixed.addingTimeInterval(TimeInterval(seconds)))
    }

    @Test(
        arguments: [
            [0x0A, 0x01, 0x74],  // Missing expiry.
            [0x0A, 0x01, 0x74, 0x10, 0x80],  // Unreadable expiry after a valid token.
            [0x0A, 0x01, 0x74, 0x00, 0x10, 0x64],  // Invalid prefix stops before later expiry.
        ] as [[UInt8]])
    func absentOrUnreadableExpiryKeepsBoundedDefault(fields: [UInt8]) throws {
        let value = try decode(grantFields: fields)
        #expect(value.token == "t")
        #expect(value.expiresAt == HarnessDates.fixed.addingTimeInterval(3_600))
    }

    @Test(
        arguments: [
            [0x28, 0x81, 0x00],  // Unknown varint, including an accepted noncanonical encoding.
            [0x31, 1, 2, 3, 4, 5, 6, 7, 8],  // Unknown fixed64.
            [0x3A, 0x02, 0xFF, 0xFE],  // Unknown opaque bytes.
            [0x45, 1, 2, 3, 4],  // Unknown fixed32.
        ] as [[UInt8]])
    func supportedUnknownFieldsAreSkippedAtBothMessageLevels(fields: [UInt8]) throws {
        let response = Data(fields) + Self.response(grantFields: fields + [0x0A, 0x01, 0x74, 0x10, 0x64])
        let value = try ClientTokenRequest.decode(response, now: HarnessDates.fixed)
        #expect(value.token == "t")
        #expect(value.expiresAt == HarnessDates.fixed.addingTimeInterval(100))
    }

    @Test
    func firstMatchingWireTypeWinsWithoutReplacingDuplicates() throws {
        let fields: [UInt8] = [
            0x08, 0x07,  // Wrong wire type for token.
            0x0A, 0x01, 0x74, 0x0A, 0x01, 0x75,  // First token wins.
            0x12, 0x01, 0x61,  // Wrong wire type for expiry.
            0x10, 0x64, 0x10, 0x01,  // First expiry wins.
        ]
        let response =
            Data([0x0A, 0x01, 0x78, 0x10, 0x00]) + Self.response(grantFields: fields)
            + Data([0x08, 0x02, 0x12, 0x00])
        let value = try ClientTokenRequest.decode(response, now: HarnessDates.fixed)
        #expect(value.token == "t")
        #expect(value.expiresAt == HarnessDates.fixed.addingTimeInterval(100))
    }

    @Test(arguments: [[0x0A, 0x00], [0x0A, 0x01, 0xFF]] as [[UInt8]])
    func invalidFirstTokenCannotBeReplacedByLaterToken(fields: [UInt8]) {
        #expect(throws: ClientTokenError.malformedResponse) {
            try decode(grantFields: fields + [0x0A, 0x01, 0x74])
        }
    }

    @Test
    func challengeDoesNotRequireAReadableGrant() {
        for data in [Data([0x08, 0x02]), Data([0x08, 0x02, 0x00]), Data([0x08, 0x02]) + Self.validResponse] {
            #expect(throws: ClientTokenError.challenged) { try ClientTokenRequest.decode(data) }
        }
    }

    @Test
    func unknownResponseTypeAndMissingGrantAreRejected() {
        for data in [Data(), Data([0x08, 0x01]), Data([0x08, 0x03]) + Self.validResponse] {
            #expect(throws: ClientTokenError.malformedResponse) { try ClientTokenRequest.decode(data) }
        }
    }

    @Test(
        arguments: [
            [0x09, 0x00], [0x0D, 0x00], [0x08, 0xAC], [0x12, 0x05, 0x61],
            [0x00], [0x0B], [0x0C], [0x0E], [0x0F],
        ] as [[UInt8]])
    func malformedFieldsCannotSupplyRequiredValues(fields: [UInt8]) {
        #expect(throws: ClientTokenError.malformedResponse) { try ClientTokenRequest.decode(Data(fields)) }
        #expect(throws: ClientTokenError.malformedResponse) { try decode(grantFields: fields) }
    }

    @Test(arguments: UInt8(0x02)...UInt8(0x7F))
    func overflowingVarintsCannotSupplyTagsLengthsOrResponseType(lastByte: UInt8) {
        let overflow = Data(repeating: 0xFF, count: 9) + Data([lastByte])
        for prefix in [Data(), Data([0x08]), Data([0x12])] {
            #expect(throws: ClientTokenError.malformedResponse) { try ClientTokenRequest.decode(prefix + overflow) }
        }
    }

    @Test(arguments: [0x80, 0x81, 0xFF] as [UInt8])
    func varintsCannotContinuePastTenBytes(lastByte: UInt8) {
        let overflow = Data([0x08]) + Data(repeating: 0xFF, count: 9) + Data([lastByte])
        for data in [overflow, overflow + Data([0x00])] {
            #expect(throws: ClientTokenError.malformedResponse) { try ClientTokenRequest.decode(data) }
        }
    }

    @Test
    func lengthsLargerThanIntAreRejected() {
        let response = Data([0x12]) + Data(repeating: 0xFF, count: 9) + Data([0x01])
        #expect(throws: ClientTokenError.malformedResponse) { try ClientTokenRequest.decode(response) }
    }

    @Test
    func malformedSuffixDoesNotInvalidateAlreadyFoundFields() throws {
        let value = try ClientTokenRequest.decode(Self.validResponse + Data([0x00]), now: HarnessDates.fixed)
        #expect(value.token == "t")
        let innerSuffix = try decode(grantFields: [0x0A, 0x01, 0x74, 0x10, 0x64, 0x00])
        #expect(innerSuffix.expiresAt == HarnessDates.fixed.addingTimeInterval(100))
        #expect(throws: ClientTokenError.malformedResponse) {
            try ClientTokenRequest.decode(Data([0x00]) + Self.validResponse)
        }
    }

    @Test
    func slicedDataUsesItsOwnStartIndex() throws {
        let storage = Data([0xFF, 0xFF]) + Self.validResponse
        let value = try ClientTokenRequest.decode(storage.dropFirst(2), now: HarnessDates.fixed)
        #expect(value.token == "t")
    }

    private static let validResponse = response(grantFields: [0x0A, 0x01, 0x74])

    private static func response(grantFields: [UInt8]) -> Data {
        // These literal fixture payloads use one-byte lengths; no production codec constructs them.
        precondition(grantFields.count < 128)
        return Data([0x08, 0x01, 0x12, UInt8(grantFields.count)] + grantFields)
    }

    private func decode(grantFields: [UInt8]) throws -> GrantedClientToken {
        try ClientTokenRequest.decode(Self.response(grantFields: grantFields), now: HarnessDates.fixed)
    }
}
