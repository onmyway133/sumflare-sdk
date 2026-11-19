// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sumflare",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "Sumflare", targets: ["Sumflare"]),
    ],
    targets: [
        .target(name: "Sumflare"),
    ]
)
