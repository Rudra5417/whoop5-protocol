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

    // MARK: Endianness helpers

    func testLittleEndianHelpers() {
        XCTAssertEqual(Whoop5Wire.littleEndian16(0x1234), [0x34, 0x12])
        XCTAssertEqual(Whoop5Wire.littleEndian32(0x12345678), [0x78, 0x56, 0x34, 0x12])
    }
}
