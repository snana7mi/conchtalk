// swift-tools-version:5.9
// ConchTalk 本地 vendored 副本：Citadel 0.12.1（tag ae8562f），见 ../README.md。
// 相对上游的改动：
//  1. swift-nio-ssh 依赖改为本地打过补丁的 ../swift-nio-ssh（修复 GHSA-998x-vgvp-xwpc）；
//  2. 移除 CitadelServerExample 可执行目标（及其仅用于示例的 ColorizeSwift 依赖）与 CitadelTests 测试目标；
//  3. 编译参数加 -suppress-warnings / -w：远程包的第三方警告本由 Xcode 自动屏蔽，本地包则会全部显示，
//     这里保持与远程依赖一致的“零警告”构建输出（仅影响 vendored 源码，不影响 App 目标）。

import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Citadel",
            targets: ["Citadel"]
        ),
    ],
    dependencies: [
        // 上游：.package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(path: "../swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt", cSettings: [.unsafeFlags(["-w"])]),
        .target(
            name: "Citadel",
            dependencies: [
                .target(name: "CCitadelBcrypt"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
