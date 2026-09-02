// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OhMyThemeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OhMyThemeKit", targets: ["ThemeModel", "ThemeCompiler"]),
        .executable(name: "ThemeTool", targets: ["ThemeTool"]),
    ],
    targets: [
        .target(
            name: "ThemeModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ThemeCompiler",
            dependencies: ["ThemeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ThemeTool",
            dependencies: ["ThemeCompiler"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThemeModelTests",
            dependencies: ["ThemeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThemeCompilerTests",
            dependencies: ["ThemeCompiler", "ThemeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
