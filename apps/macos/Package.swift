// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AccountWebTest", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "AccountWebTest"),
    .testTarget(name: "AccountWebTestTests", dependencies: ["AccountWebTest"])
])
