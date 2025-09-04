#!/usr/bin/env bash
# JupyterHub one-shot installer v4.6 (modular + offline side-load + coredns fix + logs + API proxy hints)
set -euo pipefail

###### ========= 可調參數（可用環境變數覆蓋） =========
: "${ADMIN_USER:=adminuser}"
: "${JHUB_NS:=jhub}"
: "${JHUB_RELEASE:=jhub}"
: "${JHUB_CHART_VERSION:=4.2.0}"
: "${HELM_TIMEOUT:=25m0s}"

: "${NODEPORT_FALLBACK_PORT:=30080}"
: "${PF_BIND_ADDR:=0.0.0.0}"          # 生產可改 127.0.0.1
: "${PF_LOCAL_PORT:=18080}"
: "${PF_AUTOSTART:=true}"

# Singleuser Notebook 映像（建議先用你已擴充的離線鏡像）
: "${SINGLEUSER_IMAGE:=nvcr-extended/pytorch:25.08-jhub}"
: "${PVC_SIZE:=20Gi}"

# Spawn/連線逾時，避免大鏡像超時
: "${SPAWNER_HTTP_TIMEOUT:=180}"
: "${KUBESPAWNER_START_TIMEOUT:=900}"

# GPU 與 IB（Network Operator）選項
: "${USE_GPU_OPERATOR:=true}"
: "${GPU_OPERATOR_VERSION:=}"         # 例如 23.9.1（留空用最新 chart）
: "${GPU_OPERATOR_DISABLE_DRIVER:=true}"
: "${GPU_OPERATOR_DISABLE_TOOLKIT:=false}"

: "${ENABLE_IB:=false}"               # true 則安裝 NVIDIA Network Operator（不額外套 CR）
: "${NETWORK_OPERATOR_VERSION:=}"     # 例如 24.7.0（留空用最新 chart）

# 離線側載檔名（存在才會載入）
: "${CALICO_VERSION:=v3.25.1}"
: "${CALICO_BUNDLE:=./calico-v3.25.1-bundle.tar}"
: "${NOTEBOOK_TAR:=./pytorch_25.08-py3.extended.tar}"
: "${COREDNS_TAR:=}"                  # 可選：例如 ./coredns_v1.10.1.tar（含 registry.k8s.io/coredns/coredns:v1.10.1）
: "${COREDNS_IMAGE:=registry.k8s.io/coredns/coredns:v1.10.1}"

###### ========= 常數與工具 =========
HELM_TARBALL_VERSION="v3.15.3"
K8S_CHANNEL="1.30/stable"
KUBECONFIG_PATH="/var/snap/microk8s/current/credentials/client.config"
PF_PROXY_PID="/var/run/jhub-pf.pid"
PF_PROXY_LOG="/var/log/jhub-port-forward.log"
MICROK8S="/snap/bin/microk8s"

log(){ echo -e "\e[1;36m$*\e[0m"; }
ok(){ echo -e "\e[1;32m$*\e[0m"; }
warn(){ echo -e "\e[1;33m$*\e[0m"; }
err(){ echo -e "\e[1;31m$*\e[0m" 1>&2; }

require_root(){ [[ $EUID -eq 0 ]] || { err "請用 sudo 執行：sudo $0"; exit 1; }; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_rhel(){ [[ -f /etc/redhat-release || -f /etc/os-release && "$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '\"')" == "rhel" ]]; }
is_deb(){ [ -f /etc/debian_version ]; }
KCTL(){ "$MICROK8S" kubectl "$@"; }
CTR(){ "$MICROK8S" ctr -n k8s.io "$@"; }
wait_rollout(){ KCTL -n "$1" rollout status "$2/$3" --timeout="${4:-600s}" || true; }

# ---------- Port-forward 工具 ----------
pf_stop(){ [[ -f "${PF_PROXY_PID}" ]] && kill "$(cat "${PF_PROXY_PID}")" 2>/dev/null || true; rm -f "${PF_PROXY_PID}" 2>/dev/null || true; }
pf_start(){
  nohup "$MICROK8S" kubectl -n "${JHUB_NS}" port-forward svc/proxy-public --address "${PF_BIND_ADDR}" "${PF_LOCAL_PORT}:80" >"${PF_PROXY_LOG}" 2>&1 & echo $! > "${PF_PROXY_PID}"
  for _ in {1..30}; do (exec 3<>/dev/tcp/${PF_BIND_ADDR}/${PF_LOCAL_PORT}) >/dev/null 2>&1 && { ok "[pf] ${PF_BIND_ADDR}:${PF_LOCAL_PORT} 已連通（pid $(cat ${PF_PROXY_PID})）"; return 0; }; sleep 1; done
  warn "[pf] 啟動疑似失敗，最近 log："; tail -n 50 "${PF_PROXY_LOG}" || true; return 1
}
install_portforward_tool(){
  cat >/usr/local/bin/jhub-portforward <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
NS="__JHUB_NS__"; BIND_ADDR="__PF_BIND_ADDR__"; LOCAL_PORT="__PF_LOCAL_PORT__"
PID="__PF_PROXY_PID__"; LOG="__PF_PROXY_LOG__"; M="/snap/bin/microk8s"
start(){ [[ -f "$PID" ]] && kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID";
  nohup "$M" kubectl -n "$NS" port-forward svc/proxy-public --address "$BIND_ADDR" "$LOCAL_PORT:80" >"$LOG" 2>&1 & echo $! > "$PID"
  echo "port-forward started (pid $(cat $PID)). Open http://$BIND_ADDR:$LOCAL_PORT"; }
stop(){ [[ -f "$PID" ]] && kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; echo "port-forward stopped."; }
status(){ if [[ -f "$PID" ]] && ps -p "$(cat "$PID")" >/dev/null 2>&1; then
  echo "running (pid $(cat $PID)) → http://$BIND_ADDR:$LOCAL_PORT"
else echo "not running"; exit 1; fi; }
case "${1:-status}" in start) start;; stop) stop;; status) status;; *) echo "Usage: jhub-portforward {start|stop|status}"; exit 2;; esac
EOS
  sed -i "s|__JHUB_NS__|${JHUB_NS}|g; s|__PF_BIND_ADDR__|${PF_BIND_ADDR}|g; s|__PF_LOCAL_PORT__|${PF_LOCAL_PORT}|g; s|__PF_PROXY_PID__|${PF_PROXY_PID}|g; s|__PF_PROXY_LOG__|${PF_PROXY_LOG}|g" /usr/local/bin/jhub-portforward
  chmod +x /usr/local/bin/jhub-portforward
}

# ---------- 基礎環境 ----------
ensure_env(){
  export PATH="/snap/bin:/usr/local/bin:$PATH"
  [[ -f /etc/profile.d/snap_path.sh ]] || { echo 'export PATH="/snap/bin:/usr/local/bin:$PATH"' >/etc/profile.d/snap_path.sh; chmod 644 /etc/profile.d/snap_path.sh; }
  export KUBECONFIG="${KUBECONFIG_PATH}"
}
pkg_install(){
  if is_deb; then apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif is_rhel; then dnf install -y "$@" || yum install -y "$@"; fi
}
need_pkg(){ local miss=(); for p in "$@"; do is_cmd "$p" || miss+=("$p"); done; ((${#miss[@]})) && pkg_install "${miss[@]}"; }
ensure_helm(){
  if ! is_cmd helm; then if is_cmd snap; then snap install helm --classic || true; fi; fi
  if ! is_cmd helm; then
    curl -fsSL "https://get.helm.sh/helm-${HELM_TARBALL_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz
    tar -C /tmp -xzf /tmp/helm.tgz; install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; rm -rf /tmp/linux-amd64 /tmp/helm.tgz
  fi
  helm version --short >/dev/null
}
preflight_sysctl(){
  log "[preflight] 關閉 swap / 載入 overlay, br_netfilter / 設定 ip_forward"
  swapoff -a || true; modprobe overlay || true; modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-k8s.conf <<'SYS'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
SYS
  sysctl --system >/dev/null 2>&1 || true
}
ensure_microk8s(){
  if ! is_cmd snap; then
    log "[act] 安裝 snapd"
    if is_deb; then pkg_install snapd; systemctl enable --now snapd.socket;
    else pkg_install snapd snapd-selinux || true; systemctl enable --now snapd.socket; [[ -e /snap ]] || ln -s /var/lib/snapd/snap /snap; fi
    sleep 2
  fi
  snap list | grep -q '^microk8s\s' || { log "[act] 安裝 MicroK8s (${K8S_CHANNEL})"; snap install microk8s --channel="${K8S_CHANNEL}" --classic; }
  ok "[ok] MicroK8s 安裝完成"
}
ensure_apiserver_ready(){
  log "[wait] 等待 MicroK8s API 就緒（最多 420s）"
  for _ in {1..70}; do "$MICROK8S" kubectl get --raw='/readyz' >/dev/null 2>&1 && { ok "[ok] apiserver /readyz OK"; return 0; }; sleep 6; done
  warn "[warn] apiserver /readyz 未就緒，但繼續嘗試後續步驟"
}

# ---------- 離線鏡像側載 ----------
images_import(){
  if [[ -f "${CALICO_BUNDLE}" ]]; then log "[images] 匯入 Calico bundle：${CALICO_BUNDLE}"; "$MICROK8S" images import "${CALICO_BUNDLE}"; else warn "[images] 找不到 ${CALICO_BUNDLE}，Calico 可能線上拉取"; fi
  if [[ -f "${NOTEBOOK_TAR}" ]]; then log "[images] 匯入 Notebook 映像：${NOTEBOOK_TAR}"; "$MICROK8S" images import "${NOTEBOOK_TAR}"; else warn "[images] 找不到 ${NOTEBOOK_TAR}（不影響 Hub 部署，可之後再匯入）"; fi
  if [[ -n "${COREDNS_TAR}" && -f "${COREDNS_TAR}" ]]; then log "[images] 匯入 CoreDNS 映像：${COREDNS_TAR}"; "$MICROK8S" images import "${COREDNS_TAR}" || warn "[images] CoreDNS tar 匯入失敗（略過）"; fi
}

# ---------- Calico 換 quay.io ----------
wait_for_calico_ds(){
  log "[wait] 等待 kube-system 中的 calico-node DaemonSet 出現"
  for _ in {1..180}; do KCTL -n kube-system get ds calico-node >/dev/null 2>&1 && return 0; sleep 1; done
  warn "calico-node DS 尚未出現，之後會再嘗試 patch…"; return 1
}
patch_calico_use_quay(){
  log "[image] 將 calico 工作負載改用 quay.io (CALICO=${CALICO_VERSION})"
  local tmp=/tmp/calico-ds.json
  if ! KCTL -n kube-system get ds calico-node -o json > "$tmp" 2>/dev/null; then warn "找不到 calico-node DS，略過此次 patch"; return 0; fi
  jq --arg v "${CALICO_VERSION}" '
    .spec.template.spec.containers |= (map(if .name=="calico-node" then .image = ("quay.io/calico/node:"+$v) else . end)) |
    .spec.template.spec.initContainers |= (map(if (.name=="upgrade-ipam" or .name=="install-cni") then .image = ("quay.io/calico/cni:"+$v) else . end))
  ' "$tmp" | KCTL apply -f -
  rm -f "$tmp" || true
  KCTL -n kube-system set image deploy/calico-kube-controllers calico-kube-controllers="quay.io/calico/kube-controllers:${CALICO_VERSION}" || true
  KCTL -n kube-system rollout status ds/calico-node --timeout=480s || true
  KCTL -n kube-system rollout status deploy/calico-kube-controllers --timeout=480s || true
}

# ---------- CoreDNS / Storage ----------
patch_coredns_image(){
  # 把 coredns 的 image 改到 registry.k8s.io，避開 Docker Hub 限額
  if KCTL -n kube-system get deploy coredns >/dev/null 2>&1; then
    log "[dns] 將 coredns image 改為 ${COREDNS_IMAGE}"
    KCTL -n kube-system set image deploy/coredns coredns="${COREDNS_IMAGE}" || true
  fi
}
ensure_dns_and_storage(){
  "$MICROK8S" status | grep -q 'dns\s\+.*enabled' || "$MICROK8S" enable dns
  "$MICROK8S" status | grep -q 'hostpath-storage\s\+.*enabled' || "$MICROK8S" enable hostpath-storage

  # 等 hostpath-provisioner
  KCTL -n kube-system rollout status deploy/hostpath-provisioner --timeout=240s || true

  # 設為預設 StorageClass
  KCTL annotate sc microk8s-hostpath storageclass.kubernetes.io/is-default-class=true --overwrite || true

  # 強制改 CoreDNS image & Corefile
  patch_coredns_image
  if ! KCTL -n kube-system rollout status deploy/coredns --timeout=180s; then
    warn "[dns] coredns rollout 超時，修復 Corefile → 1.1.1.1/8.8.8.8 並重啟"
    cat <<'YAML' | KCTL -n kube-system apply -f -
apiVersion: v1
kind: ConfigMap
metadata: { name: coredns }
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
        }
        forward . 1.1.1.1 8.8.8.8
        cache 30
        loop
        reload
        loadbalance
    }
YAML
    KCTL -n kube-system rollout restart deploy/coredns || true
    KCTL -n kube-system rollout status deploy/coredns --timeout=240s || true
  fi
}

# ---------- CPU/GPU 偵測與 Profiles ----------
CPU_TOTAL=1; MEM_GIB=2; GPU_COUNT=0
_detect_resources(){
  is_cmd nproc && CPU_TOTAL=$(nproc --all 2>/dev/null || nproc || echo 1)
  [[ -r /proc/meminfo ]] && MEM_GIB=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 2)
  is_cmd nvidia-smi && GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | awk '{print $1+0}')
  log "[detect] CPU=${CPU_TOTAL} cores; MEM=${MEM_GIB}Gi; GPU=${GPU_COUNT}"
}
_render_profiles_json(){
  local cpu_base=4 mem_base=32; (( CPU_TOTAL < cpu_base )) && cpu_base=$CPU_TOTAL; (( MEM_GIB < mem_base )) && mem_base=$MEM_GIB
  (( cpu_base < 1 )) && cpu_base=1; (( mem_base < 2 )) && mem_base=2
  local arr; arr=$(printf '[{"display_name":"cpu-node","description":"0 GPU / %d cores / %dGi","kubespawner_override":{"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG"}}' "$cpu_base" "$mem_base" "$cpu_base" "$cpu_base" "$mem_base" "$mem_base")
  local targets=(1 2 4 8); local max_mem_cap=$(( MEM_GIB*80/100 )); (( max_mem_cap<4 )) && max_mem_cap=4; local reserve_cpu=1
  local cpu_cap=$(( CPU_TOTAL>reserve_cpu ? CPU_TOTAL-reserve_cpu : CPU_TOTAL )); local per_gpu_cpu=8; local per_gpu_mem=192
  for g in "${targets[@]}"; do
    (( g > GPU_COUNT )) && continue
    local want_cpu=$(( per_gpu_cpu*g )); local want_mem=$(( per_gpu_mem*g ))
    local use_cpu=$want_cpu; (( use_cpu>cpu_cap )) && use_cpu=$cpu_cap; (( use_cpu<1 )) && use_cpu=1
    local use_mem=$want_mem; (( use_mem>max_mem_cap )) && use_mem=$max_mem_cap; (( use_mem<4 )) && use_mem=4
    arr+=$(printf ',{"display_name":"h100-%dv","description":"%d×GPU / %d cores / %dGi","kubespawner_override":{"runtime_class_name":"nvidia","extra_resource_limits":{"nvidia.com/gpu":%d},"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG"}}' "$g" "$g" "$use_cpu" "$use_mem" "$g" "$use_cpu" "$use_cpu" "$use_mem" "$use_mem")
  done; arr+=']'; echo "$arr"
}

# ---------- 生成 values.yaml ----------
_write_values_yaml(){
  local profiles_json; profiles_json="$(_render_profiles_json)"; mkdir -p /root/jhub
  jq -n \
    --arg name "${SINGLEUSER_IMAGE%%:*}" --arg tag "${SINGLEUSER_IMAGE##*:}" \
    --arg pvc "${PVC_SIZE}" --arg admin "${ADMIN_USER}" \
    --argjson port ${NODEPORT_FALLBACK_PORT} --argjson profiles "${profiles_json}" \
    --argjson http_to ${SPAWNER_HTTP_TIMEOUT} --argjson start_to ${KUBESPAWNER_START_TIMEOUT} '
{
  proxy: { service: { type: "NodePort", nodePorts: { http: $port } } },
  prePuller: { hook: { enabled: false }, continuous: { enabled: false } },
  singleuser: {
    image: { name: $name, tag: $tag },
    storage: {
      dynamic: { storageClass: "microk8s-hostpath" },
      capacity: $pvc,
      extraVolumes: [
        { name: "storage-local", persistentVolumeClaim: { claimName: "storage-local-pvc" } },
        { name: "jhub-logs",     persistentVolumeClaim: { claimName: "jhub-logs-pvc" } }
      ],
      extraVolumeMounts: [
        { name: "storage-local", mountPath: "/workspace/Storage" },
        { name: "jhub-logs",     mountPath: "/var/log/jupyter" }
      ]
    },
    profileList: $profiles
  },
  hub: {
    db: { type: "sqlite-memory" },   # 先確保能起；要持久化之後再改 PVC
    config: {
      JupyterHub: { admin_access: true },
      Authenticator: { admin_users: [ $admin ] },
      Spawner: { http_timeout: $http_to, start_timeout: $start_to }
    }
  }
}' > /root/jhub/values.yaml
  nl -ba /root/jhub/values.yaml | sed -n '1,200p' || true
}

# ---------- PV/PVC：Storage & Logs ----------
ensure_local_pv(){
  mkdir -p "$(pwd)/Storage" /var/log/jupyterhub
  KCTL get ns "${JHUB_NS}" >/dev/null 2>&1 || KCTL create ns "${JHUB_NS}"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: { name: storage-local-pv }
spec:
  capacity: { storage: 1Ti }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: "$(pwd)/Storage" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: storage-local-pvc, namespace: ${JHUB_NS} }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: 1Ti } }
  volumeName: storage-local-pv
  storageClassName: ""
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: jhub-logs-pv }
spec:
  capacity: { storage: 50Gi }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: "/var/log/jupyterhub" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: jhub-logs-pvc, namespace: ${JHUB_NS} }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: 50Gi } }
  volumeName: jhub-logs-pv
  storageClassName: ""
YAML
}

# ---------- IB / GPU ----------
install_network_operator(){
  [[ "${ENABLE_IB}" != "true" ]] && return 0
  log "[IB] 安裝 NVIDIA Network Operator（不套用自訂 CR）"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update nvidia >/dev/null 2>&1 || true
  local args=(--namespace nvidia-network-operator --create-namespace)
  [[ -n "${NETWORK_OPERATOR_VERSION}" ]] && args+=(--version "${NETWORK_OPERATOR_VERSION}")
  helm upgrade --install network-operator nvidia/network-operator "${args[@]}" || warn "[IB] Network Operator 安裝有誤，先略過（之後可手動調整）"
}
ensure_runtimeclass_nvidia(){
  KCTL get runtimeclass nvidia >/dev/null 2>&1 && return 0
  cat <<'YAML' | KCTL apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: { name: nvidia }
handler: nvidia
YAML
}
install_gpu_operator(){
  [[ "${USE_GPU_OPERATOR}" != "true" ]] && return 0
  KCTL -n kube-system delete ds nvidia-device-plugin-daemonset --ignore-not-found >/dev/null 2>&1 || true
  log "[GPU] 安裝 NVIDIA GPU Operator"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update nvidia >/dev/null 2>&1 || true
  local ARGS=(--install --wait gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace)
  [[ "${GPU_OPERATOR_DISABLE_DRIVER}" == "true" ]] && ARGS+=(--set driver.enabled=false)
  if [[ "${GPU_OPERATOR_DISABLE_TOOLKIT}" != "true" ]]; then
    ARGS+=(--set toolkit.enabled=true --set cdi.enabled=true --set cdi.default=true)
    ARGS+=(--set operator.defaultRuntime=containerd)
    ARGS+=(--set toolkit.env[0].name=CONTAINERD_CONFIG --set toolkit.env[0].value="/var/snap/microk8s/current/args/containerd-template.toml")
    ARGS+=(--set toolkit.env[1].name=CONTAINERD_SOCKET --set toolkit.env[1].value="/var/snap/microk8s/common/run/containerd.sock")
    ARGS+=(--set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS --set toolkit.env[2].value=nvidia)
    ARGS+=(--set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT --set-string toolkit.env[3].value=true)
  fi
  [[ -n "${GPU_OPERATOR_VERSION}" ]] && ARGS+=(--version "${GPU_OPERATOR_VERSION}")
  helm upgrade "${ARGS[@]}"
  ensure_runtimeclass_nvidia
}

# ---------- CUDA 冒煙測試（可略過） ----------
deploy_cuda_smoketest(){
  if ! CTR images ls | awk '{print $1}' | grep -q '^docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04$'; then
    warn "[cuda] 未發現已側載的 nvidia/cuda:12.4.1-base-ubuntu22.04，略過冒煙測試"
    return 0
  fi
  cat <<'YAML' | KCTL apply -f -
apiVersion: v1
kind: Pod
metadata: { name: cuda-test }
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["bash","-lc","nvidia-smi && sleep 1"]
    resources: { limits: { nvidia.com/gpu: 1 } }
YAML
  for _ in {1..40}; do KCTL logs pod/cuda-test >/dev/null 2>&1 && break || true; sleep 3; done
  KCTL logs pod/cuda-test || true
  KCTL delete pod cuda-test --ignore-not-found
}

# ---------- 診斷小工具 ----------
install_diag_tool(){
  cat >/usr/local/bin/jhub-diag <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
NS="${1:-jhub}"
echo "== Pods in $NS =="; microk8s kubectl -n "$NS" get pods -o wide || true
echo "== CoreDNS =="; microk8s kubectl -n kube-system get deploy coredns; microk8s kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide || true
echo "== Events (last 50) =="; microk8s kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 50 || true
echo "== Hub logs (tail) =="; pod=$(microk8s kubectl -n "$NS" get pods -l component=hub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); [[ -n "$pod" ]] && microk8s kubectl -n "$NS" logs "$pod" --tail=100 || true
EOS
  chmod +x /usr/local/bin/jhub-diag
}

# ---------- 主要流程 ----------
main(){
  require_root
  ensure_env
  preflight_sysctl
  ensure_microk8s
  if is_rhel; then need_pkg curl jq tar ca-certificates iproute; else need_pkg curl ca-certificates jq tar; fi
  ensure_helm
  images_import
  ensure_apiserver_ready

  wait_for_calico_ds || true
  patch_calico_use_quay

  ensure_dns_and_storage

  # 先建 namespace 與本地 PV/PVC（Storage 與 Logs）
  KCTL get ns "${JHUB_NS}" >/dev/null 2>&1 || KCTL create ns "${JHUB_NS}"
  ensure_local_pv

  # IB/GPU
  install_network_operator
  install_gpu_operator

  # 生成 values.yaml
  _detect_resources
  _write_values_yaml

  # 安裝 JupyterHub
  helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null 2>&1 || true
  helm repo update jupyterhub >/dev/null 2>&1 || true
  log "[act] 部署 JupyterHub chart ${JHUB_CHART_VERSION}"
  helm upgrade --cleanup-on-fail --install "${JHUB_RELEASE}" jupyterhub/jupyterhub \
    -n "${JHUB_NS}" --version "${JHUB_CHART_VERSION}" \
    -f /root/jhub/values.yaml --timeout "${HELM_TIMEOUT}"

  log "[wait] 等待 Hub/Proxy 就緒"
  wait_rollout "${JHUB_NS}" deploy hub 900s
  wait_rollout "${JHUB_NS}" deploy proxy 600s
  KCTL -n "${JHUB_NS}" get pods,svc

  # port-forward 小工具
  install_portforward_tool
  install_diag_tool

  ACCESS_URL="http://$(hostname -I | awk '{print $1}'):${NODEPORT_FALLBACK_PORT}"
  if [[ "${PF_AUTOSTART}" == "true" ]]; then pf_stop || true; pf_start && ACCESS_URL="http://${PF_BIND_ADDR}:${PF_LOCAL_PORT}"; fi

  # CUDA 冒煙（若側載）
  if [[ "${USE_GPU_OPERATOR}" == "true" ]]; then deploy_cuda_smoketest || true; fi

  cat <<EOF

============================================================
✅ JupyterHub 安裝完成（offline side-load + Calico via quay + CoreDNS fix + JSON-in-YAML）
▶ 存取網址：${ACCESS_URL}
▶ 管理者（admin_users）：${ADMIN_USER}
▶ 儲存 PVC：${PVC_SIZE}（SC: microk8s-hostpath + 本地 PV）
▶ SingleUser 映像：${SINGLEUSER_IMAGE}
▶ 掛載：./Storage → /workspace/Storage；/var/log/jupyterhub → /var/log/jupyter
▶ Profiles：依 CPU=${CPU_TOTAL} / RAM=${MEM_GIB}Gi / GPU=${GPU_COUNT} 動態生成
▶ 背景 pf 工具：sudo jhub-portforward {start|stop|status}
▶ 診斷工具：sudo jhub-diag ${JHUB_NS}
▶ Service：NodePort:${NODEPORT_FALLBACK_PORT}
▶ Spawner 逾時：http_timeout=${SPAWNER_HTTP_TIMEOUT}s, start_timeout=${KUBESPAWNER_START_TIMEOUT}s
▶ Hub DB：sqlite-memory（先確保能起，需持久化再改）
============================================================

【對外 API】
  你的 Notebook 內監聽的服務（例如 8888）可從外部以：
    http://<node_ip>:${NODEPORT_FALLBACK_PORT}/user/<username>/proxy/8888/...
  這是 JupyterHub 的標準代理路徑規則（base_url 下掛 /proxy/<port>）。:contentReference[oaicite:3]{index=3}

【常見故障快速檢查】
  1) DNS：若 coredns Pod 是 ImagePullBackOff，請確認已套用 ${COREDNS_IMAGE}（本腳本已強制）。:contentReference[oaicite:4]{index=4}
     - 看看：microk8s kubectl -n kube-system get deploy coredns -o yaml | grep image:
  2) Hub 狀態：sudo jhub-diag ${JHUB_NS}
  3) 仍有問題？先重跑：microk8s kubectl -n kube-system rollout restart deploy/coredns
EOF
}

main "$@"
