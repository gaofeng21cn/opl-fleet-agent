import Foundation
import OPLFleetAgentCore
import Security
import XCTest

@testable import OPLFleetAgent

@MainActor
final class AmbientOpsKeychainTests: XCTestCase {
  func testMissingLegacyTokenDoesNotBecomeAKeychainFailure() throws {
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: errSecItemNotFound, data: nil)
      ])

    XCTAssertNil(try AmbientOpsKeychain(backend: backend).token(account: "tester"))
    XCTAssertEqual(backend.readCount, 1)
  }

  func testDeniedLegacyTokenReadPreservesOSStatus() throws {
    let denied = OSStatus(-2_147_415_840)
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: denied, data: nil)
      ])

    XCTAssertThrowsError(try AmbientOpsKeychain(backend: backend).token(account: "tester")) {
      XCTAssertEqual(
        $0 as? AmbientOpsKeychainError,
        .readFailed(service: AmbientOpsKeychain.service, status: denied)
      )
    }
  }

  func testSuccessfulLegacyTokenReadIsCached() throws {
    let denied = OSStatus(-2_147_415_840)
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: errSecSuccess, data: Data(" legacy-token \n".utf8)),
        AmbientOpsKeychainRead(status: denied, data: nil),
      ])
    let keychain = AmbientOpsKeychain(backend: backend)

    XCTAssertEqual(try keychain.token(account: "tester"), "legacy-token")
    XCTAssertEqual(try keychain.token(account: "tester"), "legacy-token")
    XCTAssertEqual(backend.readCount, 1)
  }

  func testDeviceKeyIsCreatedOnlyAfterAConfirmedMissingReadAndThenCached() throws {
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: errSecItemNotFound, data: nil)
      ],
      addStatuses: [errSecSuccess]
    )
    let keychain = AmbientOpsKeychain(backend: backend)

    let first = try keychain.deviceKey(account: "tester")
    let second = try keychain.deviceKey(account: "tester")

    XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
    XCTAssertEqual(backend.readCount, 1)
    XCTAssertEqual(backend.addCount, 1)
  }

  func testDeniedDeviceKeyReadNeverCreatesAReplacementKey() throws {
    let denied = OSStatus(-2_147_415_840)
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: denied, data: nil)
      ])

    XCTAssertThrowsError(try AmbientOpsKeychain(backend: backend).deviceKey(account: "tester")) {
      XCTAssertEqual(
        $0 as? AmbientOpsKeychainError,
        .readFailed(service: AmbientOpsKeychain.deviceKeyService, status: denied)
      )
    }
    XCTAssertEqual(backend.addCount, 0)
  }

  func testDuplicateDeviceKeyRereadPreservesAReadFailure() throws {
    let denied = OSStatus(-2_147_415_840)
    let backend = FakeKeychainBackend(
      reads: [
        AmbientOpsKeychainRead(status: errSecItemNotFound, data: nil),
        AmbientOpsKeychainRead(status: denied, data: nil),
      ],
      addStatuses: [errSecDuplicateItem]
    )

    XCTAssertThrowsError(try AmbientOpsKeychain(backend: backend).deviceKey(account: "tester")) {
      XCTAssertEqual(
        $0 as? AmbientOpsKeychainError,
        .readFailed(service: AmbientOpsKeychain.deviceKeyService, status: denied)
      )
    }
  }

  func testCredentialFailuresRetryCurrentEndpointWithoutRediscovery() {
    XCTAssertEqual(
      AmbientOpsRetryBehavior.behavior(
        for: AmbientOpsKeychainError.readFailed(service: "test", status: -1),
        autoDiscover: true
      ),
      .retryCurrentEndpoint
    )
    XCTAssertEqual(
      AmbientOpsRetryBehavior.behavior(
        for: AmbientOpsPushError.server(503),
        autoDiscover: true
      ),
      .rediscover
    )
    XCTAssertEqual(
      AmbientOpsRetryBehavior.behavior(
        for: AmbientOpsPushError.server(503),
        autoDiscover: false
      ),
      .retryCurrentEndpoint
    )
  }

  func testManualGatewayAllowsDevicePairingWithoutDiscoveryMetadata() {
    XCTAssertTrue(
      AmbientOpsAuthenticationPolicy.allowsDevicePairing(
        autoDiscover: false,
        discoveredServiceSupportsPairing: nil
      )
    )
  }

  func testAutomaticDiscoveryRequiresExplicitPairingSupport() {
    XCTAssertFalse(
      AmbientOpsAuthenticationPolicy.allowsDevicePairing(
        autoDiscover: true,
        discoveredServiceSupportsPairing: nil
      )
    )
    XCTAssertFalse(
      AmbientOpsAuthenticationPolicy.allowsDevicePairing(
        autoDiscover: true,
        discoveredServiceSupportsPairing: false
      )
    )
    XCTAssertTrue(
      AmbientOpsAuthenticationPolicy.allowsDevicePairing(
        autoDiscover: true,
        discoveredServiceSupportsPairing: true
      )
    )
  }

  func testRetryDelayIsExponentialAndCapped() {
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 1), 15)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 2), 30)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 3), 60)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 4), 120)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 5), 240)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 6), 300)
    XCTAssertEqual(AmbientOpsRetryPolicy.delay(forFailureCount: 20), 300)
  }

  func testManualLocalAddressDoesNotRequireSchemeOrPort() throws {
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("192.168.50.20"),
      try XCTUnwrap(URL(string: "http://192.168.50.20:8787"))
    )
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("fleet-gateway.local"),
      try XCTUnwrap(URL(string: "http://fleet-gateway.local:8787"))
    )
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("fleet-gateway"),
      try XCTUnwrap(URL(string: "http://fleet-gateway:8787"))
    )
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("192.168.50.20:9000"),
      try XCTUnwrap(URL(string: "http://192.168.50.20:9000"))
    )
  }

  func testManualPublicAddressDefaultsToHTTPS() throws {
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("fleet.example.com"),
      try XCTUnwrap(URL(string: "https://fleet.example.com"))
    )
    XCTAssertEqual(
      AmbientOpsManualEndpoint.resolve("fcfleet.example.com"),
      try XCTUnwrap(URL(string: "https://fcfleet.example.com"))
    )
  }

  func testLegacyLocalHTTPSHandshakeFailureFallsBackToHTTP() throws {
    let endpoint = try XCTUnwrap(URL(string: "https://192.168.50.20:8787"))
    let expected = try XCTUnwrap(URL(string: "http://192.168.50.20:8787"))
    let failures: [Error] = [
      URLError(.secureConnectionFailed),
      NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed),
    ]

    for failure in failures {
      XCTAssertEqual(
        AmbientOpsManualEndpoint.httpFallback(
          for: failure,
          endpoint: endpoint,
          autoDiscover: false
        ),
        expected
      )
    }
  }

  func testHTTPFallbackDoesNotDowngradePublicOrAutomaticallyDiscoveredGateways() throws {
    let failure = URLError(.secureConnectionFailed)
    let publicEndpoint = try XCTUnwrap(URL(string: "https://fleet.example.com:8787"))
    let localEndpoint = try XCTUnwrap(URL(string: "https://gateway.local:8787"))

    XCTAssertNil(
      AmbientOpsManualEndpoint.httpFallback(
        for: failure,
        endpoint: publicEndpoint,
        autoDiscover: false
      )
    )
    XCTAssertNil(
      AmbientOpsManualEndpoint.httpFallback(
        for: failure,
        endpoint: localEndpoint,
        autoDiscover: true
      )
    )
    XCTAssertNil(
      AmbientOpsManualEndpoint.httpFallback(
        for: URLError(.timedOut),
        endpoint: localEndpoint,
        autoDiscover: false
      )
    )
  }
}

private final class FakeKeychainBackend: AmbientOpsKeychainBackend {
  private var reads: [AmbientOpsKeychainRead]
  private var addStatuses: [OSStatus]
  private(set) var readCount = 0
  private(set) var addCount = 0

  init(
    reads: [AmbientOpsKeychainRead],
    addStatuses: [OSStatus] = []
  ) {
    self.reads = reads
    self.addStatuses = addStatuses
  }

  func read(service: String, account: String) -> AmbientOpsKeychainRead {
    readCount += 1
    return reads.removeFirst()
  }

  func add(service: String, account: String, data: Data) -> OSStatus {
    addCount += 1
    return addStatuses.removeFirst()
  }
}
