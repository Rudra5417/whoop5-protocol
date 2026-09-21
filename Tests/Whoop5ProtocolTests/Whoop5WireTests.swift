import XCTest
@testable import Whoop5Protocol

/// Golden vectors from public WHOOP 5.0 protocol documentation.
/// The worked example in docs/PROTOCOL-WHOOP5.md must reproduce byte-for-byte.
final class Whoop5WireTests: XCTestCase {

    // MARK: Checksums against the documented example

    func testHeaderCRC16MatchesDocumentedExample() {
        // CRC16 of aa010c000001 is documented as 0x41E7.
        let header: [UInt8] = [0xaa, 0x01, 0x0c, 0x00, 0x00, 0x01]
        XCTAssertEqual(Whoop5Wire.crc16Modbus(header), 0x41E7)
    }

    func testPayloadCRC32MatchesDocumentedExample() {
        // CRC32 of 23f16a0101000000 is documented as 0xFC61E958.
        let payload: [UInt8] = [0x23, 0xf1, 0x6a, 0x01, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual(Whoop5Wire.crc32IEEE(payload), 0xFC61_E958)
    }

    func testCRC16EmptyAndKnownLengths() {
        XCTAssertEqual(Whoop5Wire.crc16Modbus([]), 0xFFFF)  // init value, no bytes processed
        // CRC16-Modbus("123456789") is 0x4B37 — the standard check vector.
        XCTAssertEqual(Whoop5Wire.crc16Modbus(Array("123456789".utf8)), 0x4B37)
    }

    func testCRC32StandardCheckVector() {
        XCTAssertEqual(Whoop5Wire.crc32IEEE(Array("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: Frame encode/decode

    func testCommandFrameRoundTripsThroughParser() throws {
        let data = Whoop5Wire.command(Whoop5Wire.Command.toggleIMUMode.rawValue,
                                      sequence: 0xF1, payload: [0x01, 0x01, 0x00, 0x00, 0x00])
        let frame = try Whoop5Wire.Frame(data)
        XCTAssertEqual(frame.type, 0x23)
        XCTAssertEqual(frame.version, 0x01)
        XCTAssertEqual(frame.role1, 0x00)
        XCTAssertEqual(frame.role2, 0x01)
        XCTAssertEqual(Array(frame.packet.prefix(3)), [0x23, 0xF1, 0x6A])
    }

    func testDocumentedFrameBytesAreReproduced() {
        // Rebuilding the documented example must yield the exact documented bytes.
        let expected: [UInt8] = [0xaa, 0x01, 0x0c, 0x00, 0x00, 0x01, 0xe7, 0x41,
                                 0x23, 0xf1, 0x6a, 0x01, 0x01, 0x00, 0x00, 0x00,
                                 0x58, 0xe9, 0x61, 0xfc]
        let body: [UInt8] = [0x23, 0xf1, 0x6a, 0x01, 0x01, 0x00, 0x00, 0x00]
        let built = Whoop5Wire.wrap(body + Whoop5Wire.littleEndian32(Whoop5Wire.crc32IEEE(body)))
        XCTAssertEqual([UInt8](built), expected)
    }

    func testCorruptedHeaderIsRejected() {
        let data = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue, sequence: 1)
        var bytes = [UInt8](data)
        bytes[2] ^= 0xFF  // breaks the declared length and the header CRC
        XCTAssertThrowsError(try Whoop5Wire.Frame(Data(bytes)))
    }

    func testCorruptedPayloadIsRejected() {
        let data = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue, sequence: 1)
        var bytes = [UInt8](data)
        bytes[bytes.count - 6] ^= 0xFF  // flip a payload byte, CRC32 no longer matches
        XCTAssertThrowsError(try Whoop5Wire.Frame(Data(bytes)))
    }

    func testWrongStartByteIsRejected() {
        var bytes = [UInt8](Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue, sequence: 1))
        bytes[0] = 0xAB
        XCTAssertThrowsError(try Whoop5Wire.Frame(Data(bytes)))
    }

    // MARK: Record decoding

    private func compactRealtime(heartRate: UInt8, valid: UInt8, rr: UInt16, timestamp: UInt32) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 24)
        packet[0] = 0x28; packet[1] = 0x02
        for (i, b) in Whoop5Wire.littleEndian32(timestamp).enumerated() { packet[2 + i] = b }
        packet[8] = heartRate
        packet[9] = valid
        for (i, b) in Whoop5Wire.littleEndian16(rr).enumerated() { packet[10 + i] = b }
        packet[18] = 0x01
        return packet
    }

    func testCompactRealtimeDecodesHeartRateAndIntervals() throws {
        let packet = compactRealtime(heartRate: 62, valid: 0x01, rr: 968, timestamp: 1_789_945_840)
        let record = try XCTUnwrap(Whoop5Wire.Realtime(packet: packet))
        XCTAssertEqual(record.heartRate, 62)
        XCTAssertTrue(record.valid)
        XCTAssertEqual(record.rrMilliseconds, 968)
        XCTAssertEqual(record.timestamp, 1_789_945_840)
    }

    func testCompactRealtimeReportsInvalidReading() throws {
        let packet = compactRealtime(heartRate: 0, valid: 0x00, rr: 0, timestamp: 1_789_945_840)
        let record = try XCTUnwrap(Whoop5Wire.Realtime(packet: packet))
        XCTAssertEqual(record.heartRate, 0)
        XCTAssertFalse(record.valid)
    }

    func testCompactRealtimeRejectsOtherPacketTypes() {
        var packet = compactRealtime(heartRate: 62, valid: 1, rr: 968, timestamp: 1)
        packet[0] = 0x2F  // historical, not realtime
        XCTAssertNil(Whoop5Wire.Realtime(packet: packet))
        packet[0] = 0x28; packet[1] = 0x12  // realtime type but wrong record version
        XCTAssertNil(Whoop5Wire.Realtime(packet: packet))
    }

    private func historical(heartRate: UInt8, flag: UInt8, rr: UInt16, sequence: UInt16,
                            quaternion: [Float] = [1, 0, 0, 0]) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 116)
        packet[0] = 0x2F; packet[1] = 0x12
        for (i, b) in Whoop5Wire.littleEndian16(sequence).enumerated() { packet[2 + i] = b }
        packet[14] = heartRate
        packet[15] = flag
        for (i, b) in Whoop5Wire.littleEndian16(rr).enumerated() { packet[16 + i] = b }
        packet[29] = heartRate &- 2
        for (axis, value) in quaternion.enumerated() {
            for (i, b) in Whoop5Wire.littleEndian32(value.bitPattern).enumerated() {
                packet[33 + axis * 4 + i] = b
            }
        }
        return packet
    }

    func testHistoricalRecordDecodesHeartRateIntervalsAndQuaternion() throws {
        let packet = historical(heartRate: 68, flag: 0x01, rr: 941, sequence: 7)
        let record = try XCTUnwrap(Whoop5Wire.HistoricalRecord(packet: packet))
        XCTAssertEqual(record.heartRate, 68)
        XCTAssertEqual(record.flag, 0x01)
        XCTAssertEqual(record.rrMilliseconds, 941)
        XCTAssertEqual(record.sequence, 7)
        XCTAssertEqual(record.smoothedHeartRate, 66)
        XCTAssertEqual(record.quaternion?.count, 4)
        XCTAssertEqual(record.quaternion?[0] ?? 0, 1.0, accuracy: 0.0001)
    }

    func testHistoricalRecordWithholdsImplausibleQuaternion() throws {
        let packet = historical(heartRate: 68, flag: 0x01, rr: 941, sequence: 1,
                                quaternion: [5, 5, 5, 5])  // magnitude far from 1
        let record = try XCTUnwrap(Whoop5Wire.HistoricalRecord(packet: packet))
        XCTAssertNil(record.quaternion)
    }

    func testHistoricalRecordRejectsWrongLayout() {
        var packet = historical(heartRate: 68, flag: 1, rr: 941, sequence: 1)
        packet[1] = 0x18  // version 24 is the WHOOP 4 layout, not 5.0's 18
        XCTAssertNil(Whoop5Wire.HistoricalRecord(packet: packet))
    }

    // MARK: Regression — real frames captured from a live WHOOP 5.0 (firmware 50.42.1.0)

    /// Full 24-byte payloads taken verbatim from a live session on the author's strap:
    /// four consecutive ~1 Hz REALTIME_DATA records.
    private static let realRealtimePayloads = [
        "28021070b06a0a375102c402bf020000000001003ce5fab7",
        "28021170b06a0a375101c4020000000000000100fee00359",
        "28021270b06a0a375201cf0200000000000001009b14fb3c",
        "28021370b06a0a375302b9028e020000000001000afb97fb",
    ]

    private func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    func testRealCapturedFramesDecodeToTheValuesObservedOnHardware() throws {
        // (timestamp, heart rate, raw flag, R-R ms) exactly as received.
        // 1_789_947_920 = 2026-09-20 23:45:20 UTC, the moment of capture.
        let expected: [(Double, Int, UInt8, Int)] = [
            (1_789_947_920, 81, 2, 708),
            (1_789_947_921, 81, 1, 708),
            (1_789_947_922, 82, 1, 719),
            (1_789_947_923, 83, 2, 697),
        ]
        for (hex, want) in zip(Self.realRealtimePayloads, expected) {
            let packet = try XCTUnwrap(hexBytes(hex))
            let record = try XCTUnwrap(Whoop5Wire.Realtime(packet: packet), hex)
            XCTAssertEqual(record.timestamp, want.0, hex)
            XCTAssertEqual(record.heartRate, want.1, hex)
            XCTAssertEqual(record.flag, want.2, hex)
            XCTAssertEqual(record.rrMilliseconds, want.3, hex)
            // Flag 2 also means a valid reading (HR + R-R + an extra field), not just flag 1.
            XCTAssertTrue(record.valid, "flag \(record.flag) must count as valid")
        }
    }

    func testRealFrameSurvivesCRCValidationAndItsCommandBytesStillDecode() throws {
        // Wrap the captured payload in the header the strap actually sent, so this
        // exercises the real parse path rather than a hand-built packet.
        let payload = try XCTUnwrap(hexBytes(Self.realRealtimePayloads[0]))
        let head: [UInt8] = [0xAA, 0x01] + Whoop5Wire.littleEndian16(UInt16(payload.count)) + [0x00, 0x01]
        let frame = try Whoop5Wire.Frame(Data(head + Whoop5Wire.littleEndian16(Whoop5Wire.crc16Modbus(head)) + payload))
        XCTAssertEqual(frame.type, 0x28)
        // Frame.packet deliberately excludes the 4-byte CRC32 trailer. An earlier
        // revision required 24 bytes here and silently decoded nothing.
        XCTAssertEqual(frame.packet.count, 20)
        let record = try XCTUnwrap(Whoop5Wire.Realtime(packet: frame.packet))
        XCTAssertEqual(record.heartRate, 81)
        XCTAssertEqual(record.rrMilliseconds, 708)
        XCTAssertEqual(record.timestamp, 1_789_947_920)
    }

    func testRealtimeRejectsPayloadsTooShortToHoldTheFields() throws {
        // 19 bytes cannot reach the R-R pair at offset 10–11.
        let full = try XCTUnwrap(hexBytes(Self.realRealtimePayloads[0]))
        XCTAssertNil(Whoop5Wire.Realtime(packet: Array(full.prefix(19))))
    }

    /// The reassembler must split a concatenated stream of captured frames exactly.
    func testReassemblerSplitsRealBackToBackFrames() throws {
        var stream: [UInt8] = []
        for hex in Self.realRealtimePayloads {
            let payload = try XCTUnwrap(hexBytes(hex))
            let head: [UInt8] = [0xAA, 0x01] + Whoop5Wire.littleEndian16(UInt16(payload.count)) + [0x00, 0x01]
            stream += head + Whoop5Wire.littleEndian16(Whoop5Wire.crc16Modbus(head)) + payload
        }
        var reassembler = Whoop5Reassembler()
        let frames = reassembler.append(Data(stream))
        XCTAssertEqual(frames.count, Self.realRealtimePayloads.count)
        XCTAssertEqual(reassembler.discardedBytes, 0)
        XCTAssertEqual(reassembler.pendingBytes, 0)
        let rates = frames.compactMap { try? Whoop5Wire.Frame($0) }
            .compactMap { Whoop5Wire.Realtime(packet: $0.packet)?.heartRate }
        XCTAssertEqual(rates, [81, 81, 82, 83])
    }

    // MARK: CLIENT_HELLO — the session opener (published frame, verified against our CRCs)

    /// The published CLIENT_HELLO frame from community documentation. Reproducing it
    /// byte-for-byte proves the encoder matches what the strap expects — including the
    /// `0x01` parameter byte, which the strap requires and silently ignores if it is `0x00`.
    func testEncoderReproducesThePublishedClientHelloFrame() {
        let expected: [UInt8] = [0xaa, 0x01, 0x08, 0x00, 0x00, 0x01, 0xe6, 0x71,
                                 0x23, 0x01, 0x91, 0x01, 0x36, 0x3e, 0x5c, 0x8d]
        let built = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue,
                                       sequence: 0x01, payload: [0x01])
        XCTAssertEqual([UInt8](built), expected)
    }

    func testClientHelloDecodesToTheDocumentedFields() throws {
        let packet = try XCTUnwrap(hexBytes("aa0108000001e67123019101363e5c8d"))
        let frame = try Whoop5Wire.Frame(Data(packet))
        XCTAssertEqual(frame.type, 0x23)
        XCTAssertEqual(frame.role1, 0x00)
        XCTAssertEqual(frame.role2, 0x01)
        XCTAssertEqual(Array(frame.packet), [0x23, 0x01, 0x91, 0x01])
    }

    func testZeroParameterHelloIsStructurallyValidButDifferent() throws {
        // A zero parameter still yields a parseable frame — which is exactly why this
        // was silent: the strap accepted the write and simply ignored it.
        let withZero = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue,
                                          sequence: 0x01, payload: [0x00])
        let withOne = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue,
                                         sequence: 0x01, payload: [0x01])
        XCTAssertNotEqual(withZero, withOne)
        XCTAssertEqual(try Whoop5Wire.Frame(withZero).type, 0x23)
        XCTAssertEqual(try Whoop5Wire.Frame(withOne).type, 0x23)
        XCTAssertEqual(Array(try Whoop5Wire.Frame(withZero).packet), [0x23, 0x01, 0x91, 0x00])
    }

    // MARK: Format-1 padding constraint

    func testCommandBodyIsPaddedToAFourByteBoundary() throws {
        // Format-1 acceptance requires (declaredLength - 4) to be divisible by four, and
        // a complete frame longer than 15 bytes. A zero-payload command therefore gains a
        // padding byte, and the CRC is computed over the padded body.
        let bare = Whoop5Wire.command(Whoop5Wire.Command.linkValid.rawValue, sequence: 0x01)
        let frame = try Whoop5Wire.Frame(bare)
        XCTAssertEqual(frame.packet.count % 4, 0)
        XCTAssertEqual(Array(frame.packet), [0x23, 0x01, 0x01, 0x00])
        XCTAssertEqual([UInt8](bare).count, 16, "complete frame must exceed 15 bytes")
    }

    func testFourByteBodiesAreNotPadded() throws {
        // GET_HELLO already carries a parameter, so it must stay exactly 4 bytes and keep
        // matching the published CLIENT_HELLO frame.
        let frame = try Whoop5Wire.Frame(Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue,
                                                            sequence: 0x01, payload: [0x01]))
        XCTAssertEqual(Array(frame.packet), [0x23, 0x01, 0x91, 0x01])
    }

    func testEveryPaddedBodyIsAccepted() throws {
        // Padding must hold for the odd payload lengths the app actually sends.
        for extra in 0...5 {
            let command = Whoop5Wire.command(Whoop5Wire.Command.setFFValue.rawValue, sequence: 0x09,
                                             payload: Array(repeating: 0x41, count: extra))
            let frame = try Whoop5Wire.Frame(command)
            XCTAssertEqual(frame.packet.count % 4, 0, "payload of \(extra) produced an unaligned body")
            XCTAssertGreaterThan([UInt8](command).count, 15)
        }
    }

    // MARK: Battery (verified on hardware)

    /// Two whole frames as received from a worn WHOOP 5.0. At the same moment the strap
    /// reported 41% and 45% through the standard `2A19` characteristic, which is what
    /// fixes the payload offset and proves the units are percent, not tenths.
    func testBatteryPercentDecodesRealCapturedFrames() throws {
        let cases: [(String, Double)] = [
            ("aa0110000100208124021a040129000000000000d5a361c3", 41),
            ("aa01100001002081244a1a02012d000000000000e606bf28", 45),
        ]
        for (hex, expected) in cases {
            // Frame() also validates the header CRC16 and payload CRC32.
            let frame = try Whoop5Wire.Frame(Data(try XCTUnwrap(hexBytes(hex))))
            XCTAssertEqual(Whoop5Wire.batteryPercent(packet: frame.packet), expected,
                           "failed to decode \(hex)")
        }
    }

    func testBatteryPercentRejectsAnythingButASuccessfulBatteryReply() throws {
        let whole = try XCTUnwrap(hexBytes("aa01100001002081244a1a02012d000000000000e606bf28"))
        let packet = Array(whole[8...])
        XCTAssertEqual(Whoop5Wire.batteryPercent(packet: packet), 45)

        var wrongStatus = packet; wrongStatus[4] = 0x00
        XCTAssertNil(Whoop5Wire.batteryPercent(packet: wrongStatus), "a non-success status must not decode")

        var wrongCommand = packet; wrongCommand[2] = 0x0B
        XCTAssertNil(Whoop5Wire.batteryPercent(packet: wrongCommand), "only 0x1A carries a battery value")

        var wrongType = packet; wrongType[0] = 0x28
        XCTAssertNil(Whoop5Wire.batteryPercent(packet: wrongType), "only 0x24 responses decode")

        var outOfRange = packet; outOfRange[5] = 200
        XCTAssertNil(Whoop5Wire.batteryPercent(packet: outOfRange), "200 is not a percentage")

        XCTAssertNil(Whoop5Wire.batteryPercent(packet: [0x24, 0x4a, 0x1a]),
                     "a truncated packet must not decode")
    }

    func testBatteryPercentRejectsAClockReply() {
        // 0x0B shares the status and payload offset but carries a unix timestamp.
        let packet: [UInt8] = [0x24, 0x4e, 0x0b, 0x07, 0x01, 0x10, 0x70, 0xb0, 0x6a]
        XCTAssertNil(Whoop5Wire.batteryPercent(packet: packet))
    }

    // MARK: Endianness helpers

    func testLittleEndianHelpers() {
        XCTAssertEqual(Whoop5Wire.littleEndian16(0x1234), [0x34, 0x12])
        XCTAssertEqual(Whoop5Wire.littleEndian32(0x12345678), [0x78, 0x56, 0x34, 0x12])
    }
}
