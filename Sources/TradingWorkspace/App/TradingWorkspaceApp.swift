import AppKit
import SwiftUI

@main
struct TradingWorkspaceApp: App {
  @NSApplicationDelegateAdaptor(WorkspaceAppDelegate.self) private var delegate
  @State private var connections: ConnectionStore
  @State private var portfolio: PortfolioStore
  init() {
    AppTypography.registerFonts()
    let connections = ConnectionStore()
    let portfolio = PortfolioStore()
    portfolio.bind(connections)
    _connections = State(initialValue: connections)
    _portfolio = State(initialValue: portfolio)
  }
  var body: some Scene {
    WindowGroup("Trading Workspace", id: "workspace") {
      WorkspaceView()
        .environment(connections)
        .environment(portfolio)
        .font(AppTypography.body)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1400, height: 900)
    .commands {
      WorkspaceCommands()
    }

    Window("Component Gallery", id: "components") {
      ComponentGalleryView()
        .font(AppTypography.body)
    }
    .defaultSize(width: 760, height: 860)

    Settings {
      SettingsView().environment(connections)
    }
  }
}

private final class WorkspaceAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationWillTerminate(_ notification: Notification) { ChartBackend.shared.stop() }
}

private struct WorkspaceCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.openAssetSearch) private var search
  @FocusedValue(\.workspaceStore) private var workspace

  var body: some Commands {
    CommandMenu("Workspace") {
      Button("Search Assets…") { search?() }
        .keyboardShortcut("k").disabled(search == nil)
      Divider()
      Button("Next Watched Asset") { workspace?.step(1) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(workspace?.watchlist.isEmpty != false)
      Button("Previous Watched Asset") { workspace?.step(-1) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(workspace?.watchlist.isEmpty != false)
      Divider()
      Button("Component Gallery") {
        openWindow(id: "components")
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
    }
  }
}
