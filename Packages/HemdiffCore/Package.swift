// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HemdiffCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "HemdiffCore", targets: ["HemdiffCore"])],
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")],
  targets: [
    .target(name: "HemdiffPOSIX"),
    .target(
      name: "HemdiffCore",
      dependencies: ["HemdiffPOSIX", .product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "HemdiffCoreTests", dependencies: ["HemdiffCore"]),
  ]
)
