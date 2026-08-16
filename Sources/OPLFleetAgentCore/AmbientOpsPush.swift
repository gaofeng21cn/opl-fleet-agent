import Foundation

public struct AmbientOpsMachineIdentity: Equatable, Sendable {
  public let machineID: String
  public let machineName: String
  public let platform: String

  public init(machineID: String, machineName: String, platform: String) throws {
    guard
      machineID.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression)
        != nil
    else {
      throw AmbientOpsPushError.invalidMachineID
    }
    self.machineID = machineID
    self.machineName = String(machineName.prefix(80))
    self.platform = String(platform.prefix(32))
  }
}

public struct AmbientOpsWindowSnapshot: Codable, Equatable, Sendable {
  public let tps: Double
  public let inputTokens: Int64
  public let outputTokens: Int64
  public let cachedInputTokens: Int64
  public let reasoningOutputTokens: Int64
  public let requests: Int

  init(metrics: WindowMetrics) {
    tps = metrics.tokensPerSecond
    inputTokens = Self.total(metrics.inputTokensPerSecond, seconds: metrics.windowSeconds)
    outputTokens = Self.total(metrics.outputTokensPerSecond, seconds: metrics.windowSeconds)
    cachedInputTokens = Self.total(
      metrics.cachedInputTokensPerSecond, seconds: metrics.windowSeconds)
    reasoningOutputTokens = Self.total(
      metrics.reasoningTokensPerSecond, seconds: metrics.windowSeconds)
    requests = metrics.requestCount
  }

  private static func total(_ rate: Double, seconds: Int) -> Int64 {
    Int64((rate * Double(seconds)).rounded())
  }
}

public enum AmbientOpsPetState: String, Codable, Equatable, Sendable {
  case idle
  case running
  case waiting
  case review
  case failed

  static func derived(from usage: UsageSnapshot) -> AmbientOpsPetState {
    guard usage.status == .ready else { return .failed }
    return usage.activeSessions > 0 && usage.oneMinute.requestCount > 0 ? .running : .idle
  }
}

public struct AmbientOpsPetDefinition: Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let spriteVersionNumber: Int
  public let assetHash: String

  public init(
    id: String,
    displayName: String,
    spriteVersionNumber: Int,
    assetHash: String
  ) throws {
    let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedHash = assetHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard
      normalizedID.range(
        of: #"^[a-z0-9][a-z0-9._-]{0,79}$"#,
        options: .regularExpression
      ) != nil
    else {
      throw AmbientOpsPushError.invalidPetID
    }
    guard
      normalizedHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    else {
      throw AmbientOpsPushError.invalidPetAssetHash
    }
    self.id = normalizedID
    self.displayName = String(displayName.prefix(80))
    self.spriteVersionNumber = max(1, spriteVersionNumber)
    self.assetHash = normalizedHash
  }
}

public struct AmbientOpsPetSnapshot: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let spriteVersionNumber: Int
  public let assetHash: String
  public let state: AmbientOpsPetState
  public let stateSince: Date
}

public struct AmbientOpsPetTracker: Sendable {
  private var state: AmbientOpsPetState?
  private var stateSince: Date?

  public init() {}

  public mutating func snapshot(
    definition: AmbientOpsPetDefinition,
    usage: UsageSnapshot
  ) -> AmbientOpsPetSnapshot {
    let nextState = AmbientOpsPetState.derived(from: usage)
    if nextState != state {
      state = nextState
      stateSince = usage.generatedAt
    }
    return AmbientOpsPetSnapshot(
      id: definition.id,
      displayName: definition.displayName,
      spriteVersionNumber: definition.spriteVersionNumber,
      assetHash: definition.assetHash,
      state: nextState,
      stateSince: stateSince ?? usage.generatedAt
    )
  }
}

public struct AmbientOpsAgentSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let machineName: String
  public let platform: String
  public let generatedAt: Date
  public let status: String
  public let error: String?
  public let oneMinute: AmbientOpsWindowSnapshot
  public let fiveMinutes: AmbientOpsWindowSnapshot
  public let activeSessions: Int
  public let cpuPercent: Double?
  public let network: HostNetworkTelemetry?
  public let pet: AmbientOpsPetSnapshot?
  public let oplFleet: OPLFleetAgentEnvelope?

  public init(
    usage: UsageSnapshot,
    identity: AmbientOpsMachineIdentity,
    fallback: AmbientOpsAgentSnapshot? = nil,
    cpuPercent: Double? = nil,
    network: HostNetworkTelemetry? = nil,
    pet: AmbientOpsPetSnapshot? = nil
  ) {
    schemaVersion = 3
    machineName = identity.machineName
    platform = identity.platform
    generatedAt = usage.generatedAt
    activeSessions = usage.status == .ready ? usage.activeSessions : fallback?.activeSessions ?? 0
    self.cpuPercent = usage.status == .ready ? cpuPercent : fallback?.cpuPercent
    self.network = usage.status == .ready ? network : fallback?.network
    self.pet = pet
    oplFleet = OPLFleetAgentEnvelope(stableNodeID: identity.machineID)

    if usage.status == .ready {
      status = "live"
      error = nil
      oneMinute = AmbientOpsWindowSnapshot(metrics: usage.oneMinute)
      fiveMinutes = AmbientOpsWindowSnapshot(metrics: usage.fiveMinutes)
    } else {
      status = "error"
      error = Self.errorMessage(for: usage.status)
      oneMinute = fallback?.oneMinute ?? AmbientOpsWindowSnapshot(metrics: usage.oneMinute)
      fiveMinutes = fallback?.fiveMinutes ?? AmbientOpsWindowSnapshot(metrics: usage.fiveMinutes)
    }
  }

  private static func errorMessage(for status: CollectionStatus) -> String {
    switch status {
    case .ready:
      return ""
    case .sessionsDirectoryMissing:
      return "Codex sessions directory is unavailable"
    case .readFailed:
      return "Codex usage collection failed"
    }
  }
}

public struct AmbientOpsPushRequest: Sendable {
  public let endpoint: URL
  public let token: String
  public let identity: AmbientOpsMachineIdentity

  public init(endpoint: URL, token: String, identity: AmbientOpsMachineIdentity) throws {
    guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
      endpoint.host != nil
    else {
      throw AmbientOpsPushError.invalidEndpoint
    }
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      throw AmbientOpsPushError.missingToken
    }
    self.endpoint = endpoint
    self.token = trimmedToken
    self.identity = identity
  }

  public func urlRequest(snapshot: AmbientOpsAgentSnapshot) throws -> URLRequest {
    let url =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("agents")
      .appendingPathComponent(identity.machineID)
      .appendingPathComponent("snapshot")
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.encoder().encode(snapshot)
    return request
  }

  func petAssetUploadRequest(asset: AmbientOpsPetAsset) -> URLRequest {
    let url =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("agents")
      .appendingPathComponent(identity.machineID)
      .appendingPathComponent("pets")
      .appendingPathComponent(asset.definition.assetHash)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "PUT"
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("image/webp", forHTTPHeaderField: "Content-Type")
    request.httpBody = asset.data
    return request
  }

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

public struct AmbientOpsPushClient: Sendable {
  private let snapshotRequest: @Sendable (AmbientOpsAgentSnapshot) throws -> URLRequest
  private let petAssetRequest: @Sendable (AmbientOpsPetAsset) throws -> URLRequest
  private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public init(request: AmbientOpsPushRequest, session: URLSession = .shared) {
    snapshotRequest = { snapshot in
      try request.urlRequest(snapshot: snapshot)
    }
    petAssetRequest = { asset in
      request.petAssetUploadRequest(asset: asset)
    }
    transport = { request in
      try await session.data(for: request)
    }
  }

  public init(signedRequest: AmbientOpsSignedPushRequest, session: URLSession = .shared) {
    snapshotRequest = { snapshot in
      try signedRequest.urlRequest(snapshot: snapshot)
    }
    petAssetRequest = { asset in
      try signedRequest.petAssetUploadRequest(asset: asset)
    }
    transport = { request in
      try await session.data(for: request)
    }
  }

  init(
    request: AmbientOpsPushRequest,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    snapshotRequest = { snapshot in
      try request.urlRequest(snapshot: snapshot)
    }
    petAssetRequest = { asset in
      request.petAssetUploadRequest(asset: asset)
    }
    self.transport = transport
  }

  init(
    signedRequest: AmbientOpsSignedPushRequest,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    snapshotRequest = { snapshot in
      try signedRequest.urlRequest(snapshot: snapshot)
    }
    petAssetRequest = { asset in
      try signedRequest.petAssetUploadRequest(asset: asset)
    }
    self.transport = transport
  }

  public func push(
    _ snapshot: AmbientOpsAgentSnapshot,
    petAsset: AmbientOpsPetAsset? = nil
  ) async throws {
    try await push(snapshot, petAsset: petAsset, retryUploadConflict: true)
  }

  private func push(
    _ snapshot: AmbientOpsAgentSnapshot,
    petAsset: AmbientOpsPetAsset?,
    retryUploadConflict: Bool
  ) async throws {
    let (responseData, response) = try await transport(
      snapshotRequest(snapshot))
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AmbientOpsPushError.invalidResponse
    }
    guard httpResponse.statusCode == 202 else {
      throw AmbientOpsPushError.server(httpResponse.statusCode)
    }

    let missingAssets: [String]
    if responseData.isEmpty {
      missingAssets = []
    } else {
      do {
        missingAssets = try JSONDecoder().decode(
          AmbientOpsSnapshotResponse.self, from: responseData
        ).missingPetAssets
      } catch {
        throw AmbientOpsPushError.invalidResponse
      }
    }
    guard
      let petAsset,
      missingAssets.contains(petAsset.definition.assetHash)
    else { return }

    let (_, uploadResponse) = try await transport(
      petAssetRequest(petAsset))
    guard let uploadHTTPResponse = uploadResponse as? HTTPURLResponse else {
      throw AmbientOpsPushError.invalidResponse
    }
    if uploadHTTPResponse.statusCode == 409, retryUploadConflict {
      try await push(snapshot, petAsset: petAsset, retryUploadConflict: false)
      return
    }
    guard uploadHTTPResponse.statusCode == 201 || uploadHTTPResponse.statusCode == 204 else {
      throw AmbientOpsPushError.server(uploadHTTPResponse.statusCode)
    }
  }
}

private struct AmbientOpsSnapshotResponse: Decodable {
  let missingPetAssets: [String]

  private enum CodingKeys: String, CodingKey {
    case missingPetAssets
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    missingPetAssets = try container.decodeIfPresent([String].self, forKey: .missingPetAssets) ?? []
  }
}

public enum AmbientOpsPushError: LocalizedError, Equatable {
  case invalidMachineID
  case invalidPetID
  case invalidPetAssetHash
  case invalidEndpoint
  case missingToken
  case invalidResponse
  case server(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidMachineID:
      return "Machine ID must contain 1-80 letters, numbers, dots, underscores, or hyphens"
    case .invalidPetID:
      return "Pet ID must contain 1-80 lowercase letters, numbers, dots, underscores, or hyphens"
    case .invalidPetAssetHash:
      return "Pet asset hash must be a SHA-256 value"
    case .invalidEndpoint:
      return "\(OPLFleetAgentProtocol.gatewayProductName) URL must be an absolute HTTP or HTTPS URL"
    case .missingToken:
      return "\(OPLFleetAgentProtocol.gatewayProductName) push token is required"
    case .invalidResponse:
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned an invalid response"
    case .server(let statusCode):
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned HTTP \(statusCode)"
    }
  }
}
