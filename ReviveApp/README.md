# Revive Mac Enhanced — 原生源码候选

本分支基于上游 `feb46245b5c6a1d3982909916832a02d71a33828`，沿用 SwiftUI、AVFoundation、AppKit 和原有视觉样式。当前执行端为 Windows：Swift 语法解析已验证，Apple 平台类型检查、原生测试、链接、签名和启动尚未完成。此源码包不代表已经生成可运行的增强 `.app`。

## 对齐的源码流程

1. 默认选中视频中间 3 秒，使用精准剪辑和 JPG/MOV；精准剪辑会重新编码一次。
2. 点击“生成成片预览”。引擎先生成实际视频，再从该视频的实际帧编码全分辨率 JPG，将该帧的 actualTime 写入 MOV 定时元数据。
3. 点击“查看封面原图”，确认人物没有闭眼。更改时间范围或封面会清除旧确认。
4. 导出复用已预览的配对文件，不再重新转换。原片只读；预览与导出均核对原片 SHA256。
5. 输出位置默认在原片旁边，也可选择其他位置。每次通过排他创建新 `Revive_Live_UUID` 文件夹，不覆盖已有文件。
6. 检查实际 JPEG 解码、MOV 容器、唯一配对 ID、实际 still-image-time 样本、时长、全部视频/音频解码以及预览/输出 hash；写出 `检查报告.json`。
7. 只有文件检查全部通过且原片未变才标记 `FILES_VERIFIED`；该状态不等同于苹果设备 LIVE 播放验收。

生成预览和导出期间会锁定相应控件。退出应用会等待当前转换及检查完成；每个应用进程只清理自己拥有的临时目录。图库入口在保存文件及检查报告后才调用 PhotoKit；图库导入与文件导出失败分别报告。

本版没有自动人脸/眼睛识别，封面确认是使用者对实际 JPG 的人工确认。原有多语言、时间线、原生视频播放器和图库入口继续保留。

## 在具备 macOS SDK 的 Mac 上构建

要求 macOS 14+、Swift 5.9+ 及相应 Apple 开发工具；不引入生产依赖。

```bash
cd ReviveApp
bash build.sh           # 先运行原生测试，再构建 arm64+x86_64 通用应用
bash build.sh --native  # 只构建当前 Mac 架构，同样先运行原生测试
```

构建输出进入新的 `build/Enhanced-...` 专属目录。脚本默认不安装、不覆盖现有应用，不重启 Finder、Dock 或服务。测试、编译、架构验证、ad hoc 签名验证及 ZIP 打包全部成功后，才记录 `BUILT_TESTED_NOT_DEVICE_ACCEPTED`。

结果目录包含 `.app`、保留可执行权限的 ZIP、原生测试日志、构建日志、源码 hash、签名检查和 BuildReceipt。ad hoc 签名不等于 Apple 公证。

原生测试共 45 项（包括既有测试和本轮新增测试），包含合成视频夹具及“元数据可读但媒体损坏”的反例。它们在当前 Windows 会话中没有执行，不能写成测试通过。

## 当前交付门槛

- 已执行：官方 Swift 5.9.2 前端以 `arm64-apple-macosx14.0` 目标做语法解析；源码空白检查；构建脚本语法检查；独立源码审查。
- 已尝试但被环境阻塞：Apple 平台类型检查，错误为 `unable to load standard library for target 'arm64-apple-macosx14.0'`。
- 未执行：macOS 原生编译、45 项 XCTest、通用二进制链接、签名、应用启动、界面截图与实际媒体转换。
- 苹果 Photos/iPhone 的 LIVE 标识、长按播放、方向、声音与封面仍需实机验收。

（繁體中文：[README.zh-Hant.md](README.zh-Hant.md)）
