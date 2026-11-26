import Foundation

public struct AmbientOpsGatewayMachineSummary: Equatable, Sendable {
  public let machineID: String
  public let machineName: String
  public let status: String
  public let observedAt: Date?

  public init(
    machineID: String,
    machineName: String,
    status: String,
    observedAt: Date?
  ) {
    self.machineID = machineID
    self.machineName = machineName
    self.status = status
    self.observedAt = observedAt
  }
}

public struct AmbientOpsGatewayStatusClient: Sendable {
  private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public init(session: URLSession = .shared) {
    transport = { request in
      try await session.data(for: request)
    }
  }

  init(
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    self.transport = transport
  }

  public func fetchMachines(endpoint: URL) async -> [AmbientOpsGatewayMachineSummary]? {
    guard
      ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
      endpoint.host != nil
    else { return nil }

    let statusURL =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("status")
    guard var components = URLComponents(url: statusURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.queryItems = [URLQueryItem(name: "view", value: "summary")]
    guard let url = components.url else { return nil }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    do {
      let (data, response) = try await transport(request)
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        return nil
      }
      let decoded = try JSONDecoder().decode(GatewayStatusResponseDTO.self, from: data)
      return decoded.machines.map { machine in
        AmbientOpsGatewayMachineSummary(
          machineID: machine.machineId,
          machineName: machine.machineName,
          status: machine.status,
          observedAt: Self.parseDate(machine.observedAt ?? machine.generatedAt)
        )
      }
    } catch {
      return nil
    }
  }

  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let fractional = try? Date(
      raw,
      strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    {
      return fractional
    }
    return try? Date(raw, strategy: Date.ISO8601FormatStyle())
  }
}

public enum AmbientOpsIdentityConflictAction: Equatable, Sendable {
  case none
  case observingConflict(count: Int)
  case migrate(newMachineID: String)
}

public struct AmbientOpsIdentityConflictDetector: Sendable {
  public static let timestampToleranceSeconds: TimeInterval = 1.0
  public static let initialCheckInterval: TimeInterval = 10
  public static let steadyStateCheckInterval: TimeInterval = 60
  public static let nonMatchingHostYieldThreshold = 2
  public static let matchingHostYieldThreshold = 4

  private var trackedEndpointKey: String?
  private var trackedMachineID: String?
  private var lastAcceptedGeneratedAt: Date?
  private var lastCheckAt: Date?
  private var consecutiveConflicts = 0
  private var cleanChecksSinceReset = 0

  public init() {}

  public mutating func reset() {
    trackedEndpointKey = nil
    trackedMachineID = nil
    lastAcceptedGeneratedAt = nil
    lastCheckAt = nil
    consecutiveConflicts = 0
    cleanChecksSinceReset = 0
  }

  public mutating func recordAcceptedPush(
    endpoint: URL,
    identity: AmbientOpsMachineIdentity,
    generatedAt: Date
  ) {
    let endpointKey = endpoint.absoluteString
    if trackedEndpointKey != endpointKey || trackedMachineID != identity.machineID {
      reset()
      trackedEndpointKey = endpointKey
      trackedMachineID = identity.machineID
    }
    lastAcceptedGeneratedAt = generatedAt
  }

  public func shouldCheck(
    endpoint: URL,
    identity: AmbientOpsMachineIdentity,
    now: Date
  ) -> Bool {
    guard
      trackedEndpointKey == endpoint.absoluteString,
      trackedMachineID == identity.machineID,
      lastAcceptedGeneratedAt != nil
    else {
      return false
    }
    guard let lastCheckAt else { return true }
    let interval =
      cleanChecksSinceReset >= 2
      ? Self.steadyStateCheckInterval
      : Self.initialCheckInterval
    return now.timeIntervalSince(lastCheckAt) >= interval
  }

  public mutating func evaluate(
    machines: [AmbientOpsGatewayMachineSummary],
    currentIdentity: AmbientOpsMachineIdentity,
    defaultLocalMachineID: String,
    hardwareFingerprint: String?,
    now: Date
  ) -> AmbientOpsIdentityConflictAction {
    lastCheckAt = now
    guard
      trackedMachineID == currentIdentity.machineID,
      let expectedObservedAt = lastAcceptedGeneratedAt,
      let remoteMachine = machines.first(where: { $0.machineID == currentIdentity.machineID }),
      let remoteObservedAt = remoteMachine.observedAt
    else {
      consecutiveConflicts = 0
      cleanChecksSinceReset += 1
      return .none
    }

    let delta = abs(remoteObservedAt.timeIntervalSince(expectedObservedAt))
    guard delta > Self.timestampToleranceSeconds else {
      consecutiveConflicts = 0
      cleanChecksSinceReset += 1
      return .none
    }

    consecutiveConflicts += 1
    cleanChecksSinceReset = 0
    let isMatchingHostOwner = defaultLocalMachineID == currentIdentity.machineID
    let threshold =
      isMatchingHostOwner
      ? Self.matchingHostYieldThreshold
      : Self.nonMatchingHostYieldThreshold
    guard consecutiveConflicts >= threshold else {
      return .observingConflict(count: consecutiveConflicts)
    }

    let occupiedIDs = Set(machines.map(\.machineID)).union([currentIdentity.machineID])
    let nextMachineID: String
    if !isMatchingHostOwner,
      AmbientOpsMachineIdentity.isValidMachineID(defaultLocalMachineID),
      !occupiedIDs.contains(defaultLocalMachineID)
    {
      nextMachineID = defaultLocalMachineID
    } else {
      nextMachineID = AmbientOpsMachineIdentity.disambiguatedMachineID(
        base: defaultLocalMachineID,
        hardwareFingerprint: hardwareFingerprint,
        avoiding: occupiedIDs
      )
    }

    reset()
    return .migrate(newMachineID: nextMachineID)
  }
}

private struct GatewayStatusResponseDTO: Decodable {
  let machines: [GatewayMachineDTO]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    machines = try container.decodeIfPresent([GatewayMachineDTO].self, forKey: .machines) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case machines
  }
}

private struct GatewayMachineDTO: Decodable {
  let machineId: String
  let machineName: String
  let status: String
  let observedAt: String?
  let generatedAt: String?
}
