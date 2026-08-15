// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DSH",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DSH", targets: ["DSH"])
    ],
    targets: [
        .executableTarget(
            name: "DSH",
            path: "Sources/DSH",
            exclude: ["Info.plist", "DSH.entitlements"],
            resources: [
                .copy("Resources/Themes")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ]
)
