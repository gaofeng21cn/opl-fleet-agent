import CryptoKit
import Foundation
import XCTest

@testable import OPLFleetAgentCore

final class AmbientOpsPairingTests: XCTestCase {
  func testExportsAndImportsStableDeviceIdentity() throws {
    let original = AmbientOpsDeviceKey()
    let imported = try AmbientOpsDeviceKey(rawRepresentation: original.rawRepresentation)

    XCTAssertEqual(try original.publicKey, try imported.publicKey)
    XCTAssertEqual(try original.verificationCode, try imported.verificationCode)
    XCTAssertNotNil(try Data(base64Encoded: original.publicKey))
    XCTAssertNotNil(
      try original.verificationCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression))
  }

  func testBuildsPairingAndVerifiableSignedPushWithoutSharedToken() async throws {
    let deviceKey = AmbientOpsDeviceKey()
    let identity = try AmbientOpsMachineIdentity(
      machineID: "macbook-air",
      machineName: "MacBook Air",
      platform: "macOS"
    )
    let endpoint = try XCTUnwrap(URL(string: "http://ambient-ops.local:8787"))
    let pairing = try AmbientOpsPairingClient().pairingRequest(
      endpoint: endpoint,
      identity: identity,
      deviceKey: deviceKey
    )
    let pairingBody = try XCTUnwrap(pairing.httpBody)
    let pairingText = try XCTUnwrap(String(data: pairingBody, encoding: .utf8))

    XCTAssertNil(pairing.value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(pairingText.contains("\"publicKey\""))
    XCTAssertFalse(pairingText.localizedCaseInsensitiveContains("private"))
    XCTAssertFalse(pairingText.localizedCaseInsensitiveContains("token"))

    let signed = try AmbientOpsSignedPushRequest(
      endpoint: endpoint,
      deviceKey: deviceKey,
      identity: identity
    )
    let now = Date(timeIntervalSince1970: 1_000)
    let nonce = "abcdefghijklmnop"
    let request = try signed.urlRequest(
      snapshot: AmbientOpsAgentSnapshot(
        usage: usageSnapshot(),
        identity: identity
      ),
      now: now,
      nonce: nonce
    )
    let body = try XCTUnwrap(request.httpBody)
    let signatureData = try XCTUnwrap(
      Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Ambient-Signature"))))
    let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
    let publicKeyData = try XCTUnwrap(Data(base64Encoded: deviceKey.publicKey))
    let publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyData)
    let bodyHash = SHA256.hash(data: body)
      .map { String(format: "%02x", $0) }
      .joined()
    let canonical = Data(
      "POST\n/api/v1/agents/macbook-air/snapshot\n1000\n\(nonce)\n\(bodyHash)".utf8)

    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "AmbientKey macbook-air"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ambient-Timestamp"), "1000")
    XCTAssertTrue(publicKey.isValidSignature(signature, for: canonical))
    XCTAssertFalse(
      try XCTUnwrap(String(data: body, encoding: .utf8))
        .localizedCaseInsensitiveContains("prompt"))
  }

  func testDecodesPairingSessionAndRejectsForeignApprovalURL() async throws {
    let endpoint = try XCTUnwrap(URL(string: "https://ops.example.test"))
    let response = """
      {
        "requestId": "abcdefghijklmnopqrstuvwxyzABCDEF",
        "machineId": "macbook-air",
        "machineName": "MacBook Air",
        "platform": "macOS",
        "verificationCode": "123456",
        "status": "pending",
        "replacement": false,
        "createdAt": "2026-07-26T09:00:00.000Z",
        "expiresAt": "2026-07-26T09:10:00.000Z",
        "approvedAt": null,
        "approvalPath": "/pair/abcdefghijklmnopqrstuvwxyzABCDEF",
        "pollAfterSeconds": 2
      }
      """
    let client = AmbientOpsPairingClient { request in
      (
        Data(response.utf8),
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
      )
    }
    let pairing = try await client.get(
      endpoint: endpoint,
      requestID: "abcdefghijklmnopqrstuvwxyzABCDEF"
    )

    XCTAssertTrue(pairing.isPending)
    XCTAssertEqual(
      try AmbientOpsPairingClient.approvalURL(endpoint: endpoint, pairing: pairing)
        .absoluteString,
      "https://ops.example.test/pair/abcdefghijklmnopqrstuvwxyzABCDEF"
    )

    let unsafe = AmbientOpsPairingSession(
      requestID: pairing.requestID,
      machineID: pairing.machineID,
      machineName: pairing.machineName,
      platform: pairing.platform,
      verificationCode: pairing.verificationCode,
      status: pairing.status,
      replacement: pairing.replacement,
      createdAt: pairing.createdAt,
      expiresAt: pairing.expiresAt,
      approvedAt: pairing.approvedAt,
      approvalPath: "//evil.example/pair",
      pollAfterSeconds: pairing.pollAfterSeconds
    )
    XCTAssertThrowsError(
      try AmbientOpsPairingClient.approvalURL(endpoint: endpoint, pairing: unsafe))
  }

  func testIntegrationPairingApprovalAndSignedPush() async throws {
    guard
      let value = ProcessInfo.processInfo.environment["AMBIENT_OPS_INTEGRATION_URL"],
      let endpoint = URL(string: value)
    else {
      throw XCTSkip("AMBIENT_OPS_INTEGRATION_URL is not configured")
    }

    let deviceKey = AmbientOpsDeviceKey()
    let identity = try AmbientOpsMachineIdentity(
      machineID: "macos-integration",
      machineName: "macOS Integration",
      platform: "macOS"
    )
    let client = AmbientOpsPairingClient()
    let pending = try await client.begin(
      endpoint: endpoint,
      identity: identity,
      deviceKey: deviceKey
    )
    XCTAssertTrue(pending.isPending)
    XCTAssertEqual(pending.verificationCode, try deviceKey.verificationCode)

    let approvalEndpoint =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("pairings")
      .appendingPathComponent(pending.requestID)
    var approval = URLRequest(url: approvalEndpoint)
    approval.httpMethod = "POST"
    approval.setValue("application/json", forHTTPHeaderField: "Content-Type")
    approval.setValue(
      try XCTUnwrap(
        URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
          .flatMap {
            var origin = $0
            origin.path = ""
            origin.query = nil
            origin.fragment = nil
            return origin.url?.absoluteString.trimmingCharacters(
              in: CharacterSet(charactersIn: "/"))
          }),
      forHTTPHeaderField: "Origin"
    )
    approval.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    approval.httpBody = try JSONSerialization.data(withJSONObject: [
      "action": "approve",
      "verificationCode": try deviceKey.verificationCode,
    ])
    let (_, approvalResponse) = try await URLSession.shared.data(for: approval)
    XCTAssertEqual((approvalResponse as? HTTPURLResponse)?.statusCode, 200)

    let approved = try await client.get(endpoint: endpoint, requestID: pending.requestID)
    XCTAssertTrue(approved.isApproved)

    let signed = try AmbientOpsSignedPushRequest(
      endpoint: endpoint,
      deviceKey: deviceKey,
      identity: identity
    )
    try await AmbientOpsPushClient(signedRequest: signed).push(
      AmbientOpsAgentSnapshot(usage: usageSnapshot(generatedAt: Date()), identity: identity))

    let (statusData, statusResponse) = try await URLSession.shared.data(
      from: endpoint.appendingPathComponent("api").appendingPathComponent("status"))
    XCTAssertEqual((statusResponse as? HTTPURLResponse)?.statusCode, 200)
    let status = try XCTUnwrap(
      JSONSerialization.jsonObject(with: statusData) as? [String: Any])
    let machines = try XCTUnwrap(status["machines"] as? [[String: Any]])
    XCTAssertTrue(machines.contains { $0["machineId"] as? String == identity.machineID })
  }

  private func usageSnapshot(
    generatedAt: Date = Date(timeIntervalSince1970: 1_000)
  ) -> UsageSnapshot {
    UsageSnapshot(
      generatedAt: generatedAt,
      oneMinute: WindowMetrics(
        windowSeconds: 60,
        requestCount: 2,
        requestsPerMinute: 2,
        tokensPerSecond: 10,
        inputTokensPerSecond: 8,
        cachedInputTokensPerSecond: 5,
        outputTokensPerSecond: 2,
        reasoningTokensPerSecond: 1,
        cacheRatio: 0.625,
        totalTokens: 600
      ),
      fiveMinutes: .empty(windowSeconds: 300),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 1,
      malformedRelevantLines: 0,
      status: .ready
    )
  }
}
