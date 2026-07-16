# Revive CLI

把 MP4/MOV 轉成 Apple 原況照片（Live Photo）檔案對——一張 JPEG/HEIC 靜態圖 + 一段 MOV，過程中不重新編碼影片。

影片的壓縮位元流會以 stream copy 原樣搬進輸出的 `.MOV`——和來源逐位元組相同（可用 `ffmpeg -f framemd5` 驗證）。靜態圖以來源原始解析度擷取。

## 需求環境

- Python 3.9+
- **ffmpeg** — `brew install ffmpeg`（macOS）/ `sudo apt install ffmpeg`（Linux）
- **exiftool** — `brew install exiftool` / `sudo apt install libimage-exiftool-perl`
- 僅 macOS，原生後端（推薦）：`python3 -m pip install pyobjc`
- 選用：`pip install Pillow` — 把擷取的 JPEG 從品質約 93（ffmpeg 上限）提升到品質 97、4:4:4 色度

工具會偵測作業系統，自動挑最合適的後端：

| 平台 | 影片 metadata | 圖片 metadata | still-image-time 軌 |
|---|---|---|---|
| macOS（`apple` 後端） | AVFoundation passthrough | exiftool（就地編輯） | ✅ 有寫入 |
| 任意（`exiftool` 後端） | exiftool（就地編輯） | exiftool（就地編輯） | ⚠️ 未寫入* |

\* 沒有這個軌，檔案對通常還是能匯入成 Live Photo（iOS 是靠識別碼配對的），但 `apple` 後端才是完全合規的路徑。

## 用法

```bash
# 整段影片（超過 3 秒會警告）
python3 revive_cli.py clip.mp4

# 修剪：從 0:04 開始取 3 秒，自訂輸出資料夾與檔名
python3 revive_cli.py clip.mp4 --start 4.0 --duration 3.0 -o out/ --name IMG_0042

# 選封面幀（相對於修剪後的片段；預設 = 中點）
python3 revive_cli.py clip.mp4 --duration 3 --frame-time 1.2

# 用 HEIC 靜態圖，而非 JPEG（macOS）
python3 revive_cli.py clip.mp4 --heic

# 驗證一組已存在的檔案對
python3 revive_cli.py --verify out/IMG_0042.JPG out/IMG_0042.MOV
```

每次轉換結束都會跑一份驗證清單，從兩個檔案讀回 metadata、確認識別碼一致：

```
Verification checklist:
  ✅ image has MakerNotes:ContentIdentifier
  ✅ video has Keys:ContentIdentifier (com.apple.quicktime.content.identifier)
  ✅ identifiers match
  ✅ video has still-image-time metadata track
  ✅ file basenames match
```

## 哪些地方畫質有保留、哪些沒有

- **Remux／修剪**：一律 `ffmpeg -c copy`（stream copy）。壓縮位元流原封不動搬進 `.MOV` 容器。你可以自己驗：

  ```bash
  ffmpeg -i source.mp4 -map 0:v -c copy -f h264 - | md5
  ffmpeg -i IMG_0042.MOV -map 0:v -c copy -f h264 - | md5   # 一模一樣
  ```

- **寫入 metadata**：macOS 後端以 AVFoundation *passthrough* 模式重寫容器（不解碼、不編碼）；exiftool 則就地編輯 metadata 區塊。兩者都不碰媒體資料。
- **靜態幀**：從（位元完全相同的）影片解碼一次、以原始解析度存出，JPEG 品質 97（Pillow）／ `-q:v 1`（ffmpeg 後備），或用 `sips` 存 HEIC 最高品質。
- **重新編碼只發生在兩種情況**，每種都會印出警告，且一律用視覺無損的 `libx264 -crf 12`：
  1. 來源編碼無法存在於 QuickTime 容器（例如 VP9/AV1）；
  2. 你加了 `--exact`（見下）。

### 無損修剪只能切在關鍵幀

stream copy 只能切在影片有關鍵幀的位置。手機／螢幕錄影的關鍵幀常常間隔好幾秒，所以 `--start 4 --duration 3` 可能產出一個「開始得更早、跑得更長」的片段（發生時工具會告訴你）。若你需要精準到幀的切點，加上 `--exact`——它會重新編碼一次（`libx264 -crf 12`），視覺上和來源難以分辨。

## 把檔案對匯入 iPad 照片圖庫

黃金守則：**兩個檔案必須一起、以檔案形式、metadata 完整地抵達照片圖庫。**

### 從 Mac 用 AirDrop（最可靠）

1. 在 Finder 選取**兩個**檔案 `IMG_XXXX.JPG` 和 `IMG_XXXX.MOV`（⌘ 點選）。
2. 右鍵 → 分享 → AirDrop → 你的 iPad。
3. iPadOS 會自動把它們存成一張 Live Photo。

如果 AirDrop 跳出兩個分開的「儲存」提示，兩個都接受；照片會在匯入時合併。

### iCloud 照片上傳

1. 在任意瀏覽器打開 iCloud.com → 照片。
2. 按上傳，在**同一次上傳操作**裡選這兩個檔案。
3. iCloud 會在伺服器端配對；Live Photo 會出現在每一台同步的裝置上。

或在開了 iCloud 照片的 Mac 上：打開「照片」App，選 檔案 → 輸入…，同時選這兩個檔案。

### 已知陷阱

- **「檔案」App 通常會拆散檔案對。** 把兩個檔案存進「檔案」再點開，只會匯入靜態圖（或只有影片）。別走「檔案」這條路。
- **通訊軟體會剝掉 metadata。** WhatsApp/Telegram 之類會重新壓縮並丟掉 ContentIdentifier。Email 附件有時能保住，但 AirDrop/iCloud 才是可靠路徑。
- **一次匯入兩個。** 今天匯 JPG、明天匯 MOV，你得到的是一張照片和一段影片，不是 Live Photo。
- **檔名主體要一致。** `IMG_0042.JPG` + `IMG_0042.MOV`——工具會強制這點；事後別只改其中一個的名字。
- **不確定就先驗證：** `python3 revive_cli.py --verify a.JPG a.MOV` 會明確告訴你缺了哪個 metadata 欄位。

## Technical notes（原況照片的運作原理）

Live Photo 不是單一檔案，而是靠一組共用的識別碼（UUID）連結起來的一對檔案：

| 檔案 | 角色 | 連結用的 metadata |
|---|---|---|
| `IMG_XXXX.JPG` / `.HEIC` | 靜態圖 | Apple MakerNotes 的 `ContentIdentifier` |
| `IMG_XXXX.MOV` | 短影片 | `com.apple.quicktime.content.identifier`，加上一個 `still-image-time` metadata 軌，標記封面幀 |

當兩個檔案帶有相同的 UUID、且一起匯入時，「照片」App 會把它們合併成一張 Live Photo。`still-image-time` 軌標記的是哪一幀是封面；省略它的轉檔器通常還是能配對，只是封面幀不會被保留。

## 專案結構

```
cli/
├── revive_cli.py      # CLI + ffmpeg 管線 + exiftool 後端 + 驗證
├── apple_metadata.py  # macOS 原生 writer（AVFoundation passthrough + CoreGraphics）
└── README.md
```

`convert()` 接收一個 `Job` dataclass——之後要做批次模式，就是建一串 `Job` 然後迴圈跑過去。

> 本專案在 AI 輔助下完成。

（English: [README.md](README.md)）
