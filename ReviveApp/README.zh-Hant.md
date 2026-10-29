> 本分支的 Mac 原生增強功能、GitHub Actions 建置與實際驗收範圍請以 [README.md](README.md) 為準。下方保留上游原版說明；增強版建置腳本預設只產出新套件，不執行安裝或覆寫既有應用。

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
