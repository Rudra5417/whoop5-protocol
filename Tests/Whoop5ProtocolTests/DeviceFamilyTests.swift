import XCTest
@testable import Whoop5Protocol

final class DeviceFamilyTests: XCTestCase {

    func testServiceUUIDsAreDistinctPerFamily() {
        XCTAssertNotEqual(DeviceFamily.whoop4.serviceUUID, DeviceFamily.whoop5.serviceUUID)
        XCTAssertEqual(DeviceFamily.whoop4.serviceUUID, "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        XCTAssertEqual(DeviceFamily.whoop5.serviceUUID, "fd4b0001-cce1-4033-93ce-002d5875f58a")
    }

    func testOnlyWhoop5UsesTheCRC16Header() {
        XCTAssertFalse(DeviceFamily.whoop4.usesCRC16Header)
        XCTAssertTrue(DeviceFamily.whoop5.usesCRC16Header)
    }

    /// Both generations share the `…000N` suffix pattern within their own family,
    /// which is why a suffix-only swap silently produces frames the strap ignores.
    func testCharacteristicSuffixPatternIsConsistentWithinEachFamily() {
        for family in DeviceFamily.allCases {
            let suffix = String(family.serviceUUID.dropFirst(8))
            for uuid in [family.commandUUID, family.responseUUID, family.eventUUID,
                         family.dataUUID, family.memfaultUUID] {
                XCTAssertEqual(String(uuid.dropFirst(8)), suffix,
                               "\(family) characteristic \(uuid) does not share the service suffix")
            }
        }
    }

    func testDetectIdentifiesFamilyFromDiscoveredServices() {
        XCTAssertEqual(DeviceFamily.detect(fromServiceUUIDs: [DeviceFamily.whoop4.serviceUUID]), .whoop4)
        XCTAssertEqual(DeviceFamily.detect(fromServiceUUIDs: [DeviceFamily.whoop5.serviceUUID]), .whoop5)
        // Case-insensitive, as GATT UUIDs arrive in varying case.
        XCTAssertEqual(DeviceFamily.detect(fromServiceUUIDs: [DeviceFamily.whoop5.serviceUUID.uppercased()]), .whoop5)
    }

    func testDetectIgnoresUnrelatedServices() {
        let standard = ["180d", "180f", "180a"]
        XCTAssertNil(DeviceFamily.detect(fromServiceUUIDs: standard))
        XCTAssertNil(DeviceFamily.detect(fromServiceUUIDs: []))
    }

    func testDetectFindsCustomServiceAmongStandardOnes() {
        let services = ["180a", "180d", "180f", DeviceFamily.whoop5.serviceUUID]
        XCTAssertEqual(DeviceFamily.detect(fromServiceUUIDs: services), .whoop5)
    }

    func testRoleMappingNamesTheChannelsTheSetupGateWaitsOn() {
        for family in DeviceFamily.allCases {
            XCTAssertEqual(family.role(forCharacteristicUUID: family.responseUUID), "response")
            XCTAssertEqual(family.role(forCharacteristicUUID: family.dataUUID), "data")
            XCTAssertEqual(family.role(forCharacteristicUUID: "2A37"), "heartRate")
            XCTAssertEqual(family.role(forCharacteristicUUID: family.eventUUID), "event")
            XCTAssertEqual(family.role(forCharacteristicUUID: family.memfaultUUID), "memfault")
            XCTAssertNil(family.role(forCharacteristicUUID: "180d"))
        }
    }

    func testRoleMappingIsCaseInsensitive() {
        XCTAssertEqual(DeviceFamily.whoop5.role(forCharacteristicUUID: DeviceFamily.whoop5.responseUUID.uppercased()),
                       "response")
    }

    func testFramedChannelsCoverEveryCustomNotifyChannel() {
        for family in DeviceFamily.allCases {
            for uuid in [family.responseUUID, family.eventUUID, family.dataUUID, family.memfaultUUID] {
                XCTAssertTrue(family.framedChannels.contains(uuid.lowercased()))
            }
        }
    }

    /// The live-setup gate needs these three roles before telemetry starts. If the
    /// family's role names drifted, the app would sit in "waiting for telemetry".
    func testEveryFamilyCanSatisfyTheTelemetryGate() {
        for family in DeviceFamily.allCases {
            let roles = Set([family.responseUUID, family.dataUUID, "2A37"]
                .compactMap { family.role(forCharacteristicUUID: $0) })
            XCTAssertTrue(ConnectionRecovery.notificationsReady(roles),
                          "\(family) cannot satisfy notificationsReady")
        }
    }
}
