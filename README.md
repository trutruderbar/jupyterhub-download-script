# JupyterHub Enterprise Deployment System

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![MicroK8s](https://img.shields.io/badge/MicroK8s-1.30+-brightgreen.svg)](https://microk8s.io/)
[![JupyterHub](https://img.shields.io/badge/JupyterHub-4.2.0-orange.svg)](https://jupyter.org/hub)
[![CUDA](https://img.shields.io/badge/CUDA-12.4-76B900.svg)](https://developer.nvidia.com/cuda-toolkit)

一套完整的企業級 JupyterHub 部署解決方案，支援離線環境、多節點 GPU 集群、資源配額管理與使用情況追蹤。

## ✨ 核心特色

- 🚀 **一鍵部署** - 全自動化安裝腳本，從零到完整可用的 JupyterHub
- 📦 **離線部署** - 完整支援無網路環境，所有映像檔預先打包
- 🎮 **GPU 加速** - 自動配置 NVIDIA GPU Operator、CUDA 12.4、NCCL
- 🌐 **多節點集群** - 簡易的 Worker 節點新增/移除管理
- 🔐 **多種認證** - Native、GitHub OAuth、Azure AD、自訂 SSO
- 📊 **資源監控** - 即時監控 CPU/Memory/GPU 使用與成本統計
- ⚡ **InfiniBand/RDMA** - 支援高速網路加速分散式訓練
- 🎯 **動態配額** - 根據使用者配額動態生成可用的資源 Profile
- 🖥️ **豐富環境** - 內建桌面環境 (noVNC)、Code-Server、多語言 Kernel

## 📋 系統需求

### 作業系統
- Ubuntu 22.04 LTS / 24.04 LTS
- Debian 11+ 或其他 Debian 系發行版

### 硬體需求
- **CPU**: 4 核心以上（建議 8 核心）
- **記憶體**: 16GB 以上（建議 32GB）
- **磁碟空間**: 100GB 以上（用於系統、映像與使用者資料）
- **GPU**: (可選) NVIDIA GPU + 驅動 (建議 470+)
- **網路**: (可選) InfiniBand 或 RoCE 網卡

### 軟體依賴
部署腳本會自動安裝以下組件：
- MicroK8s (Kubernetes)
- Docker / containerd
- Helm 3
- Python 3.8+

## 🚀 快速開始

### 1. 準備離線映像檔 (可選)

如需離線部署，請將以下映像檔放入 `offline-images/` 目錄：

```bash
offline-images/
├── calico-v3.25.1-bundle.tar
├── k8s-hub-4.2.0.tar
├── configurable-http-proxy-4.6.3.tar
├── gpu-operator-bundle-v25.10.0.tar
├── jhub_24.10_3.tar  # Single-user image
└── ...
```

### 2. 配置環境變數

複製範例配置檔並根據需求編輯：

```bash
cp jhub.env.example jhub.env
vim jhub.env
```

關鍵配置項：

```bash
# 認證模式 (native/github/azuread/ubilink)
export AUTH_MODE=native
export ADMIN_USERS_CSV="admin1,admin2"

# Single-user 映像
export SINGLEUSER_IMAGE="myorg/pytorch-jhub:24.10"

# GPU 支援
export USE_GPU_OPERATOR=true

# InfiniBand 支援
export ENABLE_IB=true

# 資源配額限制
export ENABLE_USAGE_LIMIT_ENFORCER=true
export USAGE_PORTAL_URL="http://your-portal-ip:29781"
```

### 3. 執行部署

```bash
sudo ./install_jhub.sh
```

部署過程約 10-15 分鐘，腳本會自動：
1. 檢查系統環境 (OS、Kernel、GPU、網卡)
2. 安裝 MicroK8s 與必要組件
3. 匯入離線映像檔
4. 部署 Calico 網路、DNS、儲存
5. 安裝 GPU Operator (若啟用)
6. 部署 JupyterHub
7. 配置 Nginx 反向代理 (若啟用)

### 4. 存取 JupyterHub

部署完成後會顯示存取資訊：

```
✅ JupyterHub 部署完成！

存取方式：
  - NodePort: http://<node-ip>:30080
  - HTTPS:    https://<domain>:443 (若啟用 Nginx)

管理員帳號: <ADMIN_USER>
```

### 5. 啟動資源監控面板

```bash
./start_usage_portal.sh
```

瀏覽器開啟 `http://<host-ip>:29781` 即可查看：
- 使用者資源使用歷史記錄
- CPU/Memory/GPU 時數統計
- 成本估算與帳務報表
- 即時 Pod 監控與管理

### 6. 啟動使用者資源儀表板

```bash
./start_user_monitor.sh
```

提供使用者查看自己的配額與當前使用量 (CPU/Memory/GPU)。

## 🏗️ 專案架構

```
.
├── install_jhub.sh              # 主部署腳本
├── uninstall_jhub.sh            # 卸載腳本
├── add_node.sh                  # 新增 Worker 節點
├── del_node.sh                  # 移除 Worker 節點
├── start_usage_portal.sh        # 啟動使用情況監控
├── start_user_monitor.sh        # 啟動使用者資源儀表板
├── healthcheck_selfheal.sh      # 健康檢查與自我修復
├── jhub.env.example             # 環境變數範例
├── Dockerfile                   # Single-user 映像建構檔
│
├── lib/                         # 安裝模組
│   ├── 00-base.sh              # 基礎函式
│   ├── 10-cluster.sh           # MicroK8s 叢集設定
│   ├── 20-portforward.sh       # Port-forward 工具
│   ├── 30-environment.sh       # 環境變數驗證
│   ├── 40-images.sh            # 離線映像匯入
│   ├── 50-calico.sh            # Calico 網路
│   ├── 60-dns-storage.sh       # DNS 與儲存
│   ├── 70-profiles.sh          # 資源 Profile 生成
│   ├── 80-containerd.sh        # Containerd 配置
│   ├── 90-values.sh            # Helm values 生成
│   ├── 100-storage.sh          # PV/PVC 建立
│   ├── 110-gpu.sh              # GPU Operator
│   ├── 120-cuda.sh             # CUDA 冒煙測試
│   ├── 130-nodeport.sh         # NodePort 與 Nginx
│   ├── 140-diag.sh             # 診斷工具
│   └── 150-mpi.sh              # MPI 支援
│
├── offline-images/              # 離線映像檔 (需自行準備)
│
├── templates/                   # 自訂模板
│   ├── login.html              # 登入頁面
│   └── nic-cluster-policy.yaml # InfiniBand 網路策略
│
├── image/                       # 前端資源
│   ├── login-logo.png
│   ├── jupyter.png
│   └── favicon.ico
│
├── usage_monitoring/            # 使用情況監控服務
│   ├── backend/                # FastAPI 後端
│   ├── frontend/               # 前端 (舊版)
│   ├── docker-compose.yml      # PostgreSQL
│   └── .env.example            # 配置範例
│
├── user_resource_monitor/       # 使用者資源儀表板
│   ├── backend/                # FastAPI 後端
│   └── frontend/               # React 前端
│
└── port_mapper/                 # Port 映射工具
```

## 🔐 認證模式

### Native 認證 (預設)

```bash
export AUTH_MODE=native
export ADMIN_USERS_CSV="user1,user2"
```

使用 JupyterHub 內建的 NativeAuthenticator，使用者首次登入時自動創建帳號並授權。

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
export AZUREAD_TENANT_ID="your_tenant_id"
export AZUREAD_CALLBACK_URL="https://your-hub.example.com/hub/oauth_callback"
```

### 自訂 SSO (Cookie-based)

```bash
export AUTH_MODE=ubilink
export UBILINK_AUTH_ME_URL="https://your-sso.example.com/api/auth/me"
export UBILINK_LOGIN_URL="https://your-sso.example.com/login"
```

## 📊 資源配額與動態 Profile

本系統支援與外部 Usage Portal 整合，根據每位使用者的配額動態生成可選的資源 Profile。

### 啟用動態配額

```bash
export ENABLE_USAGE_LIMIT_ENFORCER=true
export USAGE_PORTAL_URL="http://your-portal:29781"
```

### Usage Portal API

系統會從以下 API 端點獲取使用者配額：

```
GET /users/{username}/limits
```

回應格式：

```json
{
  "cpu_limit_cores": 64,
  "memory_limit_gib": 256,
  "gpu_limit": 8,
  "usage": {
    "cpu_cores": 16.5,
    "memory_gib": 64.0,
    "gpu": 2
  }
}
```

系統會根據使用者配額自動生成符合限制的 Profile 選項 (CPU-only、1×GPU、2×GPU、4×GPU、8×GPU)。

## 🎨 Single-User 映像功能

本專案提供的 Dockerfile 包含以下功能：

### 開發環境
- **桌面環境**: XFCE + noVNC (可在瀏覽器中使用完整桌面)
- **Code-Server**: 瀏覽器版 VS Code
- **JupyterLab**: 最新版 JupyterLab 與擴充套件

### 多語言 Kernel
- Python 3.11 (Miniconda)
- R 4.x
- Julia 1.x
- Go 1.x
- Rust
- JavaScript (Node.js)
- .NET Interactive
- Scala
- GNU Octave
- Bash

### GPU 與深度學習
- PyTorch 2.4.0 (CUDA 12.4)
- CuPy
- NCCL 2.x
- CUDA Toolkit 12.4.1
- NVDashboard (GPU 監控)

### 開發工具
- Git、Git LFS
- Language Server Protocol (LSP)
- Code Formatter
- Dask (分散式計算)
- Resource Monitor

### 建構自訂映像

```bash
# 建構映像
docker build -f Dockerfile -t myorg/pytorch-jhub:24.10 .

# 匯出為離線映像
docker save myorg/pytorch-jhub:24.10 -o offline-images/jhub_24.10_3.tar

# 在部署機上匯入
microk8s ctr images import offline-images/jhub_24.10_3.tar
```

## 🌐 多節點管理

### 新增 Worker 節點

```bash
sudo ./add_node.sh
```

互動式輸入：
- Worker 節點 IP
- SSH 使用者名稱
- SSH 密碼

腳本會自動：
1. SSH 連線到 Worker 節點
2. 安裝 MicroK8s
3. 加入叢集
4. 同步離線映像檔

### 移除 Worker 節點

```bash
sudo ./del_node.sh
```

互動式選擇要移除的節點，可選：
- Cordon (標記不可調度)
- Drain (驅逐所有 Pods)
- 遠端清理 MicroK8s

## 🛠️ 維護與診斷

### 檢查 JupyterHub 狀態

```bash
sudo jhub-diag jhub
```

### Port-forward 管理

```bash
# 查看狀態
sudo jhub-portforward status

# 啟動 Port-forward
sudo jhub-portforward start

# 停止 Port-forward
sudo jhub-portforward stop
```

### 查看叢集狀態

```bash
# 查看所有節點
microk8s kubectl get nodes

# 查看 JupyterHub Pods
microk8s kubectl -n jhub get pods,svc

# 查看使用者 Pods
microk8s kubectl -n jhub get pods -l component=singleuser-server
```

### 查看 GPU Operator 狀態

```bash
microk8s kubectl -n gpu-operator get pods
```

### 卸載 JupyterHub

```bash
sudo ./uninstall_jhub.sh
```

此腳本會清除：
- Helm release
- JupyterHub namespace
- PVC/PV (使用者資料會保留在主機上)
- GPU Operator (若啟用)
- Network Operator (若啟用)
- 自訂靜態檔案

## 🔥 防火牆設定

如需對外開放服務，請開放以下 Port：

### 使用 firewalld

```bash
firewall-cmd --add-port=30080/tcp --permanent  # JupyterHub NodePort
firewall-cmd --add-port=443/tcp --permanent    # HTTPS (若啟用)
firewall-cmd --add-port=29781/tcp --permanent  # Usage Portal
firewall-cmd --reload
```

### 使用 ufw

```bash
ufw allow 30080/tcp
ufw allow 443/tcp
ufw allow 29781/tcp
```

## ⚙️ 進階配置

### 啟用 HTTPS (Nginx 反向代理)

```bash
export ENABLE_NGINX_PROXY=true
export NGINX_PROXY_SERVER_NAME="jhub.example.com"
export NGINX_PROXY_CERT_FILE=/path/to/cert.crt
export NGINX_PROXY_KEY_FILE=/path/to/cert.key
```

### 啟用 InfiniBand/RDMA

```bash
export ENABLE_IB=true
export IB_RESOURCE_NAME="rdma/rdma_shared_device"
export IB_RESOURCE_COUNT=1
```

### 自訂儲存路徑

```bash
export SHARED_STORAGE_ENABLED=true
export SHARED_STORAGE_PATH="/your/cephfs/path"
export PVC_SIZE="128Gi"
```

### 閒置自動關閉 (預設關閉)

```bash
export ENABLE_IDLE_CULLER=true
export IDLE_TIMEOUT=3600  # 秒
```

## 📈 使用情況監控

### 啟動 Usage Portal

```bash
cd usage_monitoring
cp .env.example .env
# 編輯 .env 配置資料庫連線等

cd ..
./start_usage_portal.sh
```

### 功能特色

- **自動記錄**: 每 30 秒掃描 Kubernetes Pods 並記錄 Session
- **PostgreSQL 儲存**: 完整記錄容器起訖時間、資源使用
- **即時監控**: Web UI 即時顯示所有運行中的 Pods
- **Pod 管理**: 可在 Web 介面直接刪除 Pods
- **成本統計**: 自動計算 GPU/CPU 時數與費用
- **MySQL 同步**: 可選將資料同步至外部 MySQL
- **Token 保護**: 可設定 Bearer Token 保護 API

### API 端點

```
GET  /sessions              # 查詢所有 Sessions
GET  /sessions/{id}         # 查詢特定 Session
POST /sessions              # 創建 Session
PUT  /sessions/{id}/end     # 結束 Session
GET  /users/{username}/limits  # 查詢使用者配額
```

## 🐛 常見問題

### Q: 如何檢查離線映像檔是否完整？

A: 執行 `./install_jhub.sh` 時腳本會自動檢查 `offline-images/` 目錄，若缺少必要映像會提示。

### Q: GPU 無法使用怎麼辦？

A: 檢查以下項目：
1. 主機是否已安裝 NVIDIA 驅動 (`nvidia-smi`)
2. `jhub.env` 中 `USE_GPU_OPERATOR=true`
3. 查看 GPU Operator 狀態: `microk8s kubectl -n gpu-operator get pods`
4. 檢查 Node 是否有 GPU 標籤: `microk8s kubectl get nodes -o json | grep nvidia.com/gpu`

### Q: 使用者資料儲存在哪裡？

A: 預設掛載路徑：
- 主機路徑: `$SHARED_STORAGE_PATH/<username>`
- 容器內路徑: `/workspace/storage`

### Q: 如何調整資源配額？

A:
- 靜態方式: 編輯 `lib/70-profiles.sh` 修改 Profile 定義
- 動態方式: 啟用 `ENABLE_USAGE_LIMIT_ENFORCER` 並整合 Usage Portal API

### Q: 如何變更認證模式？

A: 編輯 `jhub.env`，修改 `AUTH_MODE` 與相關變數後，重新執行 `./install_jhub.sh`。

### Q: 部署失敗怎麼辦？

A:
1. 查看部署日誌找出錯誤訊息
2. 檢查 MicroK8s 狀態: `microk8s status`
3. 檢查 Pods 狀態: `microk8s kubectl get pods -A`
4. 執行 `./uninstall_jhub.sh` 清理後重新部署

### Q: 如何更新 Single-user 映像？

A:
1. 修改 Dockerfile
2. 建構新映像: `docker build -t myorg/pytorch-jhub:new-version .`
3. 匯出: `docker save myorg/pytorch-jhub:new-version > offline-images/new-version.tar`
4. 在部署機匯入: `microk8s ctr images import offline-images/new-version.tar`
5. 更新 `jhub.env` 中的 `SINGLEUSER_IMAGE`
6. 重新部署: `./install_jhub.sh`

## 🔒 安全注意事項

⚠️ **重要提醒**：

1. 本專案設計用於**內部受控環境**，部分腳本需要 root 權限
2. 上傳至公開 GitHub 前，請務必移除敏感資訊：
   - SSH 私鑰 (`id_rsa`, `*.pem`)
   - TLS 憑證 (`*.crt`, `*.key`)
   - OAuth Client Secret
   - 內部 IP 位址、網域名稱
   - 資料庫密碼
3. 建議使用 `.gitignore` 排除：
   - `offline-images/*.tar`
   - `usage_monitoring/.venv/`
   - `*.log`
   - `.env`
   - `id_rsa*`
   - `certs/`
4. 生產環境建議啟用：
   - HTTPS (Nginx 反向代理)
   - 強密碼策略
   - 定期備份使用者資料
   - 資源配額限制

## 📦 技術棧

| 組件 | 版本 |
|------|------|
| JupyterHub | 4.2.0 |
| MicroK8s | 1.30+ |
| Calico | 3.25.1 |
| GPU Operator | 25.10.0 |
| NVIDIA Driver | 580.65.06 |
| CUDA Toolkit | 12.4.1 |
| PyTorch | 2.4.0 |
| Python | 3.11 (Miniconda) |
| FastAPI | 0.115+ |
| PostgreSQL | 13+ |

## 🤝 貢獻

歡迎提交 Issue 或 Pull Request 改進專案！

### 開發流程

1. Fork 本專案
2. 創建 Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit 變更 (`git commit -m 'Add some AmazingFeature'`)
4. Push 到 Branch (`git push origin feature/AmazingFeature`)
5. 開啟 Pull Request

## 📄 授權

本專案採用 MIT 授權條款 - 詳見 [LICENSE](LICENSE) 檔案。

## 📚 相關資源

- [JupyterHub 官方文件](https://jupyterhub.readthedocs.io/)
- [MicroK8s 文件](https://microk8s.io/docs)
- [Kubernetes 文件](https://kubernetes.io/docs/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [Calico 網路](https://docs.tigera.io/calico/latest/)

## 👥 維護者

請參考貴組織的維護者清單。

## 🙏 致謝

感謝所有開源專案的貢獻者，讓這個專案得以實現。

---

**專案維護提醒**：
- 定期備份 `jhub.env` 與使用者資料目錄
- 監控磁碟空間使用情況
- 定期更新系統與安全性補丁
- 檢查 JupyterHub 與相關組件的新版本
