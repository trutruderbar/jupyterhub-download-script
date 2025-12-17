# 離線映像檔目錄

此目錄用於存放 JupyterHub 部署所需的所有 Docker/OCI 映像檔，以支援離線環境部署。

## 所需映像檔清單

### 核心組件

```
calico-v3.25.1-bundle.tar              # Calico 網路組件 bundle
coredns_v1.10.1.tar                    # CoreDNS
hostpath-provisioner-1.5.0.tar         # HostPath 儲存提供者
busybox-1.28.4.tar                     # BusyBox 工具
pause-3.7.tar                          # Kubernetes pause 容器
```

### JupyterHub 組件

```
k8s-hub-4.2.0.tar                      # JupyterHub Hub
configurable-http-proxy-4.6.3.tar      # HTTP Proxy
jhub_24.10_3.tar                       # Single-user 映像 (PyTorch + 多語言 Kernel)
```

### GPU 支援 (可選)

```
gpu-operator-bundle-v25.10.0.tar       # NVIDIA GPU Operator bundle
gpu-operator-v25.10.0.tar              # NVIDIA GPU Operator
kube-scheduler-v1.30.11.tar            # Kubernetes Scheduler
nfd-v0.18.2.tar                        # Node Feature Discovery
nvidia-container-toolkit-v1.18.0.tar   # NVIDIA Container Toolkit
nvidia-dcgm-exporter-4.4.1-4.6.0-distroless.tar  # DCGM Exporter
nvidia-k8s-device-plugin-v0.18.0.tar   # NVIDIA Device Plugin
```

### InfiniBand/RDMA 支援 (可選)

```
k8s-rdma-shared-dev-plugin-v1.5.2.tar  # RDMA Shared Device Plugin
```

## 準備映像檔

### 方法 1: 從有網路的機器下載

在有網路連線的機器上執行：

```bash
# 拉取 JupyterHub 映像
docker pull quay.io/jupyterhub/k8s-hub:4.2.0
docker pull quay.io/jupyterhub/configurable-http-proxy:4.6.3

# 拉取 Calico 映像
# (請參考 Calico 官方文件取得完整映像清單)

# 拉取 GPU Operator
# (請參考 NVIDIA GPU Operator 官方文件)

# 匯出映像
docker save quay.io/jupyterhub/k8s-hub:4.2.0 -o k8s-hub-4.2.0.tar
docker save quay.io/jupyterhub/configurable-http-proxy:4.6.3 -o configurable-http-proxy-4.6.3.tar
# ... 依此類推匯出其他映像
```

### 方法 2: 使用專案腳本

本專案的 `install_jhub.sh` 會自動檢查此目錄，若找不到必要映像會提示您。

### 方法 3: 從現有 MicroK8s 匯出

如果您已有運行中的 MicroK8s 環境：

```bash
# 列出所有映像
microk8s ctr images list

# 匯出特定映像
microk8s ctr images export k8s-hub-4.2.0.tar quay.io/jupyterhub/k8s-hub:4.2.0
```

## 匯入映像

部署時，腳本會自動匯入此目錄中的映像：

```bash
microk8s ctr images import offline-images/k8s-hub-4.2.0.tar
```

## 注意事項

1. **檔案大小**: 所有映像檔總計約 10-20GB，請確保有足夠磁碟空間
2. **版本相容性**: 請確保映像版本與 `jhub.env` 中的設定一致
3. **Git 忽略**: 映像檔已在 `.gitignore` 中排除，不會被提交至版控
4. **傳輸方式**: 可使用 USB 隨身碟、內部檔案伺服器等方式傳輸至離線環境

## 目錄結構

```
offline-images/
├── README.md                          # 本說明文件
├── calico-v3.25.1-bundle.tar         # (需自行準備)
├── k8s-hub-4.2.0.tar                 # (需自行準備)
├── configurable-http-proxy-4.6.3.tar # (需自行準備)
└── ...                               # 其他映像檔
```

## 相關資源

- [JupyterHub Helm Chart](https://jupyterhub.github.io/helm-chart/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [Calico Documentation](https://docs.tigera.io/calico/latest/)
- [MicroK8s Documentation](https://microk8s.io/docs)
