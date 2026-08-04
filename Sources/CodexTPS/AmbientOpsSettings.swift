import CodexTPSCore
import Foundation
import Security

enum AmbientOpsConnectionState: Equatable {
  case disabled
  case discovering
  case ready(name: String, endpoint: URL)
  case pairing(name: String, endpoint: URL, verificationCode: String, approvalURL: URL)
  case pushing(name: String, endpoint: URL)
  case live(name: String, endpoint: URL, pushedAt: Date)
  case failed(message: String)

  var label: String {
    switch self {
    case .disabled:
      "未启用"
    case .discovering:
      "正在自动发现"
    case .ready(let name, _):
      "已发现 \(name)"
    case .pairing(_, _, let verificationCode, _):
      "等待批准 · 配对码 \(verificationCode)"
    case .pushing(let name, _):
      "正在推送到 \(name)"
    case .live(let name, _, _):
      "\(name) · 已连接"
    case .failed(let message):
      message
    }
  }

  var endpoint: URL? {
    switch self {
    case .ready(_, let endpoint), .pushing(_, let endpoint),
      .live(_, let endpoint, _), .pairing(_, let endpoint, _, _):
      endpoint
    case .disabled, .discovering, .failed:
      nil
    }
  }

  var isLive: Bool {
    if case .live = self { return true }
    return false
  }

  var pairingApprovalURL: URL? {
    guard case .pairing(_, _, _, let approvalURL) = self else { return nil }
    return approvalURL
  }
}

enum AmbientOpsPetChoice: String, CaseIterable, Identifiable {
  case localCodex = "local-codex"
  case none

  var id: Self { self }

  init(savedValue: String?) {
    self = savedValue == Self.none.rawValue ? .none : .localCodex
  }

  var label: String {
    switch self {
    case .localCodex:
      "本机 Codex 宠物"
    case .none:
      "不显示"
    }
  }
}

struct AmbientOpsKeychainRead {
  let status: OSStatus
  let data: Data?
}

protocol AmbientOpsKeychainBackend {
  func read(service: String, account: String) -> AmbientOpsKeychainRead
  func add(service: String, account: String, data: Data) -> OSStatus
}

struct SystemAmbientOpsKeychainBackend: AmbientOpsKeychainBackend {
  func read(service: String, account: String) -> AmbientOpsKeychainRead {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return AmbientOpsKeychainRead(status: status, data: result as? Data)
  }

  func add(service: String, account: String, data: Data) -> OSStatus {
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: data,
    ]
    return SecItemAdd(attributes as CFDictionary, nil)
  }
}

@MainActor
final class AmbientOpsKeychain {
  static let service = "cn.gaofeng.ambient-ops.agent-push"
  static let deviceKeyService = "cn.gaofeng.codex-tps.device-key"

  private let backend: any AmbientOpsKeychainBackend
  private var cachedTokens: [String: String] = [:]
  private var cachedDeviceKeys: [String: AmbientOpsDeviceKey] = [:]

  init(backend: any AmbientOpsKeychainBackend = SystemAmbientOpsKeychainBackend()) {
    self.backend = backend
  }

  func token(account: String = NSUserName()) throws -> String? {
    if let cached = cachedTokens[account] {
      return cached
    }
    guard let data = try data(service: Self.service, account: account) else { return nil }
    guard
      let token = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { throw AmbientOpsKeychainError.invalidToken }
    cachedTokens[account] = token
    return token
  }

  func deviceKey(account: String = NSUserName()) throws -> AmbientOpsDeviceKey {
    if let cached = cachedDeviceKeys[account] {
      return cached
    }
    if let saved = try data(service: Self.deviceKeyService, account: account) {
      do {
        let existing = try AmbientOpsDeviceKey(rawRepresentation: saved)
        cachedDeviceKeys[account] = existing
        return existing
      } catch {
        throw AmbientOpsKeychainError.invalidDeviceKey
      }
    }

    let created = AmbientOpsDeviceKey()
    let status = backend.add(
      service: Self.deviceKeyService,
      account: account,
      data: created.rawRepresentation
    )
    if status == errSecSuccess {
      cachedDeviceKeys[account] = created
      return created
    }
    if status == errSecDuplicateItem {
      guard let saved = try data(service: Self.deviceKeyService, account: account) else {
        throw AmbientOpsKeychainError.writeFailed(
          service: Self.deviceKeyService,
          status: status
        )
      }
      do {
        let existing = try AmbientOpsDeviceKey(rawRepresentation: saved)
        cachedDeviceKeys[account] = existing
        return existing
      } catch {
        throw AmbientOpsKeychainError.invalidDeviceKey
      }
    }
    throw AmbientOpsKeychainError.writeFailed(service: Self.deviceKeyService, status: status)
  }

  private func data(service: String, account: String) throws -> Data? {
    let result = backend.read(service: service, account: account)
    switch result.status {
    case errSecSuccess:
      guard let data = result.data else {
        throw AmbientOpsKeychainError.invalidReadResult(service: service)
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw AmbientOpsKeychainError.readFailed(service: service, status: result.status)
    }
  }
}

enum AmbientOpsKeychainError: LocalizedError, Equatable {
  case invalidToken
  case invalidDeviceKey
  case invalidReadResult(service: String)
  case readFailed(service: String, status: OSStatus)
  case writeFailed(service: String, status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidToken:
      return "Keychain 中的 \(OPLFleetAgentProtocol.gatewayProductName) 令牌无效"
    case .invalidDeviceKey:
      return "Keychain 中的设备配对密钥无效"
    case .invalidReadResult:
      return "Keychain 返回了无效的凭据数据"
    case .readFailed(_, let status):
      return "无法读取 Keychain 凭据（\(status)）；请解锁登录钥匙串后重试"
    case .writeFailed(_, let status):
      return "无法将设备配对密钥存入 Keychain（\(status)）"
    }
  }
}

enum AmbientOpsRetryBehavior: Equatable {
  case retryCurrentEndpoint
  case rediscover

  static func behavior(for error: Error, autoDiscover: Bool) -> Self {
    if error is AmbientOpsKeychainError || !autoDiscover {
      return .retryCurrentEndpoint
    }
    return .rediscover
  }
}

enum AmbientOpsRetryPolicy {
  private static let initialDelay: TimeInterval = 15
  private static let maximumDelay: TimeInterval = 300

  static func delay(forFailureCount failureCount: Int) -> TimeInterval {
    let exponent = min(max(failureCount - 1, 0), 5)
    return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
  }
}

extension AmbientOpsMachineIdentity {
  static func defaultLocalMachineID() -> String {
    let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    return
      hostName
      .split(separator: ".")
      .first
      .map(String.init)?
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9._-]"#, with: "-", options: .regularExpression)
      ?? "mac"
  }

  static func localMachine(machineID: String) throws -> AmbientOpsMachineIdentity {
    return try AmbientOpsMachineIdentity(
      machineID: machineID,
      machineName: Host.current().localizedName ?? machineID,
      platform: "macOS"
    )
  }
}
