# Revive

把一般影片轉成 Apple 原況照片（Live Photo）——影片不重新編碼，輸出的位元流與來源逐位元組相同。

Live Photo 是一對靠共用識別碼綁定的檔案：一張靜態圖 + 一段短影片。Revive 產生這對檔案並保證影片無損。

本專案有兩個各自獨立的版本：

| 版本 | 適合 | 技術 |
|---|---|---|
| **[Revive App](ReviveApp/README.zh-Hant.md)** | 一般使用者 | 原生 macOS App，純 AVFoundation |
| **[Revive CLI](cli/README.zh-Hant.md)** | 命令列 / 跨平台 | Python + ffmpeg，可跑在 macOS 與 Linux |

無損原理、metadata 配對等技術細節見 [CLI 版的 Technical notes](cli/README.zh-Hant.md)。

## Roadmap

- 深色模式
- 擴充更多介面語言
- Android Motion Photo（格式不同，非移植）

> 本專案在 AI 輔助下完成。

（English: [README.md](README.md)）
