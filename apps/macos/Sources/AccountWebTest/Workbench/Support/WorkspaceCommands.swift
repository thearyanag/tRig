import SwiftUI

struct WorkspaceCommands: Commands {
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
