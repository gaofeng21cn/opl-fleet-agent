import Foundation

/// Public compatibility metadata for the OPL Fleet Agent envelope.
///
/// This is deliberately limited to product identity and capabilities. The
/// private Instance remains the authority for admission, leases, and dispatch.
public enum OPLFleetAgentProtocol {
  public static let schema = "opl_fleet_agent_telemetry.v1"
  public static let bundleIdentifier = "io.github.gaofeng21cn.opl-fleet-agent"
  public static let productName = "OPL Fleet Agent"
  public static let gatewayProductName = "OPL Fleet Gateway"
  public static let gatewayShortName = "Fleet Gateway"
  public static let defaultAgentVersion = "0.2.54"
  public static let agentVersion = resolveAgentVersion()
  public static let modes = ["local", "direct", "fleet"]
  public static let capabilities = [
    "node_local_observation",
    "node_local_doctor",
    "local_codex_telemetry",
    "host_dashboard",
  ]

  public static func resolveAgentVersion(
    bundleInfo: [String: Any]? = Bundle.main.infoDictionary,
    executableURL: URL? = Bundle.main.executableURL,
    fallback: String = defaultAgentVersion
  ) -> String {
    if let version = shortVersion(from: bundleInfo) {
      return version
    }
    if let executableURL {
      let siblingInfoPlistURL = executableURL
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
      if let data = try? Data(contentsOf: siblingInfoPlistURL),
         let plist = try? PropertyListSerialization.propertyList(
           from: data,
           options: [],
           format: nil
         ) as? [String: Any],
         let version = shortVersion(from: plist)
      {
        return version
      }
    }
    return fallback
  }

  private static func shortVersion(from info: [String: Any]?) -> String? {
    guard let info,
          let identifier = info["CFBundleIdentifier"] as? String,
          identifier == bundleIdentifier,
          let raw = info["CFBundleShortVersionString"] as? String
    else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct OPLFleetAgentEnvelope: Codable, Equatable, Sendable {
  public let schema: String
  public let product: String
  public let stableNodeID: String
  public let agentVersion: String
  public let modes: [String]
  public let capabilities: [String]
  public let authority: String

  public init(
    stableNodeID: String,
    agentVersion: String = OPLFleetAgentProtocol.agentVersion
  ) {
    schema = OPLFleetAgentProtocol.schema
    product = OPLFleetAgentProtocol.productName
    self.stableNodeID = stableNodeID
    self.agentVersion = agentVersion
    modes = OPLFleetAgentProtocol.modes
    capabilities = OPLFleetAgentProtocol.capabilities
    authority = "node_agent"
  }
}
