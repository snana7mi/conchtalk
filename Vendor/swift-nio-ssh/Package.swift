// swift-tools-version:5.10
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// ConchTalk 本地 vendored 副本：Wellz26/swift-nio-ssh 0.3.7（commit d88989f），见 ../README.md。
// 相对上游的改动（Apache-2.0 §4(b) 修改声明）：
//  1. Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift 应用 apple/swift-nio-ssh
//     commit 31cdc3c 的 ECDSA mpint 长度校验（GHSA-998x-vgvp-xwpc）；
//  2. 本清单仅保留 NIOSSH 库目标，移除示例可执行目标、测试目标与 swift-docc-plugin 依赖；
//  3. 编译参数加 -suppress-warnings：远程包的第三方警告本由 Xcode 自动屏蔽，本地包则会全部显示，
//     这里保持与远程依赖一致的“零警告”构建输出。

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .unsafeFlags(["-suppress-warnings"]),
]

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strictConcurrencySettings
        )
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
