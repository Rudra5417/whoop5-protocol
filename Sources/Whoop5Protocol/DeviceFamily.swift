import Foundation

/// The two WHOOP generations this app can talk to.
///
/// They are not the same protocol with different UUIDs: the frame header length,
/// header checksum, inner record offset and connection flow all differ. Anything
/// that only swaps UUIDs connects, discovers services, then stalls forever.
///
/// UUIDs are exposed as plain strings so this type stays free of CoreBluetooth and
/// can be exercised in tests, CLI tools and simulators.
public enum DeviceFamily: String, Sendable, CaseIterable {
    /// WHOOP 4.0 — "Harvard". 5-byte header, CRC8, 0x6108… UUIDs.
    case whoop4
    /// WHOOP 5.0 / MG — "Maverick/Goose". 8-byte header, CRC16-Modbus, 0xfd4b… UUIDs.
    case whoop5

    public var displayName: String {
        switch self {
        case .whoop4: return "WHOOP 4.0"
        case .whoop5: return "WHOOP 5.0 / MG"
        }
    }

    // MARK: Service and characteristic UUIDs

    public var serviceUUID: String {
        switch self {
        case .whoop4: return "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0001-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Command write (app → strap).
    public var commandUUID: String {
        switch self {
        case .whoop4: return "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0002-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Command responses (strap → app).
    public var responseUUID: String {
        switch self {
        case .whoop4: return "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0003-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Events (strap → app).
    public var eventUUID: String {
        switch self {
        case .whoop4: return "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0004-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Data / fragmented payloads (strap → app).
    public var dataUUID: String {
        switch self {
        case .whoop4: return "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0005-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Memfault diagnostics. Present on both, subscribed opportunistically.
    public var memfaultUUID: String {
        switch self {
        case .whoop4: return "61080007-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0007-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Channels whose notifications carry the `0xAA`-framed envelope and are
    /// therefore safe to run through the reassembler.
    public var framedChannels: Set<String> {
        Set([responseUUID, eventUUID, dataUUID, memfaultUUID].map { $0.lowercased() })
    }

    // MARK: Role mapping

    /// Names the channels the live-setup gate waits on.
    /// `heartRate` comes from the standard 2A37 characteristic on both families.
    public func role(forCharacteristicUUID uuid: String) -> String? {
        switch uuid.lowercased() {
        case responseUUID.lowercased(): return "response"
        case eventUUID.lowercased(): return "event"
        case dataUUID.lowercased(): return "data"
        case memfaultUUID.lowercased(): return "memfault"
        case "2a37": return "heartRate"
        default: return nil
        }
    }

    /// Standard-format heart rate characteristic, shared by both generations.
    public static let heartRateUUID = "2a37"
    /// Standard battery level characteristic, shared by both generations.
    public static let batteryUUID = "2a19"

    // MARK: Framing

    /// True when the family wraps frames with the CRC16-Modbus 8-byte header.
    public var usesCRC16Header: Bool { self == .whoop5 }

    // MARK: Detection

    /// Identify the generation from discovered service UUIDs.
    /// Returns `nil` when neither family's custom service is present — the caller
    /// should keep whatever default it had rather than guessing.
    public static func detect(fromServiceUUIDs uuids: [String]) -> DeviceFamily? {
        let lowered = Set(uuids.map { $0.lowercased() })
        return allCases.first { lowered.contains($0.serviceUUID.lowercased()) }
    }
}
