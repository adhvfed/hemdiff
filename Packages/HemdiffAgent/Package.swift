// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "HemdiffAgent", platforms: [.macOS(.v14)],
  products: [.executable(name: "hemdiff", targets: ["hemdiff"])],
  dependencies: [
    .package(path: "../HemdiffCore"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.11.0"),
  ],
  targets: [
    .target(name: "HemdiffAgentKit", dependencies: ["HemdiffCore", .product(name: "MCP", package: "swift-sdk")]),
    .executableTarget(name: "hemdiff", dependencies: ["HemdiffAgentKit"]),
    .testTarget(name: "HemdiffAgentTests", dependencies: ["HemdiffAgentKit"]),
  ]
)
