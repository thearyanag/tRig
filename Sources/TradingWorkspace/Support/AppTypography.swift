import AppKit
import CoreText
import OSLog
import SwiftUI

/// Allo is bundled and registered for this process, without installing system fonts.
@MainActor
enum AppTypography {
  private static let registration: Void = {
    let logger = Logger(subsystem: "com.aryan.TradingWorkspace", category: "Typography")
    for face in ["Allo-Regular", "Allo-Medium", "Allo-SemiBold", "Allo-Bold"] {
      guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(face).otf"),
        FileManager.default.fileExists(atPath: url.path)
      else {
        logger.error("Missing bundled font: \(face, privacy: .public)")
        continue
      }
      var error: Unmanaged<CFError>?
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
      if let error = error?.takeRetainedValue() {
        logger.error("Font registration: \(String(describing: error), privacy: .public)")
      }
    }
  }()

  static func registerFonts() { _ = registration }

  static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    registerFonts()
    let face: String
    switch weight {
    case .medium: face = "Allo-Medium"
    case .semibold: face = "Allo-SemiBold"
    case .bold: face = "Allo-Bold"
    default: face = "Allo-Regular"
    }
    return .custom(face, size: size)
  }

  private static func style(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> Font {
    font(size: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
  }

  static var body: Font { style(.body) }
  static var bodySemibold: Font { style(.body, weight: .semibold) }
  static var callout: Font { style(.callout) }
  static var calloutMedium: Font { style(.callout, weight: .medium) }
  static var caption: Font { style(.caption1) }
  static var headline: Font { style(.headline, weight: .semibold) }
  static var titleBold: Font { style(.title1, weight: .bold) }
  static var title2Semibold: Font { style(.title2, weight: .semibold) }
}
