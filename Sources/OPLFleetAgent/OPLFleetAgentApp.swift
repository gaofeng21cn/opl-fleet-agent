import SwiftUI

@main
@MainActor
struct OPLFleetAgentApp: App {
  @NSApplicationDelegateAdaptor(OPLFleetAgentAppDelegate.self) private var appDelegate
  @StateObject private var store: MonitorStore
  @StateObject private var updater: AppUpdater

  init() {
    let store = MonitorStore()
    let updater = AppUpdater()
    _store = StateObject(wrappedValue: store)
    _updater = StateObject(wrappedValue: updater)
    appDelegate.configure(store: store, updater: updater)
    store.start()
  }

  var body: some Scene {
    MenuBarExtra {
      menuBarPanel
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "waveform.path.ecg")
        Text(store.menuBarTitle)
          .monospacedDigit()
      }
      .accessibilityLabel(
        "Token throughput, \(store.selectedWindow.rawValue), \(store.menuBarTitle)")
    }
    .menuBarExtraStyle(.window)
  }

  @ViewBuilder
  private var menuBarPanel: some View {
    if #available(macOS 15.0, *) {
      panelContent
        .containerBackground(.regularMaterial, for: .window)
    } else {
      panelContent
    }
  }

  private var panelContent: some View {
    MonitorPanel()
      .environmentObject(store)
      .environmentObject(updater)
  }
}
