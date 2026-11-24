// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClaudeDockCore", targets: ["ClaudeDockCore"]),
        .executable(name: "claudedock", targets: ["ClaudeDockCLI"]),
        .executable(name: "ClaudeDockApp", targets: ["ClaudeDockApp"]),
    ],
    targets: [
        .target(
            name: "ClaudeDockCore",
            path: "Sources/ClaudeDockCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ClaudeDockCLI",
            dependencies: ["ClaudeDockCore"],
            path: "Sources/ClaudeDockCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ClaudeDockApp",
            dependencies: ["ClaudeDockCore"],
            path: "Sources/ClaudeDockApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "ClaudeDockTests",
            dependencies: ["ClaudeDockCore"],
            path: "Tests/ClaudeDockTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
