// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSH",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .library(name: "DSHHost", targets: ["DSHHost"]),
        .library(name: "DSHSurface", targets: ["DSHSurface"]),
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
        .executableTarget(name: "DSH", dependencies: ["DSHKit", "DSHHost", "DSHSurface"]),
        // Private chrome channel between the Swift host and our client plugin.
        // Not the official contract — that stays in DSHKit — and not WebKit,
        // so the envelope and the ready-queue can be tested without a view.
        .target(name: "DSHSurface", dependencies: ["DSHKit"]),

        // Replays recorded downlink traffic through the real decoder. This is
        // the defense that catches upstream drift without a live host — see
        // ARCHITECTURE §6.
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit"]),
        .testTarget(name: "DSHHostTests", dependencies: ["DSHHost"]),
        .testTarget(name: "DSHSurfaceTests", dependencies: ["DSHSurface"]),
    ]
)
