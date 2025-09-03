# JupyterHub 一鍵安裝（MicroK8s/Helm/Calico/NVIDIA GPU Operator，支援離線側載）

這個專案提供兩支腳本，幫你在單機上**快速部署 JupyterHub**（含 GPU 支援、Calico 網路、MicroK8s、Helm），同時兼顧**離線映像側載**與**一鍵清除**。

* `install_jhub.sh`：一鍵安裝與配置（支援離線匯入 Calico 與 Notebook 映像、GPU Operator、動態 Profile、port-forward 工具）
* `uninstall_jhub.sh`：深度卸載（停用/移除 Helm Release、Namespace、MicroK8s、殘留 CNI/iptables 等）

---

## 目錄結構

```
.
├─ install_jhub.sh
├─ uninstall_jhub.sh
├─ calico-v3.25.1-bundle.tar          # 可選：Calico 離線映像包
└─ pytorch_25.08-py3.extended.tar     # 可選：Notebook（SingleUser）離線映像包
```

> 以上兩個 `.tar` 檔若存在，安裝流程會自動以 `microk8s images import` 匯入；缺少也不影響 JupyterHub 部署（之後可再匯入）。

---

## 功能亮點

* ✅ **完全自動化**：安裝 snapd + MicroK8s、Helm、Calico（自動調整至 `quay.io` 來源）、DNS/Storage、JupyterHub Chart。
* ✅ **離線友善**：支援 Calico 與 Notebook 映像 **離線側載**（`microk8s images import`）。
* ✅ **GPU Ready**：NVIDIA GPU Operator（可切換是否安裝/是否安裝驅動/Toolkit），自動建立 `RuntimeClass=nvidia`，並附 **CUDA 冒煙測試**。
* ✅ **穩定性**：自動**放大 Spawner/Hub 逾時**，大映像也不容易超時。
* ✅ **動態 Profile**：依主機 CPU/MEM/GPU 自動產生 `profileList`（含 0/1/2/4/8 GPU 類型，視硬體而定）。
* ✅ **即開即用**：自動建立 `jhub-portforward` 工具，可本機或遠端透過 `kubectl port-forward` 黏到 Hub 服務。

---

## 系統需求

* x86\_64 Linux（已在 Debian/Ubuntu 族系及 RHEL 族系邏輯處理）
* Root 權限（請用 `sudo`）
* 推薦規格：≥ 4 vCPU / 8–16 GiB RAM（依實際需求增減）
* GPU 選配：NVIDIA GPU + 驅動（若用 GPU Operator 管驅動可改為啟用 driver，但預設 **不安裝 driver**）
* 連線：**線上**或**離線（搭配 `.tar` 映像側載）**

---

## 快速開始（Quick Start）

> 以下所有指令請在專案根目錄執行，且以 root / sudo 身分。

### 1) 預先（可選）準備離線映像

把下載好的映像放到專案目錄：

```
calico-v3.25.1-bundle.tar
pytorch_25.08-py3.extended.tar
```

### 2) （可選）自訂參數

若要調整管理者帳號、PVC 大小、SingleUser 映像等，可在執行前覆寫環境變數，例如：

```bash
sudo ADMIN_USER=myadmin \
     SINGLEUSER_IMAGE=nvcr-extended/pytorch:25.08-jhub \
     PVC_SIZE=50Gi \
     PF_BIND_ADDR=127.0.0.1 \
     ./install_jhub.sh
```

> 完整參數見下方「可調參數一覽」。

### 3) 執行安裝

```bash
sudo ./install_jhub.sh
```

### 4) 完成與登入

腳本最後會印出存取資訊，例如：

```
存取網址：http://127.0.0.1:18080
管理者（admin_users）：adminuser
背景 pf 工具：sudo jhub-portforward {start|stop|status}
```

* 首次登入請使用你在 `ADMIN_USER` 指定的系統帳號（Authenticator 預設使用 PAM，依你的環境）
* 也可直接走 NodePort 傳統對外：`http://<主機IP>:30080`（見下方「網路存取方式」）

---

## 網路存取方式

* **預設啟用 port-forward**（`PF_AUTOSTART=true`）：

  * 會在背景啟動 `kubectl -n jhub port-forward svc/proxy-public 18080:80`
  * 存取 `http://PF_BIND_ADDR:PF_LOCAL_PORT`（預設 `0.0.0.0:18080`，**生產建議**改 `127.0.0.1`）
* **NodePort 後備**（永遠存在）：

  * `Service: NodePort 30080`，可從 `http://<主機IP>:30080` 連線
  * 若你關閉或不想使用 port-forward，NodePort 仍可用

### `jhub-portforward` 工具

安裝流程會在 `/usr/local/bin/jhub-portforward` 放入一個小工具：

```bash
sudo jhub-portforward start
sudo jhub-portforward status
sudo jhub-portforward stop
```

---

## 可調參數一覽（節錄）

| 變數                             | 預設值                                | 說明                                     |
| ------------------------------ | ---------------------------------- | -------------------------------------- |
| `ADMIN_USER`                   | `adminuser`                        | JupyterHub 管理者                         |
| `JHUB_NS`                      | `jhub`                             | Kubernetes Namespace                   |
| `JHUB_RELEASE`                 | `jhub`                             | Helm Release 名稱                        |
| `JHUB_CHART_VERSION`           | `4.2.0`                            | jupyterhub chart 版本                    |
| `SINGLEUSER_IMAGE`             | `nvcr-extended/pytorch:25.08-jhub` | SingleUser Notebook 映像（可換成你側載的標籤）      |
| `PVC_SIZE`                     | `20Gi`                             | 使用者家目錄 PVC 大小                          |
| `SPAWNER_HTTP_TIMEOUT`         | `180`                              | Spawner `http_timeout`（s）              |
| `KUBESPAWNER_START_TIMEOUT`    | `600`                              | Spawner `start_timeout`（s）             |
| `NODEPORT_FALLBACK_PORT`       | `30080`                            | Proxy NodePort                         |
| `PF_BIND_ADDR`                 | `0.0.0.0`                          | port-forward 綁定位址（**建議生產改 127.0.0.1**） |
| `PF_LOCAL_PORT`                | `18080`                            | 本機 port-forward 連接埠                    |
| `PF_AUTOSTART`                 | `true`                             | 是否自動啟動 port-forward                    |
| `USE_GPU_OPERATOR`             | `true`                             | 是否安裝 NVIDIA GPU Operator               |
| `GPU_OPERATOR_VERSION`         | 空                                  | 指定 GPU Operator 版本（不填用預設）              |
| `GPU_OPERATOR_DISABLE_DRIVER`  | `true`                             | 不安裝驅動（預設）。若需由 Operator 安裝驅動，改成 `false` |
| `GPU_OPERATOR_DISABLE_TOOLKIT` | `false`                            | 預設安裝 Toolkit/CDI，若不需要可設 `true`         |
| `CALICO_VERSION`               | `v3.25.1`                          | Calico 版本（會把 workloads 切換到 `quay.io`）  |
| `CALICO_BUNDLE`                | `./calico-v3.25.1-bundle.tar`      | Calico 離線側載包路徑                         |
| `NOTEBOOK_TAR`                 | `./pytorch_25.08-py3.extended.tar` | Notebook 映像側載包路徑                       |

> 腳本會自動生成 `/root/jhub/values.yaml`（包含 image、PVC、Profile、逾時設定）。

---

## GPU 支援說明

* 預設會安裝 **NVIDIA GPU Operator**，並啟用：

  * Toolkit（含 CDI，`operator.defaultRuntime=containerd`）
  * `RuntimeClass: nvidia`
* 若不想裝 Operator：執行前設定 `USE_GPU_OPERATOR=false`。
* 安裝結束會自動跑一次 **CUDA 冒煙測試**（建立 `cuda-test` Pod，執行 `nvidia-smi`）。

---

## 離線側載（重要）

* 若提供 `calico-v3.25.1-bundle.tar` 與 `pytorch_25.08-py3.extended.tar`，安裝流程會自動：

  ```bash
  microk8s images import calico-v3.25.1-bundle.tar
  microk8s images import pytorch_25.08-py3.extended.tar
  ```
* 即使未提供 `.tar`，仍會嘗試線上拉取（可能較慢）。

---

## 產生的 Profiles（動態）

* 腳本會偵測主機 `CPU/MEM/GPU` 並產生 `profileList`：

  * 一個「CPU 節點」Profile（0 GPU）
  * 若偵測到 GPU，依 1/2/4/8 目標產生對應 Profile（自動限制 CPU/MEM/`nvidia.com/gpu`）
* `RuntimeClass=nvidia` 自動加在 GPU Profiles 上。

---

## 解除安裝 / 復原

要**完全清掉** JupyterHub、GPU Operator、MicroK8s 與殘留 CNI/iptables，直接執行：

```bash
sudo ./uninstall_jhub.sh
```

> 腳本會：
>
> * 停止所有 `kubectl port-forward` / `microk8s.kubectl port-forward`
> * 嘗試 `helm uninstall` + 刪 `jhub` / `gpu-operator` namespaces（含 finalizers 清理）
> * 刪除 NVIDIA 相關 CRDs（若存在）
> * 停止並 **purge** `microk8s` snap；清除 `/var/snap/microk8s`
> * 清 `cni0`、`flannel.1`、`/etc/cni/net.d/*`、`/var/lib/cni/*`
> * （可選）清 Helm 本機快取、移除 `kubectl`（snap/apt/手動）

> ⚠️ 建議在生產/遠端環境先確保有 OOB（out-of-band）管理，避免清 CNI/iptables 時短暫斷線。

---

## 疑難排解（Troubleshooting）

* **卡在 Calico/網路**

  * 腳本已將 Calico workloads 切換至 `quay.io` 並支援離線 bundle。
  * 如 DaemonSet `calico-node` 未出現，腳本會先等待，之後重試 patch；可用 `microk8s kubectl -n kube-system get ds calico-node` 確認。
* **DNS 問題（coredns rollout 超時）**

  * 腳本會自動重啟 `coredns` 並再次等待。你可手動執行：

    ```bash
    microk8s kubectl -n kube-system rollout restart deploy/coredns
    microk8s kubectl -n kube-system rollout status deploy/coredns
    ```
* **port-forward 無法連線或占用埠**

  * 使用工具檢查：`sudo jhub-portforward status`；重新啟動：`sudo jhub-portforward stop && sudo jhub-portforward start`
  * 生產建議 `PF_BIND_ADDR=127.0.0.1`，配合反向代理/Nginx 再對外。
* **Spawner 超時**

  * 已預設 `http_timeout=180s`、`start_timeout=600s`。如仍超時，可再調大，或檢查映像拉取/節點資源/Registry 速度。
* **GPU 未被偵測**

  * 檢查主機 `nvidia-smi`；確認 Operator 的 Pods 是否正常：`microk8s kubectl -n gpu-operator get pods`。
  * 重新跑冒煙測試：

    ```bash
    microk8s kubectl delete pod cuda-test --ignore-not-found
    # 重新執行 install_jhub.sh 末段會再跑；或手動套用測試 YAML（見腳本中的 deploy_cuda_smoketest）
    ```

---

## 安全性建議

* 將 `PF_BIND_ADDR` 設為 `127.0.0.1`，再以反向代理（NGINX/Traefik/Caddy）對外提供 TLS 與身分驗證整合。
* 請妥善管理 `ADMIN_USER` 帳號及系統 PAM/LDAP/SSO 配置。
* 若開放 NodePort，請在防火牆限制來源（或使用內網/Zero Trust）。

---

## 進階：自訂 SingleUser 映像

* 若你有自行建好的 Notebook 映像（例如 `nvcr-extended/pytorch:25.08-jhub`），在執行時指定：

  ```bash
  sudo SINGLEUSER_IMAGE=nvcr-extended/pytorch:25.08-jhub ./install_jhub.sh
  ```
* 若離線可先 `microk8s images import <your-notebook>.tar`，或把 `.tar` 放在本專案根目錄並改 `NOTEBOOK_TAR` 變數。

---

## 進階：Helm values 位置

* 腳本會輸出 `/root/jhub/values.yaml`，你可以查看或自行調整後再次執行 helm：

  ```bash
  sudo microk8s kubectl get ns jhub >/dev/null 2>&1 || sudo microk8s kubectl create ns jhub
  sudo helm upgrade --cleanup-on-fail --install jhub jupyterhub/jupyterhub \
       -n jhub --version 4.2.0 -f /root/jhub/values.yaml
  ```

---

## 常見問答（FAQ）

**Q1：可以不裝 GPU Operator 嗎？**
可以。執行前設 `USE_GPU_OPERATOR=false`。若之後要啟用，再次執行腳本並設回 `true` 即可。

**Q2：如何更換 PVC StorageClass？**
預設用 `microk8s-hostpath`。可安裝其他 StorageClass，然後編輯 `/root/jhub/values.yaml` 中 `singleuser.storage.dynamic.storageClass` 後重新 `helm upgrade`。

**Q3：Port 18080 被占用怎麼辦？**
執行前調整 `PF_LOCAL_PORT`，例如：

```bash
sudo PF_LOCAL_PORT=19090 ./install_jhub.sh
```

**Q4：要把 JupyterHub 對外（公網）直接開放行嗎？**
建議**不要**。建議：`PF_BIND_ADDR=127.0.0.1` + 反向代理 + TLS，或使用 NodePort/LoadBalancer 搭配防火牆與認證保護。

---

## 授權（License）

此專案 README 與腳本可自由在組織內部使用與修改。若需開源釋出，建議附上適當授權（例如 MIT），並審閱內部映像標籤與機敏資訊。

---

## 版本資訊（對應腳本）

* Installer：`JupyterHub one-shot installer v4.4.5`
* 預設 JupyterHub Chart：`4.2.0`
* Calico 預設版本：`v3.25.1`
* Helm 安裝器：`v3.15.3`
* K8s Channel（MicroK8s）：`1.30/stable`

---

### 一鍵安裝指令（最小示例）

```bash
sudo ./install_jhub.sh
# 完成後（預設已自動 pf）
# 瀏覽 http://<你的主機IP>:18080 或 http://<你的主機IP>:30080
```

祝部署順利！🧪🚀
