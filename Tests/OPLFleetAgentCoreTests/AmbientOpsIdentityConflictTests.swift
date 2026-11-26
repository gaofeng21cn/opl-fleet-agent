import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class AmbientOpsIdentityConflictTests: XCTestCase {
  func testGatewayStatusClientParsesSummaryAndLegacyPayloadsAndFailsOpen() async throws {
    let summaryJSON = """
      {
        "machines": [
          {
            "machineId": "gaofeng-mini",
            "machineName": "Gaofeng-Mini",
            "status": "live",
            "observedAt": "2026-11-26T09:00:00.250Z"
          },
          {
            "machineId": "legacy-mac",
            "machineName": "Legacy Mac",
            "status": "stale",
            "generatedAt": "2026-11-26T08:59:00Z"
          }
        ]
      }
      """
    let endpoint = try XCTUnwrap(URL(string: "http://192.168.1.170:8787/base"))
    let client = AmbientOpsGatewayStatusClient { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "http://192.168.1.170:8787/base/api/v1/status?view=summary"
      )
      return (
        Data(summaryJSON.utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    let fetched = await client.fetchMachines(endpoint: endpoint)
    let machines = try XCTUnwrap(fetched)
    XCTAssertEqual(machines.count, 2)
    XCTAssertEqual(machines[0].machineID, "gaofeng-mini")
    XCTAssertNotNil(machines[0].observedAt)
    XCTAssertEqual(machines[1].machineID, "legacy-mac")
    XCTAssertNotNil(machines[1].observedAt)

    let failingClient = AmbientOpsGatewayStatusClient { request in
      (
        Data("invalid".utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
      )
    }
    let failedResult = await failingClient.fetchMachines(endpoint: endpoint)
    XCTAssertNil(failedResult)
  }

  func testSingleWriterDoesNotTriggerConflictEvenWhenPairedNameDiffers() throws {
    let endpoint = try XCTUnwrap(URL(string: "http://192.168.1.170:8787"))
    let identity = try AmbientOpsMachineIdentity(
      machineID: "gaofeng-mini",
      machineName: "Renamed Mini",
      platform: "macOS"
    )
    let pushedAt = Date(timeIntervalSince1970: 1_700_000_000)

    var detector = AmbientOpsIdentityConflictDetector()
    detector.recordAcceptedPush(endpoint: endpoint, identity: identity, generatedAt: pushedAt)
    XCTAssertTrue(detector.shouldCheck(endpoint: endpoint, identity: identity, now: pushedAt))

    let machines = [
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mini",
        machineName: "Old Paired Name",
        status: "live",
        observedAt: pushedAt.addingTimeInterval(0.4)
      )
    ]

    let action = detector.evaluate(
      machines: machines,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "abcdef123456",
      now: pushedAt.addingTimeInterval(5)
    )
    XCTAssertEqual(action, .none)
    XCTAssertFalse(
      detector.shouldCheck(
        endpoint: endpoint,
        identity: identity,
        now: pushedAt.addingTimeInterval(14)
      )
    )
    XCTAssertTrue(
      detector.shouldCheck(
        endpoint: endpoint,
        identity: identity,
        now: pushedAt.addingTimeInterval(15)
      )
    )
  }

  func testNonMatchingHostnameOwnerYieldsOnSecondConsecutiveConflict() throws {
    let endpoint = try XCTUnwrap(URL(string: "http://192.168.1.170:8787"))
    let identity = try AmbientOpsMachineIdentity(
      machineID: "gaofeng-mbp-m4max",
      machineName: "Gaofeng-Mini",
      platform: "macOS"
    )
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    var detector = AmbientOpsIdentityConflictDetector()
    detector.recordAcceptedPush(endpoint: endpoint, identity: identity, generatedAt: t0)

    let conflictingMachines = [
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mbp-m4max",
        machineName: "Gaofeng-MBP-M4Max",
        status: "live",
        observedAt: t0.addingTimeInterval(4)
      )
    ]

    let first = detector.evaluate(
      machines: conflictingMachines,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "abcdef123456",
      now: t0.addingTimeInterval(10)
    )
    XCTAssertEqual(first, .observingConflict(count: 1))

    let second = detector.evaluate(
      machines: conflictingMachines,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "abcdef123456",
      now: t0.addingTimeInterval(25)
    )
    XCTAssertEqual(second, .migrate(newMachineID: "gaofeng-mini"))
  }

  func testNonMatchingOwnerFallsBackToDisambiguatedIDIfLocalDefaultAlreadyOccupied() throws {
    let endpoint = try XCTUnwrap(URL(string: "http://192.168.1.170:8787"))
    let identity = try AmbientOpsMachineIdentity(
      machineID: "gaofeng-mbp-m4max",
      machineName: "Gaofeng-Mini",
      platform: "macOS"
    )
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    var detector = AmbientOpsIdentityConflictDetector()
    detector.recordAcceptedPush(endpoint: endpoint, identity: identity, generatedAt: t0)

    let machines = [
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mbp-m4max",
        machineName: "Gaofeng-MBP-M4Max",
        status: "live",
        observedAt: t0.addingTimeInterval(5)
      ),
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mini",
        machineName: "Another Mini",
        status: "live",
        observedAt: t0.addingTimeInterval(3)
      ),
    ]

    _ = detector.evaluate(
      machines: machines,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "987654abcdef",
      now: t0.addingTimeInterval(10)
    )
    let second = detector.evaluate(
      machines: machines,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "987654abcdef",
      now: t0.addingTimeInterval(25)
    )
    XCTAssertEqual(second, .migrate(newMachineID: "gaofeng-mini-987654"))
  }

  func testMatchingHostnameOwnerWaitsFourConflictsBeforeDisambiguatingAndResetsOnCleanCheck()
    throws
  {
    let endpoint = try XCTUnwrap(URL(string: "http://192.168.1.170:8787"))
    let identity = try AmbientOpsMachineIdentity(
      machineID: "gaofeng-mini",
      machineName: "Gaofeng-Mini",
      platform: "macOS"
    )
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    var detector = AmbientOpsIdentityConflictDetector()
    detector.recordAcceptedPush(endpoint: endpoint, identity: identity, generatedAt: t0)

    let conflict = [
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mini",
        machineName: "Gaofeng-Mini",
        status: "live",
        observedAt: t0.addingTimeInterval(6)
      )
    ]
    let clean = [
      AmbientOpsGatewayMachineSummary(
        machineID: "gaofeng-mini",
        machineName: "Gaofeng-Mini",
        status: "live",
        observedAt: t0
      )
    ]

    XCTAssertEqual(
      detector.evaluate(
        machines: conflict,
        currentIdentity: identity,
        defaultLocalMachineID: "gaofeng-mini",
        hardwareFingerprint: "112233445566",
        now: t0.addingTimeInterval(10)
      ),
      .observingConflict(count: 1)
    )
    // A clean observation resets the streak and progresses toward steady-state cadence.
    XCTAssertEqual(
      detector.evaluate(
        machines: clean,
        currentIdentity: identity,
        defaultLocalMachineID: "gaofeng-mini",
        hardwareFingerprint: "112233445566",
        now: t0.addingTimeInterval(20)
      ),
      .none
    )
    XCTAssertEqual(
      detector.evaluate(
        machines: clean,
        currentIdentity: identity,
        defaultLocalMachineID: "gaofeng-mini",
        hardwareFingerprint: "112233445566",
        now: t0.addingTimeInterval(35)
      ),
      .none
    )
    XCTAssertFalse(
      detector.shouldCheck(
        endpoint: endpoint,
        identity: identity,
        now: t0.addingTimeInterval(94)
      )
    )
    XCTAssertTrue(
      detector.shouldCheck(
        endpoint: endpoint,
        identity: identity,
        now: t0.addingTimeInterval(95)
      )
    )

    for expectedCount in 1...3 {
      XCTAssertEqual(
        detector.evaluate(
          machines: conflict,
          currentIdentity: identity,
          defaultLocalMachineID: "gaofeng-mini",
          hardwareFingerprint: "112233445566",
          now: t0.addingTimeInterval(Double(100 + expectedCount * 10))
        ),
        .observingConflict(count: expectedCount)
      )
    }

    let fourth = detector.evaluate(
      machines: conflict,
      currentIdentity: identity,
      defaultLocalMachineID: "gaofeng-mini",
      hardwareFingerprint: "112233445566",
      now: t0.addingTimeInterval(140)
    )
    XCTAssertEqual(fourth, .migrate(newMachineID: "gaofeng-mini-112233"))
  }
}
