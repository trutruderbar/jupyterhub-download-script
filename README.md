# JupyterHub 離線部署與資源監控系統

一套針對內部環境打造的 **JupyterHub 離線部署 + 資源監控** 完整解決方案。支援離線環境部署、多節點 GPU 集群管理、使用情況追蹤與帳務統計。

## 專案特色

- ✅ **離線部署**：完整支援無網路環境的 JupyterHub 安裝
- 🚀 **一鍵安裝**：自動化腳本處理所有部署步驟
- 🖥️ **GPU 支援**：自動偵測並配置 NVIDIA GPU 與 CUDA 環境
- 📊 **資源監控**：即時監控使用者資源使用狀況與帳務統計
- 🔐 **多種認證**：支援 Native / GitHub OAuth / Azure AD / 自訂 SSO
- 🌐 **多節點叢集**：簡化的節點管理腳本（add/remove worker）
- 🎯 **InfiniBand 支援**：可選啟用 RDMA 以加速分散式訓練

## 系統需求

- **作業系統**：Ubuntu 22.04 / 24.04（或其他 Debian/Ubuntu 系發行版）
- **權限**：需要 root 權限
- **軟體依賴**：
  - Docker / Docker Compose
  - Python 3.8+
  - MicroK8s（安裝腳本會自動設定）
- **硬體建議**：
  - 磁碟空間：至少 100GB（用於離線映像與容器儲存）
  - 記憶體：建議 16GB 以上
  - （可選）NVIDIA GPU + 驅動

## 快速開始

### 1. 部署 JupyterHub

```bash
# 編輯環境設定檔（可選，已有預設值）
vim jhub.env

# 執行一鍵部署
sudo ./install_jhub.sh
```

安裝腳本會自動完成：
1. 偵測作業系統、核心、GPU/網卡資訊
2. 檢查並匯入 `offline-images/` 中的離線映像檔
3. 安裝與設定 MicroK8s（含 Calico、HostPath、DNS）
4. 部署 GPU Operator / Network Operator（若啟用）
5. 生成 Helm values 並安裝 JupyterHub
6. 建立 Admin NodePort、Nginx 反向代理（若啟用）、診斷工具

**存取 JupyterHub**：
- 安裝完成後會顯示存取網址
- 預設通過 NodePort（port 30080）或 HTTPS 反向代理存取
- 預設管理員帳號見 `jhub.env` 中的 `ADMIN_USER`

### 2. 啟動使用情況監控面板

```bash
./start_usage_portal.sh
```

這會啟動 FastAPI 服務（預設綁定 `0.0.0.0:29781`），提供：
- 📈 使用者資源使用紀錄（CPU/Memory/GPU/時長）
- 💰 帳務統計與成本估算
- 🔍 即時 Pod 監控與管理（查看/刪除）
- 🔄 自動記錄容器 session（每 30 秒更新）
- 🗄️ 可選的 MySQL 同步功能（定期同步至 `jupyterhub.pod_report`）

瀏覽器開啟 `http://<主機IP>:29781/` 即可使用。

### 3. 管理 MicroK8s 節點

**新增 Worker 節點**：
```bash
sudo ./add_node.sh
```
互動式輸入節點 IP、帳號、密碼，腳本會自動安裝 MicroK8s、加入叢集並同步離線映像。

**移除 Worker 節點**：
```bash
sudo ./del_node.sh
```
選擇要移除的節點，可選 cordon/drain 後再移除，並可選遠端清理 MicroK8s。

## 核心功能

### JupyterHub 部署

| 功能 | 說明 |
|------|------|
| **離線映像支援** | `offline-images/` 目錄存放所有必要映像，支援無網路部署 |
| **自訂登入頁** | 支援客製化 Logo、OAuth 登入按鈕（見 `templates/` 與 `image/`） |
| **多種認證模式** | Native / GitHub OAuth / Azure AD / 自訂 SSO |
| **GPU 自動偵測** | 自動配置 GPU Operator、CUDA、NCCL |
| **InfiniBand 支援** | 可選啟用 Network Operator + RDMA shared device plugin |
| **儲存自動化** | 自動建立 hostPath PV/PVC、掛載使用者工作區 |
| **MPI Operator** | 可選啟用，為每位使用者建立專屬 namespace 與 RBAC |
| **資源配額** | 依硬體自動生成 CPU/Memory/GPU profiles |

### 使用情況監控

| 功能 | 說明 |
|------|------|
| **PostgreSQL 儲存** | 完整記錄每個容器 session（起訖時間、資源用量） |
| **自動記錄** | 背景執行緒每 30 秒掃描 K8s Pods 並自動建立/結束 session |
| **即時監控** | Web UI 即時顯示所有運行中的 JupyterHub Pods |
| **Pod 管理** | 網頁介面可直接刪除選中的 Pods |
| **帳務統計** | 自動計算 GPU/CPU 時數與成本（可調整費率） |
| **MySQL 同步** | 可選將 session 資料同步至外部 MySQL `pod_report` 表 |
| **Token 保護** | 可設定 Bearer token 保護 API 端點 |

### 單一使用者映像

專案包含完整的 `Dockerfile`，建構包含以下功能的 single-user 映像：

- 🎨 **桌面環境**：XFCE + noVNC（Jupyter Launcher 內提供 "Desktop" 入口）
- 💻 **Code-Server**：瀏覽器版 VS Code
- 🧪 **多語言 Kernel**：Python、R、Julia、Go、Rust、JavaScript、.NET、Scala、Octave、Bash
- ⚡ **GPU 加速**：PyTorch（CUDA 12.4）、CuPy、NCCL
- 📦 **擴充套件**：Git、LSP、Code Formatter、Resource Monitor、NVDashboard、Dask 等

## 認證設定

編輯 `jhub.env` 選擇認證模式：

### Native 認證（預設）
```bash
export AUTH_MODE=native
export ADMIN_USERS_CSV="user1,user2"
```

### GitHub OAuth
```bash
export AUTH_MODE=github
export GITHUB_CLIENT_ID="your_client_id"
export GITHUB_CLIENT_SECRET="your_client_secret"
export GITHUB_CALLBACK_URL="https://your-hub.example.com/hub/oauth_callback"
```

### Azure AD OAuth
```bash
export AUTH_MODE=azuread
export AZUREAD_CLIENT_ID="your_client_id"
export AZUREAD_CLIENT_SECRET="your_client_secret"
export AZUREAD_CALLBACK_URL="https://your-hub.example.com/hub/oauth_callback"
export AZUREAD_TENANT_ID="your_tenant_id"
```

### 自訂 SSO（Cookie-based）
```bash
export AUTH_MODE=ubilink
export UBILINK_AUTH_ME_URL="https://your-auth-api.example.com/api/auth/me"
export UBILINK_LOGIN_URL="https://your-login-page.example.com/login"
```

## 目錄結構

```
.
├── install_jhub.sh          # 一鍵部署腳本
├── uninstall_jhub.sh        # 卸載腳本
├── add_node.sh              # 新增 Worker 節點
├── del_node.sh              # 移除 Worker 節點
├── start_usage_portal.sh    # 啟動使用情況監控面板
├── jhub.env                 # 環境變數設定檔（所有腳本共用）
├── Dockerfile               # Single-user 映像建構檔
├── lib/                     # 安裝腳本模組（00-150）
├── offline-images/          # 離線映像檔存放處
├── templates/               # 自訂登入頁面模板
├── image/                   # 前端素材（Logo、favicon）
├── usage_monitoring/        # 使用情況監控服務
│   ├── backend/            # FastAPI 後端
│   ├── frontend/           # 前端資源（舊版）
│   ├── docker-compose.yml  # PostgreSQL 設定
│   └── README.md           # 詳細文件
├── user_logs_monitor/       # 使用者日誌監控模組
├── user_resource_monitor/   # 使用者資源監控模組
└── port_mapper/             # Port 映射工具
```

## 環境變數參考（jhub.env）

主要環境變數說明：

| 變數名稱 | 說明 | 預設值 |
|---------|------|--------|
| `AUTH_MODE` | 認證模式（native/github/azuread/ubilink） | `native` |
| `ADMIN_USERS_CSV` | 管理員帳號（逗號分隔） | - |
| `SINGLEUSER_IMAGE` | Single-user 容器映像 | - |
| `PVC_SIZE` | 使用者儲存空間大小 | `128Gi` |
| `ENABLE_NGINX_PROXY` | 啟用 Nginx HTTPS 反向代理 | `false` |
| `NODEPORT_FALLBACK_PORT` | JupyterHub NodePort | `30080` |
| `USE_GPU_OPERATOR` | 啟用 GPU Operator | `false` |
| `ENABLE_IB` | 啟用 InfiniBand/RDMA | `false` |
| `ENABLE_MPI_OPERATOR` | 啟用 MPI Operator | `false` |
| `SHARED_STORAGE_ENABLED` | 啟用共享儲存 | `false` |

更多變數詳見 `jhub.env` 檔案內的註解。

## 維護操作

### 卸載 JupyterHub
```bash
sudo ./uninstall_jhub.sh
```
會清除 Helm release、PVC/PV、自訂靜態檔、portal、GPU/IB 元件等。

### 診斷工具
```bash
# 檢查 JupyterHub 狀態
sudo jhub-diag jhub

# 查看 Port-forward 狀態
sudo jhub-portforward status

# 啟動/停止 Port-forward
sudo jhub-portforward start
sudo jhub-portforward stop
```

### 更新 Single-user 映像
```bash
# 修改 Dockerfile 後建構
docker build -f Dockerfile -t myorg/pytorch-jhub:24.10 .

# 匯出離線映像
docker save myorg/pytorch-jhub:24.10 > myorg-pytorch-jhub.tar

# 在部署機上匯入
microk8s ctr images import myorg-pytorch-jhub.tar
```

### 查看叢集狀態
```bash
microk8s kubectl -n jhub get pods,svc
microk8s kubectl get nodes
```

## 防火牆設定

如需對外開放服務，請開放以下 port：

**使用 firewalld**：
```bash
firewall-cmd --add-port=30080/tcp --permanent  # NodePort
firewall-cmd --add-port=443/tcp --permanent    # HTTPS（若啟用）
firewall-cmd --add-port=29781/tcp --permanent  # Usage Portal
firewall-cmd --reload
```

**使用 ufw**：
```bash
ufw allow 30080/tcp
ufw allow 443/tcp
ufw allow 29781/tcp
```

## 常見問題

### Q: 如何檢查離線映像是否完整？
A: 安裝腳本會自動檢查 `offline-images/` 目錄，若缺少必要映像會提示。

### Q: 如何變更認證模式？
A: 編輯 `jhub.env`，更改 `AUTH_MODE` 與相關變數後，重新執行 `./install_jhub.sh`。

### Q: 使用者工作區儲存在哪裡？
A: 預設掛載 `/kubeflow_cephfs/jhub_storage/<username>` 到容器內的 `/workspace/storage`。

### Q: 如何調整資源配額？
A: 腳本會依硬體自動生成 profiles，如需手動調整可修改 `lib/70-profiles.sh`。

### Q: GPU 無法使用？
A: 檢查：
1. 主機是否安裝 NVIDIA 驅動
2. `jhub.env` 中 `USE_GPU_OPERATOR=true`
3. 查看 GPU Operator 狀態：`microk8s kubectl -n gpu-operator get pods`

### Q: 如何設定使用情況監控的 token？
A: 在 `usage_monitoring/.env` 中設定 `DASHBOARD_TOKEN=your_secret_token`。

## 技術細節

### 自動化模組（lib/）

安裝腳本依序執行以下模組：

1. **00-base.sh**：基礎函式與環境檢查
2. **10-cluster.sh**：MicroK8s 叢集設定
3. **20-portforward.sh**：Port-forward 工具
4. **30-environment.sh**：環境變數驗證
5. **40-images.sh**：離線映像匯入
6. **50-calico.sh**：Calico 網路設定
7. **60-dns-storage.sh**：DNS 與儲存設定
8. **70-profiles.sh**：資源 profiles 生成
9. **80-containerd.sh**：Containerd 設定
10. **90-values.sh**：Helm values 生成
11. **100-storage.sh**：PV/PVC 建立
12. **110-gpu.sh**：GPU Operator 安裝
13. **120-cuda.sh**：CUDA 冒煙測試
14. **130-nodeport.sh**：NodePort 與 Nginx 設定
15. **140-diag.sh**：診斷工具部署
16. **150-mpi.sh**：MPI Operator 與 RBAC

### 時區處理

所有時間戳在寫入資料庫時統一轉換為 UTC+8（Asia/Taipei），前端直接顯示資料庫值。

### 計費邏輯

預設費率：`4 USD / GPU / hour`，可透過環境變數 `GPU_RATE_PER_HOUR` 調整。

## 安全注意事項

⚠️ **重要提醒**：

1. 本專案常以 root 權限執行腳本，請在受控環境使用
2. 上傳至公開 GitHub 前，請務必移除敏感資訊：
   - SSH 私鑰（`id_rsa`）
   - TLS 憑證（`certs/`）
   - 環境變數中的密碼與 token
   - 內部 URL 與 IP 位址
3. 建議使用 `.gitignore` 排除：
   - `.venv/`
   - `offline-images/*.tar`
   - `*.log`
   - 資料庫檔案

## 版本資訊

- **JupyterHub**：4.2.0
- **PyTorch**：2.4.0（CUDA 12.4）
- **CUDA Toolkit**：12.4.1
- **Python**：3.11（Miniconda）
- **MicroK8s**：依系統自動選擇 stable channel

## 貢獻

歡迎提交 Issue 或 Pull Request 改進專案！

## 相關文件

- [Usage Portal 詳細文件](usage_monitoring/README.md)
- [JupyterHub 官方文件](https://jupyterhub.readthedocs.io/)
- [MicroK8s 文件](https://microk8s.io/docs)

---

**專案維護**：請定期備份 `jhub.env`、`values.yaml` 與使用者資料目錄。
