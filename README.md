# jupyterhub-download-script

> 一鍵在 **MicroK8s** 上部署／移除 **JupyterHub** 的腳本組合：支援離線鏡像側載、Calico via quay / CoreDNS 映像修補、HostPath 儲存、GPU / IB / NVIDIA Operator、自動 MIG 設定、adminuser 專屬 NodePort、入口 Portal 以及 `jhub-portforward` / `jhub-diag` 等診斷工具。

GitHub：[https://github.com/trutruderbar/jupyterhub-download-script](https://github.com/trutruderbar/jupyterhub-download-script)

---

## 主要特色

- `install_jhub.sh` v4.6 會自動安裝 MicroK8s + Helm、套用 Calico（quay.io）與 CoreDNS 修補、關閉 kubelet image GC、建立 HostPath PV/PVC 與 Log 目錄。
- 內建離線 `tar` 側載機制：Hub/Proxy/Notebook/Calico/CoreDNS/GPU Operator 等會自動 `ctr images import`，並可同步到 `CLUSTER_NODE_IPS` 指定的 worker 節點。
- 入口體驗：啟用 `PF_AUTOSTART` port-forward 服務、adminuser API NodePort、`sudo jhub-portforward {start|stop|status}` 小工具，並產生 `/root/jhub/index.html` + `portal-config.js` 供瀏覽器啟動。
- Storage 與使用者體驗：建立 Storage/Logs PV、可選 Shared Storage、ResourceQuota / LimitRange、NetworkPolicy、Frame-Ancestors、Idle Culler 等常用設定。
- GPU 與運算：支援 GPU Operator / Network Operator、`GPU_DRIVER_MODE=auto|host|dkms|precompiled`、CUDA smoke test、MIG profiles 與 runtimeClass（含 `ENABLE_MIG` 相關 configmap）。
- 叢集支援：設定 `CLUSTER_NODE_IPS` 後，自動以 SSH 安裝 MicroK8s、加入 HA/worker、同步離線鏡像、套用 containerd nvidia runtime 與 Calico 修補。

---

## 快速開始

```bash
git clone https://github.com/trutruderbar/jupyterhub-download-script
cd jupyterhub-download-script

# 建議以 root / sudo 執行，腳本會自動安裝 MicroK8s + Helm + JupyterHub
sudo bash install_jhub.sh
```

安裝完成後終端機會列出：

- 推薦入口 `ACCESS_URL`（port-forward，預設 `http://<HOST IP>:18080`）
- Hub NodePort（預設 `http://<HOST IP>:30080`）
- adminuser API NodePort（預設 `http://<HOST IP>:32081/ping`）
- `/root/jhub/index.html` 與同步到工作目錄的 `portal-config.js`

如需離線安裝，請將對應 `*.tar` 放在 `offline-images/` 或覆寫對應路徑後再執行腳本。

---

## 安裝流程摘要

- `ensure_microk8s`：自動安裝/升級 MicroK8s、啟用 `dns storage metallb gpu ingress registry` 等模組並停用 kubelet image GC。
- `images_import`：從 `OFFLINE_IMAGE_DIR` 匯入 Hub/Proxy/Notebook/Calico/CoreDNS/GPU Operator/HostPath/Busybox 等鏡像，支援 `AUTO_PULL_CORE_IMAGES=true` 線上備援。
- `ensure_dns_and_storage`：建立 HostPath Provisioner、Storage/Logs PV/PVC、Shared Storage（可關閉）、NetworkPolicy、ResourceQuota/LimitRange、TLS Secret、Frame Ancestors。
- `install_network_operator` / `install_gpu_operator`：依 `ENABLE_IB`、`USE_GPU_OPERATOR`、`GPU_DRIVER_MODE` 等設定佈署對應 Operator，必要時安裝 kernel headers 並執行 CUDA smoke test。
- `enable MIG`：當 `ENABLE_MIG=true` 時，同步 runtimeClass、configmap 與目標節點 MIG 設定。
- `ensure_cluster_nodes`：針對 `CLUSTER_NODE_IPS` 逐一安裝 MicroK8s、加入 HA/worker、同步側載鏡像並套用 NVIDIA runtime。
- 安裝 JupyterHub chart、檢查 Pod rollout、建立 adminuser NodePort、安裝 `jhub-portforward` / `jhub-diag` 工具、產生入口 Portal。

---

## 離線鏡像與素材

- 預設離線資料夾：`OFFLINE_IMAGE_DIR=${SCRIPT_DIR}/offline-images`
- 常用 tar：
  - `HUB_IMAGE_TAR`、`PROXY_IMAGE_TAR`、`NOTEBOOK_TAR`
  - Calico：`CALICO_BUNDLE`
  - HostPath：`HOSTPATH_PROVISIONER_TAR`
  - CoreDNS：`COREDNS_TAR`
  - GPU Operator：`GPU_OPERATOR_BUNDLE_TAR`、`GPU_OPERATOR_CORE_TAR`、`NFD_TAR`、`NVIDIA_K8S_DEVICE_PLUGIN_TAR` 等
  - 其他：`PAUSE_IMAGE_TAR`、`BUSYBOX_IMAGE_TAR`、`KUBE_SCHEDULER_TAR`
- 若沒有 tar，可設定 `AUTO_PULL_CORE_IMAGES=true` 讓腳本自動從遠端 registry 抓取。
- 叢集模式下會自動將 Notebook/Calico/CoreDNS/HostPath/GPU Operator 等 tar 或鏡像同步到 worker。

---

## 常用環境變數

### 基本參數

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `ADMIN_USER` | `adminuser` | JupyterHub 管理者帳號並同步到 `admin_users` |
| `JHUB_NS` / `JHUB_RELEASE` | `jhub` / `jhub` | 佈署 Namespace 與 Helm Release 名稱 |
| `JHUB_CHART_VERSION` | `4.2.0` | 使用的 JupyterHub chart 版本 |
| `HELM_TIMEOUT` | `25m0s` | `helm upgrade --install` timeout |
| `ENABLE_IDLE_CULLER` | `true` | 啟用 Idle culler，間隔由 `CULL_*` 變數控制 |
| `ENABLE_NETWORK_POLICY` | `true` | 建立預設 NetworkPolicy（限制 adminuser、proxy 等流向） |

### Notebook 與儲存

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `SINGLEUSER_IMAGE` | `myorg3/pytorch-jhub:24.10` | Singleuser Notebook 映像，可搭配 `SINGLEUSER_IMAGE_PULL_POLICY` |
| `PVC_SIZE` | `20Gi` | 每位使用者 home PVC 容量 |
| `SINGLEUSER_STORAGE_CLASS` | `microk8s-hostpath` | Notebook PVC 使用的 StorageClass |
| `SHARED_STORAGE_ENABLED` | `true` | 建立 shared storage（`SHARED_STORAGE_PATH`、`SHARED_STORAGE_SIZE`） |
| `ALLOWED_CUSTOM_IMAGES` | 空 | 允許的自訂映像（逗號分隔） |
| `ALLOW_NAMED_SERVERS` / `NAMED_SERVER_LIMIT` | `true` / `5` | 啟用 named servers 與上限 |

### 入口與安全

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `NODEPORT_FALLBACK_PORT` | `30080` | Hub 對外 NodePort |
| `PF_BIND_ADDR` / `PF_LOCAL_PORT` / `PF_AUTOSTART` | `0.0.0.0` / `18080` / `true` | port-forward 工具預設綁定與啟動狀態（正式環境建議改成 `127.0.0.1`） |
| `EXPOSE_ADMINUSER_NODEPORT` | `true` | Adminuser API 是否建 NodePort |
| `ADMINUSER_NODEPORT` / `ADMINUSER_TARGET_PORT` | `32081` / `8000` | adminuser 對外與 container 服務埠 |
| `ADMINUSER_PORTFORWARD` | `false` | 是否同時建立 adminuser port-forward（預設關閉） |
| `JHUB_FRAME_ANCESTORS` | `http://${DEFAULT_HOST_IP} http://localhost:8080` | Hub `frame_ancestors` 設定 |
| `ENABLE_INGRESS` / `INGRESS_HOST` | `false` / `${DEFAULT_HOST_IP}` | 如需 TLS/Ingress 可覆寫並提供 `TLS_CERT_FILE` / `TLS_KEY_FILE` |

### GPU / 運算

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `USE_GPU_OPERATOR` | `true` | 佈署 NVIDIA GPU Operator |
| `GPU_DRIVER_MODE` | `auto` | `auto`（預設，偵測 host/dkms）/ `host` / `dkms` / `precompiled` |
| `GPU_OPERATOR_DISABLE_DRIVER` | `false` | 是否跳過 Operator driver 安裝 |
| `GPU_DKMS_INSTALL_HEADERS` | `true` | `dkms` 模式下自動安裝 kernel headers（Debian/Ubuntu） |
| `ENABLE_IB` | `false` | 啟用 NVIDIA Network Operator（IB、RDMA） |
| `ENABLE_MIG` | `false` | 啟用 MIG 設定，搭配 `MIG_*` 變數指定 profile、對象 GPU、configmap |

### 叢集與同步

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `CLUSTER_NODE_IPS` | 空 | 以逗號分隔 worker IP；若設定會自動加節點 |
| `CLUSTER_SSH_USER` / `CLUSTER_SSH_KEY` / `CLUSTER_SSH_PORT` | `root` / `./id_rsa` / `22` | SSH 連線資訊（需可無密碼登入） |
| `CLUSTER_SSH_OPTS` | 空 | 額外 SSH 參數（例如 `-o ProxyJump=bastion`） |
| `AUTO_PULL_CORE_IMAGES` | `false` | 沒有離線 tar 時自動 `ctr images pull` |
| `PATCH_CALICO` | `false` | 強制以 quay 映像覆寫 Calico（節點已側載可保持 `false`） |
| `FORCE_RUNC` | `false` | 強制切換 containerd runtime 為 `runc`（疑難排解用） |

---

## 管理工具與檔案

- `sudo jhub-portforward {start|stop|status}`：控制 Hub `proxy-public` 的長駐 port-forward（預設自動啟動）。
- `sudo jhub-diag ${JHUB_NS}`：收集 Hub / Proxy / CoreDNS / 事件 / logs，協助除錯。
- Portal：`/root/jhub/index.html` 搭配 `portal-config.js`，會自動複製一份到工作目錄，方便靜態端點部署。
- 管理使用者 API：`http://<node_ip>:${ADMINUSER_NODEPORT}/ping` 或透過 Hub proxy `http://<node_ip>:${NODEPORT_FALLBACK_PORT}/user/<username>/proxy/${ADMINUSER_TARGET_PORT}/…`。
- CUDA smoke test：`USE_GPU_OPERATOR=true` 時會自動部署，可在 Namespace 內檢查測試 Pod。

---

## 更新與日常維護

- 安全滾動更新（保留使用者 Pod）：`sudo ./update_jhub.sh -f /root/jhub/values.yaml`
- 更新 chart 版本：`sudo ./update_jhub.sh -f /root/jhub/values.yaml -V 4.2.0`
- 只同步 adminuser NodePort（不跑 helm）：`sudo ./update_jhub.sh --svc-only`
- 停止/啟動 port-forward：`sudo jhub-portforward stop` / `sudo jhub-portforward start`

---

## 解除安裝（`uninstall_jhub.sh`）

```bash
# 直接清除（預設保留 Helm 清單以降低 timeout）
sudo ./uninstall_jhub.sh

# 觀察動作但不生效
sudo ./uninstall_jhub.sh --dry-run

# 保留使用者資料與 containerd 鏡像
sudo ./uninstall_jhub.sh --keep-storage --keep-images
```

功能摘要：

- 停用 `jhub-portforward` / adminuser port-forward、移除 portal / config / systemd 檔案。
- 移除 JupyterHub Namespace、（選擇性）GPU / Network Operator、CRDs、RuntimeClass、finalizers。
- 刪除 Storage / Logs PV/PVC；除非 `--keep-storage`。
- 清理 `./Storage`、`/var/log/jupyterhub`、CNI 殘留（cni0、flannel、/etc/cni/net.d、/var/lib/cni）。
- 移除 containerd 映像（`--keep-images` 可保留）、Snap MicroK8s、helm/kubectl 快取與二進位。
- 若設定 `CLUSTER_NODE_IPS` 會遠端 SSH 執行相同的清理（含 MicroK8s、containerd、CNI）。
- 針對仍在 Terminating 的 Namespace，可搭配 `FORCE=true` 自動刪除 finalizers。

CLI 參數對應環境變數（可事先覆寫）：`KEEP_STORAGE`、`KEEP_IMAGES`、`NO_HELM`、`NO_OPERATORS`、`FORCE`、`DRY_RUN`。遠端節點設定沿用 `CLUSTER_*` 參數，並使用 `PORTAL_ROOT_DIR` / `PORTAL_CONFIG_PATH` 決定入口檔案路徑。

---

## 疑難排解速查

- **CoreDNS 無法啟動 / ImagePullBackOff**：確認 `COREDNS_TAR` 已側載，或設定 `COREDNS_IMAGE` 後重新執行腳本匯入。
- **Calico 啟動失敗**：確定 `CALICO_BUNDLE` 已存在，若節點有外網也可設 `PATCH_CALICO=true` 強制拉取 quay.io。
- **外部無法存取 18080/30080/32081**：檢查 `firewalld` / `ufw` 規則，或雲端 Security Group 是否開放。
- **GPU 相關問題**：利用 `sudo jhub-diag jhub`、`microk8s kubectl logs -n gpu-operator`；必要時設定 `GPU_DRIVER_MODE=dkms` 並保證 kernel headers 齊備。
- **MIG 設定未套用**：確認 `ENABLE_MIG=true`、`MIG_TARGET_GPU_IDS` 與 `MIG_CONFIG_PROFILE` 是否符合實際 GPU，重新執行腳本會重寫 configmap。

---

## 安全建議

- 正式環境建議設定 Ingress/TLS、身分驗證（OIDC/GitHub/LDAP）、資源限制、`PF_BIND_ADDR=127.0.0.1`，避免對外暴露 port-forward。
- 若需公開 adminuser API，請搭配反向代理或 API gateway，限制來源與認證。
- GPU Driver 建議預先手動安裝，可設定 `GPU_OPERATOR_DISABLE_DRIVER=true` 讓 Operator 僅管理 Kubernetes 組件。

---

## 貢獻

Issues / PRs 歡迎透過 GitHub 提交：[https://github.com/trutruderbar/jupyterhub-download-script](https://github.com/trutruderbar/jupyterhub-download-script)  
如果這個專案對你有幫助，也請幫忙點個 ⭐ 支持！

