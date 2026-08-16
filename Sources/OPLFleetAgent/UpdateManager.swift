import Foundation
import OPLFleetAgentCore
import SwiftUI

struct AppRelease: Equatable, Sendable {
  let tagName: String
  let version: SemanticVersion
  let dmgURL: URL
  let checksumURL: URL
}

enum UpdateState: Equatable {
  case idle
  case checking
  case upToDate
  case available(AppRelease)
  case installing
  case failed(String)
}

@MainActor
final class UpdateManager: ObservableObject {
  @Published private(set) var state: UpdateState = .idle

  let currentVersion: SemanticVersion

  private let session: URLSession
  private var checkLoop: Task<Void, Never>?
  private var statusResetTask: Task<Void, Never>?

  private static let checkInterval: Duration = .seconds(6 * 60 * 60)
  private static let latestReleaseURL = URL(
    string: "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest")!
  private static let releaseDownloadURL = URL(
    string: "https://github.com/gaofeng21cn/opl-fleet-agent/releases/download")!
  private static let allowedReleasePagePrefix = "/gaofeng21cn/opl-fleet-agent/releases/tag/"

  init(bundle: Bundle = .main, session: URLSession = .shared) {
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    currentVersion = version.flatMap(SemanticVersion.init) ?? .zero
    self.session = session
  }

  var isBusy: Bool {
    switch state {
    case .checking, .installing:
      true
    default:
      false
    }
  }

  func start() {
    guard checkLoop == nil else { return }
    checkLoop = Task { [weak self] in
      guard let self else { return }
      await checkForUpdates(manual: false)

      while !Task.isCancelled {
        try? await Task.sleep(for: Self.checkInterval)
        guard !Task.isCancelled else { return }
        await checkForUpdates(manual: false)
      }
    }
  }

  func checkForUpdates(manual: Bool = true) async {
    guard !isBusy else { return }
    statusResetTask?.cancel()

    let previousState = state
    state = .checking

    do {
      let release = try await fetchLatestRelease()
      if release.version > currentVersion {
        try await validateAssets(for: release)
        state = .available(release)
      } else {
        state = .upToDate
        scheduleStatusReset(after: manual ? .seconds(4) : .seconds(2))
      }
    } catch {
      if manual {
        state = .failed(Self.message(for: error))
        scheduleStatusReset(to: previousState, after: .seconds(8))
      } else {
        state = previousState
      }
    }
  }

  func installAvailableUpdate() {
    guard case .available(let release) = state else { return }
    statusResetTask?.cancel()
    state = .installing

    Task { [weak self] in
      guard let self else { return }
      do {
        try await runInstaller(for: release)
        state = .upToDate
      } catch {
        state = .failed(Self.message(for: error))
      }
    }
  }

  private func fetchLatestRelease() async throws -> AppRelease {
    let response = try await headResponse(for: Self.latestReleaseURL)
    guard (200..<300).contains(response.statusCode) else {
      throw UpdateError.server(response.statusCode)
    }
    guard let pageURL = response.url,
      Self.isAllowedReleasePage(pageURL),
      let tagName = pageURL.lastPathComponent.removingPercentEncoding,
      let version = SemanticVersion(tagName)
    else {
      throw UpdateError.invalidRelease
    }

    let versionDownloadURL = Self.releaseDownloadURL.appendingPathComponent(tagName)
    let dmgURL = versionDownloadURL.appendingPathComponent("OPL-Fleet-Agent.dmg")
    let checksumURL = versionDownloadURL.appendingPathComponent("OPL-Fleet-Agent.dmg.sha256")

    return AppRelease(
      tagName: tagName,
      version: version,
      dmgURL: dmgURL,
      checksumURL: checksumURL
    )
  }

  private func validateAssets(for release: AppRelease) async throws {
    async let dmgResponse = headResponse(for: release.dmgURL)
    async let checksumResponse = headResponse(for: release.checksumURL)
    let responses = try await [dmgResponse, checksumResponse]

    guard responses.allSatisfy({ (200..<300).contains($0.statusCode) }) else {
      throw UpdateError.missingAssets
    }
  }

  private func headResponse(for url: URL) async throws -> HTTPURLResponse {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "HEAD"
    request.setValue("OPL-Fleet-Agent", forHTTPHeaderField: "User-Agent")
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw UpdateError.invalidResponse
    }
    return response
  }

  private func runInstaller(for release: AppRelease) async throws {
    guard
      let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("install-release.sh"),
      FileManager.default.isReadableFile(atPath: scriptURL.path)
    else {
      throw UpdateError.installerUnavailable
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptURL.path]

    var environment = ProcessInfo.processInfo.environment
    let runningAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
    environment["OPL_FLEET_AGENT_DMG_URL"] = release.dmgURL.absoluteString
    environment["OPL_FLEET_AGENT_CHECKSUM_URL"] = release.checksumURL.absoluteString
    environment["OPL_FLEET_AGENT_EXPECTED_VERSION"] = release.version.description
    environment["OPL_FLEET_AGENT_INSTALL_DIR"] = runningAppURL.deletingLastPathComponent().path
    environment["OPL_FLEET_AGENT_RUNNING_PID"] = String(ProcessInfo.processInfo.processIdentifier)
    environment["OPL_FLEET_AGENT_RUNNING_APP"] = runningAppURL.path

    let logURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("opl-fleet-agent-update-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
      throw UpdateError.installerUnavailable
    }
    let logHandle = try FileHandle(forWritingTo: logURL)
    defer {
      try? logHandle.close()
      try? FileManager.default.removeItem(at: logURL)
    }

    environment["OPL_FLEET_AGENT_UPDATE_LOG"] = logURL.path
    process.environment = environment
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()

    while process.isRunning {
      try await Task.sleep(for: .milliseconds(200))
    }

    try logHandle.synchronize()
    let outputData = (try? Data(contentsOf: logURL)) ?? Data()
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: outputData, as: UTF8.self)
        .split(separator: "\n")
        .last
        .map(String.init)
      throw UpdateError.installationFailed(detail)
    }
  }

  private func scheduleStatusReset(
    to nextState: UpdateState = .idle,
    after delay: Duration
  ) {
    statusResetTask?.cancel()
    statusResetTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.state = nextState
    }
  }

  private static func isAllowedReleasePage(_ url: URL) -> Bool {
    url.scheme == "https"
      && url.host == "github.com"
      && url.path.hasPrefix(allowedReleasePagePrefix)
  }

  private static func message(for error: Error) -> String {
    if let updateError = error as? UpdateError {
      return updateError.errorDescription ?? "更新失败"
    }
    if error is URLError {
      return "检查更新失败，请确认网络连接"
    }
    return "更新失败，请稍后重试"
  }
}

private enum UpdateError: LocalizedError {
  case invalidResponse
  case server(Int)
  case invalidRelease
  case missingAssets
  case installerUnavailable
  case installationFailed(String?)

  var errorDescription: String? {
    switch self {
    case .invalidResponse, .invalidRelease:
      "GitHub 返回了无法识别的版本信息"
    case .server(let statusCode):
      "检查更新失败（HTTP \(statusCode)）"
    case .missingAssets:
      "最新版本缺少 DMG 或校验文件"
    case .installerUnavailable:
      "应用内未找到更新安装器"
    case .installationFailed(let detail):
      detail.map { "安装失败：\($0)" } ?? "安装更新失败"
    }
  }
}
