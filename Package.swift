// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiteLens",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "BiteLensCore", targets: ["BiteLensCore"])],
    targets: [
        .target(name: "BiteLensCore"),
        .testTarget(name: "BiteLensCoreTests", dependencies: ["BiteLensCore"])
    ]
)
