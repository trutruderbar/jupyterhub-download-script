# jupyterhub-download-script

> 一鍵在 **MicroK8s** 上安裝／升級／移除 **JupyterHub**，支援**離線鏡像側載**、**CoreDNS 修復**、**Calico 換源（quay.io）**、**GPU/IB（NVIDIA Operator）**、**動態 Profile**、**adminuser 專屬 NodePort 對外 API**、與**診斷/port-forward**小工具。

GitHub：[https://github.com/trutruderbar/jupyterhub-download-script](https://github.com/trutruderbar/jupyterhub-download-script)

---

## 內容物

* `install_jhub.sh`
  一鍵部署（含 MicroK8s 與 Helm 就緒、離線鏡像匯入、CoreDNS/Calico 修復、Storage 與 Logs PV/PVC、GPU/IB 選配、adminuser NodePort、`jhub-portforward` / `jhub-diag` 小工具）。

* `update_jhub.sh`
  安全升級既有 JupyterHub（不會主動刪除 singleuser pods），或用 `--svc-only` 僅同步 adminuser 的 NodePort Service（零風險）。

* `uninstall_jhub.sh`
  徹底清除：Helm releases、CRDs、Namespaces、PV/PVC、本機掛載資料夾、CNI 殘留、containerd 影像、MicroK8s 與本機快取（可用旗標選擇保留）。

---

## 快速開始

```bash
# 取得專案
git clone https://github.com/trutruderbar/jupyterhub-download-script
cd jupyterhub-download-script

# 以預設參數一鍵安裝（建議使用 sudo）
sudo bash install_jhub.sh
```

安裝完成後終端會顯示存取資訊，例如：

* 透過 pf：`http://<HOST_IP>:18080`
* 透過 NodePort（Hub）：`http://<HOST_IP>:30080`
* adminuser 專屬 API（免 Hub 登入）：`http://<HOST_IP>:32081/ping`

> 若 `PF_AUTOSTART=true`（預設），會自動背景啟動 `proxy-public` 的 port-forward。

---

## 系統需求

* Linux x86\_64（Debian/Ubuntu 或 RHEL/Fedora 系列）
* root 權限（`sudo`）
* 可連網或準備好**離線鏡像 tar**
* （選配）NVIDIA GPU 與對應驅動（`nvidia-smi` 正常）

預設連接埠（可改）：

* 18080（pf）
* 30080（Hub NodePort）
* 32081（adminuser 對外 API NodePort）

---

## 常用環境變數（節錄）

| 變數                                                   | 預設值                                                                    | 說明                                            |
| ---------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------- |
| `ADMIN_USER`                                         | `adminuser`                                                            | JupyterHub 管理者與 adminuser NodePort 的 selector |
| `JHUB_NS` / `JHUB_RELEASE` / `JHUB_CHART_VERSION`    | `jhub` / `jhub` / `4.2.0`                                              | Namespace / Helm release / Chart 版本           |
| `NODEPORT_FALLBACK_PORT`                             | `30080`                                                                | Hub 對外 NodePort                               |
| `PF_BIND_ADDR` / `PF_LOCAL_PORT` / `PF_AUTOSTART`    | `0.0.0.0` / `18080` / `true`                                           | proxy-public 的本機 port-forward                 |
| `SINGLEUSER_IMAGE`                                   | `nvcr-extended/pytorch:25.08-jhub`                                     | Singleuser Notebook 映像                        |
| `PVC_SIZE`                                           | `20Gi`                                                                 | 使用者家目錄 PVC                                    |
| `SPAWNER_HTTP_TIMEOUT` / `KUBESPAWNER_START_TIMEOUT` | `180` / `900`                                                          | 避免大鏡像逾時                                       |
| `USE_GPU_OPERATOR` / `GPU_OPERATOR_DISABLE_DRIVER`   | `true` / `true`                                                        | 安裝 GPU Operator；不安裝驅動（建議主機先裝好驅動）              |
| `ENABLE_IB`                                          | `false`                                                                | 安裝 NVIDIA Network Operator（僅 operator）        |
| `CALICO_BUNDLE` / `NOTEBOOK_TAR` / `COREDNS_TAR`     | `./calico-v3.25.1-bundle.tar` / `./pytorch_25.08-py3.extended.tar` / 空 | 離線鏡像 tar 存在才匯入                                |
| `EXPOSE_ADMINUSER_NODEPORT`                          | `true`                                                                 | 建立 adminuser 專屬 NodePort 服務                   |
| `ADMINUSER_TARGET_PORT` / `ADMINUSER_NODEPORT`       | `8000` / `32081`                                                       | Notebook 內服務監聽埠 / 對外 NodePort                 |

**覆寫範例：**

```bash
sudo NODEPORT_FALLBACK_PORT=31080 \
     SINGLEUSER_IMAGE="yourrepo/pytorch:tag" \
     PVC_SIZE=100Gi \
     bash install_jhub.sh
```

---

## 升級與維運

**升級：**

```bash
# 使用現有 values.yaml 安全升級
sudo ./update_jhub.sh -f /root/jhub/values.yaml

# 指定 chart 版本
sudo ./update_jhub.sh -f /root/jhub/values.yaml -V 4.2.0

# 只同步 adminuser NodePort（不碰 Helm）
sudo ./update_jhub.sh --svc-only
```

**診斷：**

```bash
# 檢視 jhub pods / coredns / 事件 / hub logs tail
sudo jhub-diag jhub

# pf 工具
sudo jhub-portforward status
sudo jhub-portforward stop
sudo jhub-portforward start
```

---

## 完整清除

```bash
# 直接清除（建議先 --dry-run）
sudo ./uninstall_jhub.sh

# 乾跑
sudo ./uninstall_jhub.sh --dry-run

# 保留使用者資料與日誌
sudo ./uninstall_jhub.sh --keep-storage

# 保留 containerd 影像
sudo ./uninstall_jhub.sh --keep-images
```

會移除：Helm releases、CRDs、Namespaces、PV/PVC、CNI 殘留、相關 containerd 影像、MicroK8s 與本機快取。清除後**建議重開機**。

---

## 疑難排解（速查）

* **CoreDNS 拉取失敗 / 解析異常**
  腳本會將 image 改為 `COREDNS_IMAGE`，必要時重寫 Corefile → 1.1.1.1 / 8.8.8.8 並重啟。
* **Calico 受限**
  自動將 DS/Deploy 改為 `quay.io/calico/*`，避開 Docker Hub 限額。
* **外部連不通（18080/30080/32081）**
  開防火牆（`firewalld` 或 `ufw`），或檢查雲端安全群組。
* **GPU 測試**
  若側載 `docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04`，會自動跑一個 `nvidia-smi` 冒煙測試（RuntimeClass、CDI 無誤）。

---

## 安全建議

* 正式環境請：配置 TLS/Ingress、強化認證（OIDC/GitHub/LDAP）、限制來源、設定資源配額與節點隔離，並將 `PF_BIND_ADDR` 規劃為 `127.0.0.1` 再由反向代理對外。
* GPU 環境建議**主機先裝好驅動**，Operator 不自動安裝驅動更可控。

---

## 貢獻

Issues / PRs 歡迎提出：[https://github.com/trutruderbar/jupyterhub-download-script](https://github.com/trutruderbar/jupyterhub-download-script)
若這個專案對你有幫助，也歡迎幫忙點個 ⭐️！
