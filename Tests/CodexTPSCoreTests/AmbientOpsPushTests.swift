import CryptoKit
import Foundation
import XCTest

@testable import CodexTPSCore

final class AmbientOpsPushTests: XCTestCase {
  func testUsesCurrentGatewayProductName() {
    XCTAssertEqual(OPLFleetAgentProtocol.gatewayProductName, "OPL Fleet Gateway")
  }

  func testMapsOnlyAggregateSnapshotFields() throws {
    let snapshot = usageSnapshot(status: .ready)
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )

    let payload = AmbientOpsAgentSnapshot(usage: snapshot, identity: identity)
    let data = try JSONEncoder().encode(payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(
      Set(object.keys),
      [
        "schemaVersion", "machineName", "platform", "generatedAt", "status",
        "oneMinute", "fiveMinutes", "activeSessions", "oplFleet",
      ])
    XCTAssertEqual(payload.status, "live")
    XCTAssertEqual(payload.oneMinute.tps, 10)
    XCTAssertEqual(payload.oneMinute.inputTokens, 480)
    XCTAssertEqual(payload.oneMinute.cachedInputTokens, 300)
    XCTAssertEqual(payload.oneMinute.outputTokens, 120)
    XCTAssertEqual(payload.oneMinute.reasoningOutputTokens, 60)
    XCTAssertEqual(payload.oneMinute.requests, 2)
    XCTAssertNil(payload.cpuPercent)
    XCTAssertEqual(payload.schemaVersion, 3)
    XCTAssertEqual(payload.oplFleet?.schema, OPLFleetAgentProtocol.schema)
    XCTAssertEqual(payload.oplFleet?.product, OPLFleetAgentProtocol.productName)
    XCTAssertEqual(payload.oplFleet?.stableNodeID, "primary-mac")
    XCTAssertFalse(payload.oplFleet?.capabilities.contains("prompt") == true)
  }

  func testIncludesOptionalHostCPUOnlyWhenSampled() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )
    let payload = AmbientOpsAgentSnapshot(
      usage: usageSnapshot(status: .ready),
      identity: identity,
      cpuPercent: 42.5
    )
    let data = try JSONEncoder().encode(payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["cpuPercent"] as? Double, 42.5)
  }

  func testIncludesOnlyAggregateHostNetworkTelemetryWhenSampled() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )
    let sampledAt = Date(timeIntervalSince1970: 1_000)
    let payload = AmbientOpsAgentSnapshot(
      usage: usageSnapshot(status: .ready),
      identity: identity,
      network: HostNetworkTelemetry(
        downloadMbps: 123.5,
        uploadMbps: 12.25,
        sampledAt: sampledAt
      )
    )
    let data = try JSONEncoder().encode(payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let network = try XCTUnwrap(object["network"] as? [String: Any])

    XCTAssertEqual(network["downloadMbps"] as? Double, 123.5)
    XCTAssertEqual(network["uploadMbps"] as? Double, 12.25)
    XCTAssertNotNil(network["sampledAt"])
    XCTAssertNil(network["interface"])
    XCTAssertNil(network["address"])
  }

  func testCollectionFailureRetainsLastSuccessfulValues() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )
    let live = AmbientOpsAgentSnapshot(
      usage: usageSnapshot(status: .ready), identity: identity)
    let failed = AmbientOpsAgentSnapshot(
      usage: usageSnapshot(status: .readFailed), identity: identity, fallback: live)

    XCTAssertEqual(failed.status, "error")
    XCTAssertEqual(failed.error, "Codex usage collection failed")
    XCTAssertEqual(failed.oneMinute, live.oneMinute)
    XCTAssertEqual(failed.fiveMinutes, live.fiveMinutes)
    XCTAssertEqual(failed.activeSessions, live.activeSessions)
    XCTAssertEqual(failed.network, live.network)
  }

  func testTracksHostPetIdentityAndActivityState() throws {
    let definition = try AmbientOpsPetDefinition(
      id: "ledger-owl",
      displayName: "Ledger Owl",
      spriteVersionNumber: 1,
      assetHash: String(repeating: "a", count: 64)
    )
    var tracker = AmbientOpsPetTracker()
    let runningUsage = usageSnapshot(
      status: .ready,
      generatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let running = tracker.snapshot(definition: definition, usage: runningUsage)
    let stillRunning = tracker.snapshot(
      definition: definition,
      usage: usageSnapshot(status: .ready, generatedAt: Date(timeIntervalSince1970: 1_010))
    )
    let failed = tracker.snapshot(
      definition: definition,
      usage: usageSnapshot(status: .readFailed, generatedAt: Date(timeIntervalSince1970: 1_020))
    )

    XCTAssertEqual(running.id, "ledger-owl")
    XCTAssertEqual(running.state, .running)
    XCTAssertEqual(running.stateSince, Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(stillRunning.stateSince, running.stateSince)
    XCTAssertEqual(failed.state, .failed)
    XCTAssertEqual(failed.stateSince, Date(timeIntervalSince1970: 1_020))
  }

  func testEncodesPetWithoutConversationContent() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )
    let definition = try AmbientOpsPetDefinition(
      id: "ledger-owl",
      displayName: "Ledger Owl",
      spriteVersionNumber: 1,
      assetHash: String(repeating: "b", count: 64)
    )
    let usage = usageSnapshot(status: .ready)
    var tracker = AmbientOpsPetTracker()
    let payload = AmbientOpsAgentSnapshot(
      usage: usage,
      identity: identity,
      pet: tracker.snapshot(definition: definition, usage: usage)
    )
    let data = try JSONEncoder().encode(payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let pet = try XCTUnwrap(object["pet"] as? [String: Any])

    XCTAssertEqual(payload.schemaVersion, 3)
    XCTAssertEqual(pet["id"] as? String, "ledger-owl")
    XCTAssertEqual(pet["state"] as? String, "running")
    XCTAssertNil(pet["prompt"])
  }

  func testBuildsAuthenticatedRequestWithoutIdentityLeaks() throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary-mac",
      machineName: "Primary Mac",
      platform: "macOS"
    )
    let configuration = try AmbientOpsPushRequest(
      endpoint: XCTUnwrap(URL(string: "https://ops.example.test/base")),
      token: "test-token",
      identity: identity
    )
    let request = try configuration.urlRequest(
      snapshot: AmbientOpsAgentSnapshot(
        usage: usageSnapshot(status: .ready), identity: identity))

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://ops.example.test/base/api/v1/agents/primary-mac/snapshot")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    let body = try XCTUnwrap(request.httpBody)
    let text = try XCTUnwrap(String(data: body, encoding: .utf8))
    XCTAssertFalse(text.contains("session"))
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertFalse(text.contains("prompt"))
    XCTAssertFalse(text.contains("response"))
  }

  func testRejectsUnsafeMachineIDAndEndpoint() throws {
    XCTAssertThrowsError(
      try AmbientOpsMachineIdentity(
        machineID: "../primary",
        machineName: "Primary",
        platform: "macOS"
      ))
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary",
      machineName: "Primary",
      platform: "macOS"
    )
    XCTAssertThrowsError(
      try AmbientOpsPushRequest(
        endpoint: XCTUnwrap(URL(string: "file:///tmp/ambient")),
        token: "test-token",
        identity: identity
      ))
  }

  func testClientRequiresAcceptedResponse() async throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary",
      machineName: "Primary",
      platform: "macOS"
    )
    let request = try AmbientOpsPushRequest(
      endpoint: XCTUnwrap(URL(string: "https://ops.example.test")),
      token: "test-token",
      identity: identity
    )
    let snapshot = AmbientOpsAgentSnapshot(
      usage: usageSnapshot(status: .ready), identity: identity)
    let accepted = AmbientOpsPushClient(request: request) { request in
      (
        Data(#"{"missingPetAssets":[]}"#.utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 202,
          httpVersion: nil,
          headerFields: nil
        )!
      )
    }
    try await accepted.push(snapshot)

    let rejected = AmbientOpsPushClient(request: request) { request in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 401,
          httpVersion: nil,
          headerFields: nil
        )!
      )
    }
    do {
      try await rejected.push(snapshot)
      XCTFail("Expected a non-202 response to fail")
    } catch let error as AmbientOpsPushError {
      XCTAssertEqual(error, .server(401))
    }
  }

  func testUploadsOnlyRequestedPetAssetWithBearerToken() async throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary", machineName: "Primary", platform: "macOS")
    let request = try AmbientOpsPushRequest(
      endpoint: XCTUnwrap(URL(string: "https://ops.example.test/base")),
      token: "test-token",
      identity: identity
    )
    let assetData = webP(payload: Data("pet pixels".utf8))
    let hash = SHA256.hash(data: assetData)
      .map { String(format: "%02x", $0) }
      .joined()
    let definition = try AmbientOpsPetDefinition(
      id: "local-pet",
      displayName: "Local Pet",
      spriteVersionNumber: 2,
      assetHash: hash
    )
    let asset = AmbientOpsPetAsset(definition: definition, data: assetData)
    let recorder = URLRequestRecorder()
    let client = AmbientOpsPushClient(request: request) { urlRequest in
      await recorder.append(urlRequest)
      let status = urlRequest.httpMethod == "PUT" ? 201 : 202
      let data =
        urlRequest.httpMethod == "PUT"
        ? Data(#"{"stored":true}"#.utf8)
        : Data(#"{"accepted":true,"missingPetAssets":["\#(hash)"]}"#.utf8)
      return (
        data,
        HTTPURLResponse(
          url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }

    let usage = usageSnapshot(status: .ready)
    var tracker = AmbientOpsPetTracker()
    let snapshot = AmbientOpsAgentSnapshot(
      usage: usage,
      identity: identity,
      pet: tracker.snapshot(definition: definition, usage: usage)
    )
    try await client.push(snapshot, petAsset: asset)

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(
      requests[1].url?.absoluteString,
      "https://ops.example.test/base/api/v1/agents/primary/pets/\(hash)")
    XCTAssertEqual(requests[1].httpMethod, "PUT")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "image/webp")
    XCTAssertEqual(requests[1].httpBody, assetData)
  }

  func testDoesNotUploadUnrequestedOrForeignAsset() async throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary", machineName: "Primary", platform: "macOS")
    let request = try AmbientOpsPushRequest(
      endpoint: XCTUnwrap(URL(string: "https://ops.example.test")),
      token: "test-token",
      identity: identity
    )
    let assetData = webP(payload: Data("pet pixels".utf8))
    let hash = SHA256.hash(data: assetData)
      .map { String(format: "%02x", $0) }
      .joined()
    let asset = AmbientOpsPetAsset(
      definition: try AmbientOpsPetDefinition(
        id: "local-pet", displayName: "Local", spriteVersionNumber: 1, assetHash: hash),
      data: assetData
    )
    let recorder = URLRequestRecorder()
    let client = AmbientOpsPushClient(request: request) { urlRequest in
      await recorder.append(urlRequest)
      return (
        Data(
          #"{"missingPetAssets":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}"#
            .utf8),
        HTTPURLResponse(
          url: urlRequest.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
      )
    }
    try await client.push(
      AmbientOpsAgentSnapshot(usage: usageSnapshot(status: .ready), identity: identity),
      petAsset: asset
    )
    let requestCount = await recorder.count
    XCTAssertEqual(requestCount, 1)
  }

  func testRetriesSnapshotOnceAfterUploadManifestConflict() async throws {
    let identity = try AmbientOpsMachineIdentity(
      machineID: "primary", machineName: "Primary", platform: "macOS")
    let request = try AmbientOpsPushRequest(
      endpoint: XCTUnwrap(URL(string: "https://ops.example.test")),
      token: "test-token",
      identity: identity
    )
    let assetData = webP(payload: Data("pet pixels".utf8))
    let hash = SHA256.hash(data: assetData)
      .map { String(format: "%02x", $0) }
      .joined()
    let definition = try AmbientOpsPetDefinition(
      id: "local-pet", displayName: "Local", spriteVersionNumber: 1, assetHash: hash)
    let asset = AmbientOpsPetAsset(definition: definition, data: assetData)
    let recorder = URLRequestRecorder()
    let client = AmbientOpsPushClient(request: request) { urlRequest in
      await recorder.append(urlRequest)
      let requestCount = await recorder.count
      let status =
        urlRequest.httpMethod == "PUT"
        ? (requestCount == 2 ? 409 : 201)
        : 202
      let data =
        urlRequest.httpMethod == "PUT"
        ? Data()
        : Data(#"{"missingPetAssets":["\#(hash)"]}"#.utf8)
      return (
        data,
        HTTPURLResponse(
          url: urlRequest.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }

    try await client.push(
      AmbientOpsAgentSnapshot(usage: usageSnapshot(status: .ready), identity: identity),
      petAsset: asset
    )

    let recordedRequests = await recorder.requests
    let methods = recordedRequests.map(\.httpMethod)
    XCTAssertEqual(methods, ["POST", "PUT", "POST", "PUT"])
  }

  private func webP(payload: Data) -> Data {
    var data = Data("RIFF".utf8)
    var size = UInt32(payload.count + 4).littleEndian
    data.append(Data(bytes: &size, count: MemoryLayout<UInt32>.size))
    data.append(Data("WEBP".utf8))
    data.append(payload)
    return data
  }

  private func usageSnapshot(
    status: CollectionStatus,
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
      fiveMinutes: WindowMetrics(
        windowSeconds: 300,
        requestCount: 7,
        requestsPerMinute: 1.4,
        tokensPerSecond: 6,
        inputTokensPerSecond: 4.8,
        cachedInputTokensPerSecond: 3,
        outputTokensPerSecond: 1.2,
        reasoningTokensPerSecond: 0.4,
        cacheRatio: 0.625,
        totalTokens: 1_800
      ),
      thirtyMinutes: .empty(windowSeconds: 1_800),
      oneHour: .empty(windowSeconds: 3_600),
      activeSessions: 3,
      malformedRelevantLines: 0,
      status: status
    )
  }
}

private actor URLRequestRecorder {
  private(set) var requests: [URLRequest] = []

  var count: Int {
    requests.count
  }

  func append(_ request: URLRequest) {
    requests.append(request)
  }
}
