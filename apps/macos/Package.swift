// swift-tools-version: 6.1
//
// DSH Studio — macOS 原生宿主（W1）
//
// 依赖方向是本包最重要的架构不变量（ADR-0002）：
//
//   DSHKit      ← 契约层，零依赖
//   DSHClient   ← 数据通道，只依赖 DSHKit；**不依赖 WebKit / DSHSurface**
//   DSHSurface  ← 控制通道 + 插槽装配，只依赖 DSHKit（内部 import WebKit）
//   DSHApp      ← 应用与原生插槽视图，是唯一同时认识两条通道的地方
//
// DSHClient 与 DSHSurface 互不认识：W8 删掉 WebView 时，删的是 DSHSurface，
// DSHClient 一行不动。DSHClientTests/ArchitectureGuardTests.swift 用源码扫描
// 把这条约束变成会失败的测试。

import PackageDescription

let package = Package(
    name: "DSHStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dsh-studio", targets: ["DSHApp"]),
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .library(name: "DSHClient", targets: ["DSHClient"]),
        .library(name: "DSHSurface", targets: ["DSHSurface"]),
    ],
    targets: [
        .target(name: "DSHKit"),
        .target(name: "DSHClient", dependencies: ["DSHKit"]),
        .target(name: "DSHSurface", dependencies: ["DSHKit"]),
        .executableTarget(name: "DSHApp", dependencies: ["DSHKit", "DSHClient", "DSHSurface"]),
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit"]),
        .testTarget(name: "DSHClientTests", dependencies: ["DSHClient", "DSHKit"]),
        .testTarget(name: "DSHSurfaceTests", dependencies: ["DSHSurface", "DSHKit"]),
    ],
    swiftLanguageModes: [.v6]
)
