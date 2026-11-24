import SwiftUI

enum TerminalStyle {
  static let canvas = Color(red: 0.075, green: 0.098, blue: 0.118)
  static let panel = Color(red: 0.094, green: 0.122, blue: 0.145)
  static let field = Color(red: 0.063, green: 0.082, blue: 0.098)
  static let border = Color.white.opacity(0.08)
  static let accent = Color(red: 0.19, green: 0.36, blue: 1)
  static let buy = Color(red: 0.14, green: 0.83, blue: 0.62)
  static let sell = Color(red: 0.86, green: 0.18, blue: 0.26)
  static let controlRadius: CGFloat = 4

  static var quotePanel: Color {
    if #available(macOS 26, *) {
      return Color(red: 0.08, green: 0.105, blue: 0.155)
    }
    return panel
  }

  static var quoteFieldRadius: CGFloat {
    if #available(macOS 26, *) { return 8 }
    return controlRadius
  }
}
