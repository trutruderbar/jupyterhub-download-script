# 安全注意事項

## 部署前必讀

### 敏感資訊處理

在部署此專案前，請務必處理以下敏感資訊：

#### 1. 環境變數設定

**jhub.env**：
- 從 `jhub.env.example` 複製並重新命名為 `jhub.env`
- 更新所有 URL、IP 位址、使用者名稱為您的實際值
- 設定 OAuth 相關的 Client ID 和 Secret（如使用）
- 配置 TLS 憑證路徑

**usage_monitoring/.env**：
- 從 `.env.example` 複製並重新命名為 `.env`
- 設定強密碼給 `POSTGRES_PASSWORD`
- 配置 `DASHBOARD_TOKEN` 以保護 API 端點
- 如需 MySQL 同步，填寫正確的資料庫連線資訊

#### 2. SSH 金鑰

專案**不包含** SSH 私鑰。如需使用節點管理功能（`add_node.sh` / `del_node.sh`），請：
- 生成新的 SSH 金鑰對：`ssh-keygen -t rsa -b 4096 -f id_rsa`
- 將公鑰部署到目標節點
- **永不**將私鑰提交到版本控制系統

#### 3. TLS 憑證

如啟用 HTTPS（`ENABLE_NGINX_PROXY=true`），需要準備：
- TLS 憑證（`.crt` 或 `.pem`）
- 私鑰（`.key`）
- 可使用 Let's Encrypt 或自簽憑證

建議將憑證存放於 `certs/` 目錄（已在 `.gitignore` 中排除）。

#### 4. 資料庫密碼

所有範例密碼僅供參考，生產環境**必須**更換為強密碼：
- PostgreSQL（usage_monitoring）
- MySQL（pod_report 同步，如使用）

### 建議的安全措施

1. **防火牆設定**：
   - 僅開放必要的 port（30080、443、29781）
   - 限制來源 IP 範圍（如可能）

2. **定期更新**：
   - 保持 JupyterHub、MicroK8s、GPU Operator 為最新版本
   - 定期更新 base image 與依賴套件

3. **最小權限原則**：
   - 避免使用 root 帳號執行 Notebook
   - 為每個使用者設定適當的資源配額

4. **日誌監控**：
   - 定期檢查 `/var/log/jupyterhub` 與各類 log 檔案
   - 啟用異常登入偵測

5. **網路隔離**：
   - 使用 NetworkPolicy 隔離不同使用者的 Pod
   - 考慮使用 VPN 或內網限制存取

### 不應提交到 Git 的檔案

已在 `.gitignore` 中排除以下類型檔案：
- `*.env`（環境變數設定）
- `id_rsa`、`*.key`、`*.crt`（金鑰與憑證）
- `offline-images/`、`*.tar`（大型映像檔）
- `*.log`、`*_log.txt`（日誌檔案）
- `port_mapper_backup_*/`（備份資料夾）
- `values.yaml`（可能包含敏感設定）

### 報告安全問題

如發現安全漏洞，請：
1. **不要**公開揭露
2. 透過私人管道聯絡專案維護者
3. 提供詳細的重現步驟與影響範圍

---

**最後提醒**：本專案常需要 root 權限執行，請僅在受信任的環境中部署。
