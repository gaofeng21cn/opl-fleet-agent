import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class AmbientOpsMachineIdentityTests: XCTestCase {
  func testFreshInstallDerivesDefaultIDAndPersistsHardwareFingerprint() {
    let resolution = AmbientOpsMachineIdentity.resolvePersistedMachineID(
      savedMachineID: nil,
      savedHardwareFingerprint: nil,
      currentHardwareFingerprint: "fp-mini-001",
      hostName: "Gaofeng-Mini"
    )

    XCTAssertEqual(resolution.machineID, "gaofeng-mini")
    XCTAssertEqual(resolution.hardwareFingerprint, "fp-mini-001")
    XCTAssertFalse(resolution.migratedFromAnotherHost)
    XCTAssertTrue(resolution.shouldPersist)
  }

  func testSameHardwareRestartAndRenameKeepSavedMachineID() {
    let resolution = AmbientOpsMachineIdentity.resolvePersistedMachineID(
      savedMachineID: "custom-paired-node",
      savedHardwareFingerprint: "fp-mini-001",
      currentHardwareFingerprint: "fp-mini-001",
      hostName: "Renamed-Mini"
    )

    XCTAssertEqual(resolution.machineID, "custom-paired-node")
    XCTAssertEqual(resolution.hardwareFingerprint, "fp-mini-001")
    XCTAssertFalse(resolution.migratedFromAnotherHost)
    XCTAssertFalse(resolution.shouldPersist)
  }

  func testLegacyUpgradeBackfillsFingerprintWithoutChangingSavedID() {
    let resolution = AmbientOpsMachineIdentity.resolvePersistedMachineID(
      savedMachineID: "gaofeng-mbp-m4max",
      savedHardwareFingerprint: nil,
      currentHardwareFingerprint: "fp-mbp-001",
      hostName: "Gaofeng-MBP-M4Max"
    )

    XCTAssertEqual(resolution.machineID, "gaofeng-mbp-m4max")
    XCTAssertEqual(resolution.hardwareFingerprint, "fp-mbp-001")
    XCTAssertFalse(resolution.migratedFromAnotherHost)
    XCTAssertTrue(resolution.shouldPersist)
  }

  func testCrossHardwareMigrationWithDifferentHostnameSwitchesToLocalDefaultID() {
    let resolution = AmbientOpsMachineIdentity.resolvePersistedMachineID(
      savedMachineID: "gaofeng-mbp-m4max",
      savedHardwareFingerprint: "fp-mbp-001",
      currentHardwareFingerprint: "fp-mini-002",
      hostName: "Gaofeng-Mini"
    )

    XCTAssertEqual(resolution.machineID, "gaofeng-mini")
    XCTAssertEqual(resolution.hardwareFingerprint, "fp-mini-002")
    XCTAssertTrue(resolution.migratedFromAnotherHost)
    XCTAssertTrue(resolution.shouldPersist)
  }

  func testCrossHardwareMigrationWithIdenticalHostnameAppendsFingerprintSuffix() {
    let targetFP = "abcdef1234567890"
    let resolution = AmbientOpsMachineIdentity.resolvePersistedMachineID(
      savedMachineID: "gaofeng-mbp-m4max",
      savedHardwareFingerprint: "fp-source-001",
      currentHardwareFingerprint: targetFP,
      hostName: "Gaofeng-MBP-M4Max"
    )

    XCTAssertEqual(resolution.machineID, "gaofeng-mbp-m4max-abcdef")
    XCTAssertNotEqual(resolution.machineID, "gaofeng-mbp-m4max")
    XCTAssertTrue(AmbientOpsMachineIdentity.isValidMachineID(resolution.machineID))
    XCTAssertTrue(resolution.migratedFromAnotherHost)
    XCTAssertTrue(resolution.shouldPersist)
  }

  func testDisambiguatedMachineIDRespectsMaxLengthAndExcludedIDs() {
    let longBase = String(repeating: "a", count: 80)
    let first = AmbientOpsMachineIdentity.disambiguatedMachineID(
      base: longBase,
      hardwareFingerprint: "1234567890abcdef"
    )
    XCTAssertLessThanOrEqual(first.count, 80)
    XCTAssertTrue(AmbientOpsMachineIdentity.isValidMachineID(first))
    XCTAssertTrue(first.hasSuffix("-123456"))

    let second = AmbientOpsMachineIdentity.disambiguatedMachineID(
      base: longBase,
      hardwareFingerprint: "1234567890abcdef",
      avoiding: [first]
    )
    XCTAssertLessThanOrEqual(second.count, 80)
    XCTAssertNotEqual(second, first)
    XCTAssertTrue(second.hasSuffix("-12345678"))
  }

  func testHardwareFingerprintNormalizesCaseAndNeverExposesRawUUID() throws {
    let rawUUID = "952C6835-3D30-54BE-8484-D8DBC14E719B"
    let lower = try XCTUnwrap(
      AmbientOpsMachineIdentity.hardwareFingerprint(fromPlatformUUID: rawUUID.lowercased()))
    let spaced = try XCTUnwrap(
      AmbientOpsMachineIdentity.hardwareFingerprint(fromPlatformUUID: "  \(rawUUID)\n"))

    XCTAssertEqual(lower, spaced)
    XCTAssertEqual(lower.count, 64)
    XCTAssertFalse(lower.localizedCaseInsensitiveContains("952c6835"))
    XCTAssertNil(AmbientOpsMachineIdentity.hardwareFingerprint(fromPlatformUUID: "   "))
  }

  func testProviderIdentityAdaptsIdenticallyOnCrossHardwareMigration() throws {
    let migrated = try AmbientOpsMachineIdentity.providerIdentity(
      environment: [:],
      savedMachineID: "gaofeng-mbp-m4max",
      savedHardwareFingerprint: "fp-mbp-001",
      currentHardwareFingerprint: "fp-mini-002",
      hostName: "Gaofeng-Mini"
    )

    XCTAssertEqual(migrated.machineID, "gaofeng-mini")
    XCTAssertEqual(migrated.machineName, "Gaofeng-Mini")
  }
}
