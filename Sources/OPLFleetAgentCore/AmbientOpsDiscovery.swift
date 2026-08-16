@preconcurrency import Foundation

public struct AmbientOpsService: Equatable, Sendable {
  public let instanceID: String
  public let name: String
  public let endpoint: URL
  public let displayPath: String
  public let supportsPairing: Bool

  public init(
    instanceID: String,
    name: String,
    endpoint: URL,
    displayPath: String,
    supportsPairing: Bool = false
  ) {
    self.instanceID = instanceID
    self.name = name
    self.endpoint = endpoint
    self.displayPath = displayPath
    self.supportsPairing = supportsPairing
  }
}

public enum AmbientOpsDiscoveryContract {
  public static let serviceType = "_ambient-ops._tcp."
  public static let domain = "local."
  public static let protocolVersion = "1"
  public static let defaultDisplayPath = "/display/overview"

  public static func service(
    serviceName: String,
    hostName: String?,
    port: Int,
    txtRecordData: Data?
  ) -> AmbientOpsService? {
    guard
      let hostName = hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      !hostName.isEmpty,
      port > 0
    else { return nil }

    let txt = txtDictionary(txtRecordData)
    guard txt["protocol"] == protocolVersion else { return nil }
    let instanceID =
      normalizedInstanceID(txt["id"])
      ?? normalizedInstanceID(serviceName)
      ?? String(serviceName.lowercased().prefix(80))
    var components = URLComponents()
    components.scheme = "http"
    components.host = hostName
    components.port = port
    guard let endpoint = components.url else { return nil }

    return AmbientOpsService(
      instanceID: instanceID,
      name: String((txt["name"] ?? serviceName).prefix(80)),
      endpoint: endpoint,
      displayPath: normalizedPath(txt["path"]),
      supportsPairing: txt["pairing"] == "1"
    )
  }

  public static func txtDictionary(_ data: Data?) -> [String: String] {
    guard let data else { return [:] }
    return NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) {
      result, entry in
      guard let value = String(data: entry.value, encoding: .utf8) else { return }
      result[entry.key] = value
    }
  }

  public static func normalizedPath(_ value: String?) -> String {
    guard let value else { return defaultDisplayPath }
    let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), path.count <= 160 else {
      return defaultDisplayPath
    }
    return path
  }

  private static func normalizedInstanceID(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard
      normalized.range(
        of: #"^[a-z0-9][a-z0-9._-]{0,79}$"#,
        options: .regularExpression
      ) != nil
    else { return nil }
    return normalized
  }
}

public struct AmbientOpsServiceSelector: Sendable {
  private let preferredInstanceID: String?
  private var failedEndpoints: Set<URL> = []

  public init(preferredInstanceID: String?) {
    self.preferredInstanceID =
      preferredInstanceID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  public func select(from services: [AmbientOpsService]) -> AmbientOpsService? {
    services
      .filter { !failedEndpoints.contains($0.endpoint) }
      .sorted(by: isOrderedBefore)
      .first
  }

  public mutating func recordPushFailure(for service: AmbientOpsService) {
    failedEndpoints.insert(service.endpoint)
  }

  public mutating func resetFailures() {
    failedEndpoints.removeAll()
  }

  private func isOrderedBefore(_ lhs: AmbientOpsService, _ rhs: AmbientOpsService) -> Bool {
    let lhsPreferred = lhs.instanceID == preferredInstanceID
    let rhsPreferred = rhs.instanceID == preferredInstanceID
    if lhsPreferred != rhsPreferred {
      return lhsPreferred
    }
    if lhs.instanceID != rhs.instanceID {
      return lhs.instanceID < rhs.instanceID
    }
    return lhs.endpoint.absoluteString < rhs.endpoint.absoluteString
  }
}

@MainActor
public final class AmbientOpsDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  public var onServiceResolved: ((AmbientOpsService) -> Void)?
  public var onStatusChanged: ((String) -> Void)?

  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var resolvedServices: [URL: AmbientOpsService] = [:]
  private var selector = AmbientOpsServiceSelector(preferredInstanceID: nil)
  private var selectedService: AmbientOpsService?
  public private(set) var isRunning = false

  public override init() {
    super.init()
    browser.delegate = self
  }

  public func start(preferredInstanceID: String?) {
    guard !isRunning else { return }
    selector = AmbientOpsServiceSelector(preferredInstanceID: preferredInstanceID)
    resolvedServices.removeAll()
    selectedService = nil
    isRunning = true
    onStatusChanged?("正在查找局域网服务")
    browser.searchForServices(
      ofType: AmbientOpsDiscoveryContract.serviceType,
      inDomain: AmbientOpsDiscoveryContract.domain
    )
  }

  public func stop() {
    guard isRunning else { return }
    browser.stop()
    for service in services {
      service.stop()
    }
    services.removeAll()
    resolvedServices.removeAll()
    selectedService = nil
    isRunning = false
  }

  @discardableResult
  public func recordPushFailure(for service: AmbientOpsService) -> AmbientOpsService? {
    selector.recordPushFailure(for: service)
    if selectedService == service {
      selectedService = nil
    }
    return selectResolvedService()
  }

  @discardableResult
  public func retryFailedEndpoints() -> AmbientOpsService? {
    selector.resetFailures()
    selectedService = nil
    return selectResolvedService()
  }

  public func resetPushFailures() {
    selector.resetFailures()
  }

  nonisolated public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

  nonisolated public func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    let box = AmbientOpsNetServiceBox(service)
    Task { @MainActor [weak self, box] in
      guard let self else { return }
      services.append(box.value)
      box.value.delegate = self
      box.value.resolve(withTimeout: 3)
    }
  }

  nonisolated public func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didRemove service: NetService,
    moreComing: Bool
  ) {
    let box = AmbientOpsNetServiceBox(service)
    Task { @MainActor [weak self, box] in
      self?.services.removeAll { $0 == box.value }
    }
  }

  nonisolated public func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    Task { @MainActor [weak self] in
      self?.isRunning = false
      self?.onStatusChanged?("自动发现不可用")
    }
  }

  nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
    let box = AmbientOpsNetServiceBox(sender)
    Task { @MainActor [weak self, box] in
      self?.handleResolved(box.value)
    }
  }

  nonisolated public func netService(
    _ sender: NetService,
    didNotResolve errorDict: [String: NSNumber]
  ) {
    let box = AmbientOpsNetServiceBox(sender)
    Task { @MainActor [weak self, box] in
      self?.services.removeAll { $0 == box.value }
    }
  }

  private func handleResolved(_ service: NetService) {
    services.removeAll { $0 == service }
    guard
      let candidate = AmbientOpsDiscoveryContract.service(
        serviceName: service.name,
        hostName: service.hostName,
        port: service.port,
        txtRecordData: service.txtRecordData()
      )
    else { return }
    resolvedServices[candidate.endpoint] = candidate
    _ = selectResolvedService()
  }

  @discardableResult
  private func selectResolvedService() -> AmbientOpsService? {
    guard
      let selected = selector.select(from: Array(resolvedServices.values)),
      selected != selectedService
    else { return selectedService }
    selectedService = selected
    onServiceResolved?(selected)
    return selected
  }
}

private final class AmbientOpsNetServiceBox: @unchecked Sendable {
  let value: NetService

  init(_ value: NetService) {
    self.value = value
  }
}
