import AppKit
import SwiftUI

/// AppKit's standard controls stay in the custom title strip when SwiftUI hides its toolbar.
struct WindowControlsView: NSViewRepresentable {
  func makeNSView(context: Context) -> ControlsView { ControlsView() }
  func updateNSView(_ view: ControlsView, context: Context) {}
  static func dismantleNSView(_ view: ControlsView, coordinator: ()) {
    view.restoreSystemControls()
  }

  final class ControlsView: NSView {
    private weak var attachedWindow: NSWindow?
    private let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, attachedWindow !== window else { return }
      restoreSystemControls()
      attachedWindow = window
      for view in subviews { view.removeFromSuperview() }
      for (index, kind) in kinds.enumerated() {
        guard
          let button = NSWindow.standardWindowButton(
            kind, for: [.titled, .closable, .miniaturizable, .resizable])
        else { continue }
        window.standardWindowButton(kind)?.isHidden = true
        button.target = self
        switch kind {
        case .closeButton:
          button.action = #selector(closeWindow)
          button.setAccessibilityLabel("Close window")
        case .miniaturizeButton:
          button.action = #selector(minimizeWindow)
          button.setAccessibilityLabel("Minimize window")
        default:
          button.action = #selector(zoomWindow)
          button.setAccessibilityLabel("Full screen or zoom window")
        }
        button.setFrameOrigin(
          NSPoint(x: 16 + CGFloat(index) * 21, y: (54 - button.frame.height) / 2))
        addSubview(button)
      }
    }

    func restoreSystemControls() {
      for kind in kinds { attachedWindow?.standardWindowButton(kind)?.isHidden = false }
      attachedWindow = nil
    }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.performMiniaturize(nil) }
    @objc private func zoomWindow() {
      if NSEvent.modifierFlags.contains(.option) {
        window?.performZoom(nil)
      } else {
        window?.toggleFullScreen(nil)
      }
    }
  }
}
