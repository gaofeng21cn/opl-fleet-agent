import Foundation
import XCTest

@testable import CodexTPSCore

final class AmbientOpsDiscoveryTests: XCTestCase {
  func testUsesCurrentGatewayProductNames() {
    XCTAssertEqual(OPLFleetAgentProtocol.gatewayProductName, "OPL Fleet Gateway")
    XCTAssertEqual(OPLFleetAgentProtocol.gatewayShortName, "Fleet Gateway")
  }

  func testParsesCompatibleTXTRecordAndDisplayPath() throws {
    let data = NetService.data(
      fromTXTRecord: [
        "id": Data("Home-Ops.1".utf8),
        "name": Data("Gaofeng Home".utf8),
        "pairing": Data("1".utf8),
        "path": Data(" /display/pet ".utf8),
        "protocol": Data("1".utf8),
      ])

    let service = try XCTUnwrap(
      AmbientOpsDiscoveryContract.service(
        serviceName: "OPL Fleet Gateway",
        hostName: "ambient-ops.local.",
        port: 8791,
        txtRecordData: data
      ))

    XCTAssertEqual(service.instanceID, "home-ops.1")
    XCTAssertEqual(service.name, "Gaofeng Home")
    XCTAssertEqual(service.endpoint.absoluteString, "http://ambient-ops.local:8791")
    XCTAssertEqual(service.displayPath, "/display/pet")
    XCTAssertTrue(service.supportsPairing)
    XCTAssertNil(
      AmbientOpsDiscoveryContract.service(
        serviceName: "Future Ops",
        hostName: "future.local.",
        port: 8791,
        txtRecordData: NetService.data(
          fromTXTRecord: ["protocol": Data("2".utf8)])
      ))
  }

  func testRejectsUnsafeDisplayPath() {
    XCTAssertEqual(
      AmbientOpsDiscoveryContract.normalizedPath("https://example.test/"),
      "/display/overview"
    )
    XCTAssertEqual(
      AmbientOpsDiscoveryContract.normalizedPath(String(repeating: "/", count: 161)),
      "/display/overview"
    )
  }

  func testSelectsPreferredInstanceDeterministically() {
    let preferred = service(id: "preferred", port: 8791)
    let other = service(id: "another", port: 8792)
    let selector = AmbientOpsServiceSelector(preferredInstanceID: "PREFERRED")

    XCTAssertEqual(selector.select(from: [other, preferred]), preferred)
    XCTAssertEqual(selector.select(from: [preferred, other]), preferred)
  }

  func testFallsBackToCompatibleInstanceAfterPreferredPushFailure() {
    let preferred = service(id: "preferred", port: 8791)
    let other = service(id: "another", port: 8792)
    var selector = AmbientOpsServiceSelector(preferredInstanceID: "preferred")

    XCTAssertEqual(selector.select(from: [other, preferred]), preferred)
    selector.recordPushFailure(for: preferred)
    XCTAssertEqual(selector.select(from: [preferred, other]), other)
  }

  func testFailedEndpointCanBeRetriedAfterARecoveryReset() {
    let preferred = service(id: "preferred", port: 8791)
    var selector = AmbientOpsServiceSelector(preferredInstanceID: "preferred")

    selector.recordPushFailure(for: preferred)
    XCTAssertNil(selector.select(from: [preferred]))
    selector.resetFailures()
    XCTAssertEqual(selector.select(from: [preferred]), preferred)
  }

  func testFallsBackWhenSavedPreferredInstanceIsNoLongerAdvertised() {
    let available = service(id: "available", port: 8792)
    let selector = AmbientOpsServiceSelector(preferredInstanceID: "retired")

    XCTAssertEqual(selector.select(from: [available]), available)
  }

  private func service(id: String, port: Int) -> AmbientOpsService {
    AmbientOpsService(
      instanceID: id,
      name: id,
      endpoint: URL(string: "http://\(id).local:\(port)")!,
      displayPath: "/display/overview"
    )
  }
}
