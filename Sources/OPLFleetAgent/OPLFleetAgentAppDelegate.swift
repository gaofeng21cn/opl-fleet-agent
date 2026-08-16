import AppKit
import OPLFleetAgentCore
import SwiftUI

@MainActor
final class OPLFleetAgentAppDelegate: NSObject, NSApplicationDelegate {
  private var store: MonitorStore?
  private var updateManager: UpdateManager?
  private var previewWindow: NSWindow?

  func configure(store: MonitorStore, updateManager: UpdateManager) {
    self.store = store
    self.updateManager = updateManager
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard ProcessInfo.processInfo.arguments.contains("--preview-window"),
      let store,
      let updateManager
    else { return }

    let panel = MonitorPanel()
      .environmentObject(store)
      .environmentObject(updateManager)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 430),
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
