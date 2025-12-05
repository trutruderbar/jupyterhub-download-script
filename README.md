# install_jhub_oauth_local

針對 Ubilink 內部環境打造的一套「JupyterHub 離線部署 + 資源監控」工具組。專案同時涵蓋

- **JupyterHub 部署腳本**：自動偵測 OS / kernel / GPU、匯入離線映像、產生 Helm values 並安裝/移除整個 Hub，且會建立登入入口與診斷工具。
- **MicroK8s 節點管理**：透過互動式腳本將 worker 節點加入或移出 HA 叢集（含遠端清理與映像同步）。
- **使用情況儀表板**：`usage_monitoring/` 提供 FastAPI + PostgreSQL 的後台（內含 30 秒一次的 auto recorder），並可選配每 30 分鐘同步 PostgreSQL → MySQL（`jupyterhub.pod_report`），整合原有 `jhub_usage_dashboard.py` 加上帳務統計、pod 管理、API 與手動「立即同步」功能。
- **單一使用者映像**：`Dockerfile` 負責打造包含桌面、Code-Server、多種 Kernel 的 single-user image，搭配 `offline-images/` 可在無網路環境側載。

> **注意**：本專案常以 root 權限執行腳本，請在受控環境使用，並先備份重要資料。

---

## 專案結構與用途

| 路徑/檔案 | 功能摘要 |
| --- | --- |
| `install_jhub.sh` | 一鍵部署腳本，依序執行 `lib/` 模組（00–140）：檢查硬體、匯入 `offline-images/`、設定 MicroK8s/Calico/HostPath、寫入 `values.yaml`、部署 Helm、建立 portal/NodePort/port-forward 工具。 |
| `uninstall_jhub.sh` | 解除安裝腳本，會清除 Helm release、PVC/PV、自訂靜態檔、portal、port-forward 工具、GPU/IB 元件等，並留下診斷 log。 |
| `add_node.sh` / `del_node.sh` | 對 MicroK8s HA 叢集新增/移除 worker：整合 `sshpass`、`rsync`、`microk8s add-node/remove-node` 並可同步離線映像。 |
| `start_usage_portal.sh` | 啟動「Usage Portal」：在 `usage_monitoring/.venv` 建立虛擬環境、以 docker compose 啟動 Postgres，設定 `.env`，最後執行 FastAPI（`usage_monitoring/backend/app`）。 |
| `usage_monitoring/` | Usage Portal 後端/前端原始碼與設定：`backend/app`（FastAPI + SQLAlchemy + Jinja2 + kubectl 整合）、`frontend/`（舊版靜態 UI）、`.env.example`、`docker-compose.yml`、`README.md`。 |
| `Dockerfile` | 以 `pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime` 為基底，自動安裝桌面環境、常用語言/Kernel、Remote Desktop、Code-Server、R/Julia/Go/Rust kernel 等，用於生成單一 user image。 |
| `offline-images/` | JupyterHub、Calico、GPU Operator 等 tarball，供沒有網路的環境匯入。 |
| `templates/login.html` | 自訂 JupyterHub 登入頁面（取代 chart 預設 UI，含 OAuth 登入按鈕樣式）。 |
| `image/` | 前端素材，如 Ubilink 標誌、favicon。 |
| `certs/` | 內含 `jhub.crt`, `jhub.key` 等 TLS 憑證，供 portal 與 nginx 反向代理使用。 |
| `Storage/` | 儲存 PV/PVC YAML 與初始化檔案，確保 Hub 日誌、使用者資料可掛載到本機目錄。 |
| `portal-config.js` | 入口頁面會載入的 JSON 物件，紀錄 NodePort、port-forward、Admin 服務 URL 以及啟動狀態。 |
| `ublink-all-tool-pytorch-1.0.tar` | 事先打包好的 single-user image，可使用 `microk8s ctr images import` 直接匯入。 |
| `fix_cpu_mode.py` | 在啟動容器前檢查 GPU，並設定 `CUDA_VISIBLE_DEVICES` 等環境變數以支援 CPU/GPU 模式切換。 |

---

## 需求與建議環境

- Ubuntu 22.04 / 24.04（其他 Linux 亦可，但腳本主要對應 Debian/Ubuntu 發行版）
- Root 權限（安裝腳本會操作 `snap`, `microk8s`, `helm`, `iptables` 等）
- Docker / Docker Compose Plugin
- Python 3.8+
- 充足磁碟空間（離線映像與虛擬環境可能佔用數十 GB）

---

## 快速開始

### 1. 部署 JupyterHub

先確認 `jhub.env` 內的值（已預填 admin_user、singleuser image、NodePort、GPU/IB、TLS 路徑等；需客製時直接改檔，無須再手動 export）。

```bash
sudo ./install_jhub.sh
```

腳本會自動：

1. 讀取 `lib/*.sh` 模組，檢查 OS、kernel、GPU/NIC、hostname 等。
2. 檢驗 `offline-images/` 是否具備所需 tar，若缺少會提示。
3. 安裝/設定 MicroK8s（含 HA、Calico、HostPath、DNS）。
4. 匯入離線映像、安裝 GPU / Network Operator（視環境自動啟用）。
5. 產生 `values.yaml`，部署 `jupyterhub/jupyterhub` Helm chart。
6. 建立 admin NodePort、nginx portal、port-forward 工具與診斷腳本。

執行完後：

- 安裝結束會在終端輸出摘要：ACCESS_URL、admin_users、認證模式、PVC/SingleUser 映像、掛載路徑 (`/kubeflow_cephfs/jhub_storage/<user> → /workspace/storage`、`/var/log/jupyterhub → /var/log/jupyter`)、pf/diag 工具、NodePort、叢集節點與 Adminuser API（免登入 NodePort 或 port-forward）。
- `kubectl -n jhub get pods,svc` 可檢查 Hub、Proxy、User-scheduler 以及 GPU/IB 元件。
- Portal 會顯示 NodePort、port-forward、admin 服務 URL，方便分享給內部使用者。
- `values.yaml`、`portal-config.js` 與 `J_log.txt` 會記錄部署過程，便於日後參考。

> **移除**：如需卸載，執行 `sudo ./uninstall_jhub.sh`，會自動刪除 Helm release、PVC、對應 Kubernetes 物件並回收 portal。

### 2. 啟動 Usage Portal

```bash
./start_usage_portal.sh
```

流程：

1. 在 `usage_monitoring/` 複製 `.env.example` 為 `.env`（若尚未存在）。
2. `docker compose up -d` 啟動 PostgreSQL（預設 5433 -> container 5432）。
3. 建立/啟用 `usage_monitoring/.venv`，安裝 `backend/requirements.txt`。
4. 於 `backend/` 執行 `python -m app.main`，預設綁定 `0.0.0.0:29781`。

瀏覽器前往 `http://<host>:29781/` 即可切換「Usage Records」與「JupyterHub Pods」兩個分頁，支援：

- 即時 pod 資源監控與刪除操作：UI 會呼叫 `/api/usage`、`/api/pods/{pod}/action`，底層以 `KUBECTL_BIN` 指令查詢/刪除。
- 使用者/部門/成本統計：整合 PostgreSQL 的 `users`、`container_sessions`，自動計算 GPU/CPU 時數與計費。
- Session timeline / 查詢：可依使用者、關鍵字或時段篩選，並即時更新卡片數值。
- Bearer token 保護：設定 `.env` 內 `DASHBOARD_TOKEN` 即可要求 UI 及外部 API 呼叫帶入 `Authorization: Bearer`。
- 所有時間戳在寫入資料庫時就轉換為 UTC+8（Asia/Taipei），前端直接顯示資料庫值，不再額外偏移。
- Auto recorder 與跨庫同步：預設 `AUTO_RECORD_INTERVAL=30` 秒從 K8s Pods 寫入 PostgreSQL `container_sessions`，同時 `POD_REPORT_SYNC_INTERVAL_SECONDS=1800` 會每 30 分鐘將整理過的 session 投影到遠端 MySQL `jupyterhub.pod_report`，必要時可透過 `.env` 調整頻率或停用。
- 手動「立即同步」：Portal 頂欄新增按鈕，可無視 30 分鐘排程立即觸發 `/api/pod-report-sync`，寫入成功筆數會顯示於狀態文字。
- Pod 卡片選取優化：Pods 分頁採整卡片點選 + 動態 highlighting，方便大量選取後執行「關閉選取的 Pods」，並支援鍵盤操作（Enter/Space 切換）。
- 容器掛載路徑：主機 `/kubeflow_cephfs/jhub_storage/<username>` 掛載至容器 `/workspace/storage`；`/var/log/jupyterhub` 繼續提供日誌掛載。

### 3. 管理 MicroK8s 節點

- `sudo ./add_node.sh`：互動式輸入 worker IP/帳號/密碼/port，腳本會：
  - 檢查本機 MicroK8s channel、HA 設定。
  - 在遠端安裝 MicroK8s、同步 GPU toolkit（如設定）。
  - 先清除遠端殘留 cluster-info/backend 再 join，避免舊叢集資訊卡住；若啟用 IB 會預載 rdma_cm/ib_umad 等模組。
  - 透過 `microk8s add-node --worker` 取得 join 指令並於遠端執行。
  - 等待新節點 Ready，並可選擇匯入 `offline-images/`。

- `sudo ./del_node.sh`：輸入 node 名稱後，可選擇 cordon/drain、`microk8s remove-node`，以及遠端 SSH 清除 MicroK8s/Snap。

---

## 啟用 SSO / OAuth

`install_jhub.sh` 依 `AUTH_MODE` 決定要載入哪種驗證流程，對應邏輯在 `lib/30-environment.sh:validate_auth_config` 與 `lib/90-values.sh:_write_values_yaml`。預設為 `native`（內建帳號密碼）。若要使用 SSO，請在執行安裝腳本前 export 所需環境變數：

| 模式 | 必填環境變數 | 選填 / 備註 |
| --- | --- | --- |
| `AUTH_MODE=github` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_CALLBACK_URL` | `GITHUB_ALLOWED_USERS`（CSV 使用者白名單）、`GITHUB_ALLOWED_ORGS`、`GITHUB_SCOPES`。 |
| `AUTH_MODE=azuread` | `AZUREAD_CLIENT_ID`, `AZUREAD_CLIENT_SECRET`, `AZUREAD_CALLBACK_URL` | `AZUREAD_TENANT_ID`（未設定則為 `common`）、`AZUREAD_ALLOWED_USERS`, `AZUREAD_ALLOWED_TENANTS`, `AZUREAD_SCOPES`, `AZUREAD_LOGIN_SERVICE`。 |
| `AUTH_MODE=ubilink` | `UBILINK_AUTH_ME_URL`（驗證 API） | `UBILINK_LOGIN_URL`（外部登入頁）、`UBILINK_LOGIN_SERVICE`（登入按鈕文字）、`UBILINK_HTTP_TIMEOUT_SECONDS`。需由 upstream SSO 於 Cookie 中提供驗證資訊。 |
| `AUTH_MODE=native` | *(無)* | 可透過 `ALLOWED_USERS_CSV` 匯入白名單；登入 UI 仍會使用客製化樣式。 |

範例：啟用 GitHub OAuth

```bash
export AUTH_MODE=github
export GITHUB_CLIENT_ID="xxx"
export GITHUB_CLIENT_SECRET="yyy"
export GITHUB_CALLBACK_URL="https://hub.example.com/hub/oauth_callback"
sudo ./install_jhub.sh
```

安裝完成後，登入頁會依模式顯示對應的按鈕與文字（`templates/login.html` 透過 `login_service` 變數渲染），而 `values.yaml` 中會自動填入 OAuthenticator 設定或 Ubilink 自訂 authenticator 代碼。若需切換模式，可重新 export 環境變數並執行 `./install_jhub.sh` 以更新 Helm release。

### 全域參數檔（jhub.env）

為了讓 `install_jhub.sh`、`add_node.sh`、`del_node.sh`、`uninstall_jhub.sh` 等腳本共用同組設定，專案根目錄提供 `jhub.env`。檔案內容採 `export VAR=value` 格式，腳本在啟動時會自動載入並匯出所有變數，因此不必每次手動 `export`。若想改用其他檔案，可設定 `JHUB_ENV_FILE=/path/to/other.env` 再執行腳本。

目前 `jhub.env` 已補齊主要參數：管理員帳號 (`ADMIN_USER`/`ADMIN_USERS_CSV`)、Helm 版本/timeout、NodePort/port-forward、單一使用者映像與儲存、GPU 驅動模式 (`GPU_DRIVER_MODE=host`)、GPU Operator 版本、IB/RDMA、TLS 憑證等。只需依環境調整檔案，不需手動 `export`。

範例：

```bash
cat jhub.env
export AUTH_MODE=ubilink
export UBILINK_AUTH_ME_URL="https://billing.ubilink.ai/api/auth/me"
export ENABLE_NGINX_PROXY=true
export NGINX_PROXY_SERVER_NAME="https://jhubserver.ubilink.ai 10.2.2.112 $(hostname -f)"
# ...

sudo ./install_jhub.sh        # 會自動載入 jhub.env
sudo ./add_node.sh            # 其他腳本也會共用同一組參數
```

`start_usage_portal.sh` 也會載入這份檔案，確保整套環境使用一致的變數。

---

## 建立/更新使用者映像

1. 依需求修改 `Dockerfile`（例如新增套件或設定 `SINGLEUSER_IMAGE`）。
2. 建置並 tag：

```bash
docker build -f Dockerfile -t myorg/pytorch-jhub:24.10 .
# 若需離線散佈，可自行決定 tar 名稱
docker save myorg/pytorch-jhub:24.10 > myorg-pytorch-jhub.tar
```

3. 將產出的 image 推送到 registry，或將 tar 複製到部署機後使用 `microk8s ctr images import myorg-pytorch-jhub.tar`/`docker load` 匯入供 `install_jhub.sh` 使用。

`Dockerfile` 已整合：

- XFCE + noVNC + jupyter-remote-desktop-proxy（提供「Desktop」Launcher）。
- Code-Server、JupyterLab 擴充（Git、Link Share、Resource Usage…）。
- 多語言 kernel：Python、R (IRkernel)、Julia、Go、Rust、IJavascript。
- 其他工具：cupy、ucx-py、jupyterlab-nvdashboard 等。

---

## 常見資料夾

- `lib/`：`install_jhub.sh` 所載入的模組（base 設定、cluster、port-forward、images、calico、profiles、containerd、storage、GPU/CUDA、nodeport、診斷…）。若要客製流程可在此調整。
- `offline-images/`：若要更新 chart 或 GPU Operator 版本，請重新下載/打包對應 tar 置於此處。
- `templates/` + `image/`：自訂登入頁與 Logo，安裝時會複製到 Hub 的 `custom` 資料夾。
- `usage_monitoring/frontend/`：早期的前端原型，現行版主要由 backend/templates 提供 UI，但此目錄可保留設計草稿。
- `.venv`：由 `start_usage_portal.sh` 建立，僅供 Usage Portal 使用；想要重置可刪除後重新執行腳本。
- `certs/`：儲存 Hub/portal 使用的 TLS 憑證；如需更新，請替換檔案並重新部署。
- `Storage/`：包含 PV/PVC 樣板與預設資料夾結構，可在重新安裝時直接沿用舊資料。

---

## JupyterHub 內部功能亮點

- **自訂登入與 OAuth 混合登入**：`templates/login.html`、`image/`、`lib/90-values.sh` 會把自訂樣式部署到 Hub 的 `custom/` 目錄，並根據 `UBILINK_LOGIN_SERVICE`、`CUSTOM_LOGO_PATH` 等環境變數顯示 Ubilink 品牌、OAuth 按鈕、提示文字。
- **Portal 與 NodePort 管理**：`lib/130-nodeport.sh`、`lib/30-environment.sh` 會建立 admin user 專用 NodePort（免登入即可存取）、nginx portal 以及 port-forward 工具。`portal-config.js` 紀錄 Hub NodePort、port-forward URL、Admin 服務 URL、啟動狀態，方便前端入口頁載入。
- **資源與儲存自動化**：`lib/60-dns-storage.sh`、`lib/100-storage.sh` 自動建立 hostPath PV/PVC、ResourceQuota、NetworkPolicy、TLS Secret 與網路政策，並且會檢查 `Storage/` 目錄備份的 PV YAML，確保 Hub 日誌與使用者工作區有固定路徑。
- **GPU / InfiniBand 支援**：`lib/110-gpu.sh`, `lib/120-cuda.sh` 搭配 `offline-images/` 的 GPU Operator bundle，自動部署 nvidia-device-plugin、dcgm-exporter、validator、CUDA smoke test，並於 singleuser image 寫入 GPU kernel module 與 CUDA 變數，使 Notebook 能識別 GPU 與 IB 設備。
- **診斷與維運工具**：`lib/140-diag.sh` 會部署診斷腳本與 API proxy 範例；Usage Portal (`start_usage_portal.sh`) 提供健康檢查、pod 刪除、資源用量查詢等 API，讓管理員即使沒有直接登入 K8s 也能從網頁維護叢集。
- **安裝記錄與復原資訊**：每次執行 `install_jhub.sh` 會在 `J_log.txt` 中記錄時間戳與步驟結果，若失敗可根據 log 快速定位，並且 `lib/40-images.sh` 負責記錄映像匯入狀態，以便復原或重新嘗試。

---

## 開發與貢獻建議

1. **版本控管**：目前目錄下尚未初始化 Git，如需 push 至 GitHub，建議 `git init` 後建立 `.gitignore`（可排除 `.venv/`, `offline-images/*.tar`, 自行產生的映像 tar 等大檔）。
2. **設定同步**：`install_jhub.sh` 會寫入多個環境變數（例如 `CUSTOM_STATIC_*`, `PF_*`），若要切換登入頁、NodePort 或 portal URL，請於 `lib/00-base.sh` / `lib/90-values.sh` 調整。
3. **安全性**：`id_rsa`、`portal-config.js` 等可能含敏感資訊，上傳至 GitHub 前務必清查、更換密鑰或改用 vault。
4. **測試流程**：預設測試方式為實際在 staging 機器跑 `install_jhub.sh`、`start_usage_portal.sh`。若要 CI 化，可將離線 tar 轉為 registry pull 或改寫成 Kind + GitHub Actions。

---

## 附錄：相關文件

- `usage_monitoring/README.md`：Usage Portal 更細部的 API/架構解說。

如需更多細節或要擴充功能，歡迎參考上述檔案或直接檢視各腳本內的註解。若要在 GitHub 上對外發布，建議補充授權條款、移除內部專屬資訊並更新 screenshots。祝使用順利！
