import Foundation

#if os(macOS)
  import Darwin
#endif

/// Samples host-wide CPU utilization without reading or transmitting process or
/// conversation data. The first sample establishes a baseline; later samples
/// report the utilization between two reads.
public struct HostTelemetrySampler: Sendable {
  private var previousTotalTicks: UInt64?
  private var previousIdleTicks: UInt64?

  public init() {}

  public mutating func sampleCPUPercent() -> Double? {
    #if os(macOS)
      var load = host_cpu_load_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &load) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
        }
      }
      guard result == KERN_SUCCESS else { return nil }

      let user = UInt64(load.cpu_ticks.0)
      let system = UInt64(load.cpu_ticks.1)
      let idle = UInt64(load.cpu_ticks.2)
      let nice = UInt64(load.cpu_ticks.3)
      let total = user &+ system &+ nice &+ idle

      defer {
        previousTotalTicks = total
        previousIdleTicks = idle
      }
      guard let previousTotalTicks, let previousIdleTicks else { return nil }
      guard total >= previousTotalTicks, idle >= previousIdleTicks else { return nil }
      return Self.utilizationPercent(
        totalDelta: total - previousTotalTicks,
        idleDelta: idle - previousIdleTicks
      )
    #else
      return nil
    #endif
  }

  static func utilizationPercent(totalDelta: UInt64, idleDelta: UInt64) -> Double? {
    guard totalDelta > 0, idleDelta <= totalDelta else { return nil }
    let busy = Double(totalDelta - idleDelta) / Double(totalDelta) * 100
    return min(100, max(0, busy))
  }
}

public struct HostNetworkTelemetry: Codable, Equatable, Sendable {
  public let downloadMbps: Double
  public let uploadMbps: Double
  public let sampledAt: Date

  public init(downloadMbps: Double, uploadMbps: Double, sampledAt: Date) {
    self.downloadMbps = max(0, downloadMbps)
    self.uploadMbps = max(0, uploadMbps)
    self.sampledAt = sampledAt
  }
}

/// Samples aggregate physical-interface throughput. Tunnel and loopback
/// interfaces are excluded so a packet is not counted both before and after VPN
/// encapsulation.
public struct HostNetworkTelemetrySampler: Sendable {
  private var previousReceivedBytes: UInt64?
  private var previousSentBytes: UInt64?
  private var previousSampledAt: Date?

  public init() {}

  public mutating func sample(at now: Date = Date()) -> HostNetworkTelemetry? {
    #if os(macOS)
      guard let counters = Self.physicalInterfaceCounters() else { return nil }
      defer {
        previousReceivedBytes = counters.received
        previousSentBytes = counters.sent
        previousSampledAt = now
      }
      guard
        let previousReceivedBytes,
        let previousSentBytes,
        let previousSampledAt,
        counters.received >= previousReceivedBytes,
        counters.sent >= previousSentBytes
      else { return nil }
      let elapsed = now.timeIntervalSince(previousSampledAt)
      guard elapsed > 0 else { return nil }
      return Self.telemetry(
        receivedDelta: counters.received - previousReceivedBytes,
        sentDelta: counters.sent - previousSentBytes,
        elapsedSeconds: elapsed,
        sampledAt: now
      )
    #else
      return nil
    #endif
  }

  static func telemetry(
    receivedDelta: UInt64,
    sentDelta: UInt64,
    elapsedSeconds: TimeInterval,
    sampledAt: Date
  ) -> HostNetworkTelemetry? {
    guard elapsedSeconds > 0 else { return nil }
    let bitsPerMegabit = 1_000_000.0
    return HostNetworkTelemetry(
      downloadMbps: Double(receivedDelta) * 8 / elapsedSeconds / bitsPerMegabit,
      uploadMbps: Double(sentDelta) * 8 / elapsedSeconds / bitsPerMegabit,
      sampledAt: sampledAt
    )
  }

  #if os(macOS)
    private static func physicalInterfaceCounters() -> (received: UInt64, sent: UInt64)? {
      var firstAddress: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
      defer { freeifaddrs(firstAddress) }

      var received: UInt64 = 0
      var sent: UInt64 = 0
      var found = false
      var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
      while let address = current {
        defer { current = address.pointee.ifa_next }
        let interface = address.pointee
        guard let socketAddress = interface.ifa_addr,
          socketAddress.pointee.sa_family == UInt8(AF_LINK),
          interface.ifa_flags & UInt32(IFF_UP) != 0,
          interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
          let namePointer = interface.ifa_name
        else { continue }
        let name = String(cString: namePointer)
        guard name.hasPrefix("en"), let rawData = interface.ifa_data else { continue }
        let data = rawData.assumingMemoryBound(to: if_data.self).pointee
        received &+= UInt64(data.ifi_ibytes)
        sent &+= UInt64(data.ifi_obytes)
        found = true
      }
      return found ? (received, sent) : nil
    }
  #endif
}
