// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSH",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .library(name: "DSHHost", targets: ["DSHHost"]),
        .executable(name: "dsh-probe", targets: ["dsh-probe"]),
        .executable(name: "DSH", targets: ["DSH"]),
    ],
    targets: [
        // The protocol layer: the Swift face of the official ApiProxy contract.
        // No product logic, no process management, no UI.
        .target(name: "DSHKit"),
        // Local runtime lifecycle: finding, launching, and stopping `dsh`.
        // Separate from DSHKit because none of it is part of the contract.
        .target(name: "DSHHost", dependencies: ["DSHKit"]),
        // Acceptance harness: drives real sessions end to end, and doubles as
        // the smoke test that stands in for the version negotiation the
        // gateway protocol does not have.
        .executableTarget(name: "dsh-probe", dependencies: ["DSHKit", "DSHHost"]),
        // The desktop product.
        .executableTarget(name: "DSH", dependencies: ["DSHKit", "DSHHost"]),
    ]
)
