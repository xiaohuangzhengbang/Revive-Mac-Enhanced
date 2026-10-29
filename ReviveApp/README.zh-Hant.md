> 本分支為尚未在 Mac 構建的增強版原始碼；目前狀態與新構建入口請參照 [README.md](README.md)。舊版 --install 入口已移除，構建不會覆蓋既有應用。

# Revive App

把影片轉成 Apple 原況照片的原生 macOS App，影片不重新編碼。

拖入影片、選片段，轉換後可直接加入照片圖庫或匯出檔案。介面支援繁中／簡中／English／Español。

## 建置

```bash
cd ReviveApp
./build.sh            # 建置到 build/Revive.app
./build.sh --install  # 安裝到 /Applications
```

需求：macOS 14+、Swift 5.9+。

（English: [README.md](README.md)）
