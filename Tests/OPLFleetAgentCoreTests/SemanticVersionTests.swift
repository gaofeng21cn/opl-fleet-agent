import XCTest

@testable import OPLFleetAgentCore

final class SemanticVersionTests: XCTestCase {
  func testParsesAppAndTagVersions() {
    XCTAssertEqual(SemanticVersion("0.2.0"), SemanticVersion(major: 0, minor: 2, patch: 0))
    XCTAssertEqual(SemanticVersion("v12.34.56"), SemanticVersion(major: 12, minor: 34, patch: 56))
  }

  func testComparesEachVersionComponent() {
    XCTAssertLessThan(SemanticVersion("0.1.9")!, SemanticVersion("0.2.0")!)
    XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
    XCTAssertEqual(SemanticVersion("2.3.4"), SemanticVersion("v2.3.4"))
  }

  func testRejectsMalformedVersions() {
    XCTAssertNil(SemanticVersion("0.2"))
    XCTAssertNil(SemanticVersion("release-0.2.0"))
    XCTAssertNil(SemanticVersion("0.2.beta"))
    XCTAssertNil(SemanticVersion("-1.2.3"))
  }
}
