# Vendor — 本地打补丁的第三方依赖

本目录存放 ConchTalk 临时 vendored 的 Swift Package，用于在上游发布修复前封堵安全漏洞。
**等上游发布修复后应尽快恢复为远程依赖**（步骤见下文“恢复上游”）。

## 为什么需要

| 项目 | 内容 |
|---|---|
| 漏洞 | [GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc)：swift-nio-ssh 解析 ECDSA 签名时未校验 `r`/`s` mpint 长度，预认证阶段即可触发栈上越界写 |
| 上游修复 | apple/swift-nio-ssh commit `31cdc3c`（apple/swift-nio-ssh 0.14.1 起包含） |
| ConchTalk 的依赖链 | `Citadel 0.12.1` → `Wellz26/swift-nio-ssh`（`0.3.4..<0.4.0`，fork 自 apple/swift-nio-ssh）。截至 0.3.7 该 fork 仍未合入修复，Citadel 也未切换 |

## 目录内容

| 目录 | 上游来源 | 本地改动 |
|---|---|---|
| `Citadel/` | [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) tag `0.12.1`（`ae8562f`） | `Package.swift`：swift-nio-ssh 依赖改为 `.package(path: "../swift-nio-ssh")`；删除 `CitadelServerExample` 示例目标、仅示例使用的 ColorizeSwift 依赖和 `CitadelTests` 目标。`Sources/` 原样未改 |
| `swift-nio-ssh/` | [Wellz26/swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh) tag `0.3.7`（`d88989f`） | `Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift` 应用 `patches/swift-nio-ssh-GHSA-998x-vgvp-xwpc.patch`（即 apple commit `31cdc3c` 的源码部分）；`Package.swift` 仅保留 `NIOSSH` 库目标（删除示例、测试、swift-docc-plugin） |
| `patches/` | — | 所应用补丁的原始 diff，便于审查/重放 |

两个 `Package.swift` 还为 vendored 目标加了 `-suppress-warnings`（C 目标 `-w`）：Xcode 对远程包会自动屏蔽第三方警告，
改成本地包后这些上游警告（约 85 条，均为 Swift 6 并发/弃用类）会全部出现在构建输出中，故显式屏蔽以保持原有的零警告输出。

两个包都只保留构建所需的 `Package.swift`、`Sources/` 与许可证文件（Citadel: MIT `LICENSE`；swift-nio-ssh: Apache-2.0 `LICENSE.txt`）。

Xcode 工程中 Citadel 以 `XCLocalSwiftPackageReference`（`relativePath = Vendor/Citadel`）引用，
因此 `Package.resolved` 中不再有 `citadel` / `swift-nio-ssh` 的远程 pin。

## 校验补丁是否生效

```sh
grep -n "exceeds curve point size" "Vendor/swift-nio-ssh/Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift"
# 构建日志中 NIOSSH 的编译路径应指向 Vendor/swift-nio-ssh，而不是 SourcePackages/checkouts/swift-nio-ssh
xcodebuild -project ConchTalk.xcodeproj -scheme ConchTalk -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -m1 "Vendor/swift-nio-ssh/Sources/NIOSSH"
```

## 恢复上游（上游发布修复后）

1. 确认修复已发布：Wellz26/swift-nio-ssh 新 tag 包含 `31cdc3c` 的校验（搜索 `exceeds curve point size`），
   或 Citadel 新版本已依赖含修复的 swift-nio-ssh（例如切回 apple/swift-nio-ssh ≥ 0.14.1）。
2. Xcode → 工程 → Package Dependencies：移除本地 `Citadel` 包，重新添加
   `https://github.com/orlandos-nl/citadel.git`（Up to Next Major，最低为含修复的版本），
   并把 `Citadel` 产品重新勾选到 ConchTalk target。
   （或手工编辑 `project.pbxproj`：把 `XCLocalSwiftPackageReference "Vendor/Citadel"` 换回
   `XCRemoteSwiftPackageReference`，`productRef` 的 `package` 指回远程引用。）
3. 运行 `xcodebuild -resolvePackageDependencies`，确认 `Package.resolved` 中 swift-nio-ssh 版本包含修复。
4. 删除整个 `Vendor/` 目录，构建并跑测试。

如果只是 Wellz26 fork 发布了修复而 Citadel 未更新：Citadel 的 `0.3.4..<0.4.0` 范围会自动接受 fork 的新 0.3.x 补丁版本，
恢复远程 Citadel 后 resolve 即可；注意该 fork 的 `0.4.0` tag 是 2025 年的旧提交，不在范围内也不是升级。
