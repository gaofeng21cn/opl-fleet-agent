import Foundation

/// Public compatibility metadata for the OPL Fleet Agent envelope.
///
/// This is deliberately limited to product identity and capabilities. The
/// private Instance remains the authority for admission, leases, and dispatch.
public enum OPLFleetAgentProtocol {
  public static let schema = "opl_fleet_agent_telemetry.v1"
  public static let productName = "OPL Fleet Agent"
  public static let gatewayProductName = "OPL Fleet Gateway"
  public static let gatewayShortName = "Fleet Gateway"
  public static let agentVersion = "0.2.38"
  public static let modes = ["local", "direct", "fleet"]
  public static let capabilities = [
    "node_local_observation",
    "node_local_doctor",
    "node_local_execution_constraints",
    "sanitized_execution_receipts",
    "local_codex_telemetry",
    "host_dashboard",
  ]
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
