import Foundation
import Network
import OPLFleetAgentCore

final class AmbientOpsDirectServer: @unchecked Sendable {
  private let observationStore: AmbientOpsMachineObservationStore
  private let identity: AmbientOpsMachineIdentity
  private let serverVersion: String
  private let queue = DispatchQueue(label: "io.github.gaofeng21cn.opl-fleet-agent.direct")
  private var listener: NWListener?
  private var service: NetService?
  private var networkTelemetryTask: Task<Void, Never>?

  init(
    observationStore: AmbientOpsMachineObservationStore,
    identity: AmbientOpsMachineIdentity,
    serverVersion: String
  ) {
    self.observationStore = observationStore
    self.identity = identity
    self.serverVersion = serverVersion
  }

  func start() {
    guard listener == nil else { return }
    do {
      let listener = try NWListener(using: .tcp, on: .any)
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else {
          connection.cancel()
          return
        }
        AmbientOpsDirectHTTPConnection(
          connection: connection,
          observationStore: observationStore,
          serverVersion: serverVersion,
          queue: queue
        ).start()
      }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = listener.port else { return }
          DispatchQueue.main.async { [weak self] in
            self?.publishService(port: port)
          }
        case .failed:
          self.stop()
        default:
          break
        }
      }
      self.listener = listener
      listener.start(queue: queue)
      networkTelemetryTask = Task.detached(priority: .utility) { [observationStore] in
        var sampler = HostNetworkTelemetrySampler()
        _ = sampler.sample()
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled else { return }
          if let telemetry = sampler.sample() {
            await observationStore.updateNetwork(telemetry)
          }
        }
      }
    } catch {
      listener = nil
    }
  }

  func stop() {
    service?.stop()
    service = nil
    listener?.cancel()
    listener = nil
    networkTelemetryTask?.cancel()
    networkTelemetryTask = nil
  }

  private func publishService(port: NWEndpoint.Port) {
    service?.stop()
    let service = NetService(
      domain: "local.",
      type: "_opl-fleet-agent._tcp.",
      name: String(identity.machineName.prefix(63)),
      port: Int32(port.rawValue)
    )
    let txt = [
      "id": Data("opl-fleet-agent-\(identity.machineID)".utf8),
      "name": Data(identity.machineName.utf8),
      "api": Data("/api/v1/status".utf8),
      "protocol": Data("1".utf8),
      "kind": Data("opl-fleet-agent".utf8),
      "scope": Data("machine".utf8),
      "version": Data(serverVersion.utf8),
    ]
    service.setTXTRecord(NetService.data(fromTXTRecord: txt))
    service.publish()
    self.service = service
  }
}

private final class AmbientOpsDirectHTTPConnection: @unchecked Sendable {
  private static let maximumHeaderBytes = 16 * 1_024

  private let connection: NWConnection
  private let observationStore: AmbientOpsMachineObservationStore
  private let serverVersion: String
  private let queue: DispatchQueue

  init(
    connection: NWConnection,
    observationStore: AmbientOpsMachineObservationStore,
    serverVersion: String,
    queue: DispatchQueue
  ) {
    self.connection = connection
    self.observationStore = observationStore
    self.serverVersion = serverVersion
    self.queue = queue
  }

  func start() {
    connection.start(queue: queue)
    receive(Data())
  }

  private func receive(_ accumulated: Data) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 4 * 1_024
    ) { [self] data, _, isComplete, error in
      var request = accumulated
      if let data { request.append(data) }
      if request.count > Self.maximumHeaderBytes {
        send(status: 431, reason: "Request Header Fields Too Large", body: Data())
        return
      }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        handle(request)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        receive(request)
      }
    }
  }

  private func handle(_ request: Data) {
    guard
      let requestText = String(data: request, encoding: .utf8),
      let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first
    else {
      send(status: 400, reason: "Bad Request", body: Data())
      return
    }
    let components = requestLine.split(separator: " ")
    guard components.count == 3 else {
      send(status: 400, reason: "Bad Request", body: Data())
      return
    }
    let method = String(components[0])
    let path =
      String(components[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    guard method == "GET" || method == "HEAD" else {
      send(
        status: 405,
        reason: "Method Not Allowed",
        body: Data(),
        extraHeaders: ["Allow": "GET, HEAD"]
      )
      return
    }
    let headOnly = method == "HEAD"

    Task {
      let observation = await observationStore.current()
      let networkTelemetry = await observationStore.currentNetwork()
      switch path {
      case "/healthz":
        let body = Data(#"{"ok":true,"provider":"opl-fleet-agent","scope":"machine"}"#.utf8)
        send(
          status: 200,
          reason: "OK",
          body: body,
          contentType: "application/json; charset=utf-8",
          headOnly: headOnly
        )
      case "/api/v1/status":
        guard let observation else {
          send(
            status: 503,
            reason: "Service Unavailable",
            body: Data(#"{"error":"Metrics are not ready"}"#.utf8),
            contentType: "application/json; charset=utf-8",
            headOnly: headOnly
          )
          return
        }
        do {
          let status = AmbientOpsDirectStatusBuilder.build(
            observation: observation,
            serverVersion: serverVersion,
            networkTelemetry: networkTelemetry
          )
          let body = try AmbientOpsDirectStatusBuilder.encoder().encode(status)
          send(
            status: 200,
            reason: "OK",
            body: body,
            contentType: "application/json; charset=utf-8",
            headOnly: headOnly
          )
        } catch {
          send(status: 500, reason: "Internal Server Error", body: Data(), headOnly: headOnly)
        }
      default:
        let prefix = "/api/v1/pets/"
        guard
          path.hasPrefix(prefix),
          let observation,
          let asset = observation.petAsset,
          String(path.dropFirst(prefix.count)) == asset.definition.assetHash
        else {
          send(status: 404, reason: "Not Found", body: Data(), headOnly: headOnly)
          return
        }
        send(
          status: 200,
          reason: "OK",
          body: asset.data,
          contentType: "image/webp",
          headOnly: headOnly,
          extraHeaders: ["Cache-Control": "public, max-age=31536000, immutable"]
        )
      }
    }
  }

  private func send(
    status: Int,
    reason: String,
    body: Data,
    contentType: String = "text/plain; charset=utf-8",
    headOnly: Bool = false,
    extraHeaders: [String: String] = [:]
  ) {
    var headers = [
      "HTTP/1.1 \(status) \(reason)",
      "Content-Type: \(contentType)",
      "Content-Length: \(body.count)",
      "Connection: close",
      "Cache-Control: no-store",
      "X-Content-Type-Options: nosniff",
    ]
    headers.append(contentsOf: extraHeaders.map { "\($0.key): \($0.value)" })
    let header = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    let payload = headOnly ? header : header + body
    connection.send(
      content: payload,
      completion: .contentProcessed { [connection] _ in
        connection.cancel()
      })
  }
}
