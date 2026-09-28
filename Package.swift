// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mail",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MailCore",
            path: "Sources/MailCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Mail",
            dependencies: ["MailCore"],
            path: "Sources/Mail",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mailctl",
            dependencies: ["MailCore"],
            path: "Sources/mailctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MailCoreTests",
            dependencies: ["MailCore"],
            path: "Tests/MailCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
