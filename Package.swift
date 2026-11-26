// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TradingWorkspace",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "TradingWorkspace", targets: ["TradingWorkspace"]),
    .executable(name: "PortfolioPulseWidget", targets: ["PortfolioPulseWidget"]),
  ],
  dependencies: [
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
  ],
  targets: [
    .target(name: "PortfolioPulseSupport"),
    .executableTarget(
      name: "TradingWorkspace",
      dependencies: ["PortfolioPulseSupport", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
      exclude: ["Resources"]),
    .executableTarget(
      name: "PortfolioPulseWidget", dependencies: ["PortfolioPulseSupport"],
      swiftSettings: [.unsafeFlags(["-application-extension"])],
      // Match the entry point Xcode uses for a macOS app extension.
      linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
    .testTarget(name: "TradingWorkspaceTests", dependencies: ["TradingWorkspace", "PortfolioPulseSupport"]),
  ]
)
