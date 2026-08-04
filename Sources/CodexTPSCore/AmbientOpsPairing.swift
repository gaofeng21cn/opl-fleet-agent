import CryptoKit
import Foundation

public struct AmbientOpsDeviceKey: Sendable {
  public let rawRepresentation: Data

  public init() {
    rawRepresentation = P256.Signing.PrivateKey().rawRepresentation
  }

  public init(rawRepresentation: Data) throws {
    _ = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    self.rawRepresentation = rawRepresentation
  }

  public var publicKey: String {
    get throws {
      let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
      return key.publicKey.derRepresentation.base64EncodedString()
    }
  }

  public var verificationCode: String {
    get throws {
      let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
      let digest = SHA256.hash(data: key.publicKey.derRepresentation)
      let prefix = digest.prefix(4).reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
      }
      return String(format: "%06u", prefix % 1_000_000)
    }
  }

  func signature(
    method: String,
    path: String,
    timestamp: String,
    nonce: String,
    body: Data
  ) throws -> String {
    let bodyHash = SHA256.hash(data: body)
      .map { String(format: "%02x", $0) }
      .joined()
    let canonical = Data(
      "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash)".utf8)
    let key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    return try key.signature(for: canonical).derRepresentation.base64EncodedString()
  }

  public static func nonce() -> String {
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<18).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    return
      data.base64EncodedString()
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }
}

public struct AmbientOpsPairingSession: Codable, Equatable, Sendable {
  public let requestID: String
  public let machineID: String
  public let machineName: String
  public let platform: String
  public let verificationCode: String
  public let status: String
  public let replacement: Bool
  public let createdAt: Date
  public let expiresAt: Date
  public let approvedAt: Date?
  public let approvalPath: String
  public let pollAfterSeconds: Int

  public var isApproved: Bool { status == "approved" }
  public var isPending: Bool { status == "pending" }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case machineID = "machineId"
    case machineName
    case platform
    case verificationCode
    case status
    case replacement
    case createdAt
    case expiresAt
    case approvedAt
    case approvalPath
    case pollAfterSeconds
  }
}

public struct AmbientOpsPairingClient: Sendable {
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

  public func begin(
    endpoint: URL,
    identity: AmbientOpsMachineIdentity,
    deviceKey: AmbientOpsDeviceKey,
    bearerToken: String? = nil
  ) async throws -> AmbientOpsPairingSession {
    let request = try pairingRequest(
      endpoint: endpoint,
      identity: identity,
      deviceKey: deviceKey,
      bearerToken: bearerToken
    )
    return try await send(request, expectedStatusCode: 202)
  }

  public func get(endpoint: URL, requestID: String) async throws -> AmbientOpsPairingSession {
    guard
      requestID.range(
        of: #"^[A-Za-z0-9_-]{32,80}$"#,
        options: .regularExpression
      ) != nil
    else {
      throw AmbientOpsPairingError.invalidRequestID
    }
    let base = try Self.validatedEndpoint(endpoint)
    var request = URLRequest(
      url:
        base
        .appendingPathComponent("api")
        .appendingPathComponent("v1")
        .appendingPathComponent("pairings")
        .appendingPathComponent(requestID),
      cachePolicy: .reloadIgnoringLocalCacheData
    )
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    return try await send(request, expectedStatusCode: 200)
  }

  public static func approvalURL(
    endpoint: URL,
    pairing: AmbientOpsPairingSession
  ) throws -> URL {
    let base = try validatedEndpoint(endpoint)
    guard
      pairing.approvalPath.hasPrefix("/"),
      !pairing.approvalPath.hasPrefix("//"),
      pairing.approvalPath.count <= 160,
      let url = URL(string: pairing.approvalPath, relativeTo: base)?.absoluteURL,
      url.scheme == base.scheme,
      url.host == base.host,
      url.port == base.port
    else {
      throw AmbientOpsPairingError.invalidApprovalPath
    }
    return url
  }

  func pairingRequest(
    endpoint: URL,
    identity: AmbientOpsMachineIdentity,
    deviceKey: AmbientOpsDeviceKey,
    bearerToken: String? = nil
  ) throws -> URLRequest {
    let base = try Self.validatedEndpoint(endpoint)
    let payload = AmbientOpsPairingRequestBody(
      schemaVersion: 1,
      machineID: identity.machineID,
      machineName: identity.machineName,
      platform: identity.platform,
      publicKey: try deviceKey.publicKey
    )
    var request = URLRequest(
      url:
        base
        .appendingPathComponent("api")
        .appendingPathComponent("v1")
        .appendingPathComponent("pairings"),
      cachePolicy: .reloadIgnoringLocalCacheData
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(payload)
    return request
  }

  private func send(
    _ request: URLRequest,
    expectedStatusCode: Int
  ) async throws -> AmbientOpsPairingSession {
    let (data, response) = try await transport(request)
    guard let response = response as? HTTPURLResponse else {
      throw AmbientOpsPairingError.invalidResponse
    }
    guard response.statusCode == expectedStatusCode else {
      throw AmbientOpsPairingError.server(response.statusCode)
    }
    do {
      return try Self.decoder().decode(AmbientOpsPairingSession.self, from: data)
    } catch {
      throw AmbientOpsPairingError.invalidResponse
    }
  }

  private static func validatedEndpoint(_ endpoint: URL) throws -> URL {
    guard
      ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
      endpoint.host != nil
    else {
      throw AmbientOpsPairingError.invalidEndpoint
    }
    return endpoint
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      if let date = try? Date(
        value,
        strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
      {
        return date
      }
      if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Invalid ISO-8601 date")
    }
    return decoder
  }
}

public struct AmbientOpsSignedPushRequest: Sendable {
  public let endpoint: URL
  public let deviceKey: AmbientOpsDeviceKey
  public let identity: AmbientOpsMachineIdentity

  public init(
    endpoint: URL,
    deviceKey: AmbientOpsDeviceKey,
    identity: AmbientOpsMachineIdentity
  ) throws {
    guard
      ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
      endpoint.host != nil
    else {
      throw AmbientOpsPushError.invalidEndpoint
    }
    self.endpoint = endpoint
    self.deviceKey = deviceKey
    self.identity = identity
  }

  public func urlRequest(
    snapshot: AmbientOpsAgentSnapshot,
    now: Date = Date(),
    nonce: String = AmbientOpsDeviceKey.nonce()
  ) throws -> URLRequest {
    let url =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("agents")
      .appendingPathComponent(identity.machineID)
      .appendingPathComponent("snapshot")
    return try signedRequest(
      url: url,
      method: "POST",
      contentType: "application/json",
      body: AmbientOpsPushRequest.encoder().encode(snapshot),
      timeout: 10,
      now: now,
      nonce: nonce
    )
  }

  func petAssetUploadRequest(
    asset: AmbientOpsPetAsset,
    now: Date = Date(),
    nonce: String = AmbientOpsDeviceKey.nonce()
  ) throws -> URLRequest {
    let url =
      endpoint
      .appendingPathComponent("api")
      .appendingPathComponent("v1")
      .appendingPathComponent("agents")
      .appendingPathComponent(identity.machineID)
      .appendingPathComponent("pets")
      .appendingPathComponent(asset.definition.assetHash)
    return try signedRequest(
      url: url,
      method: "PUT",
      contentType: "image/webp",
      body: asset.data,
      timeout: 20,
      now: now,
      nonce: nonce
    )
  }

  private func signedRequest(
    url: URL,
    method: String,
    contentType: String,
    body: Data,
    timeout: TimeInterval,
    now: Date,
    nonce: String
  ) throws -> URLRequest {
    let timestamp = String(Int64(now.timeIntervalSince1970))
    let signature = try deviceKey.signature(
      method: method,
      path: url.path,
      timestamp: timestamp,
      nonce: nonce,
      body: body
    )
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("AmbientKey \(identity.machineID)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(timestamp, forHTTPHeaderField: "X-Ambient-Timestamp")
    request.setValue(nonce, forHTTPHeaderField: "X-Ambient-Nonce")
    request.setValue(signature, forHTTPHeaderField: "X-Ambient-Signature")
    request.httpBody = body
    return request
  }
}

private struct AmbientOpsPairingRequestBody: Encodable {
  let schemaVersion: Int
  let machineID: String
  let machineName: String
  let platform: String
  let publicKey: String

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case machineID = "machineId"
    case machineName
    case platform
    case publicKey
  }
}

public enum AmbientOpsPairingError: LocalizedError, Equatable {
  case invalidEndpoint
  case invalidRequestID
  case invalidApprovalPath
  case invalidResponse
  case server(Int)
  case rejected
  case expired

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "\(OPLFleetAgentProtocol.gatewayProductName) URL must be an absolute HTTP or HTTPS URL"
    case .invalidRequestID:
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned an invalid pairing request ID"
    case .invalidApprovalPath:
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned an invalid pairing approval path"
    case .invalidResponse:
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned an invalid pairing response"
    case .server(let statusCode):
      return "\(OPLFleetAgentProtocol.gatewayProductName) returned HTTP \(statusCode)"
    case .rejected:
      return "\(OPLFleetAgentProtocol.gatewayProductName) pairing request was rejected"
    case .expired:
      return "\(OPLFleetAgentProtocol.gatewayProductName) pairing request expired"
    }
  }
}
