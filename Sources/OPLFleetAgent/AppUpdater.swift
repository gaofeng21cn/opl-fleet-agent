import AppKit
import Foundation
import Sparkle

enum AppUpdateConfiguration {
  static let feedURLKey = "SUFeedURL"
  static let publicEDKey = "SUPublicEDKey"
  static let automaticChecksKey = "SUEnableAutomaticChecks"
  static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
  static let canonicalFeedURL =
    "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/appcast.xml"
  static let scheduledCheckIntervalSeconds = 6 * 60 * 60

  static func canStartSparkle(
    bundle: Bundle = .main,
    processArguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard environment["XCTestConfigurationFilePath"] == nil,
      !processArguments.contains("--preview-window")
    else {
      return false
    }

    guard bundle.bundleURL.pathExtension == "app" else {
      return false
    }

    guard
      let feedURLString = bundle.object(forInfoDictionaryKey: feedURLKey) as? String,
      let feedURL = URL(string: feedURLString),
      feedURL.scheme == "https",
      let host = feedURL.host,
      !host.isEmpty
    else {
      return false
    }

    guard
      let publicKey = bundle.object(forInfoDictionaryKey: publicEDKey) as? String,
      !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }

    return true
  }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var availableUpdateVersion: String?
  @Published private(set) var isConfigured = false

  private var updaterController: SPUStandardUpdaterController?
  private var canCheckObservation: NSKeyValueObservation?
  private var checkAction: (() -> Void)?

  init(
    bundle: Bundle = .main,
    processArguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    startImmediately: Bool = true
  ) {
    super.init()

    let configured = AppUpdateConfiguration.canStartSparkle(
      bundle: bundle,
      processArguments: processArguments,
      environment: environment
    )
    self.isConfigured = configured

    guard configured else { return }

    let controller = SPUStandardUpdaterController(
      startingUpdater: startImmediately,
      updaterDelegate: nil,
      userDriverDelegate: self
    )
    self.updaterController = controller
    self.canCheckForUpdates = controller.updater.canCheckForUpdates
    self.canCheckObservation = controller.updater.observe(
      \.canCheckForUpdates,
      options: [.initial, .new]
    ) { [weak self] _, change in
      guard let canCheck = change.newValue else { return }
      Task { @MainActor [weak self] in
        self?.canCheckForUpdates = canCheck
      }
    }
  }

  /// Test-only initializer for verifying UI state transitions without invoking Sparkle UI.
  init(
    isConfigured: Bool,
    canCheckForUpdates: Bool,
    availableUpdateVersion: String? = nil,
    checkAction: (() -> Void)? = nil
  ) {
    super.init()
    self.isConfigured = isConfigured
    self.canCheckForUpdates = canCheckForUpdates
    self.availableUpdateVersion = availableUpdateVersion
    self.checkAction = checkAction
  }

  var availableUpdateDisplayLabel: String? {
    guard let availableUpdateVersion, !availableUpdateVersion.isEmpty else {
      return nil
    }
    return availableUpdateVersion.hasPrefix("v")
      ? availableUpdateVersion
      : "v\(availableUpdateVersion)"
  }

  func checkForUpdates() {
    if let checkAction {
      checkAction()
      return
    }
    guard let updaterController else { return }
    NSApplication.shared.activate(ignoringOtherApps: true)
    updaterController.checkForUpdates(nil)
  }

  fileprivate func handleAvailableScheduledUpdate(version: String) {
    availableUpdateVersion = version
  }

  fileprivate func clearAvailableUpdate() {
    availableUpdateVersion = nil
  }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
  nonisolated var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    let version = update.displayVersionString
    let userInitiated = state.userInitiated
    MainActor.assumeIsolated {
      if handleShowingUpdate || userInitiated {
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      if !userInitiated {
        self.handleAvailableScheduledUpdate(version: version)
      }
    }
  }

  nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    MainActor.assumeIsolated {
      self.clearAvailableUpdate()
    }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated {
      self.clearAvailableUpdate()
    }
  }
}
