// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TaxCollector",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TaxCore"),
        .executableTarget(name: "TaxCollector", dependencies: ["TaxCore"]),
        .executableTarget(name: "taxcore-check", dependencies: ["TaxCore"], path: "Sources/TaxCoreCheck"),
    ]
)
