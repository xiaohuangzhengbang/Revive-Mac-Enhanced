# Revive

Turn an ordinary video into an Apple Live Photo — without re-encoding the video. The output bitstream is byte-for-byte identical to the source.

A Live Photo is a pair of files linked by a shared identifier: a still image and a short video. Revive produces that pair and keeps the video lossless.

The project ships in two independent versions:

| Version | For | Stack |
|---|---|---|
| **[Revive App](ReviveApp/README.md)** | end users | native macOS app, pure AVFoundation |
| **[Revive CLI](cli/README.md)** | command line / cross-platform | Python + ffmpeg, runs on macOS and Linux |

How the lossless pipeline and metadata pairing work is documented in the [CLI Technical notes](cli/README.md).

## Roadmap

- Dark mode
- More interface languages
- Android Motion Photo (different format, not a port)

> Built with AI assistance.

（繁體中文：[README.zh-Hant.md](README.zh-Hant.md)）
