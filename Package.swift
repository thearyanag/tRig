// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TradingWorkspace",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "TradingWorkspace", targets: ["TradingWorkspace"])],
  targets: [
    .executableTarget(name: "TradingWorkspace", exclude: ["Resources"]),
    .testTarget(name: "TradingWorkspaceTests", dependencies: ["TradingWorkspace"]),
  ]
)
