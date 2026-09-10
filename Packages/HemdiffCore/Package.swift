// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HemdiffCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HemdiffCore", targets: ["HemdiffCore"])],
    targets: [
        .target(name: "HemdiffCore"),
        .testTarget(name: "HemdiffCoreTests", dependencies: ["HemdiffCore"])
    ]
)
