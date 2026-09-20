import Foundation

/// WHOOP 5.0 / MG ("Maverick/Goose", fd4b) wire format.
///
/// Distinct from the 4.0 envelope in three ways that matter:
///   * an 8-byte header instead of 5, with two role bytes
///   * CRC16-Modbus over the header instead of CRC8
///   * `payloadLen` counts the CRC32 trailer, so payload = payloadLen - 4
///
/// See docs/PROTOCOL-WHOOP5.md. Protocol facts only; no third-party source copied.
public enum Whoop5Wire {

    // MARK: - Checksums

    /// CRC16-Modbus: reflected polynomial 0xA001, init 0xFFFF, no final xor.
    public static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// CRC32 IEEE 802.3 / zlib, as used for the payload trailer.
    public static func crc32IEEE(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Encoding

    public static func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    public static func littleEndian32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// Common command numbers. WHOOP 5 reuses the 4.0 command vocabulary on a new
    /// transport, so a shared name does not imply identical request bytes.
    public enum Command: UInt8 {
        case linkValid = 0x01
        case toggleRealtimeHR = 0x03
        case reportVersionInfo = 0x07
        case setClock = 0x0A
        case getClock = 0x0B
        case toggleGenericHRProfile = 0x0E
        case abortHistoricalTransmits = 0x14
        case sendHistoricalData = 0x16
        case historicalDataResult = 0x17
        case getBatteryLevel = 0x1A
        case getDataRange = 0x22
        case sendR10R11Realtime = 0x3F
        case enterHighFreqSync = 0x60
        case exitHighFreqSync = 0x61
        case getExtendedBatteryInfo = 0x62
        case toggleIMUMode = 0x6A
        case toggleOpticalMode = 0x6C
        case setFFValue = 0x78
        case stopHaptics = 0x7A
        case selectWrist = 0x7B
        case getFFValue = 0x80
        case getHello = 0x91
    }

    /// Build a command frame: header + [type][seq][command][params…] + CRC32 trailer.
    public static func command(_ command: UInt8, sequence: UInt8, payload: [UInt8] = []) -> Data {
        var body: [UInt8] = [0x23, sequence, command] + payload
        let trailer = crc32IEEE(body)
        body += littleEndian32(trailer)
        return wrap(body)
    }

    /// Wrap an already-composed payload (including its CRC32 trailer) in the 8-byte header.
    public static func wrap(_ payloadWithTrailer: [UInt8]) -> Data {
        let header: [UInt8] = [0xAA, 0x01]
            + littleEndian16(UInt16(payloadWithTrailer.count))
            + [0x00, 0x01]
        let headerCRC = crc16Modbus(header)
        return Data(header + littleEndian16(headerCRC) + payloadWithTrailer)
    }

    // MARK: - Decoding

    public enum WireError: Error { case truncated, invalid, checksum }

    /// A validated 5.0 frame. `payload` excludes the CRC32 trailer.
    public struct Frame: Sendable {
        public let raw: Data
        public let version: UInt8
        public let role1: UInt8
        public let role2: UInt8
        public let type: UInt8
        public let packet: [UInt8]
        public init(_ raw: Data) throws {
            let b = [UInt8](raw)
            guard b.count >= 12, b[0] == 0xAA else { throw WireError.invalid }
            let declared = Int(littleEndian16(b, 2))
            guard declared >= 4, b.count == declared + 8 else { throw WireError.invalid }
            guard crc16Modbus(Array(b[0..<6])) == littleEndian16(b, 6) else { throw WireError.checksum }
            let withTrailer = Array(b[8...])
            let command = Array(withTrailer.dropLast(4))
            guard crc32IEEE(command) == littleEndian32(withTrailer, withTrailer.count - 4) else {
                throw WireError.checksum
            }
            self.raw = raw
            version = b[1]; role1 = b[4]; role2 = b[5]
            packet = command
            type = command.first ?? 0
        }
    }

    static func littleEndian16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    static func littleEndian32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(littleEndian16(b, i)) | UInt32(littleEndian16(b, i + 2)) << 16
    }

    // MARK: - Records

    /// Compact REALTIME_DATA (type 0x28, record type 2, 24-byte payload).
    /// Streams about once a second, including outside sync sessions.
    public struct Realtime: Sendable {
        public let timestamp: Double
        public let heartRate: Int
        public let valid: Bool
        public let rrMilliseconds: Int

        /// - Parameter packet: payload bytes including the CRC32 trailer.
        public init?(packet: [UInt8]) {
            guard packet.count >= 24, packet[0] == 0x28, packet[1] == 0x02 else { return nil }
            // Timestamp sits at offset 2 here, unlike other packet types.
            timestamp = Double(littleEndian32(packet, 2))
            heartRate = Int(packet[8])
            valid = packet[9] == 0x01
            rrMilliseconds = Int(littleEndian16(packet, 10))
        }
    }

    /// HISTORICAL_DATA (type 0x2F, record type 18, 116-byte payload).
    /// WHOOP 5 history is not a shifted WHOOP 4 layout.
    public struct HistoricalRecord: Sendable {
        public let sequence: Int
        public let heartRate: Int
        public let flag: UInt8
        public let rrMilliseconds: Int
        public let smoothedHeartRate: Int
        public let quaternion: [Float]?

        public init?(packet: [UInt8]) {
            guard packet.count >= 49, packet[0] == 0x2F, packet[1] == 0x12 else { return nil }
            sequence = Int(littleEndian16(packet, 2))
            heartRate = Int(packet[14])
            flag = packet[15]
            rrMilliseconds = Int(littleEndian16(packet, 16))
            smoothedHeartRate = Int(packet[29])
            var axes: [Float] = []
            for offset in stride(from: 33, through: 45, by: 4) {
                let bits = littleEndian32(packet, offset)
                axes.append(Float(bitPattern: bits))
            }
            let magnitude = axes.reduce(Float(0)) { $0 + $1 * $1 }
            // Preserve only plausible unit quaternions; anything else stays raw.
            quaternion = axes.allSatisfy({ $0.isFinite }) && abs(magnitude - 1) < 0.25 ? axes : nil
        }
    }

    /// Extended battery response (command 0x62) is not yet decoded; the standard
    /// 2A19 characteristic remains the reliable battery source.
}
