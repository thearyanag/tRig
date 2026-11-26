import SwiftUI

private struct SearchActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct SettingsActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct WorkspaceStoreKey: FocusedValueKey { typealias Value = WorkspaceStore }
extension FocusedValues {
  var openAssetSearch: (() -> Void)? {
    get { self[SearchActionKey.self] }
    set { self[SearchActionKey.self] = newValue }
  }
  var openWorkspaceSettings: (() -> Void)? {
    get { self[SettingsActionKey.self] }
    set { self[SettingsActionKey.self] = newValue }
  }
  var workspaceStore: WorkspaceStore? {
    get { self[WorkspaceStoreKey.self] }
    set { self[WorkspaceStoreKey.self] = newValue }
  }
}

extension EnvironmentValues {
  @Entry var openWorkspaceSettings: @MainActor (WorkspaceSettingsSection?) -> Void = { _ in }
}
