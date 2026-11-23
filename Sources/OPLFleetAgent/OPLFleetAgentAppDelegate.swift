import AppKit
import OPLFleetAgentCore
import SwiftUI

@MainActor
final class OPLFleetAgentAppDelegate: NSObject, NSApplicationDelegate {
  private var store: MonitorStore?
  private var updater: AppUpdater?
  private var previewWindow: NSWindow?

  func configure(store: MonitorStore, updater: AppUpdater) {
    self.store = store
    self.updater = updater
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard ProcessInfo.processInfo.arguments.contains("--preview-window"),
      let store,
      let updater
    else { return }

    let panel = MonitorPanel()
      .environmentObject(store)
      .environmentObject(updater)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = OPLFleetAgentProtocol.productName
    window.contentView = NSHostingView(rootView: panel)
    window.center()
    window.makeKeyAndOrderFront(nil)

    previewWindow = window
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
