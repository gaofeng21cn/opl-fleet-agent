import XCTest

@testable import OPLFleetAgentCore

final class HostTelemetryTests: XCTestCase {
  func testUtilizationUsesIdleDeltaRatherThanNiceDelta() throws {
    XCTAssertEqual(
      try XCTUnwrap(
        HostTelemetrySampler.utilizationPercent(totalDelta: 100, idleDelta: 60)),
      40,
      accuracy: 0.001
    )
  }

  func testUtilizationRejectsInvalidDeltas() {
    XCTAssertNil(HostTelemetrySampler.utilizationPercent(totalDelta: 0, idleDelta: 0))
    XCTAssertNil(HostTelemetrySampler.utilizationPercent(totalDelta: 100, idleDelta: 101))
  }

  func testUtilizationClampsToTheValidRange() throws {
    XCTAssertEqual(
      try XCTUnwrap(
        HostTelemetrySampler.utilizationPercent(totalDelta: 100, idleDelta: 0)),
      100,
      accuracy: 0.001
    )
    XCTAssertEqual(
      try XCTUnwrap(
        HostTelemetrySampler.utilizationPercent(totalDelta: 100, idleDelta: 100)),
      0,
      accuracy: 0.001
    )
  }

  func testNetworkTelemetryUsesDecimalMegabitsAndElapsedTime() throws {
    let sampledAt = Date(timeIntervalSince1970: 1_000)
    let telemetry = try XCTUnwrap(
      HostNetworkTelemetrySampler.telemetry(
        receivedDelta: 25_000_000,
        sentDelta: 2_500_000,
        elapsedSeconds: 2,
        sampledAt: sampledAt
      )
    )

    XCTAssertEqual(telemetry.downloadMbps, 100, accuracy: 0.001)
    XCTAssertEqual(telemetry.uploadMbps, 10, accuracy: 0.001)
    XCTAssertEqual(telemetry.sampledAt, sampledAt)
    XCTAssertNil(
      HostNetworkTelemetrySampler.telemetry(
        receivedDelta: 1,
        sentDelta: 1,
        elapsedSeconds: 0,
        sampledAt: sampledAt
      )
    )
  }
}
