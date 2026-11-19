import AppKit
import SwiftUI

/// Only the custom title strip bridges to AppKit; SwiftUI owns all controls and layout.
struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {}

  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 {
        window?.performZoom(nil)
      } else {
        window?.performDrag(with: event)
      }
    }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.titleVisibility = .hidden
      window?.titlebarAppearsTransparent = true
    }
  }
}
