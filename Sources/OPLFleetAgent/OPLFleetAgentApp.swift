import SwiftUI

@main
@MainActor
struct OPLFleetAgentApp: App {
  @NSApplicationDelegateAdaptor(OPLFleetAgentAppDelegate.self) private var appDelegate
  @StateObject private var store: MonitorStore

  init() {
    let store = MonitorStore()
    _store = StateObject(wrappedValue: store)
    appDelegate.configure(store: store)
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
  }
}
