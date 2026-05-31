// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "windowless-reaper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "wreaper", targets: ["wreaper"]),
        .library(name: "WindowlessReaperCore", targets: ["WindowlessReaperCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "WindowlessReaperCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "wreaper",
            dependencies: [
                "WindowlessReaperCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "WindowlessReaperCoreTests",
            dependencies: ["WindowlessReaperCore", "wreaper"],
            resources: [.copy("__Snapshots__")],
            swiftSettings: strictSettings
        ),
    ]
)
