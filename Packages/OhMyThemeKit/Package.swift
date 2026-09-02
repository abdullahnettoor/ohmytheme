// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OhMyThemeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OhMyThemeKit", targets: ["ThemeModel"])
    ],
    targets: [
        .target(
            name: "ThemeModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThemeModelTests",
            dependencies: ["ThemeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
