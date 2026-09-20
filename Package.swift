// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Whoop5Protocol",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "Whoop5Protocol", targets: ["Whoop5Protocol"])
    ],
    targets: [
        .target(name: "Whoop5Protocol"),
        .testTarget(name: "Whoop5ProtocolTests", dependencies: ["Whoop5Protocol"])
    ]
)
