# Usage Portal

單一 Python 服務整合了容器使用紀錄（PostgreSQL 儲存）與原有的 `jhub_usage_dashboard.py`。介面採用分頁設計，可快速切換「資源使用紀錄」與「JupyterHub Pods」兩個視圖，並於同一頁面呈現帳務統計、Pod 詳細資訊與刪除操作。

## 架構

- **PostgreSQL**：紀錄使用者資訊與每一次 container session。僅需透過 docker compose 起庫。
- **FastAPI 服務**：單一 `python3` 程式兼具 API 與前端，採 Jinja2 + 原生 JS/CSS 呈現儀表板。整合 `bin/jhub_usage_dashboard.py` 的命令列邏輯並保留 `/api/usage`、`/api/pods/{name}/action` 等端點。
- **前端**：由 FastAPI 直接提供靜態資源與模板，兩個分頁分別對接 Postgres 資料與 kubectl 指標，並具備自動更新、搜尋/排序等能力。
- **自動監聽**：服務啟動後會有背景執行緒定期呼叫 `kubectl`，自動建立/結束 `container_sessions`，並以固定 `4 USD / GPU / hour` 写入計費資料，可透過環境變數停用或調整頻率。
- **MySQL pod_report 同步**：可選的背景工作會每 30 分鐘讀取本地 PostgreSQL 的 container session 紀錄，重建 `jupyterhub.pod_report`（透過 `mysql-connector-python` 直連 MySQL），讓外部系統能即時取得最新的 CPU/Memory/GPU/LifeTime 等資料。

## 快速啟動

### 一鍵啟動（建議）

在儲存庫主目錄執行：

```bash
./start_usage_portal.sh
```

腳本會自動：

1. 於 `usage_monitoring/` 內建立 `.env`（如不存在則從 `.env.example` 複製）。
2. 啟動 docker compose 中的 PostgreSQL。
3. 建立 / 重用 `.venv` 並安裝 `backend/requirements.txt`。
4. 以 `python -m app.main` 啟動 FastAPI 服務（預設 0.0.0.0:29781）。

瀏覽器開啟 `http://<主機>:29781/` 即可看到含分頁的管理儀表板。

### 手動模式

若想手動跑每個步驟，可參考：

```bash
cd usage_monitoring
cp .env.example .env  # 視需要調整
docker compose up -d
python3 -m venv .venv && source .venv/bin/activate
pip install -r backend/requirements.txt
cd backend
python3 -m app.main
```

> 若設定 `DASHBOARD_TOKEN`，瀏覽器 UI 會自動帶上 Bearer token 存取 `/api/*`，其餘 API 也可使用自訂腳本呼叫。

## API 一覽

| Method | Path | 說明 |
| --- | --- | --- |
| `POST` | `/users` | 建立使用者（username、email、department）。 |
| `GET` | `/users` | 取得全部使用者。 |
| `POST` | `/sessions` | 新增 container session 與資源需求。 |
| `PATCH` | `/sessions/{id}` | 更新狀態、結束時間或實際用量。 |
| `GET` | `/sessions?user_id=` | 依使用者過濾 session。 |
| `GET` | `/billing/summary` | 取得每位使用者的總時數與估計成本。 |
| `GET` | `/api/usage` | (JupyterHub) 即時 pod/使用者彙整。 |
| `POST` | `/api/pods/{pod}/action` | 目前支援 `{"action":"delete"}` 刪除單一 pod。 |
| `GET` | `/health` | 健康檢查。 |

所有時間戳在寫入資料庫時即轉換為 UTC+8（Asia/Taipei），前端直接使用資料庫值；成本由 `cost_rate_per_hour × 使用時數` 推算並在前端顯示。

## 設定

`.env.example` 提供常用設定：

- `APP_HOST` / `APP_PORT`：FastAPI 服務綁定位置。
- `DATABASE_URL`：SQLAlchemy 連線字串（預設連到 compose 啟動的 Postgres 5433）。
- `KUBECTL_BIN` / `JHUB_NAMESPACE`：`kubectl` 位置與 JupyterHub 命名空間，供 `/api/usage` 蒐集指標用（若指令包含空白，記得用引號，例如 `KUBECTL_BIN="microk8s kubectl"`）。
- `DASHBOARD_TOKEN`：設為非空字串即可要求 `/api/*` 提供 `Authorization: Bearer <token>`。
- `AUTO_RECORD_ENABLED` / `AUTO_RECORD_INTERVAL`：控制是否啟用自動監聽 pod -> session 的背景同步，以及輪詢秒數。
- `GPU_RATE_PER_HOUR`：如需調整固定計費，可在環境變數覆寫（預設 4 USD/GPU/hour）。
- `POD_REPORT_SYNC_*`：若需回寫資料到 MySQL（例如 `jupyterhub.pod_report`），可以設定：
  - `POD_REPORT_SYNC_ENABLED=true`
  - `POD_REPORT_SYNC_INTERVAL_SECONDS=1800`（單位秒）
  - `POD_REPORT_SYNC_DB_HOST` / `POD_REPORT_SYNC_DB_PORT` / `POD_REPORT_SYNC_DB_USER` / `POD_REPORT_SYNC_DB_PASSWORD`
  - `POD_REPORT_SYNC_DB_NAME=jupyterhub`
  - `POD_REPORT_SYNC_TABLE=pod_report`
  - `POD_REPORT_SYNC_NAMESPACE=jhub`（若與 `JHUB_NAMESPACE` 不同，可覆寫）
  同步器會刪除舊資料並整批匯入最新的 container session 清單，`storage_request` 固定寫入 `0`，`live_time` 依 session 的起訖時間計算，`created_at` 對應 session 的 `start_time`。

## 開發小提示

- 所有 Python 程式碼位於 `backend/app/`，包含 SQLAlchemy models、CRUD、FastAPI 端點與 JupyterHub 整合邏輯。
- UI 可於 `backend/app/static/` (CSS/JS) 與 `backend/app/templates/` (Jinja2) 調整；屬於單檔原生實作，修改後重新啟動服務即可。
- `jhub_usage_dashboard.py` 的低階收集邏輯被抽出到 `backend/app/jhub.py`，如需擴充 GPU 指標或 Kubectl 參數，可在該模組調整。
