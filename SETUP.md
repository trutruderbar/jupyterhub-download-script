# 專案設定指南

本專案已移除所有敏感資訊，以下是完整的設定步驟。

## 前置準備

### 1. 配置環境變數

#### jhub.env（JupyterHub 主要設定）

```bash
# 從範例檔案複製
cp jhub.env.example jhub.env

# 編輯並填入您的實際值
vim jhub.env
```

**必須設定的項目**：
- `ADMIN_USERS_CSV`：管理員帳號列表
- `SINGLEUSER_IMAGE`：Single-user 容器映像名稱
- 若使用 OAuth：填寫對應的 Client ID、Secret、Callback URL
- 若啟用 HTTPS：設定 `NGINX_PROXY_*` 相關變數與憑證路徑

#### usage_monitoring/.env（監控面板設定）

```bash
cd usage_monitoring
cp .env.example .env
vim .env
```

**必須設定的項目**：
- `POSTGRES_PASSWORD`：PostgreSQL 密碼（請使用強密碼）
- `DASHBOARD_TOKEN`：API 保護用的 Bearer token（可選但建議設定）
- 若需 MySQL 同步：填寫 `POD_REPORT_SYNC_DB_*` 相關變數

### 2. 準備 TLS 憑證（若啟用 HTTPS）

```bash
# 建立憑證目錄
mkdir -p certs

# 方式 1：使用 Let's Encrypt（推薦）
# （參考 Let's Encrypt 官方文件）

# 方式 2：生成自簽憑證（僅供測試）
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/jhub.key \
  -out certs/jhub.crt \
  -subj "/CN=your-hub.example.com"

# 設定權限
chmod 600 certs/jhub.key
chmod 644 certs/jhub.crt
```

### 3. 準備 SSH 金鑰（若需要多節點部署）

```bash
# 生成新的 SSH 金鑰對
ssh-keygen -t rsa -b 4096 -f id_rsa -N ""

# 將公鑰部署到 worker 節點
ssh-copy-id -i id_rsa.pub user@worker-node-ip
```

### 4. 準備離線映像檔（若無網路環境）

```bash
# 建立目錄
mkdir -p offline-images

# 下載或複製必要的映像檔到此目錄
# - JupyterHub chart
# - Calico
# - GPU Operator（若使用）
# - Network Operator（若使用）
# - Single-user image

# 範例：匯出 single-user image
docker save myorg/pytorch-jhub:24.10 -o offline-images/singleuser.tar
```

## 部署步驟

### 1. 安裝 JupyterHub

```bash
# 確認 jhub.env 已正確設定
cat jhub.env

# 執行一鍵部署
sudo ./install_jhub.sh
```

安裝完成後，終端會顯示存取網址與其他重要資訊。

### 2. 啟動監控面板

```bash
# 確認 usage_monitoring/.env 已正確設定
cat usage_monitoring/.env

# 啟動服務
./start_usage_portal.sh
```

瀏覽器開啟 `http://<主機IP>:29781/` 即可使用。

### 3. 新增 Worker 節點（可選）

```bash
sudo ./add_node.sh
```

依提示輸入節點 IP、帳號、密碼即可。

## 驗證部署

### 檢查 JupyterHub 狀態

```bash
# 查看所有 Pod
microk8s kubectl -n jhub get pods

# 查看服務
microk8s kubectl -n jhub get svc

# 使用診斷工具
sudo jhub-diag jhub
```

### 檢查監控面板

```bash
# 檢查 PostgreSQL 容器
docker ps | grep postgres

# 測試 API（需要設定 DASHBOARD_TOKEN）
curl -H "Authorization: Bearer your_token_here" \
  http://localhost:29781/api/usage
```

### 測試登入

1. 開啟瀏覽器，前往 JupyterHub 存取網址
2. 使用管理員帳號登入
3. 確認能成功啟動 Notebook

## 常見設定調整

### 變更認證模式

編輯 `jhub.env`，更改 `AUTH_MODE` 與相關變數：

```bash
# 例如：從 native 改為 GitHub OAuth
export AUTH_MODE=github
export GITHUB_CLIENT_ID="your_client_id"
export GITHUB_CLIENT_SECRET="your_client_secret"
export GITHUB_CALLBACK_URL="https://your-hub.example.com/hub/oauth_callback"
```

重新執行安裝腳本以套用變更：
```bash
sudo ./install_jhub.sh
```

### 啟用 GPU 支援

```bash
# 編輯 jhub.env
export USE_GPU_OPERATOR=true
export GPU_DRIVER_MODE="host"
export GPU_OPERATOR_DRIVER_VERSION="580.65.06"  # 依實際驅動版本調整
```

### 調整資源配額

編輯 `lib/70-profiles.sh` 或在 `jhub.env` 中設定預設值。

## 備份與復原

### 備份重要檔案

```bash
# 備份設定
tar czf jhub-config-backup.tar.gz \
  jhub.env \
  usage_monitoring/.env \
  certs/ \
  values.yaml

# 備份使用者資料（依您的 SHARED_STORAGE_PATH）
tar czf jhub-userdata-backup.tar.gz /path/to/shared/storage
```

### 復原

1. 復原設定檔到原位置
2. 重新執行 `./install_jhub.sh`
3. 復原使用者資料到對應目錄

## 疑難排解

### 安裝失敗

1. 檢查 log 檔案（`*_log.txt`）
2. 執行診斷工具：`sudo jhub-diag jhub`
3. 查看詳細錯誤：`microk8s kubectl -n jhub describe pod <pod-name>`

### 無法存取 JupyterHub

1. 檢查防火牆設定
2. 確認 NodePort 或 Nginx 服務正常運行
3. 檢查 DNS 解析（若使用域名）

### GPU 無法使用

1. 確認主機已安裝 NVIDIA 驅動
2. 檢查 GPU Operator Pod 狀態
3. 查看 `nvidia-smi` 輸出

詳見 [README.md](README.md) 的常見問題章節。

## 安全檢查清單

- [ ] 已設定強密碼給所有資料庫
- [ ] 已設定 `DASHBOARD_TOKEN` 保護監控 API
- [ ] 已替換所有預設的 secret 與 token
- [ ] TLS 憑證已正確配置（若使用 HTTPS）
- [ ] SSH 私鑰權限設為 600
- [ ] 已設定防火牆規則，僅開放必要 port
- [ ] 已檢查 `.gitignore`，確保不會提交敏感檔案

## 更多資訊

- [README.md](README.md)：專案功能與架構說明
- [SECURITY.md](SECURITY.md)：安全注意事項
- [usage_monitoring/README.md](usage_monitoring/README.md)：監控面板詳細文件

---

**需要協助？** 請參考專案 README 或提交 Issue。
