// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [.iOS(.v13), .macOS(.v12), .macCatalyst(.v17)],
    products: [
        .library(name: "Flux", targets: ["Flux"]),
        .library(name: "FluxTestStore", targets: ["FluxTestStore"]),
    ],
    targets: [
        .target(name: "Flux"),
        .target(
            name: "FluxTestStore",
            dependencies: ["Flux"]
        ),
        .testTarget(name: "FluxTests", dependencies: ["Flux"]),
    ]
)
