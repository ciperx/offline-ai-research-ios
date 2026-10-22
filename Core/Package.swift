// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OfflineResearchCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "OfflineResearchCore", targets: ["OfflineResearchCore"])
    ],
    targets: [
        .target(
            name: "OfflineResearchCore",
            path: "Sources/OfflineResearchCore"
        ),
        .testTarget(
            name: "OfflineResearchCoreTests",
            dependencies: ["OfflineResearchCore"],
            path: "Tests/OfflineResearchCoreTests"
        )
    ]
)
