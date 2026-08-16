import SwiftUI

@main
@MainActor
struct OPLFleetAgentApp: App {
  @NSApplicationDelegateAdaptor(OPLFleetAgentAppDelegate.self) private var appDelegate
  @StateObject private var store: MonitorStore
  @StateObject private var updateManager: UpdateManager

  init() {
    let store = MonitorStore()
    let updateManager = UpdateManager()
    _store = StateObject(wrappedValue: store)
    _updateManager = StateObject(wrappedValue: updateManager)
    appDelegate.configure(store: store, updateManager: updateManager)
    store.start()
    if !ProcessInfo.processInfo.arguments.contains("--preview-window") {
      updateManager.start()
    }
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
        "Codex token throughput, \(store.selectedWindow.rawValue), \(store.menuBarTitle)")
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
      .environmentObject(updateManager)
  }
}
