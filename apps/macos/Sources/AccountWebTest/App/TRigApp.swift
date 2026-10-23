import AppKit
import SwiftUI

@main
struct TRigApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var chatAccount = ChatGPTAccount()
  var body: some Scene {
    WindowGroup("tRig") {
      ContentView(chatAccount: chatAccount).frame(minWidth: 1060, minHeight: 720)
    }.defaultSize(width: 1440, height: 900)
      .commands { WorkspaceCommands() }
    Window("Component Gallery", id: "components") {
      ComponentGalleryView()
    }.defaultSize(width: 760, height: 860)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationWillTerminate(_ notification: Notification) { ChartBackend.shared.stop() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
