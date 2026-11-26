import CryptoKit
import Foundation

#if os(macOS)
  import IOKit
#endif

public struct AmbientOpsMachineIdentityResolution: Equatable, Sendable {
  public let machineID: String
  public let hardwareFingerprint: String?
  public let migratedFromAnotherHost: Bool
  public let shouldPersist: Bool

  public init(
    machineID: String,
    hardwareFingerprint: String?,
    migratedFromAnotherHost: Bool,
    shouldPersist: Bool
  ) {
    self.machineID = machineID
    self.hardwareFingerprint = hardwareFingerprint
    self.migratedFromAnotherHost = migratedFromAnotherHost
    self.shouldPersist = shouldPersist
  }
}

extension AmbientOpsMachineIdentity {
  public static let hardwareFingerprintDefaultsKey = "ambientOpsMachineHardwareFingerprint"

  public static func isValidMachineID(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) != nil
  }

  public static func currentHardwareFingerprint() -> String? {
    #if os(macOS)
      let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
      )
      guard service != 0 else { return nil }
      defer { IOObjectRelease(service) }
      guard
        let rawUUID = IORegistryEntryCreateCFProperty(
          service,
          kIOPlatformUUIDKey as CFString,
          kCFAllocatorDefault,
          0
        )?.takeRetainedValue() as? String
      else {
        return nil
      }
      return hardwareFingerprint(fromPlatformUUID: rawUUID)
    #else
      return nil
    #endif
  }

  public static func hardwareFingerprint(fromPlatformUUID uuid: String) -> String? {
    let normalized = uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data("opl-fleet-agent.hardware.v1:\(normalized)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  public static func disambiguatedMachineID(
    base: String,
    hardwareFingerprint: String?,
    avoiding excludedIDs: Set<String> = []
  ) -> String {
    let normalizedBase = normalizedBaseID(base)
    let fingerprintSuffixSource = (hardwareFingerprint ?? "")
      .lowercased()
      .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }

    for suffixLength in [6, 8, 12] where fingerprintSuffixSource.count >= suffixLength {
      let suffix = String(fingerprintSuffixSource.prefix(suffixLength))
      let candidate = suffixedMachineID(base: normalizedBase, suffix: suffix)
      if isValidMachineID(candidate), !excludedIDs.contains(candidate) {
        return candidate
      }
    }

    for index in 2...999 {
      let candidate = suffixedMachineID(base: normalizedBase, suffix: String(index))
      if isValidMachineID(candidate), !excludedIDs.contains(candidate) {
        return candidate
      }
    }

    while true {
      let randomSuffix = String(
        format: "%06x",
        UInt32.random(in: 0..<0x0100_0000)
      )
      let candidate = suffixedMachineID(base: normalizedBase, suffix: randomSuffix)
      if isValidMachineID(candidate), !excludedIDs.contains(candidate) {
        return candidate
      }
    }
  }

  public static func resolvePersistedMachineID(
    savedMachineID: String?,
    savedHardwareFingerprint: String?,
    currentHardwareFingerprint: String?,
    hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  ) -> AmbientOpsMachineIdentityResolution {
    let savedID = nonEmptyTrimmed(savedMachineID)
    let savedFP = nonEmptyTrimmed(savedHardwareFingerprint)
    let currentFP = nonEmptyTrimmed(currentHardwareFingerprint)

    if let savedFP, let currentFP, savedFP != currentFP {
      let candidate = defaultLocalMachineID(hostName: hostName)
      let excluded: Set<String> = savedID.map { [$0] } ?? []
      let resolvedID =
        if isValidMachineID(candidate), !excluded.contains(candidate) {
          candidate
        } else {
          disambiguatedMachineID(
            base: candidate,
            hardwareFingerprint: currentFP,
            avoiding: excluded
          )
        }
      return AmbientOpsMachineIdentityResolution(
        machineID: resolvedID,
        hardwareFingerprint: currentFP,
        migratedFromAnotherHost: true,
        shouldPersist: true
      )
    }

    if let savedID {
      return AmbientOpsMachineIdentityResolution(
        machineID: savedID,
        hardwareFingerprint: currentFP ?? savedFP,
        migratedFromAnotherHost: false,
        shouldPersist: currentFP != nil && savedFP != currentFP
      )
    }

    return AmbientOpsMachineIdentityResolution(
      machineID: defaultLocalMachineID(hostName: hostName),
      hardwareFingerprint: currentFP,
      migratedFromAnotherHost: false,
      shouldPersist: true
    )
  }

  private static func normalizedBaseID(_ raw: String) -> String {
    let sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9._-]"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !sanitized.isEmpty, isValidMachineID(String(sanitized.prefix(80))) else {
      return "mac"
    }
    return String(sanitized.prefix(80))
  }

  private static func suffixedMachineID(base: String, suffix: String) -> String {
    let maxBaseLength = max(1, 80 - 1 - suffix.count)
    var prefix = String(base.prefix(maxBaseLength)).trimmingCharacters(
      in: CharacterSet(charactersIn: "-"))
    if prefix.isEmpty {
      prefix = String("mac".prefix(maxBaseLength))
    }
    return "\(prefix)-\(suffix)"
  }

  private static func nonEmptyTrimmed(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
