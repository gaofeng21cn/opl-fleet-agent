import AppKit
import CodexTPSCore
import ServiceManagement
import SwiftUI

@MainActor
final class MonitorStore: ObservableObject {
  @Published private(set) var snapshot: UsageSnapshot
  @Published private(set) var isRefreshing = false
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var selectedWindow: MetricWindow
  @Published private(set) var refreshCadence: RefreshCadence
  @Published private(set) var settingsError: String?
  @Published private(set) var ambientEnabled: Bool
  @Published private(set) var ambientAutoDiscover: Bool
  @Published private(set) var ambientManualURL: String
  @Published private(set) var ambientPet: AmbientOpsPetChoice
  @Published private(set) var ambientConnection: AmbientOpsConnectionState = .disabled

  let sessionsURL: URL

  private let scanner: SessionScanner
  private let ambientPetCatalog: AmbientOpsPetAssetCatalog
  private let ambientMachineID: String
  private let observationStore = AmbientOpsMachineObservationStore()
  private let ambientDiscovery = AmbientOpsDiscovery()
  private let ambientKeychain = AmbientOpsKeychain()
  private var refreshLoop: Task<Void, Never>?
  private var ambientPushTask: Task<Void, Never>?
  private var ambientRetryTask: Task<Void, Never>?
  private var ambientFailureCount = 0
  private var ambientBearerTokenRejected = false
  private var ambientService: AmbientOpsService?
  private var ambientPairingSession: AmbientOpsPairingSession?
  private var ambientPairingEndpoint: URL?
  private var openedAmbientPairingRequestID: String?
  private var lastObservedSnapshot: AmbientOpsAgentSnapshot?
  private var latestObservation: AmbientOpsMachineObservation?
  private var directServer: AmbientOpsDirectServer?
  private var hostTelemetry = HostTelemetrySampler()
  private var ambientPetTracker = AmbientOpsPetTracker()
  private static let selectedWindowDefaultsKey = "selectedMetricWindow"
  private static let refreshCadenceDefaultsKey = "refreshCadenceSeconds"
  private static let ambientEnabledDefaultsKey = "ambientOpsEnabled"
  private static let ambientAutoDiscoverDefaultsKey = "ambientOpsAutoDiscover"
  private static let ambientManualURLDefaultsKey = "ambientOpsManualURL"
  private static let ambientInstanceIDDefaultsKey = "ambientOpsInstanceID"
  private static let ambientPetDefaultsKey = "ambientOpsPet"
  private static let ambientMachineIDDefaultsKey = "ambientOpsMachineID"

  init(codexHome: URL = SessionScanner.defaultCodexHome()) {
    let savedWindow = UserDefaults.standard.string(forKey: Self.selectedWindowDefaultsKey)
    let savedCadence = UserDefaults.standard.double(forKey: Self.refreshCadenceDefaultsKey)
    selectedWindow = savedWindow.flatMap(MetricWindow.init(rawValue:)) ?? .oneMinute
    refreshCadence = RefreshCadence(rawValue: savedCadence) ?? .fifteenSeconds
    ambientEnabled =
      UserDefaults.standard.object(forKey: Self.ambientEnabledDefaultsKey) as? Bool ?? true
    ambientAutoDiscover =
      UserDefaults.standard.object(forKey: Self.ambientAutoDiscoverDefaultsKey) as? Bool ?? true
    ambientManualURL =
      UserDefaults.standard.string(forKey: Self.ambientManualURLDefaultsKey) ?? ""
    ambientPet = AmbientOpsPetChoice(
      savedValue: UserDefaults.standard.string(forKey: Self.ambientPetDefaultsKey))
    ambientMachineID =
      UserDefaults.standard.string(forKey: Self.ambientMachineIDDefaultsKey)
      ?? AmbientOpsMachineIdentity.defaultLocalMachineID()
    UserDefaults.standard.set(ambientMachineID, forKey: Self.ambientMachineIDDefaultsKey)
    scanner = SessionScanner(codexHome: codexHome)
    ambientPetCatalog = AmbientOpsPetAssetCatalog(codexHome: codexHome)
    sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
    snapshot = .empty(at: Date(), status: .ready)
    if let identity = try? AmbientOpsMachineIdentity.localMachine(machineID: ambientMachineID) {
      directServer = AmbientOpsDirectServer(
        observationStore: observationStore,
        identity: identity,
        serverVersion: Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
      )
    }
    refreshLaunchAtLoginStatus()
    configureAmbientDiscovery()
  }

  var menuBarTitle: String {
    guard snapshot.status == .ready else { return "-- t/s" }
    let metrics = selectedWindow.metrics(from: snapshot)
    return "\(RateFormatter.compact(metrics.tokensPerSecond)) t/s"
  }

  func start() {
    guard refreshLoop == nil else { return }
    directServer?.start()
    scheduleRefreshLoop()
    refreshAmbientConfiguration()
  }

  func setRefreshCadence(_ cadence: RefreshCadence) {
    guard cadence != refreshCadence else { return }
    refreshCadence = cadence
    UserDefaults.standard.set(cadence.rawValue, forKey: Self.refreshCadenceDefaultsKey)
    scheduleRefreshLoop()
  }

  func setMetricWindow(_ window: MetricWindow) {
    guard window != selectedWindow else { return }
    selectedWindow = window
    UserDefaults.standard.set(window.rawValue, forKey: Self.selectedWindowDefaultsKey)
  }

  private func scheduleRefreshLoop() {
    refreshLoop?.cancel()
    let cadence = refreshCadence
    refreshLoop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        try? await Task.sleep(for: .seconds(cadence.rawValue))
      }
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    let nextSnapshot = await scanner.refresh()
    snapshot = nextSnapshot
    isRefreshing = false
    guard let identity = try? AmbientOpsMachineIdentity.localMachine(machineID: ambientMachineID)
    else { return }
    let petAsset = ambientPet == .localCodex ? await ambientPetCatalog.currentAsset() : nil
    let pet = petAsset.map {
      ambientPetTracker.snapshot(definition: $0.definition, usage: nextSnapshot)
    }
    let networkTelemetry = await observationStore.currentNetwork()
    let payload = AmbientOpsAgentSnapshot(
      usage: nextSnapshot,
      identity: identity,
      fallback: lastObservedSnapshot,
      cpuPercent: hostTelemetry.sampleCPUPercent(),
      network: networkTelemetry,
      pet: pet
    )
    let observation = AmbientOpsMachineObservation(
      identity: identity,
      snapshot: payload,
      petAsset: petAsset
    )
    latestObservation = observation
    if nextSnapshot.status == .ready {
      lastObservedSnapshot = payload
    }
    await observationStore.update(observation)
    pushAmbient(observation)
  }

  func setAmbientEnabled(_ enabled: Bool) {
    ambientEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.ambientEnabledDefaultsKey)
    resetAmbientPairing()
    resetAmbientEndpointFailures()
    refreshAmbientConfiguration()
    if enabled {
      Task { await refresh() }
    }
  }

  func setAmbientAutoDiscover(_ enabled: Bool) {
    ambientAutoDiscover = enabled
    UserDefaults.standard.set(enabled, forKey: Self.ambientAutoDiscoverDefaultsKey)
    ambientService = nil
    resetAmbientPairing()
    resetAmbientEndpointFailures()
    refreshAmbientConfiguration()
    Task { await refresh() }
  }

  func setAmbientManualURL(_ value: String) {
    ambientManualURL = value
    UserDefaults.standard.set(value, forKey: Self.ambientManualURLDefaultsKey)
    guard !ambientAutoDiscover else { return }
    resetAmbientPairing()
    resetAmbientEndpointFailures()
    refreshAmbientConfiguration()
  }

  func setAmbientPet(_ pet: AmbientOpsPetChoice) {
    guard pet != ambientPet else { return }
    ambientPet = pet
    ambientPetTracker = AmbientOpsPetTracker()
    UserDefaults.standard.set(pet.rawValue, forKey: Self.ambientPetDefaultsKey)
    Task { await refresh() }
  }

  func rediscoverAmbientOps() {
    UserDefaults.standard.removeObject(forKey: Self.ambientInstanceIDDefaultsKey)
    ambientService = nil
    resetAmbientPairing()
    resetAmbientEndpointFailures()
    ambientDiscovery.stop()
    refreshAmbientConfiguration()
  }

  func openAmbientPairingApproval() {
    guard let url = ambientConnection.pairingApprovalURL else { return }
    NSWorkspace.shared.open(url)
  }

  func openSessionsDirectory() {
    NSWorkspace.shared.open(sessionsURL)
  }

  func refreshLaunchAtLoginStatus() {
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled, SMAppService.mainApp.status != .enabled {
        try SMAppService.mainApp.register()
      } else if !enabled, SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      }
      settingsError = nil
    } catch {
      settingsError = error.localizedDescription
    }
    refreshLaunchAtLoginStatus()
  }

  func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func configureAmbientDiscovery() {
    ambientDiscovery.onStatusChanged = { [weak self] _ in
      guard let self, ambientEnabled, ambientAutoDiscover, ambientService == nil else {
        return
      }
      ambientConnection = .discovering
    }
    ambientDiscovery.onServiceResolved = { [weak self] service in
      guard let self, ambientEnabled, ambientAutoDiscover else { return }
      if ambientService?.endpoint != service.endpoint {
        resetAmbientPairing()
        ambientBearerTokenRejected = false
      }
      ambientService = service
      UserDefaults.standard.set(service.instanceID, forKey: Self.ambientInstanceIDDefaultsKey)
      ambientConnection = .ready(name: service.name, endpoint: service.endpoint)
      if let latestObservation {
        pushAmbient(latestObservation)
      }
    }
  }

  private func refreshAmbientConfiguration() {
    ambientPushTask?.cancel()
    ambientPushTask = nil
    resetAmbientRetry()
    ambientBearerTokenRejected = false

    guard ambientEnabled else {
      ambientDiscovery.stop()
      ambientConnection = .disabled
      return
    }
    if ambientAutoDiscover {
      let preferredID = UserDefaults.standard.string(
        forKey: Self.ambientInstanceIDDefaultsKey)
      ambientConnection =
        ambientService.map {
          .ready(name: $0.name, endpoint: $0.endpoint)
        } ?? .discovering
      ambientDiscovery.start(preferredInstanceID: preferredID)
      return
    }

    ambientDiscovery.stop()
    guard let endpoint = manualAmbientEndpoint else {
      ambientConnection = .failed(message: "请输入有效的 HTTP(S) 地址")
      return
    }
    ambientConnection = .ready(
      name: endpoint.host ?? OPLFleetAgentProtocol.gatewayProductName,
      endpoint: endpoint
    )
  }

  private var manualAmbientEndpoint: URL? {
    guard
      let endpoint = URL(string: ambientManualURL),
      ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
      endpoint.host != nil
    else { return nil }
    return endpoint
  }

  private func pushAmbient(_ observation: AmbientOpsMachineObservation) {
    guard ambientEnabled, ambientPushTask == nil, ambientRetryTask == nil else { return }
    let service = ambientService
    let endpoint: URL?
    let name: String
    if ambientAutoDiscover {
      endpoint = service?.endpoint
      name = service?.name ?? OPLFleetAgentProtocol.gatewayProductName
    } else {
      endpoint = manualAmbientEndpoint
      name = endpoint?.host ?? OPLFleetAgentProtocol.gatewayProductName
    }
    guard let endpoint else { return }
    ambientPushTask = Task { [weak self] in
      guard let self else { return }
      defer { ambientPushTask = nil }
      ambientConnection = .pushing(name: name, endpoint: endpoint)
      do {
        let pairingSupported = AmbientOpsAuthenticationPolicy.allowsDevicePairing(
          autoDiscover: ambientAutoDiscover,
          discoveredServiceSupportsPairing: service?.supportsPairing
        )
        let token = ambientBearerTokenRejected ? nil : try ambientKeychain.token()
        if token == nil, ambientAutoDiscover, !pairingSupported {
          ambientConnection = .failed(
            message: "此 \(OPLFleetAgentProtocol.gatewayProductName) 不支持安全配对"
          )
          return
        }
        let identity = observation.identity
        let payload = observation.snapshot
        let petAsset = observation.petAsset
        if let token {
          let request = try AmbientOpsPushRequest(
            endpoint: endpoint,
            token: token,
            identity: identity
          )
          do {
            try await AmbientOpsPushClient(request: request).push(payload, petAsset: petAsset)
          } catch let error as AmbientOpsPushError
            where pairingSupported && (error == .server(401) || error == .server(403))
          {
            ambientBearerTokenRejected = true
            let deviceKey = try ambientKeychain.deviceKey()
            try await pushSignedAmbient(
              payload,
              petAsset: petAsset,
              endpoint: endpoint,
              name: name,
              identity: identity,
              deviceKey: deviceKey
            )
          }
        } else {
          let deviceKey = try ambientKeychain.deviceKey()
          try await pushSignedAmbient(
            payload,
            petAsset: petAsset,
            endpoint: endpoint,
            name: name,
            identity: identity,
            deviceKey: deviceKey
          )
        }
        resetAmbientRetry()
        resetAmbientEndpointFailures()
        ambientConnection = .live(name: name, endpoint: endpoint, pushedAt: Date())
      } catch is CancellationError {
        return
      } catch AmbientOpsPairingError.rejected {
        ambientConnection = .failed(message: "配对请求已拒绝 · 请重新发现后重试")
      } catch {
        ambientConnection = .failed(message: "推送失败：\(error.localizedDescription)")
        scheduleAmbientRetry(
          behavior: AmbientOpsRetryBehavior.behavior(
            for: error,
            autoDiscover: ambientAutoDiscover
          ),
          failedService: service
        )
      }
    }
  }

  private func pushSignedAmbient(
    _ payload: AmbientOpsAgentSnapshot,
    petAsset: AmbientOpsPetAsset?,
    endpoint: URL,
    name: String,
    identity: AmbientOpsMachineIdentity,
    deviceKey: AmbientOpsDeviceKey
  ) async throws {
    let signedRequest = try AmbientOpsSignedPushRequest(
      endpoint: endpoint,
      deviceKey: deviceKey,
      identity: identity
    )
    let client = AmbientOpsPushClient(signedRequest: signedRequest)
    do {
      try await client.push(payload, petAsset: petAsset)
      resetAmbientPairing()
      return
    } catch let error as AmbientOpsPushError
      where error == .server(401) || error == .server(403)
    {
      try await awaitAmbientPairing(
        endpoint: endpoint,
        name: name,
        identity: identity,
        deviceKey: deviceKey
      )
      ambientConnection = .pushing(name: name, endpoint: endpoint)
      try await client.push(payload, petAsset: petAsset)
      resetAmbientPairing()
    }
  }

  private func awaitAmbientPairing(
    endpoint: URL,
    name: String,
    identity: AmbientOpsMachineIdentity,
    deviceKey: AmbientOpsDeviceKey
  ) async throws {
    let client = AmbientOpsPairingClient()
    if ambientPairingEndpoint != endpoint {
      resetAmbientPairing()
      ambientPairingEndpoint = endpoint
    }

    var pairing = ambientPairingSession
    if pairing == nil {
      pairing = try await client.begin(
        endpoint: endpoint,
        identity: identity,
        deviceKey: deviceKey
      )
    }

    while let current = pairing {
      ambientPairingSession = current
      switch current.status {
      case "approved":
        return
      case "rejected":
        throw AmbientOpsPairingError.rejected
      case "pending":
        let approvalURL = try AmbientOpsPairingClient.approvalURL(
          endpoint: endpoint,
          pairing: current
        )
        ambientConnection = .pairing(
          name: name,
          endpoint: endpoint,
          verificationCode: try deviceKey.verificationCode,
          approvalURL: approvalURL
        )
        if openedAmbientPairingRequestID != current.requestID {
          openedAmbientPairingRequestID = current.requestID
          NSWorkspace.shared.open(approvalURL)
        }
        let pollSeconds = max(1, min(current.pollAfterSeconds, 10))
        try await Task.sleep(for: .seconds(pollSeconds))
        pairing = try await client.get(endpoint: endpoint, requestID: current.requestID)
      default:
        throw AmbientOpsPairingError.invalidResponse
      }
    }
    throw AmbientOpsPairingError.expired
  }

  private func resetAmbientPairing() {
    ambientPairingSession = nil
    ambientPairingEndpoint = nil
    openedAmbientPairingRequestID = nil
  }

  private func scheduleAmbientRetry(
    behavior: AmbientOpsRetryBehavior,
    failedService: AmbientOpsService?
  ) {
    ambientRetryTask?.cancel()
    ambientFailureCount += 1
    if behavior == .rediscover, ambientAutoDiscover {
      resetAmbientPairing()
      if let service = failedService {
        ambientService = ambientDiscovery.recordPushFailure(for: service)
      }
    }
    let hasFallback = ambientAutoDiscover && ambientService != nil
    let delay = hasFallback ? 1 : AmbientOpsRetryPolicy.delay(forFailureCount: ambientFailureCount)
    ambientRetryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, ambientEnabled else { return }
      ambientRetryTask = nil
      if behavior == .rediscover, ambientAutoDiscover, ambientService == nil {
        ambientService = ambientDiscovery.retryFailedEndpoints()
      }
      if let latestObservation {
        pushAmbient(latestObservation)
      }
    }
  }

  private func resetAmbientRetry() {
    ambientRetryTask?.cancel()
    ambientRetryTask = nil
    ambientFailureCount = 0
  }

  private func resetAmbientEndpointFailures() {
    ambientDiscovery.resetPushFailures()
  }
}

enum AmbientOpsAuthenticationPolicy {
  static func allowsDevicePairing(
    autoDiscover: Bool,
    discoveredServiceSupportsPairing: Bool?
  ) -> Bool {
    !autoDiscover || discoveredServiceSupportsPairing == true
  }
}

enum MetricWindow: String, CaseIterable, Identifiable {
  case oneMinute = "1 分钟"
  case fiveMinutes = "5 分钟"
  case thirtyMinutes = "30 分钟"
  case oneHour = "1 小时"

  var id: Self { self }

  func metrics(from snapshot: UsageSnapshot) -> WindowMetrics {
    switch self {
    case .oneMinute:
      snapshot.oneMinute
    case .fiveMinutes:
      snapshot.fiveMinutes
    case .thirtyMinutes:
      snapshot.thirtyMinutes
    case .oneHour:
      snapshot.oneHour
    }
  }
}

enum RefreshCadence: Double, CaseIterable, Identifiable {
  case fiveSeconds = 5
  case fifteenSeconds = 15
  case thirtySeconds = 30
  case oneMinute = 60

  var id: Self { self }

  var label: String {
    switch self {
    case .fiveSeconds:
      "5 秒"
    case .fifteenSeconds:
      "15 秒"
    case .thirtySeconds:
      "30 秒"
    case .oneMinute:
      "1 分钟"
    }
  }
}

enum RateFormatter {
  static func compact(_ value: Double) -> String {
    switch abs(value) {
    case 1_000_000...:
      return String(format: "%.1fM", value / 1_000_000)
    case 1_000...:
      return String(format: "%.1fk", value / 1_000)
    case 10...:
      return String(format: "%.0f", value)
    default:
      return String(format: "%.1f", value)
    }
  }

  static func detailed(_ value: Double) -> String {
    if abs(value) >= 1_000 {
      return value.formatted(.number.precision(.fractionLength(0)))
    }
    return value.formatted(.number.precision(.fractionLength(1)))
  }
}
