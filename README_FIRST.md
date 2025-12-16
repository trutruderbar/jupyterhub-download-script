# 🎉 歡迎使用 JupyterHub 離線部署系統

這是一個已完整整理、移除敏感資訊的專案備份。

## 📋 快速導覽

1. **[README.md](README.md)** - 專案功能介紹與完整使用說明
2. **[SETUP.md](SETUP.md)** - 詳細的設定與部署指南（**從這裡開始**）
3. **[SECURITY.md](SECURITY.md)** - 安全注意事項與最佳實踐

## ⚠️ 部署前必讀

### 本專案已移除的敏感資訊：

- ✅ SSH 私鑰（`id_rsa`）
- ✅ 環境變數設定檔（`jhub.env`、`usage_monitoring/.env`）
- ✅ 資料庫密碼
- ✅ OAuth Client Secrets
- ✅ API Tokens
- ✅ 內部 URL 與 IP 位址

### 您需要自行準備：

1. **環境變數設定**：從 `.env.example` 與 `jhub.env.example` 複製並填入實際值
2. **TLS 憑證**（若啟用 HTTPS）：準備或生成憑證與私鑰
3. **SSH 金鑰**（若需多節點部署）：生成新的金鑰對
4. **離線映像檔**（若無網路環境）：下載並放置於 `offline-images/` 目錄

## 🚀 快速開始

```bash
# 1. 設定環境變數
cp jhub.env.example jhub.env
vim jhub.env  # 填入您的實際值

# 2. 部署 JupyterHub
sudo ./install_jhub.sh

# 3. 啟動監控面板（可選）
cd usage_monitoring
cp .env.example .env
vim .env  # 填入您的實際值
cd ..
./start_usage_portal.sh
```

詳細步驟請參閱 [SETUP.md](SETUP.md)。

## 📊 專案統計

- **總檔案數**：約 100 個
- **專案大小**：約 3.6 MB（不含離線映像檔）
- **支援的認證方式**：Native / GitHub OAuth / Azure AD / 自訂 SSO
- **包含的 Kernel**：Python、R、Julia、Go、Rust、JavaScript、.NET、Scala、Octave、Bash

## 📁 目錄結構

```
.
├── README.md                 # 專案總覽
├── SETUP.md                  # 設定指南
├── SECURITY.md               # 安全注意事項
├── install_jhub.sh           # 一鍵部署腳本
├── jhub.env.example          # 環境變數範例
├── Dockerfile                # Single-user 映像
├── lib/                      # 安裝模組
├── templates/                # 自訂模板
├── usage_monitoring/         # 監控系統
└── ...
```

## 🔒 安全提醒

- 本專案需要 **root 權限**，請在受信任環境中使用
- 部署前務必閱讀 [SECURITY.md](SECURITY.md)
- 生產環境請使用強密碼與正式的 TLS 憑證
- 建議定期備份設定檔與使用者資料

## 🆘 需要協助？

1. 查看 [README.md](README.md) 的「常見問題」章節
2. 參考 [SETUP.md](SETUP.md) 的「疑難排解」
3. 檢查各模組的日誌檔案（`*_log.txt`）

## 📄 授權

請依您的組織政策設定授權條款。

---

**準備好了嗎？** 前往 [SETUP.md](SETUP.md) 開始設定！
