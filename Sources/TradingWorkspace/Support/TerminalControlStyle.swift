import SwiftUI

struct TerminalControlStyle: ButtonStyle {
  var fill: Color = TerminalStyle.field
  var foreground: Color = .primary
  var border: Color = TerminalStyle.border
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foreground)
      .background(fill, in: RoundedRectangle(cornerRadius: TerminalStyle.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(border))
      .frame(minWidth: 40, minHeight: 40)
      .contentShape(Rectangle())
      .brightness(configuration.isPressed ? 0.06 : 0)
      .opacity(isEnabled ? 1 : 0.38)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
