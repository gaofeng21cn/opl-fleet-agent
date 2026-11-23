import Foundation
import XCTest

@testable import OPLFleetAgent

@MainActor
final class AppUpdaterTests: XCTestCase {
  func testCanStartSparkleValidatesAppBundleAndInfoPlistContract() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-updater-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let validBundle = try makeTestAppBundle(
      at: tempRoot.appendingPathComponent("Valid.app", isDirectory: true),
      feedURL: AppUpdateConfiguration.canonicalFeedURL,
      publicEDKey: Data(repeating: 0x2A, count: 32).base64EncodedString()
    )
    XCTAssertTrue(
      AppUpdateConfiguration.canStartSparkle(
        bundle: validBundle,
        processArguments: ["OPLFleetAgent"],
        environment: [:]
      )
    )

    // Preview mode and XCTest host must never launch Sparkle UI loops.
    XCTAssertFalse(
      AppUpdateConfiguration.canStartSparkle(
        bundle: validBundle,
        processArguments: ["OPLFleetAgent", "--preview-window"],
        environment: [:]
      )
    )
    XCTAssertFalse(
      AppUpdateConfiguration.canStartSparkle(
        bundle: validBundle,
        processArguments: ["OPLFleetAgent"],
        environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
      )
    )

    // Non-.app bundle (for example bare swift run) must stay safely disabled.
    let nonAppBundle = try makeTestAppBundle(
      at: tempRoot.appendingPathComponent("BareDir", isDirectory: true),
      feedURL: AppUpdateConfiguration.canonicalFeedURL,
      publicEDKey: Data(repeating: 0x2A, count: 32).base64EncodedString()
    )
    XCTAssertFalse(
      AppUpdateConfiguration.canStartSparkle(
        bundle: nonAppBundle,
        processArguments: ["OPLFleetAgent"],
        environment: [:]
      )
    )

    // Insecure feed URL or missing EdDSA public key must be rejected.
    let httpFeedBundle = try makeTestAppBundle(
      at: tempRoot.appendingPathComponent("InsecureFeed.app", isDirectory: true),
      feedURL: "http://example.com/appcast.xml",
      publicEDKey: Data(repeating: 0x2A, count: 32).base64EncodedString()
    )
    XCTAssertFalse(
      AppUpdateConfiguration.canStartSparkle(
        bundle: httpFeedBundle,
        processArguments: ["OPLFleetAgent"],
        environment: [:]
      )
    )

    let missingKeyBundle = try makeTestAppBundle(
      at: tempRoot.appendingPathComponent("MissingKey.app", isDirectory: true),
      feedURL: AppUpdateConfiguration.canonicalFeedURL,
      publicEDKey: nil
    )
    XCTAssertFalse(
      AppUpdateConfiguration.canStartSparkle(
        bundle: missingKeyBundle,
        processArguments: ["OPLFleetAgent"],
        environment: [:]
      )
    )
  }

  func testAppUpdaterFormatsAvailableVersionAndInvokesCheckAction() {
    var triggered = 0
    let updater = AppUpdater(
      isConfigured: true,
      canCheckForUpdates: true,
      availableUpdateVersion: "0.2.53"
    ) {
      triggered += 1
    }

    XCTAssertTrue(updater.isConfigured)
    XCTAssertTrue(updater.canCheckForUpdates)
    XCTAssertTrue(updater.supportsGentleScheduledUpdateReminders)
    XCTAssertEqual(updater.availableUpdateDisplayLabel, "v0.2.53")

    updater.checkForUpdates()
    XCTAssertEqual(triggered, 1)

    let prefixed = AppUpdater(
      isConfigured: true,
      canCheckForUpdates: true,
      availableUpdateVersion: "v0.2.54"
    )
    XCTAssertEqual(prefixed.availableUpdateDisplayLabel, "v0.2.54")

    let empty = AppUpdater(
      isConfigured: true,
      canCheckForUpdates: true,
      availableUpdateVersion: nil
    )
    XCTAssertNil(empty.availableUpdateDisplayLabel)
  }

  func testRepositoryInfoPlistDeclaresSparkleAutoUpdateContract() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let infoPlistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
    let plist = try XCTUnwrap(raw as? [String: Any])

    XCTAssertEqual(
      plist[AppUpdateConfiguration.feedURLKey] as? String,
      AppUpdateConfiguration.canonicalFeedURL
    )

    let publicKeyString = try XCTUnwrap(plist[AppUpdateConfiguration.publicEDKey] as? String)
    let decodedKey = try XCTUnwrap(Data(base64Encoded: publicKeyString))
    XCTAssertEqual(
      decodedKey.count,
      32,
      "SUPublicEDKey must be a 32-byte base64 Ed25519 public key"
    )

    XCTAssertEqual(plist[AppUpdateConfiguration.automaticChecksKey] as? Bool, true)
    XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
    XCTAssertEqual(
      plist[AppUpdateConfiguration.scheduledCheckIntervalKey] as? Int,
      AppUpdateConfiguration.scheduledCheckIntervalSeconds
    )
  }

  private func makeTestAppBundle(
    at bundleURL: URL,
    feedURL: String?,
    publicEDKey: String?
  ) throws -> Bundle {
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    var info: [String: Any] = [
      "CFBundleIdentifier": "io.github.gaofeng21cn.opl-fleet-agent.tests",
      "CFBundleName": "OPL Fleet Agent",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.2.52",
      "CFBundleVersion": "43",
    ]
    if let feedURL {
      info[AppUpdateConfiguration.feedURLKey] = feedURL
    }
    if let publicEDKey {
      info[AppUpdateConfiguration.publicEDKey] = publicEDKey
    }

    let plistData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return try XCTUnwrap(Bundle(url: bundleURL))
  }
}
