import AppKit
import CodexTPSCore
import SwiftUI

struct MonitorPanel: View {
  @EnvironmentObject private var store: MonitorStore
  @EnvironmentObject private var updateManager: UpdateManager
  @State private var settingsExpanded = false

  private var metrics: WindowMetrics {
    store.selectedWindow.metrics(from: store.snapshot)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      throughput
      Divider()
      settings
      Divider()
      footer
    }
    .frame(width: 380)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(OPLFleetAgentProtocol.productName)
          .font(.headline)

        HStack(spacing: 6) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
          Text(statusText)
          Text("·")
          Text(store.snapshot.generatedAt, style: .time)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 4) {
        HeaderIconButton(
          systemName: "arrow.clockwise",
          help: "立即刷新",
          isDisabled: store.isRefreshing
        ) {
          Task { await store.refresh() }
        }

        HeaderIconButton(
          systemName: "arrow.down.circle",
          help: "检查更新",
          isDisabled: updateManager.isBusy
        ) {
          Task { await updateManager.checkForUpdates() }
        }

        HeaderIconButton(
          systemName: "folder",
          help: "打开 Codex 会话目录",
          action: store.openSessionsDirectory
        )
      }
    }
    .padding(16)
  }

  private var throughput: some View {
    VStack(alignment: .leading, spacing: 15) {
      Picker(
        "统计窗口",
        selection: Binding(
          get: { store.selectedWindow },
          set: { window in store.setMetricWindow(window) }
        )
      ) {
        ForEach(MetricWindow.allCases) { window in
          Text(window.rawValue).tag(window)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(RateFormatter.detailed(metrics.tokensPerSecond))
          .font(.system(size: 32, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .layoutPriority(1)
        Text("token/s")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        VStack(alignment: .trailing, spacing: 2) {
          Text(metrics.requestsPerMinute.formatted(.number.precision(.fractionLength(1))))
            .font(.headline.weight(.semibold))
            .monospacedDigit()
          Text("请求/分钟")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 0) {
        RateColumn(title: "输入", value: metrics.inputTokensPerSecond, color: .blue)
        RateColumn(title: "缓存", value: metrics.cachedInputTokensPerSecond, color: .teal)
        RateColumn(title: "输出", value: metrics.outputTokensPerSecond, color: .orange)
        RateColumn(title: "推理", value: metrics.reasoningTokensPerSecond, color: .purple)
      }

      HStack(spacing: 16) {
        Label("\(store.snapshot.activeSessions) 个活跃会话", systemImage: "rectangle.stack")
        Spacer()
        Text("缓存占比 \(metrics.cacheRatio.formatted(.percent.precision(.fractionLength(0))))")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(16)
  }

  private var footer: some View {
    VStack(spacing: 10) {
      updateStatus

      HStack {
        Picker(
          "自动刷新",
          selection: Binding(
            get: { store.refreshCadence },
            set: { cadence in store.setRefreshCadence(cadence) }
          )
        ) {
          ForEach(RefreshCadence.allCases) { cadence in
            Text(cadence.label).tag(cadence)
          }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()

        Spacer()

        Toggle(
          "登录时启动",
          isOn: Binding(
            get: { store.launchAtLoginEnabled },
            set: { enabled in store.setLaunchAtLogin(enabled) }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.small)

        Spacer()

        Button(action: store.quit) {
          Image(systemName: "power")
        }
        .buttonStyle(.borderless)
        .help("退出 OPL Fleet Agent")
      }

      if let settingsError = store.settingsError {
        Text(settingsError)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          settingsExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Label(OPLFleetAgentProtocol.gatewayShortName, systemImage: "display.2")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Circle()
            .fill(ambientStatusColor)
            .frame(width: 7, height: 7)
          Text(store.ambientConnection.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(OPLFleetAgentProtocol.gatewayShortName) 高级连接设置")
      .accessibilityValue(store.ambientConnection.label)
      .accessibilityHint(settingsExpanded ? "收起设置" : "展开设置")

      if settingsExpanded {
        ambientSettings
          .padding(.top, 12)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
  }

  private var ambientSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Toggle(
          "发送聚合指标",
          isOn: Binding(
            get: { store.ambientEnabled },
            set: { enabled in store.setAmbientEnabled(enabled) }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.small)

        Spacer()

        Toggle(
          "自动发现",
          isOn: Binding(
            get: { store.ambientAutoDiscover },
            set: { enabled in store.setAmbientAutoDiscover(enabled) }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!store.ambientEnabled)

        Button(action: store.rediscoverAmbientOps) {
          Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .buttonStyle(.borderless)
        .disabled(!store.ambientEnabled || !store.ambientAutoDiscover)
        .help("重新发现 \(OPLFleetAgentProtocol.gatewayProductName)")
      }

      if store.ambientEnabled && !store.ambientAutoDiscover {
        TextField(
          "http://opl-fleet-gateway.local:8787",
          text: Binding(
            get: { store.ambientManualURL },
            set: { value in store.setAmbientManualURL(value) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospaced())
      } else if let endpoint = store.ambientConnection.endpoint {
        Text(endpoint.absoluteString)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      if store.ambientConnection.pairingApprovalURL != nil {
        Button(action: store.openAmbientPairingApproval) {
          Label("打开配对批准页", systemImage: "checkmark.shield")
        }
        .controlSize(.small)
      }

      HStack {
        Label("宠物", systemImage: "bird")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Picker(
          "宠物",
          selection: Binding(
            get: { store.ambientPet },
            set: { pet in store.setAmbientPet(pet) }
          )
        ) {
          ForEach(AmbientOpsPetChoice.allCases) { pet in
            Text(pet.label).tag(pet)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
      }
      .disabled(!store.ambientEnabled)
    }
  }

  private var ambientStatusColor: Color {
    if store.ambientConnection.isLive { return .green }
    switch store.ambientConnection {
    case .failed:
      return .red
    case .disabled:
      return .secondary
    case .discovering, .ready, .pairing, .pushing:
      return .orange
    case .live:
      return .green
    }
  }

  @ViewBuilder
  private var updateStatus: some View {
    switch updateManager.state {
    case .idle:
      EmptyView()
    case .checking:
      updateStatusLabel("正在检查更新", systemImage: nil)
    case .upToDate:
      updateStatusLabel("已是最新版本", systemImage: "checkmark.circle")
    case .available(let release):
      HStack(spacing: 8) {
        Label("发现新版本 \(release.tagName)", systemImage: "arrow.down.circle.fill")
          .lineLimit(1)
        Spacer()
        Button("立即更新") {
          updateManager.installAvailableUpdate()
        }
        .controlSize(.small)
      }
      .font(.caption)
    case .installing:
      updateStatusLabel("正在安装，应用将重新启动", systemImage: nil)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func updateStatusLabel(_ text: String, systemImage: String?) -> some View {
    HStack(spacing: 7) {
      if let systemImage {
        Image(systemName: systemImage)
      } else {
        ProgressView()
          .controlSize(.small)
      }
      Text(text)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusText: String {
    if store.isRefreshing { return "读取中" }
    switch store.snapshot.status {
    case .ready:
      return store.snapshot.malformedRelevantLines == 0 ? "就绪" : "部分记录无法解析"
    case .sessionsDirectoryMissing:
      return "未找到会话目录"
    case .readFailed:
      return "读取失败"
    }
  }

  private var statusColor: Color {
    if store.isRefreshing { return .blue }
    switch store.snapshot.status {
    case .ready:
      return store.snapshot.malformedRelevantLines == 0 ? .green : .orange
    case .sessionsDirectoryMissing:
      return .orange
    case .readFailed:
      return .red
    }
  }
}

private struct RateColumn: View {
  let title: String
  let value: Double
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle()
          .fill(color)
          .frame(width: 5, height: 5)
        Text(title)
          .foregroundStyle(.secondary)
      }
      .font(.caption)

      Text(RateFormatter.compact(value))
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text("token/s")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct HeaderIconButton: View {
  let systemName: String
  let help: String
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(isDisabled)
    .help(help)
  }
}
