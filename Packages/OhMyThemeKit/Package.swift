// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OhMyThemeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "OhMyThemeKit",
            targets: ["ThemeModel", "ThemeCompiler", "PlatformClients", "Persistence", "ThemeEngine"]
        ),
        .executable(name: "ThemeTool", targets: ["ThemeTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
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
        .target(
            name: "PlatformClients",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ThemeEngine",
            dependencies: ["ThemeModel", "PlatformClients", "Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Persistence",
            dependencies: [
                "ThemeModel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
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
        .testTarget(
            name: "PlatformClientsTests",
            dependencies: ["PlatformClients"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThemeEngineTests",
            dependencies: ["ThemeEngine", "ThemeModel", "PlatformClients", "Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "ThemeModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
