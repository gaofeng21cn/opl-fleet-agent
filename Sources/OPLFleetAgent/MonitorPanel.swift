import AppKit
import OPLFleetAgentCore
import SwiftUI

struct MonitorPanel: View {
  @EnvironmentObject private var store: MonitorStore
  @EnvironmentObject private var updater: AppUpdater
  @State private var sourcesExpanded = false
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
      sourcesSection
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

        Menu {
          Button("打开 Codex 会话目录", action: store.openSessionsDirectory)
          Button("打开 Antigravity 会话目录", action: store.openAntigravityDirectory)
        } label: {
          Image(systemName: "folder")
            .font(.system(size: 14, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("打开会话目录")
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

  private var sourcesSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          sourcesExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Label("数据源", systemImage: "square.stack.3d.up")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text(sourcesSummaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(sourcesExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("数据源明细与开关")
      .accessibilityValue(sourcesSummaryText)
      .accessibilityHint(sourcesExpanded ? "收起数据源" : "展开数据源")

      if sourcesExpanded {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(UsageSourceKind.allCases) { source in
            sourceRow(for: source)
          }
        }
        .padding(.top, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
  }

  private func sourceRow(for source: UsageSourceKind) -> some View {
    let breakdown = store.breakdown(for: source)
    let enabled = store.isSourceEnabled(source)
    let status = breakdown?.snapshot.status ?? .ready
    let sourceMetrics = breakdown.map { store.selectedWindow.metrics(from: $0.snapshot) }
    let activeSessions = breakdown?.snapshot.activeSessions ?? 0

    return HStack(spacing: 10) {
      Circle()
        .fill(sourceStatusColor(enabled: enabled, status: status))
        .frame(width: 7, height: 7)

      VStack(alignment: .leading, spacing: 2) {
        Text(source.displayName)
          .font(.subheadline.weight(.medium))
        Text(
          sourceStatusLabel(
            enabled: enabled,
            status: status,
            activeSessions: activeSessions
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Text(sourceRateText(enabled: enabled, status: status, metrics: sourceMetrics))
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(enabled && status == .ready ? .primary : .secondary)

      Toggle(
        source.displayName,
        isOn: Binding(
          get: { store.isSourceEnabled(source) },
          set: { isOn in store.setSourceEnabled(isOn, for: source) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
    }
  }

  private var footer: some View {
    VStack(spacing: 10) {
      if let updateVersion = updater.availableUpdateDisplayLabel {
        HStack(spacing: 8) {
          Label("发现新版本 \(updateVersion)", systemImage: "arrow.down.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
          Spacer()
          Button("立即更新", action: updater.checkForUpdates)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
      }

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

      HStack(spacing: 8) {
        Text(appVersionLabel)
          .monospacedDigit()
          .foregroundStyle(.tertiary)

        Spacer()

        Button(action: updater.checkForUpdates) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle")
              .font(.system(size: 11, weight: .medium))
            Text(updater.availableUpdateDisplayLabel == nil ? "检查更新" : "查看更新")
          }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(updater.canCheckForUpdates ? .secondary : .tertiary)
        .disabled(!updater.canCheckForUpdates)
        .help(updater.isConfigured ? "检查应用更新" : "仅在打包安装后的应用内可用")
      }
      .font(.caption2)
      .frame(maxWidth: .infinity, alignment: .leading)
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
          "192.168.50.20 或 opl-fleet-gateway.local",
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

  private var appVersionLabel: String {
    guard
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
      !version.isEmpty
    else {
      return "dev"
    }
    return "v\(version)"
  }

  private var statusText: String {
    if store.isRefreshing { return "读取中" }
    guard store.codexEnabled || store.antigravityEnabled else { return "未启用数据源" }
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
    guard store.codexEnabled || store.antigravityEnabled else { return .secondary }
    switch store.snapshot.status {
    case .ready:
      return store.snapshot.malformedRelevantLines == 0 ? .green : .orange
    case .sessionsDirectoryMissing:
      return .orange
    case .readFailed:
      return .red
    }
  }

  private var sourcesSummaryText: String {
    let enabledSources = UsageSourceKind.allCases.filter { store.isSourceEnabled($0) }
    guard !enabledSources.isEmpty else { return "已全部关闭" }
    if enabledSources.count == 1, let only = enabledSources.first {
      let breakdown = store.breakdown(for: only)
      let status = breakdown?.snapshot.status ?? .ready
      guard status == .ready, let snapshot = breakdown?.snapshot else {
        return "仅 \(only.displayName)"
      }
      let rate = RateFormatter.compact(
        store.selectedWindow.metrics(from: snapshot).tokensPerSecond
      )
      return "仅 \(only.displayName) · \(rate) t/s"
    }
    return enabledSources.map { source in
      let breakdown = store.breakdown(for: source)
      let status = breakdown?.snapshot.status ?? .ready
      guard status == .ready, let snapshot = breakdown?.snapshot else {
        return "\(source.displayName) --"
      }
      let rate = RateFormatter.compact(
        store.selectedWindow.metrics(from: snapshot).tokensPerSecond
      )
      return "\(source.displayName) \(rate)"
    }.joined(separator: " · ")
  }

  private func sourceStatusLabel(
    enabled: Bool,
    status: CollectionStatus,
    activeSessions: Int
  ) -> String {
    guard enabled else { return "已关闭" }
    switch status {
    case .ready:
      return "\(activeSessions) 活跃"
    case .sessionsDirectoryMissing:
      return "未找到目录"
    case .readFailed:
      return "读取失败"
    }
  }

  private func sourceStatusColor(enabled: Bool, status: CollectionStatus) -> Color {
    guard enabled else { return .secondary }
    switch status {
    case .ready:
      return .green
    case .sessionsDirectoryMissing:
      return .orange
    case .readFailed:
      return .red
    }
  }

  private func sourceRateText(
    enabled: Bool,
    status: CollectionStatus,
    metrics: WindowMetrics?
  ) -> String {
    guard enabled, status == .ready, let metrics else { return "-- t/s" }
    return "\(RateFormatter.compact(metrics.tokensPerSecond)) t/s"
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
