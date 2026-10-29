> 本工作分支提供 Mac 原生增强版：默认精准截取 3 秒、实际成片 JPG 封面预览与确认、保留原片、新建独立输出文件夹和 JPG/MOV 检查。GitHub Actions 在 Intel 与 Apple Silicon 上运行完整原生测试、构建通用 .app、验证 ad hoc 签名与打包后启动；具体结果以对应提交的 Actions 记录为准。构建和使用说明见 [ReviveApp/README.md](ReviveApp/README.md)。下方保留上游原版说明。

# Revive

Turn an ordinary video into an Apple Live Photo — without re-encoding the video. The output bitstream is byte-for-byte identical to the source.

A Live Photo is a pair of files linked by a shared identifier: a still image and a short video. Revive produces that pair and keeps the video lossless.

The project ships in two independent versions:

| Version | For | Stack |
|---|---|---|
| **[Revive App](ReviveApp/README.md)** | end users | native macOS app, pure AVFoundation |
| **[Revive CLI](cli/README.md)** | command line / cross-platform | Python + ffmpeg, runs on macOS and Linux |

How the lossless pipeline and metadata pairing work is documented in the [CLI Technical notes](cli/README.md).

## Download

Get the macOS app from the [latest release](https://github.com/Ed3110/Revive/releases/latest): unzip it and drag `Revive.app` to your Applications folder. The app isn't notarized yet, so allow the first launch by running `xattr -cr /Applications/Revive.app` once in Terminal. Requires macOS 14+.

Prefer to build from source, or want the CLI? See the version READMEs above.

## Roadmap

- Dark mode
- More interface languages
- Android Motion Photo (different format, not a port)

> Built with AI assistance.

（繁體中文：[README.zh-Hant.md](README.zh-Hant.md)）
