# Revive Mac Enhanced

本分支基于上游 `feb46245b5c6a1d3982909916832a02d71a33828`，沿用 SwiftUI、AVFoundation、AppKit 和原有视觉样式，增强实际成片封面预览、人工确认、安全导出和文件校验。支持在 Mac 本地构建，也可通过 GitHub Actions 分别在 Intel、Apple Silicon runner 上构建和验收。具体提交是否通过，以对应运行的日志、构建凭据和产物为准；本文不预先宣称测试或设备验收通过。

## 使用流程

1. 添加视频，默认选中视频中间约 3 秒。当前增强模式固定使用精准剪辑及 JPG/MOV 配对；精准剪辑会重新编码视频一次，不承诺成片视频码流与原片逐字节相同。可调整片段与封面位置，也可选择静音。
2. 点击“生成成片预览”。引擎先生成实际 MOV，再从该视频的实际帧编码全分辨率 JPG，将实际取帧时间写入 MOV 的定时元数据。
3. 点击“查看封面原图”，人工确认人物没有闭眼，再勾选封面确认。更改片段、封面或其他转换设置会清除旧预览及确认，需要重新生成和检查。程序没有自动人脸或眼睛识别，人工确认不能由自动测试替代。
4. 导出复用已经预览的 JPG/MOV，不重新转换。原片只读；预览和导出均核对原片 SHA-256，并检查导出文件与已预览文件一致。
5. 输出默认位于原片旁边，也可选择其他位置。每次导出新建 `Revive_Live_<UUID>` 专用文件夹，不覆盖原片、已有文件或旧输出。
6. 输出包含 JPG、MOV 和 `检查报告.json`。报告记录配对 ID、实际封面时间、时长、真实 JPEG 解码、MOV 容器、定时元数据样本、完整视频/音频解码，以及原片与输出的哈希检查。
7. 只有全部文件检查通过、原片保持不变，报告才标记 `FILES_VERIFIED`。此状态只表示文件层检查通过，不能视为 Apple Photos 或 iPhone 已识别 LIVE、可以长按播放，或已通过其他平台的发布验收。

生成预览与导出期间会锁定相应控件；退出应用会等待当前转换安全结束，每个应用进程只清理自己拥有的临时目录。选择加入照片图库时，程序先保存本地文件及报告，再通过 PhotoKit 请求授权并导入；文件保存和图库导入失败分别报告。即使图库导入完成，LIVE 识别和播放仍需在目标设备实际确认。

## 在 Mac 本地构建

要求 macOS 14+、Swift 5.9+ 和包含 macOS SDK 的 Apple 开发工具。构建不需要新增第三方生产依赖。

```bash
cd ReviveApp
bash build.sh           # 先运行完整 Debug 和 Release 原生 XCTest，再构建 arm64+x86_64 universal 应用
bash build.sh --native  # 仅构建当前 Mac 架构，同样先运行完整 Debug 和 Release 原生 XCTest
```

每次构建使用新的 `build/Enhanced-<时间>-<UUID>` 目录。脚本不安装或覆盖已有应用，也不修改 Finder、Dock 或服务设置。只有测试、编译、架构检查、ad hoc 签名验证及 ZIP 打包全部成功，`BuildReceipt.json` 才记录 `BUILT_TESTED_NOT_DEVICE_ACCEPTED`。

输出目录包含 `Revive.app`、`Revive-Enhanced-macOS.zip`、`BuildReceipt.json`、`NativeTests.log`、`NativeBuild.log`、`SwiftVersion.txt`、`source-sha256.txt`、`SignatureVerification.txt` 和 `SHA256SUMS.txt`。失败时保留已生成的日志及凭据，不能把部分输出视为构建完成。

universal 构建完成后，可额外验证实际打包产物；请将下列路径替换为本次构建的准确目录：

```bash
bash ci-verify-app.sh "build/Enhanced-<时间>-<UUID>"
```

该脚本解压实际 ZIP，检查 SHA-256、签名和双架构，启动解压后的 release 可执行文件并观察 12 秒；随后另外构建 DEBUG，使用仓库中的合成视频生成并校验真实 JPG/MOV 预览，再保存原生 UI 截图。验收凭据、启动日志和截图保存在 `build/ci-evidence/`。此脚本要求 universal 产物，不能用于 `--native` 的单架构输出。

## GitHub Actions 双架构验收

[macOS 增强版工作流](../.github/workflows/macos-enhanced.yml)由 `codex/mac-parity` 分支 push 或手动运行触发，仅在公共仓库的该分支执行。使用 GitHub 标准 `macos-15-intel` 和 `macos-15` runner，分别原生执行 Intel 与 Apple Silicon 验收；每个 job 上限 30 分钟，产物保留 7 天。

每个 job 都独立运行完整 XCTest，再构建 universal `.app`、验证 ad hoc 签名并打包 ZIP。测试覆盖真实合成媒体转换、配对元数据与封面时间、媒体损坏、输出冲突与路径安全、原片保持不变及预览确认状态；实际用例数量、失败和跳过情况以该 job 的 `NativeTests.log` 为准。随后执行打包 release 启动和 DEBUG 原生 UI 预览检查。CI 不导入 Photos，也不自动发布 GitHub Release。

- 应用产物：`Revive-Enhanced-macOS-universal-<intel或apple-silicon>-<提交SHA>`，仅在该 job 的前序验收成功后上传。
- 证据产物：`Revive-Enhanced-ci-evidence-<intel或apple-silicon>-<运行ID>-<重试序号>`，包含已产生的测试/构建日志、BuildReceipt、哈希与签名信息，以及 `ci-evidence/` 下的 `CIVerification.json`、启动日志和 UI 截图；失败时也尽量保留诊断。

两种 runner 各自构建并验收自己的 ZIP，每份 ZIP 都包含 arm64+x86_64。交付时应核对所选产物对应的提交、job、哈希及凭据；两个 job 通过表示同一源码在两种原生架构上分别通过，不等于同一份 ZIP 已在两类用户设备测试。还应实际查看 `NativeUISmoke.png` 的画面与相应日志，不能只凭 PNG 文件存在就认定界面效果正确。

`CIVerification.json` 仅在相应检查完成后标记 `PACKAGED_STARTUP_AND_UI_SMOKE_PASSED`。CI 的启动检查直接执行解压后的 release 二进制，UI 截图来自独立 DEBUG 构建；两者不替代浏览器下载后的 Gatekeeper/Finder 首次打开、完整交互、macOS 14 实际运行、真实用户媒体或 Photos/iPhone LIVE 设备验收。

## 下载后的签名与首次打开

构建使用 `codesign --sign -` 进行 ad hoc 签名，并以 `codesign --verify --strict` 检查签名完整性。ad hoc 签名没有开发者签名身份，不等同于 Developer ID 签名，也不代表通过 Apple 公证。Apple 公证要求适用的 Developer ID 证书并向 Apple 提交检查，本工作流未使用此类证书或执行公证。[Apple：ad hoc 签名](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc)、[Apple：分发前公证 macOS 软件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

1. 从对应成功的 Actions 运行下载应用 artifact 及证据。先解压 GitHub 包装的外层 ZIP，再找到并解压内部 `Revive-Enhanced-macOS.zip`，得到 `Revive.app`；使用证据中的 `SHA256SUMS.txt` 核对内部 ZIP 的 SHA-256。
2. 将应用放到单独目录，避免覆盖已有版本，然后双击尝试打开。
3. 如果 macOS 因开发者无法验证或无法检查恶意软件而阻止打开，确认下载来源可信、哈希一致且文件未被篡改后，进入“系统设置 → 隐私与安全性”，为该应用选择“仍要打开”，再确认“打开”。这只添加该应用的例外，无需关闭全局安全策略。具体以 [Apple 官方首次打开指引](https://support.apple.com/en-us/102445)及当前系统提示为准。
4. 如果系统提示应用已损坏、会损害电脑或检测到恶意软件，应停止打开并核对包、哈希与签名，不将此类提示当作普通首次打开确认。

繁體中文：[README.zh-Hant.md](README.zh-Hant.md)。

## 原生写入停滞回归

保留的合成故障夹具为 `Tests/ReviveTests/Fixtures/TEST_writer_stall_prepared.mov`。它来自实际超时现场，包含 HEVC 视频与 AAC 音频，仅供测试。专用诊断工作流支持 Debug/Release、固定重放次数以及新建/复用预览项，遇到首个失败即停并保存错误、线程采样和中间文件。实际用户素材不会上传到此工作流。

修复前的现场显示：reader/writer 均仍在读写，元数据轨道已结束；音频只读取了 95/142 个样本，其输入已恢复可写，但原生 readiness 回调没有再次执行，视频也因此等待。应用不能把后续推进完全寄托在该回调上。每条轨道现在由同一串行队列上的 250ms 定时检查兜底唤醒，并复用原回调逻辑：只在 ready 时读写；结束、失败或取消时撤销检查。定时检查本身不计作媒体进展，原 120 秒无进展保护保留。

构建脚本现在要求 Debug 与 Release 两套原生 XCTest 均通过，之后才构建和签名应用。验收应同时核对两套测试日志，不能用 Debug 的成功代替优化后 Release 的稳定性。
