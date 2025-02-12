// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v13)],
    products: [
        .library(name: "Flux", targets: ["Flux"]),
    ],
    targets: [
        .target(name: "Flux"),
        .testTarget(name: "FluxTests", dependencies: ["Flux"]),
    ]
)
