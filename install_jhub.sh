#!/usr/bin/env bash
# JupyterHub one-shot installer v4.6 (modular + offline side-load + coredns fix + logs + API proxy hints)
set -euo pipefail

DEFAULT_HOST_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')"
if [[ -z "${DEFAULT_HOST_IP}" ]] && command -v ip >/dev/null 2>&1; then
  DEFAULT_HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
if [[ -z "${DEFAULT_HOST_IP}" ]]; then
  DEFAULT_HOST_IP="localhost"
fi

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
: "${SINGLEUSER_IMAGE:=myorg3/pytorch-jhub:24.10}"
: "${SINGLEUSER_IMAGE_PULL_POLICY:=IfNotPresent}"
: "${PVC_SIZE:=20Gi}"
: "${SINGLEUSER_STORAGE_CLASS:=microk8s-hostpath}"
: "${SHARED_STORAGE_ENABLED:=true}"
: "${SHARED_STORAGE_SIZE:=1Ti}"
: "${SHARED_STORAGE_PATH:=./Storage}"
: "${HOSTPATH_PROVISIONER_IMAGE:=}"
: "${HOSTPATH_PROVISIONER_TAR:=}"

# Spawn/連線逾時，避免大鏡像超時
: "${SPAWNER_HTTP_TIMEOUT:=180}"
: "${KUBESPAWNER_START_TIMEOUT:=900}"

# GPU 與 IB（Network Operator）選項
: "${USE_GPU_OPERATOR:=true}"
: "${GPU_OPERATOR_VERSION:=}"         # 例如 23.9.1（留空用最新 chart）
: "${GPU_OPERATOR_DISABLE_DRIVER:=false}"
: "${GPU_OPERATOR_DRIVER_VERSION:=580.65.06}"
: "${GPU_OPERATOR_DISABLE_TOOLKIT:=false}"
: "${GPU_OPERATOR_DRIVER_RUNFILE_URL:=}"
: "${GPU_OPERATOR_DRIVER_PKG_MANAGER:=}" # 例如 deb 或 rpm；留空則由 Operator 自判

: "${ENABLE_IB:=false}"               # true 則安裝 NVIDIA Network Operator（不額外套 CR）
: "${NETWORK_OPERATOR_VERSION:=}"     # 例如 24.7.0（留空用最新 chart）
: "${JHUB_FRAME_ANCESTORS:=http://${DEFAULT_HOST_IP} http://localhost:8080}"

# Ingress / TLS
: "${ENABLE_INGRESS:=false}"
: "${INGRESS_HOST:=${DEFAULT_HOST_IP}}"
: "${INGRESS_TLS_SECRET:=jhub-tls}"
: "${TLS_CERT_FILE:=}"
: "${TLS_KEY_FILE:=}"
: "${INGRESS_ANNOTATIONS_JSON:=}"

# Idle culling
: "${ENABLE_IDLE_CULLER:=true}"
: "${CULL_TIMEOUT_SECONDS:=3600}"
: "${CULL_EVERY_SECONDS:=300}"
: "${CULL_CONCURRENCY:=10}"
: "${CULL_USERS:=false}"

# Pre-pull images
: "${PREPULL_IMAGES:=false}"
: "${PREPULL_EXTRA_IMAGES:=}"

# Network policy
: "${ENABLE_NETWORK_POLICY:=true}"

# Node 選擇 / 污點容忍
: "${SINGLEUSER_NODE_SELECTOR_JSON:=}"
: "${SINGLEUSER_TOLERATIONS_JSON:=}"
: "${HUB_NODE_SELECTOR_JSON:=}"
: "${HUB_TOLERATIONS_JSON:=}"

# ResourceQuota / LimitRange
: "${ENABLE_RESOURCE_QUOTA:=false}"
: "${RQ_REQUESTS_CPU:=32}"
: "${RQ_REQUESTS_MEMORY:=128Gi}"
: "${RQ_LIMITS_CPU:=64}"
: "${RQ_LIMITS_MEMORY:=256Gi}"
: "${RQ_PODS:=50}"
: "${RQ_GPUS:=8}"
: "${LIMITRANGE_DEFAULT_CPU:=1}"
: "${LIMITRANGE_DEFAULT_MEMORY:=4Gi}"
: "${LIMITRANGE_MAX_CPU:=32}"
: "${LIMITRANGE_MAX_MEMORY:=64Gi}"

# GPU / MIG
: "${ENABLE_MIG:=false}"
: "${MIG_STRATEGY:=mixed}"
: "${MIG_RESOURCE_NAME:=nvidia.com/mig-1g.10gb}"
: "${MIG_PROFILE_NAME:=mig-1g}"
: "${MIG_CPU_CORES:=8}"
: "${MIG_MEM_GIB:=64}"
: "${MIG_TARGET_GPU_IDS:=0}"
: "${MIG_TARGET_PROFILE:=1g.10gb}"
: "${MIG_TARGET_PROFILE_COUNT:=1}"
: "${MIG_CONFIGMAP_NAME:=jhub-mig-config}"
: "${MIG_CONFIG_DEFAULT:=all-disabled}"
: "${MIG_CONFIG_PROFILE:=jhub-single-mig}"
: "${MIG_TARGET_NODES:=*}"

# 自訂映像與命名伺服器
: "${ALLOWED_CUSTOM_IMAGES:=}"
: "${ALLOW_NAMED_SERVERS:=true}"
: "${NAMED_SERVER_LIMIT:=5}"
# 離線側載檔名（存在才會載入）
: "${CALICO_VERSION:=v3.25.1}"
: "${CALICO_BUNDLE:=./calico-v3.25.1-bundle.tar}"
: "${NOTEBOOK_TAR:=./jhub_24.10_3.tar}"
: "${COREDNS_TAR:=}"                  # 可選：例如 ./coredns_v1.10.1.tar（含 registry.k8s.io/coredns/coredns:v1.10.1）
: "${COREDNS_IMAGE:=registry.k8s.io/coredns/coredns:v1.10.1}"

# --- 新增：讓 adminuser 的單人伺服器可直接對外（免 Hub 登入） ---
: "${EXPOSE_ADMINUSER_NODEPORT:=true}"   # true=建立 NodePort 服務
: "${ADMINUSER_TARGET_PORT:=8000}"       # Notebook 內 FastAPI 監聽埠
: "${ADMINUSER_NODEPORT:=32081}"         # 對外固定 NodePort (30000-32767)
: "${ADMINUSER_PORTFORWARD:=false}"      # true=另外以 port-forward 映射本機
: "${ADMINUSER_PF_PORT:=18081}"          # adminuser port-forward 本機埠
: "${ADMINUSER_PF_BIND_ADDR:=127.0.0.1}" # adminuser port-forward 綁定位址


###### ========= 常數與工具 =========
HELM_TARBALL_VERSION="v3.15.3"
K8S_CHANNEL="1.30/stable"
KUBECONFIG_PATH="/var/snap/microk8s/current/credentials/client.config"
PF_PROXY_PID="/var/run/jhub-pf.pid"
PF_PROXY_LOG="/var/log/jhub-port-forward.log"
MICROK8S="/snap/bin/microk8s"
ADMINUSER_PF_PID="/var/run/jhub-adminuser-pf.pid"
ADMINUSER_PF_LOG="/var/log/jhub-adminuser-port-forward.log"

log(){ echo -e "\e[1;36m$*\e[0m"; }
ok(){ echo -e "\e[1;32m$*\e[0m"; }
warn(){ echo -e "\e[1;33m$*\e[0m"; }
err(){ echo -e "\e[1;31m$*\e[0m" 1>&2; }

_bool_to_json(){
  [[ "${1,,}" == "true" || "${1}" == "1" ]] && echo true || echo false
}
_parse_json_or_default(){
  local value="$1" default="$2" name="$3"
  if [[ -z "${value}" ]]; then
    echo "${default}"
    return 0
  fi
  if echo "${value}" | jq -c '.' >/dev/null 2>&1; then
    echo "${value}"
  else
    warn "[json] ${name:-值} 解析失敗，改用預設 ${default}"
    echo "${default}"
  fi
}
_csv_to_json_array(){
  local value="$1"
  if [[ -z "${value}" ]]; then
    echo '[]'
  else
    printf '%s' "${value}" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))'
  fi
}
_ensure_numeric_or_default(){
  local value="$1" default="$2" name="${3:-value}"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
  else
    [[ -n "${value}" ]] && warn "[num] ${name}=${value} 非整數，改用預設 ${default}"
    echo "${default}"
  fi
}
_indent(){
  local spaces="${1:-2}"
  local pad
  printf -v pad '%*s' "${spaces}" ''
  sed "s/^/${pad}/"
}
_split_image_components(){
  local image="$1" digest="" tag="" registry="" remainder="$1"
  if [[ "$remainder" == *@* ]]; then
    digest="${remainder##*@}"
    remainder="${remainder%%@*}"
  fi
  if [[ "${remainder##*/}" == *":"* ]]; then
    tag="${remainder##*:}"
    remainder="${remainder%:*}"
  fi
  local repository="$remainder"
  if [[ "$repository" == */* ]]; then
    local first_segment="${repository%%/*}"
    if [[ "$first_segment" == "localhost" || "$first_segment" == *"."* || "$first_segment" == *":"* ]]; then
      registry="$first_segment"
      repository="${repository#*/}"
    fi
  fi
  printf '%s|%s|%s|%s\n' "${registry}" "${repository}" "${tag}" "${digest}"
}
_image_exists_locally(){
  local ref="$1"
  CTR images ls --quiet | grep -Fx "${ref}" >/dev/null 2>&1
}
require_root(){ [[ $EUID -eq 0 ]] || { err "請用 sudo 執行：sudo $0"; exit 1; }; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_rhel(){ [[ -f /etc/redhat-release || -f /etc/os-release && "$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '\"')" == "rhel" ]]; }
is_deb(){ [ -f /etc/debian_version ]; }
KCTL(){ "$MICROK8S" kubectl "$@"; }
CTR(){ CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr "$@"; }
wait_rollout(){ KCTL -n "$1" rollout status "$2/$3" --timeout="${4:-600s}" || true; }

# ---------- Port-forward 工具 ----------
pf_stop(){ [[ -f "${PF_PROXY_PID}" ]] && kill "$(cat "${PF_PROXY_PID}")" 2>/dev/null || true; rm -f "${PF_PROXY_PID}" 2>/dev/null || true; }
pf_start(){
  nohup "$MICROK8S" kubectl -n "${JHUB_NS}" port-forward svc/proxy-public --address "${PF_BIND_ADDR}" "${PF_LOCAL_PORT}:80" >"${PF_PROXY_LOG}" 2>&1 & echo $! > "${PF_PROXY_PID}"
  for _ in {1..30}; do (exec 3<>/dev/tcp/${PF_BIND_ADDR}/${PF_LOCAL_PORT}) >/dev/null 2>&1 && { ok "[pf] ${PF_BIND_ADDR}:${PF_LOCAL_PORT} 已連通（pid $(cat ${PF_PROXY_PID})）"; return 0; }; sleep 1; done
  warn "[pf] 啟動疑似失敗，最近 log："; tail -n 50 "${PF_PROXY_LOG}" || true; return 1
}
adminuser_pf_stop(){ [[ -f "${ADMINUSER_PF_PID}" ]] && kill "$(cat "${ADMINUSER_PF_PID}")" 2>/dev/null || true; rm -f "${ADMINUSER_PF_PID}" 2>/dev/null || true; }
adminuser_pf_start(){
  local addr="${ADMINUSER_PF_BIND_ADDR}"
  [[ -z "${addr}" ]] && addr="127.0.0.1"
  mkdir -p "$(dirname "${ADMINUSER_PF_LOG}")"
  : > "${ADMINUSER_PF_LOG}"
  nohup bash -s -- "${JHUB_NS}" "$addr" "${ADMINUSER_PF_PORT}" "${ADMINUSER_TARGET_PORT}" "${ADMINUSER_PF_LOG}" "$MICROK8S" >"${ADMINUSER_PF_LOG}" 2>&1 <<'EOS' &
set -euo pipefail
NS="$1"
ADDR="$2"
HOST_PORT="$3"
TARGET_PORT="$4"
LOG_FILE="$5"
MICROK8S_BIN="$6"
echo "[pf] waiting for endpoints..." >>"$LOG_FILE"
while true; do
  if "$MICROK8S_BIN" kubectl -n "$NS" get endpoints adminuser-fastapi-np -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -q '.'; then
    echo "[pf] endpoint ready, starting port-forward" >>"$LOG_FILE"
    break
  fi
  sleep 5
done
exec "$MICROK8S_BIN" kubectl -n "$NS" port-forward svc/adminuser-fastapi-np --address "$ADDR" "$HOST_PORT:$TARGET_PORT"
EOS
  echo $! > "${ADMINUSER_PF_PID}"
  for _ in {1..60}; do
    if (exec 3<>/dev/tcp/${addr}/${ADMINUSER_PF_PORT}) >/dev/null 2>&1; then
      ok "[api] adminuser port-forward ${addr}:${ADMINUSER_PF_PORT}→${ADMINUSER_TARGET_PORT} 已啟動（pid $(cat ${ADMINUSER_PF_PID})）"
      return 0
    fi
    sleep 2
  done
  warn "[api] adminuser port-forward 尚未建立（可能等待 singleuser pod 啟動），背景工作會持續重試"
  return 1
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
status(){ if ss -ltn | grep -q ":${LOCAL_PORT} " ; then
  echo "running → http://$BIND_ADDR:$LOCAL_PORT"
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
_ensure_kubelet_image_gc_disabled(){
  local kubelet_args="/var/snap/microk8s/current/args/kubelet"
  [[ -f "${kubelet_args}" ]] || return 0
  local updated=false
  if grep -q -- '--image-gc-high-threshold=' "${kubelet_args}"; then
    if ! grep -q -- '--image-gc-high-threshold=100' "${kubelet_args}"; then
      sed -i 's/--image-gc-high-threshold=[^[:space:]]*/--image-gc-high-threshold=100/' "${kubelet_args}"
      updated=true
    fi
  else
    echo "--image-gc-high-threshold=100" >> "${kubelet_args}"
    updated=true
  fi
  if grep -q -- '--image-gc-low-threshold=' "${kubelet_args}"; then
    if ! grep -q -- '--image-gc-low-threshold=99' "${kubelet_args}"; then
      sed -i 's/--image-gc-low-threshold=[^[:space:]]*/--image-gc-low-threshold=99/' "${kubelet_args}"
      updated=true
    fi
  else
    echo "--image-gc-low-threshold=99" >> "${kubelet_args}"
    updated=true
  fi
  if [[ "${updated}" == true ]]; then
    log "[kubelet] 調整 image GC 門檻（high=100, low=99），避免自動回收側載映像"
    if command -v snapctl >/dev/null 2>&1; then
      if ! snapctl restart microk8s.daemon-kubelet >/dev/null 2>&1; then
        warn "[kubelet] snapctl restart microk8s.daemon-kubelet 失敗，請手動確認"
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      if ! systemctl restart snap.microk8s.daemon-kubelet.service; then
        warn "[kubelet] systemctl 重啟 kubelet 失敗，請手動確認"
      fi
    else
      warn "[kubelet] 找不到 snapctl/systemctl，請手動重啟 kubelet"
    fi
  fi
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
  if [[ -f "${NOTEBOOK_TAR}" ]]; then
    local tar_repo=""
    if is_cmd jq && tar -tf "${NOTEBOOK_TAR}" manifest.json >/dev/null 2>&1; then
      tar_repo=$(tar -xf "${NOTEBOOK_TAR}" manifest.json -O | jq -r '.[0].RepoTags[0]' 2>/dev/null || true)
    fi
   log "[images] 匯入 Notebook 映像：${NOTEBOOK_TAR}"
   local -a before_images after_images new_image_refs=()
   mapfile -t before_images < <(CTR images ls --quiet | LC_ALL=C sort -u)
   if "$MICROK8S" images import "${NOTEBOOK_TAR}"; then
     ok "[images] Notebook 映像匯入成功（microk8s images import）"
   else
     warn "[images] microk8s images import 失敗，改用 ctr fallback"
      if CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${NOTEBOOK_TAR}" >/dev/null 2>&1; then
        ok "[images] Notebook 映像匯入成功（ctr fallback）"
      else
        err "[images] Notebook tar 匯入失敗，無法匯入 ${NOTEBOOK_TAR}"
        return 1
      fi
    fi
    mapfile -t after_images < <(CTR images ls --quiet | LC_ALL=C sort -u)
    mapfile -t new_image_refs < <(comm -13 \
      <(printf '%s\n' "${before_images[@]}" | LC_ALL=C sort -u) \
      <(printf '%s\n' "${after_images[@]}" | LC_ALL=C sort -u))
    if [[ -n "${tar_repo}" && "${tar_repo}" != "${SINGLEUSER_IMAGE}" ]]; then
      warn "[images] tar 內 repo tag (${tar_repo}) 與設定 ${SINGLEUSER_IMAGE} 不同，嘗試重新 tag"
      CTR images tag "${tar_repo}" "${SINGLEUSER_IMAGE}" || true
    fi
    local candidate_ref="" ref
    for ref in "${new_image_refs[@]}"; do
      [[ -z "${ref}" || "${ref}" == *@* ]] && continue
      candidate_ref="${ref}"
      break
    done
    if [[ -z "${candidate_ref}" && -n "${tar_repo}" ]]; then
      candidate_ref="${tar_repo}"
    fi
    if [[ -n "${candidate_ref}" && "${candidate_ref}" != "${SINGLEUSER_IMAGE}" ]]; then
      warn "[images] 重新標記 ${candidate_ref} → ${SINGLEUSER_IMAGE}"
      CTR images tag "${candidate_ref}" "${SINGLEUSER_IMAGE}" || warn "[images] 重新標記 ${candidate_ref} 失敗"
    fi
    # 等待影像在 containerd 中可用
    sleep 10
    if ! _image_exists_locally "${SINGLEUSER_IMAGE}"; then
      local docker_prefix_ref="docker.io/${SINGLEUSER_IMAGE}"
      if _image_exists_locally "${docker_prefix_ref}"; then
        warn "[images] 找到 ${docker_prefix_ref}，同步標記為 ${SINGLEUSER_IMAGE}"
        CTR images tag "${docker_prefix_ref}" "${SINGLEUSER_IMAGE}" || true
      fi
    fi
    if ! _image_exists_locally "${SINGLEUSER_IMAGE}"; then
      err "[images] 匯入後仍找不到 ${SINGLEUSER_IMAGE}，請檢查 ${NOTEBOOK_TAR}"
      if ((${#new_image_refs[@]})); then
        printf '    新增的映像標記：%s\n' "${new_image_refs[@]}" >&2 || true
      fi
      return 1
    fi
    ok "[images] 成功驗證 Notebook 映像存在"
  else
    warn "[images] 找不到 ${NOTEBOOK_TAR}（不影響 Hub 部署，可之後再匯入）"
  fi
  if [[ -n "${HOSTPATH_PROVISIONER_TAR}" ]]; then
    if [[ -f "${HOSTPATH_PROVISIONER_TAR}" ]]; then
      log "[images] 匯入 HostPath Provisioner 映像：${HOSTPATH_PROVISIONER_TAR}"
      if "$MICROK8S" images import "${HOSTPATH_PROVISIONER_TAR}"; then
        ok "[images] HostPath 映像匯入成功（microk8s images import）"
      else
        warn "[images] microk8s images import 失敗，改用 ctr 匯入 HostPath 映像"
        if CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${HOSTPATH_PROVISIONER_TAR}" >/dev/null 2>&1; then
          ok "[images] HostPath 映像匯入成功（ctr fallback）"
        else
          warn "[images] HostPath tar 匯入失敗，請手動確認"
        fi
      fi
      if [[ -n "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
        local hostpath_repo=""
        if is_cmd jq && tar -tf "${HOSTPATH_PROVISIONER_TAR}" manifest.json >/dev/null 2>&1; then
          hostpath_repo=$(tar -xf "${HOSTPATH_PROVISIONER_TAR}" manifest.json -O | jq -r '.[0].RepoTags[0]' 2>/dev/null || true)
        fi
        if [[ -n "${hostpath_repo}" && "${hostpath_repo}" != "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
          warn "[images] HostPath tar repo (${hostpath_repo}) 與設定 ${HOSTPATH_PROVISIONER_IMAGE} 不同，嘗試重新 tag"
          CTR images tag "${hostpath_repo}" "${HOSTPATH_PROVISIONER_IMAGE}" || true
        fi
      fi
    else
      warn "[images] 找不到 ${HOSTPATH_PROVISIONER_TAR}，HostPath Provisioner 可能需要線上拉取"
    fi
  elif [[ -n "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
    warn "[images] 未提供 ${HOSTPATH_PROVISIONER_TAR}，將直接使用 ${HOSTPATH_PROVISIONER_IMAGE} 線上拉取"
  fi
  if [[ -n "${COREDNS_TAR}" && -f "${COREDNS_TAR}" ]]; then log "[images] 匯入 CoreDNS 映像：${COREDNS_TAR}" || true; "$MICROK8S" images import "${COREDNS_TAR}" || warn "[images] CoreDNS tar 匯入失敗（略過）"; fi
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
patch_hostpath_provisioner_image(){
  [[ -z "${HOSTPATH_PROVISIONER_IMAGE}" ]] && return 0
  if ! KCTL -n kube-system get deploy hostpath-provisioner >/dev/null 2>&1; then
    warn "[storage] 找不到 hostpath-provisioner deployment，略過 image patch"
    return 0
  fi
  log "[storage] 將 hostpath-provisioner image 改為 ${HOSTPATH_PROVISIONER_IMAGE}"
  if ! KCTL -n kube-system set image deploy/hostpath-provisioner hostpath-provisioner="${HOSTPATH_PROVISIONER_IMAGE}"; then
    warn "[storage] 調整 hostpath-provisioner image 失敗"
    return 0
  fi
  KCTL -n kube-system rollout restart deploy/hostpath-provisioner || true
  KCTL -n kube-system rollout status deploy/hostpath-provisioner --timeout=300s || true
}
ensure_dns_and_storage(){
  "$MICROK8S" status | grep -q 'dns\s\+.*enabled' || "$MICROK8S" enable dns
  "$MICROK8S" status | grep -q 'hostpath-storage\s\+.*enabled' || "$MICROK8S" enable hostpath-storage

  # 等 hostpath-provisioner
  KCTL -n kube-system rollout status deploy/hostpath-provisioner --timeout=240s || true
  patch_hostpath_provisioner_image

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
  local arr; arr=$(printf '[{"display_name":"cpu-node","description":"0 GPU / %d cores / %dGi","kubespawner_override":{"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG","environment":{"CUDA_VISIBLE_DEVICES":"","NVIDIA_VISIBLE_DEVICES":"void","PYTORCH_ENABLE_MPS_FALLBACK":"1"}}}' "$cpu_base" "$mem_base" "$cpu_base" "$cpu_base" "$mem_base" "$mem_base")
  local targets=(1 2 4 8); local max_mem_cap=$(( MEM_GIB*80/100 )); (( max_mem_cap<4 )) && max_mem_cap=4; local reserve_cpu=1
  local cpu_cap=$(( CPU_TOTAL>reserve_cpu ? CPU_TOTAL-reserve_cpu : CPU_TOTAL )); local per_gpu_cpu=8; local per_gpu_mem=192
  for g in "${targets[@]}"; do
    (( g > GPU_COUNT )) && continue
    local want_cpu=$(( per_gpu_cpu*g )); local want_mem=$(( per_gpu_mem*g ))
    local use_cpu=$want_cpu; (( use_cpu>cpu_cap )) && use_cpu=$cpu_cap; (( use_cpu<1 )) && use_cpu=1
    local use_mem=$want_mem; (( use_mem>max_mem_cap )) && use_mem=$max_mem_cap; (( use_mem<4 )) && use_mem=4
    local cuda_vis=""
    if (( g > 0 )); then
      local -a idx=()
      for ((i=0;i<g;i++)); do idx+=("$i"); done
      cuda_vis=$(IFS=,; echo "${idx[*]}")
    fi
    arr+=$(printf ',{"display_name":"h100-%dv","description":"%d×GPU / %d cores / %dGi","kubespawner_override":{"extra_pod_config":{"runtimeClassName":"nvidia"},"extra_resource_limits":{"nvidia.com/gpu":%d},"environment":{"CUDA_VISIBLE_DEVICES":"%s","NVIDIA_VISIBLE_DEVICES":"all","PYTORCH_CUDA_ALLOC_CONF":"expandable_segments:True","CUDA_COMPAT_PATH":"/usr/local/cuda-13.0/compat/lib.real","LD_LIBRARY_PATH":"/usr/local/cuda-13.0/compat/lib.real:/usr/local/lib/python3.12/dist-packages/torch/lib:/usr/local/lib/python3.12/dist-packages/torch_tensorrt/lib:/usr/local/cuda/compat/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64"},"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG"}}' "$g" "$g" "$use_cpu" "$use_mem" "$g" "$cuda_vis" "$use_cpu" "$use_cpu" "$use_mem" "$use_mem")
  done; arr+=']'
  local json="$arr"
  if [[ "${ENABLE_MIG}" == "true" ]]; then
    local mig_cpu=${MIG_CPU_CORES:-8}; (( mig_cpu<1 )) && mig_cpu=1
    local mig_mem=${MIG_MEM_GIB:-64}; (( mig_mem<4 )) && mig_mem=4
    local mig_profile="${MIG_PROFILE_NAME:-MIG}"
    local mig_resource="${MIG_RESOURCE_NAME:-nvidia.com/mig-1g.10gb}"
    json=$(echo "$json" | jq -c --arg name "${mig_profile}" --arg res "${mig_resource}" --argjson cpu "$mig_cpu" --argjson mem "$mig_mem" '
      . + [{
        display_name: $name,
        description: ("MIG 1 slice / " + ($cpu|tostring) + " cores / " + ($mem|tostring) + "Gi"),
        kubespawner_override: {
          extra_pod_config: { runtimeClassName: "nvidia" },
          environment: {
            "CUDA_VISIBLE_DEVICES": "0",
            "NVIDIA_VISIBLE_DEVICES": "all",
            "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
            "CUDA_COMPAT_PATH": "/usr/local/cuda-13.0/compat/lib.real",
            "LD_LIBRARY_PATH": "/usr/local/cuda-13.0/compat/lib.real:/usr/local/lib/python3.12/dist-packages/torch/lib:/usr/local/lib/python3.12/dist-packages/torch_tensorrt/lib:/usr/local/cuda/compat/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
          },
          extra_resource_limits: {($res):1},
          cpu_guarantee: $cpu,
          cpu_limit: $cpu,
          mem_guarantee: ($mem|tostring + "G"),
          mem_limit: ($mem|tostring + "G")
        }
      }]
    ')
  fi
  echo "$json"
}

_render_mig_manager_config(){
  local config_key="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
  local ids_raw="${MIG_TARGET_GPU_IDS:-0}"
  local profile="${MIG_TARGET_PROFILE:-1g.10gb}"
  local count
  count="$(_ensure_numeric_or_default "${MIG_TARGET_PROFILE_COUNT:-1}" 1 "MIG_TARGET_PROFILE_COUNT")"
  (( count < 1 )) && count=1
  # Normalize GPU ID list
  local -a ids=()
  IFS=',' read -ra ids <<< "${ids_raw}"
  local cleaned_ids=()
  for id in "${ids[@]}"; do
    local trimmed="${id// /}"
    [[ -z "${trimmed}" ]] && continue
    if [[ ! "${trimmed}" =~ ^[0-9]+$ ]]; then
      warn "[MIG] GPU ID '${trimmed}' 非整數，略過"
      continue
    fi
    cleaned_ids+=("${trimmed}")
  done
  if (( ${#cleaned_ids[@]} == 0 )); then
    warn "[MIG] 未提供有效的 MIG GPU ID，預設使用 GPU 0"
    cleaned_ids=(0)
  fi
  local yaml
  yaml="version: v1
mig-configs:
  all-disabled:
    - devices: all
      mig-enabled: false
  ${config_key}:
    - devices: all
      mig-enabled: false"
  local id
  for id in "${cleaned_ids[@]}"; do
    yaml+="
    - devices: [${id}]
      mig-enabled: true
      mig-devices:
        \"${profile}\": ${count}"
  done
  printf '%s\n' "${yaml}"
}

_label_mig_nodes(){
  local profile="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
  local raw="${MIG_TARGET_NODES:-*}"
  local nodes=()
  if [[ "${raw}" == "*" || "${raw,,}" == "all" ]]; then
    mapfile -t nodes < <(KCTL get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  else
    IFS=',' read -ra nodes <<< "${raw}"
  fi
  if (( ${#nodes[@]} == 0 )); then
    warn "[MIG] 找不到可標記的節點，略過 nvidia.com/mig.config 標籤"
    return 0
  fi
  for node in "${nodes[@]}"; do
    local trimmed="${node// /}"
    [[ -z "${trimmed}" ]] && continue
    log "[GPU][MIG] Label 節點 ${trimmed} -> nvidia.com/mig.config=${profile}"
    if ! KCTL label node "${trimmed}" "nvidia.com/mig.config=${profile}" --overwrite; then
      warn "[MIG] 標記節點 ${trimmed} 失敗"
    fi
  done
}

# ---------- 生成 values.yaml ----------
_write_values_yaml(){
  local profiles_json; profiles_json="$(_render_profiles_json)"; mkdir -p /root/jhub
  local ancestors_array csp
  # shellcheck disable=SC2206
  ancestors_array=(${JHUB_FRAME_ANCESTORS})
  csp="frame-ancestors ${ancestors_array[*]};"
  local custom_images_json; custom_images_json="$(_csv_to_json_array "${ALLOWED_CUSTOM_IMAGES}")"
  if [[ "${custom_images_json}" != "[]" ]]; then
    profiles_json=$(jq -nc --argjson base "${profiles_json}" --argjson imgs "${custom_images_json}" '
      $base + ($imgs | map({
        display_name: .,
        slug: ("custom-" + (gsub("[^A-Za-z0-9]+";"-"))),
        description: "自訂映像 " + .,
        kubespawner_override: {
          image: .,
          image_pull_policy: "IfNotPresent"
        }
      }))
    ')
  fi
  local singleuser_node_selector_json singleuser_tolerations_json hub_node_selector_json hub_tolerations_json ingress_annotations_json
  singleuser_node_selector_json="$(_parse_json_or_default "${SINGLEUSER_NODE_SELECTOR_JSON}" "{}" "SINGLEUSER_NODE_SELECTOR_JSON")"
  singleuser_tolerations_json="$(_parse_json_or_default "${SINGLEUSER_TOLERATIONS_JSON}" "[]" "SINGLEUSER_TOLERATIONS_JSON")"
  hub_node_selector_json="$(_parse_json_or_default "${HUB_NODE_SELECTOR_JSON}" "{}" "HUB_NODE_SELECTOR_JSON")"
  hub_tolerations_json="$(_parse_json_or_default "${HUB_TOLERATIONS_JSON}" "[]" "HUB_TOLERATIONS_JSON")"
  ingress_annotations_json="$(_parse_json_or_default "${INGRESS_ANNOTATIONS_JSON}" "{}" "INGRESS_ANNOTATIONS_JSON")"
  local shared_enabled_json ingress_enabled_json prepull_enabled_json idle_enabled_json cull_users_json named_servers_json
  shared_enabled_json="$(_bool_to_json "${SHARED_STORAGE_ENABLED}")"
  ingress_enabled_json="$(_bool_to_json "${ENABLE_INGRESS}")"
  prepull_enabled_json="$(_bool_to_json "${PREPULL_IMAGES}")"
  idle_enabled_json="$(_bool_to_json "${ENABLE_IDLE_CULLER}")"
  cull_users_json="$(_bool_to_json "${CULL_USERS}")"
  named_servers_json="$(_bool_to_json "${ALLOW_NAMED_SERVERS}")"
  local prepull_extra_json; prepull_extra_json="$(_csv_to_json_array "${PREPULL_EXTRA_IMAGES}")"
  local cull_timeout; cull_timeout="$(_ensure_numeric_or_default "${CULL_TIMEOUT_SECONDS}" 3600 "CULL_TIMEOUT_SECONDS")"
  local cull_every; cull_every="$(_ensure_numeric_or_default "${CULL_EVERY_SECONDS}" 300 "CULL_EVERY_SECONDS")"
  local cull_concurrency; cull_concurrency="$(_ensure_numeric_or_default "${CULL_CONCURRENCY}" 10 "CULL_CONCURRENCY")"
  local named_limit; named_limit="$(_ensure_numeric_or_default "${NAMED_SERVER_LIMIT}" 5 "NAMED_SERVER_LIMIT")"
  local image_components singleuser_image_registry singleuser_image_repo singleuser_image_tag singleuser_image_digest singleuser_image_name
  image_components="$(_split_image_components "${SINGLEUSER_IMAGE}")"
  IFS='|' read -r singleuser_image_registry singleuser_image_repo singleuser_image_tag singleuser_image_digest <<< "${image_components}"
  if [[ -n "${singleuser_image_registry}" ]]; then
    singleuser_image_name="${singleuser_image_registry}/${singleuser_image_repo}"
  else
    singleuser_image_name="${singleuser_image_repo}"
  fi
  local resolved_pull_policy="${SINGLEUSER_IMAGE_PULL_POLICY}"
  if [[ "${resolved_pull_policy}" == "IfNotPresent" ]]; then
    local docker_prefixed_image="docker.io/${SINGLEUSER_IMAGE}"
    if _image_exists_locally "${SINGLEUSER_IMAGE}" || _image_exists_locally "${docker_prefixed_image}"; then
      resolved_pull_policy="Never"
      log "[images] 偵測到 ${SINGLEUSER_IMAGE} 已在本地，將 singleuser image pullPolicy 改為 Never"
    fi
  fi
  SINGLEUSER_IMAGE_PULL_POLICY="${resolved_pull_policy}"
  jq -n \
    --arg image_name "${singleuser_image_name}" \
    --arg image_tag "${singleuser_image_tag}" \
    --arg image_digest "${singleuser_image_digest}" \
    --arg pvc "${PVC_SIZE}" \
    --arg storage_class "${SINGLEUSER_STORAGE_CLASS}" \
    --arg shared_mount "/workspace/Storage" \
    --arg logs_mount "/var/log/jupyter" \
    --arg image_pull_policy "${SINGLEUSER_IMAGE_PULL_POLICY}" \
    --arg csp "$csp" \
    --arg admin "${ADMIN_USER}" \
    --arg auth_class "nativeauthenticator.NativeAuthenticator" \
    --arg host "${INGRESS_HOST}" \
    --arg tls_secret "${INGRESS_TLS_SECRET}" \
    --argjson port ${NODEPORT_FALLBACK_PORT} \
    --argjson profiles "${profiles_json}" \
    --argjson http_to ${SPAWNER_HTTP_TIMEOUT} \
    --argjson start_to ${KUBESPAWNER_START_TIMEOUT} \
    --argjson singleuser_node_selector ${singleuser_node_selector_json} \
    --argjson singleuser_tolerations ${singleuser_tolerations_json} \
    --argjson hub_node_selector ${hub_node_selector_json} \
    --argjson hub_tolerations ${hub_tolerations_json} \
    --argjson ingress_annotations ${ingress_annotations_json} \
    --argjson shared_enabled ${shared_enabled_json} \
    --argjson ingress_enabled ${ingress_enabled_json} \
    --argjson prepull_enabled ${prepull_enabled_json} \
    --argjson prepull_extra ${prepull_extra_json} \
    --argjson idle_enabled ${idle_enabled_json} \
    --argjson cull_timeout ${cull_timeout} \
    --argjson cull_every ${cull_every} \
    --argjson cull_concurrency ${cull_concurrency} \
    --argjson cull_users ${cull_users_json} \
    --argjson named_servers ${named_servers_json} \
    --argjson named_limit ${named_limit} '
{
  "proxy": {
    "service": { 
      "type": "NodePort", 
      "nodePorts": { "http": $port } 
    }
  },
  "ingress": (
    if $ingress_enabled then 
      {
        "enabled": true,
        "hosts": [{ "host": $host, "paths": [{ "path": "/", "pathType": "Prefix" }] }],
        "annotations": $ingress_annotations,
        "tls": (
          if ($tls_secret | length) > 0 then 
            [{ "hosts": [$host], "secretName": $tls_secret }] 
          else 
            [] 
          end
        )
      } 
    else 
      { "enabled": false } 
    end
  ),
  "prePuller": (
    if $prepull_enabled then 
      {
        "hook": { "enabled": true },
        "continuous": { "enabled": true }
      } 
    else 
      { 
        "hook": { "enabled": false }, 
        "continuous": { "enabled": false } 
      } 
    end
  ),
  "singleuser": {
    "image": (
      {
        "name": $image_name,
        "pullPolicy": $image_pull_policy
      }
      | (if ($image_tag | length) > 0 then . + { "tag": $image_tag } else . end)
      | (if ($image_digest | length) > 0 then . + { "digest": $image_digest } else . end)
    ),
    "storage": {
      "dynamic": { "storageClass": $storage_class },
      "capacity": $pvc,
      "extraVolumes": (
        if $shared_enabled then
          [
            { "name": "shared-storage", "persistentVolumeClaim": { "claimName": "storage-local-pvc" } },
            { "name": "jhub-logs", "persistentVolumeClaim": { "claimName": "jhub-logs-pvc" } }
          ]
        else []
        end
      ),
      "extraVolumeMounts": (
        if $shared_enabled then
          [
            { "name": "shared-storage", "mountPath": $shared_mount },
            { "name": "jhub-logs", "mountPath": $logs_mount }
          ]
        else []
        end
      )
    },
    "nodeSelector": $singleuser_node_selector,
    "extraTolerations": $singleuser_tolerations,
    "profileList": $profiles,
    "extraEnv": {
      "GRANT_SUDO": "yes"
    },
    "allowPrivilegeEscalation": true
  },
  "hub": {
    "db": {
      "type": "sqlite-pvc",
      "pvc": {
        "accessModes": ["ReadWriteOnce"],
        "storage": "1Gi"
      }
    },
    "templatePaths": ["/usr/local/share/jupyterhub/custom_templates"],
    "nodeSelector": $hub_node_selector,
    "tolerations": $hub_tolerations,
    "config": {
      "JupyterHub": {
        "admin_access": true,
        "authenticator_class": $auth_class,
        "allow_named_servers": $named_servers,
        "named_server_limit_per_user": $named_limit,
        "tornado_settings": {
          "headers": {
            "Content-Security-Policy": $csp,
            "X-Frame-Options": "ALLOWALL"
          }
        }
      },
      "Authenticator": {
        "admin_users": [ $admin ],
        "allowed_users": [ $admin ]
      },
      "NativeAuthenticator": {
        "open_signup": true,
        "minimum_password_length": 6
      },
      "Spawner": {
        "http_timeout": $http_to,
        "start_timeout": $start_to,
        "args": [
          "--ServerApp.tornado_settings={\"headers\":{\"Content-Security-Policy\":\"" + $csp + "\"}}"
        ]
      }
    },
    "extraVolumes": [
      { "name": "hub-templates", "configMap": { "name": "hub-templates" } }
    ],
    "extraVolumeMounts": [
      { "name": "hub-templates", "mountPath": "/usr/local/share/jupyterhub/custom_templates", "readOnly": true }
    ]
  },
  "cull": {
    "enabled": $idle_enabled,
    "timeout": $cull_timeout,
    "every": $cull_every,
    "concurrency": $cull_concurrency,
    "users": $cull_users
  }
}' > /root/jhub/values.yaml
  nl -ba /root/jhub/values.yaml | sed -n '1,200p' || true
}

_deploy_portal_page(){
  local preferred_url="$1" nodeport_url="$2" pf_url="$3" admin_url="$4" pf_active="$5"
  local root_dir="/root/jhub" template_path output_path portal_config portal_label pf_status
  mkdir -p "$root_dir"

  [[ -z "$preferred_url" ]] && preferred_url="$nodeport_url"
  [[ -z "$admin_url" ]] && admin_url=""
  [[ -z "$pf_url" ]] && pf_url=""

  if [[ "$pf_active" == "true" ]]; then
    portal_label="Port-Forward 入口（建議）"
    pf_status="已啟動"
  else
    portal_label="NodePort 入口"
    pf_status="未啟動"
  fi

  template_path="$(pwd)/index.html"
  output_path="${root_dir}/index.html"
  if [[ -f "$template_path" ]]; then
    cp "$template_path" "$output_path"
  else
    cat >"$output_path" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8" />
  <title>JupyterHub 快速入口</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+TC:wght@400;600&display=swap">
  <style>
    body { font-family: "Noto Sans TC", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #f5f7fb; color: #1f2933; }
    header { background: #1f6feb; color: #fff; padding: 24px 32px; }
    main { padding: 24px 32px 40px; max-width: 1080px; margin: 0 auto; }
    .card { background: #fff; border-radius: 12px; box-shadow: 0 12px 32px rgba(15,23,42,0.1); padding: 28px; margin-bottom: 24px; }
    .btn { display: inline-flex; align-items: center; padding: 12px 20px; margin: 6px 14px 6px 0; border-radius: 10px; text-decoration: none; font-weight: 600; transition: all .2s ease; }
    .btn-primary { background: #1f6feb; color: #fff; }
    .btn-secondary { background: #e2e8f0; color: #1f2933; }
    .btn[aria-disabled="true"] { opacity: .6; pointer-events: none; }
    iframe { width: 100%; min-height: 640px; border: 1px solid #d0d7de; border-radius: 12px; }
    code { background: #f1f5f9; padding: 2px 6px; border-radius: 6px; }
    .tag { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 999px; font-size: 12px; background: #dbeafe; color: #1d4ed8; margin-left: 8px; }
    .grid { display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
    footer { text-align: center; padding: 16px; font-size: 13px; color: #6b7280; }
  </style>
</head>
<body>
  <header>
    <h1>JupyterHub 快速入口</h1>
    <p>此模板可置於任意 HTTP 伺服器，部署腳本會自動更新 portal-config.js 供下方連結使用。</p>
  </header>
  <main>
    <section class="card">
      <h2>主要入口 <span class="tag" data-text="preferredLabel">載入中</span></h2>
      <p>依照目前的部署狀態，自動指向最適合的 Hub 入口；若無法載入，請改用 NodePort 連結。</p>
      <p>網址：<code data-text="preferredUrl">讀取中…</code></p>
      <a class="btn btn-primary" data-href="preferredUrl" target="_blank" rel="noopener" aria-disabled="true">前往 Hub</a>
    </section>
    <section class="card">
      <h3>其他連線方式</h3>
      <div class="grid">
        <div>
          <h4>NodePort 入口</h4>
          <p>直接連到 Proxy 的 NodePort。</p>
          <p><code data-text="nodePortUrl">讀取中…</code></p>
          <a class="btn btn-secondary" data-href="nodePortUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 NodePort</a>
        </div>
        <div>
          <h4>Port-Forward</h4>
          <p>若執行 port-forward，這裡會顯示本機入口。</p>
          <p>狀態：<span class="tag" data-text="portForwardStatus">偵測中</span></p>
          <p><code data-text="portForwardUrl">尚未設定</code></p>
          <a class="btn btn-secondary" data-href="portForwardUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 Port-Forward</a>
        </div>
        <div>
          <h4>adminuser 服務</h4>
          <p>由 adminuser Notebook 暴露的服務（NodePort）。</p>
          <p><code data-text="adminServiceUrl">讀取中…</code></p>
          <a class="btn btn-secondary" data-href="adminServiceUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 adminuser</a>
        </div>
      </div>
    </section>
    <section class="card">
      <h3>即時預覽</h3>
      <p>此 iframe 會嵌入主要入口（需搭配 CSP frame-ancestors 設定）。</p>
      <iframe data-iframe="preferredUrl" title="JupyterHub"></iframe>
    </section>
  </main>
  <footer>由 install_jhub.sh 產生；詳細設定請查看 portal-config.js</footer>
  <script src="portal-config.js"></script>
  <script>
    (function(){
      const data = window.JUPYTER_PORTAL || {};
      const textElements = document.querySelectorAll('[data-text]');
      textElements.forEach(el => {
        const key = el.getAttribute('data-text');
        const value = data[key];
        if (value) {
          el.textContent = value;
        } else if (key === 'portForwardUrl') {
          el.textContent = '尚未啟動';
        } else {
          el.textContent = '未設定';
        }
      });
      document.querySelectorAll('[data-href]').forEach(el => {
        const key = el.getAttribute('data-href');
        const value = data[key];
        if (value) {
          el.href = value;
          el.setAttribute('aria-disabled', 'false');
          el.style.pointerEvents = '';
          el.style.opacity = '';
        } else {
          el.href = '#';
          el.setAttribute('aria-disabled', 'true');
          el.style.pointerEvents = 'none';
          el.style.opacity = '0.6';
        }
      });
      const iframe = document.querySelector('[data-iframe="preferredUrl"]');
      if (iframe && data.preferredUrl) {
        iframe.src = data.preferredUrl;
      }
    })();
  </script>
</body>
</html>
HTML
  fi

  portal_config="${root_dir}/portal-config.js"
  cat >"$portal_config" <<JS
window.JUPYTER_PORTAL = {
  preferredUrl: "${preferred_url}",
  preferredLabel: "${portal_label}",
  nodePortUrl: "${nodeport_url}",
  portForwardUrl: "${pf_url}",
  portForwardActive: ${pf_active:-false},
  portForwardStatus: "${pf_status}",
  adminServiceUrl: "${admin_url}",
  generatedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
};
JS

  # 讓工作目錄下的 HTTP server 也能讀到最新設定
  cp "$portal_config" "$(pwd)/portal-config.js" || true
}

_install_custom_templates(){
  local repo_template="$(pwd)/templates/login.html"
  local target_dir="/root/jhub/templates"
  local target_file="${target_dir}/login.html"

  mkdir -p "$target_dir"

  if [[ -f "$repo_template" ]]; then
    cp "$repo_template" "$target_file"
  else
    cat >"$target_file" <<'HTML'
{% extends "page.html" %}

{% block stylesheet %}
<style>
body {
  background: radial-gradient(circle at top left, #1f6feb 0%, #0b3d91 40%, #0f172a 100%);
  min-height: 100vh;
  margin: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: "Noto Sans TC", "Segoe UI", system-ui, sans-serif;
  color: #0f172a;
}
.login-shell {
  background: rgba(255, 255, 255, 0.92);
  backdrop-filter: blur(8px);
  border-radius: 20px;
  box-shadow: 0 24px 60px rgba(15, 23, 42, 0.25);
  width: min(880px, 92%);
  overflow: hidden;
  display: grid;
  grid-template-columns: 1fr 0.9fr;
}
.login-panel {
  padding: 42px 48px;
  display: flex;
  flex-direction: column;
  gap: 24px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 14px;
  font-size: 26px;
  font-weight: 700;
  color: #1f2933;
}
.brand img {
  height: 42px;
}
.subtitle {
  margin: 0;
  color: #475569;
  font-size: 15px;
  line-height: 1.6;
}
.alert {
  padding: 12px 16px;
  border-radius: 10px;
  font-size: 14px;
  margin: 0;
}
.alert.error { background: #fee2e2; color: #b91c1c; }
.alert.info { background: #dbeafe; color: #1d4ed8; }
.login-form {
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.field label {
  display: block;
  margin-bottom: 6px;
  font-size: 13px;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: #475569;
}
.field input {
  width: 100%;
  border: 1px solid #cbd5f5;
  border-radius: 10px;
  padding: 12px 14px;
  font-size: 15px;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.field input:focus {
  outline: none;
  border-color: #1f6feb;
  box-shadow: 0 0 0 3px rgba(31, 111, 235, 0.2);
}
.submit-btn {
  margin-top: 6px;
  background: linear-gradient(135deg, #2563eb, #1f6feb);
  color: #fff;
  border: none;
  border-radius: 999px;
  padding: 13px 20px;
  font-size: 16px;
  font-weight: 600;
  letter-spacing: 0.04em;
  cursor: pointer;
  transition: transform 0.2s ease, box-shadow 0.2s ease;
}
.submit-btn:hover {
  transform: translateY(-1px);
  box-shadow: 0 10px 22px rgba(37, 99, 235, 0.3);
}
.oauth-button {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  justify-content: center;
  background: #0f172a;
  color: #fff;
  text-decoration: none;
  border-radius: 999px;
  padding: 13px 20px;
  margin-top: 12px;
  font-weight: 600;
}
.side-panel {
  background: linear-gradient(145deg, rgba(37, 99, 235, 0.95), rgba(14, 116, 144, 0.92));
  color: #e2e8f0;
  padding: 48px 40px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
}
.side-panel h2 {
  font-size: 28px;
  margin: 0 0 12px;
}
.side-panel p {
  line-height: 1.7;
  font-size: 15px;
  color: #e0f2fe;
}
.tips {
  margin-top: 32px;
  background: rgba(15, 23, 42, 0.25);
  border-radius: 14px;
  padding: 18px;
  font-size: 13px;
  display: grid;
  gap: 8px;
}
.tips strong { color: #fff; }
.footer-note {
  margin-top: auto;
  font-size: 12px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(226, 232, 240, 0.7);
}
@media (max-width: 960px) {
  .login-shell { grid-template-columns: 1fr; }
  .side-panel { display: none; }
}
</style>
{% endblock %}

{% block main %}
<div class="login-shell">
  <div class="login-panel">
    <div class="brand">
      <img src="{{ static_url('images/jupyterhub-icon.svg') }}" alt="JupyterHub" />
      <span>JupyterHub 控制中心</span>
    </div>
    {% if custom_html %}
      {{ custom_html | safe }}
    {% else %}
      <p class="subtitle">登入以啟動你的 Notebook 或管理運算資源。第一次使用請先註冊帳號、設定密碼。</p>
    {% endif %}

    {% if login_error %}
      <p class="alert error">{{ login_error }}</p>
    {% endif %}
    {% if login_message %}
      <p class="alert info">{{ login_message }}</p>
    {% endif %}

    {% if login_service %}
      <a class="oauth-button" role="button" href="{{ authenticator_login_url }}">使用 {{ login_service }} 登入</a>
    {% else %}
      <form action="{{ login_url }}" method="post" role="form" class="login-form">
        {{ xsrf_form_html() }}
        {% if next %}
          <input type="hidden" name="next" value="{{ next }}" />
        {% endif %}

        <div class="field">
          <label for="username">使用者帳號</label>
          <input id="username" type="text" name="username" value="{{ username|default('') }}" autocomplete="username" autofocus />
        </div>
        <div class="field">
          <label for="password">密碼</label>
          <input id="password" type="password" name="password" autocomplete="current-password" />
        </div>

        <button type="submit" class="submit-btn">登入 JupyterHub</button>
      </form>
    {% endif %}
  </div>

  <div class="side-panel">
    <div>
      <h2>打造你的資料科學工作室</h2>
      <p>整合 GPU、AI 筆記本與共享儲存，讓團隊能夠快速開啟環境、部署應用程式，並保持安全控管。</p>
      <div class="tips">
        <div><strong>首次使用？</strong> 請向系統管理員申請帳號或自行註冊。</div>
        <div><strong>忘記密碼？</strong> 聯絡管理員協助重設。</div>
        <div><strong>最佳體驗：</strong> 建議使用 Chrome 或 Edge 瀏覽器。</div>
      </div>
    </div>
    <div class="footer-note">POWERED BY JUPYTERHUB</div>
  </div>
</div>
{% endblock %}
HTML
  fi

  KCTL -n "${JHUB_NS}" create configmap hub-templates \
    --from-file=login.html="${target_file}" \
    --dry-run=client -o yaml | KCTL apply -f -
}

# ---------- PV/PVC：Storage & Logs ----------
ensure_local_pv(){
  local storage_dir="${SHARED_STORAGE_PATH:-./Storage}"
  [[ "${storage_dir}" != /* ]] && storage_dir="$(pwd)/${storage_dir#./}"
  KCTL get ns "${JHUB_NS}" >/dev/null 2>&1 || KCTL create ns "${JHUB_NS}"
  mkdir -p "${storage_dir}" /var/log/jupyterhub
  chown -R 1000:100 "${storage_dir}" || true
  chmod 0777 "${storage_dir}" || true
  if [[ "${SHARED_STORAGE_ENABLED}" == "true" ]]; then
    cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: { name: storage-local-pv }
spec:
  capacity: { storage: ${SHARED_STORAGE_SIZE} }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: "${storage_dir}" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: storage-local-pvc, namespace: ${JHUB_NS} }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: ${SHARED_STORAGE_SIZE} } }
  volumeName: storage-local-pv
  storageClassName: ""
---
YAML
  else
    warn "[storage] SHARED_STORAGE_ENABLED=false，略過共享 Storage PV/PVC 建立"
  fi
  cat <<YAML | KCTL apply -f -
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

ensure_resource_quota(){
  [[ "${ENABLE_RESOURCE_QUOTA}" != "true" ]] && return 0
  log "[quota] 套用 ResourceQuota / LimitRange"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: jhub-quota
  namespace: ${JHUB_NS}
spec:
  hard:
    requests.cpu: "${RQ_REQUESTS_CPU}"
    requests.memory: "${RQ_REQUESTS_MEMORY}"
    limits.cpu: "${RQ_LIMITS_CPU}"
    limits.memory: "${RQ_LIMITS_MEMORY}"
    pods: "${RQ_PODS}"
    nvidia.com/gpu: "${RQ_GPUS}"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: jhub-defaults
  namespace: ${JHUB_NS}
spec:
  limits:
  - type: Container
    default:
      cpu: "${LIMITRANGE_DEFAULT_CPU}"
      memory: "${LIMITRANGE_DEFAULT_MEMORY}"
    defaultRequest:
      cpu: "${LIMITRANGE_DEFAULT_CPU}"
      memory: "${LIMITRANGE_DEFAULT_MEMORY}"
    max:
      cpu: "${LIMITRANGE_MAX_CPU}"
      memory: "${LIMITRANGE_MAX_MEMORY}"
YAML
}

ensure_tls_secret(){
  [[ "${ENABLE_INGRESS}" != "true" ]] && return 0
  if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" && -f "${TLS_CERT_FILE}" && -f "${TLS_KEY_FILE}" ]]; then
    log "[tls] 建立/更新 TLS Secret ${INGRESS_TLS_SECRET}"
    KCTL -n "${JHUB_NS}" create secret tls "${INGRESS_TLS_SECRET}" \
      --cert="${TLS_CERT_FILE}" --key="${TLS_KEY_FILE}" \
      --dry-run=client -o yaml | KCTL apply -f -
  else
    warn "[tls] 未提供 TLS_CERT_FILE/TLS_KEY_FILE 或檔案不存在，請確認 secret/${INGRESS_TLS_SECRET} 已建立"
  fi
}

ensure_network_policy(){
  [[ "${ENABLE_NETWORK_POLICY}" != "true" ]] && return 0
  log "[netpol] 建立預設 NetworkPolicy"
  cat <<YAML | KCTL apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hub-internal-access
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/component: hub
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${JHUB_NS}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: singleuser-default
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      component: singleuser-server
  policyTypes: ["Ingress","Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          hub.jupyter.org/component: proxy
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${JHUB_NS}
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
  - {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-proxy
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/component: proxy
  policyTypes: ["Ingress","Egress"]
  ingress:
  - {}
  egress:
  - {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-adminuser
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/username: ${ADMIN_USER}
      component: singleuser-server
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: ${ADMINUSER_TARGET_PORT}
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
  fi
  if [[ "${GPU_OPERATOR_DISABLE_DRIVER}" != "true" ]]; then
    if [[ -n "${GPU_OPERATOR_DRIVER_VERSION}" ]]; then
      ARGS+=(--set-string driver.version="${GPU_OPERATOR_DRIVER_VERSION}")
    fi
    if [[ -n "${GPU_OPERATOR_DRIVER_RUNFILE_URL}" ]]; then
      ARGS+=(--set-string driver.runfile.url="${GPU_OPERATOR_DRIVER_RUNFILE_URL}")
    fi
    if [[ -n "${GPU_OPERATOR_DRIVER_PKG_MANAGER}" ]]; then
      ARGS+=(--set-string driver.manager="${GPU_OPERATOR_DRIVER_PKG_MANAGER}")
    fi
    ARGS+=(--set driver.manager.imagePullPolicy=IfNotPresent)
    ARGS+=(--set driver.repository=nvcr.io/nvidia/driver --set driver.imagePullPolicy=IfNotPresent)
    ARGS+=(--set driver.usePrecompiled=true)
  fi
  if [[ "${ENABLE_MIG}" == "true" ]]; then
    local gpu_ns="gpu-operator"
    local mig_cm="${MIG_CONFIGMAP_NAME:-jhub-mig-config}"
    local mig_default="${MIG_CONFIG_DEFAULT:-all-disabled}"
    local mig_profile="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
    if [[ "${mig_default}" != "all-disabled" && -n "${mig_default}" ]]; then
      warn "[MIG] MIG_CONFIG_DEFAULT=${mig_default} 不被 GPU Operator 接受，改為 all-disabled"
      mig_default="all-disabled"
    fi
    log "[GPU][MIG] 生成 MIG Manager ConfigMap (${mig_cm}/${mig_profile})"
    KCTL get ns "${gpu_ns}" >/dev/null 2>&1 || KCTL create ns "${gpu_ns}"
    local mig_config
    mig_config="$(_render_mig_manager_config)"
    cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${mig_cm}
  namespace: ${gpu_ns}
data:
  config.yaml: |
$(printf '%s\n' "${mig_config}" | _indent 4)
YAML
    ARGS+=(--set migManager.enabled=true)
    ARGS+=(--set-string mig.strategy="${MIG_STRATEGY}")
    ARGS+=(--set-string migManager.config.create=false)
    ARGS+=(--set-string migManager.config.name="${mig_cm}")
    ARGS+=(--set-string migManager.config.default="${mig_default}")
    log "[GPU][MIG] MIG_CONFIG_DEFAULT=${mig_default}；將自動標記節點以套用 ${mig_profile}"
    _label_mig_nodes
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

# ---------- 對外 NodePort（adminuser 專用）與防火牆 ----------
open_fw_port(){
  local p="$1"
  if is_rhel && is_cmd firewall-cmd; then
    firewall-cmd --add-port="${p}"/tcp --permanent || true
    firewall-cmd --reload || true
  elif is_cmd ufw; then
    ufw allow "${p}"/tcp || true
  elif is_cmd nft; then
    nft list tables | grep -q '^table inet filter$' || nft add table inet filter || true
    if ! nft list chain inet filter input >/dev/null 2>&1; then
      nft add chain inet filter input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
    fi
    if ! nft list ruleset | grep -q "tcp dport ${p}.*accept"; then
      nft add rule inet filter input tcp dport ${p} counter accept 2>/dev/null || true
    fi
  elif is_cmd iptables; then
    if ! iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT || true
    fi
    if is_cmd ip6tables && ! ip6tables -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null; then
      ip6tables -I INPUT -p tcp --dport "${p}" -j ACCEPT || true
    fi
  fi
}
ensure_adminuser_nodeport(){
  [[ "${EXPOSE_ADMINUSER_NODEPORT}" != "true" ]] && return 0
  log "[api] 建立 adminuser 的 NodePort 對外服務（免登入） → ${ADMINUSER_NODEPORT}"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: Service
metadata:
  name: adminuser-fastapi-np
  namespace: ${JHUB_NS}
  labels: { app: adminuser-fastapi-np }
spec:
  type: NodePort
  selector:
    hub.jupyter.org/username: ${ADMIN_USER}
    component: singleuser-server
  ports:
    - name: http
      port: ${ADMINUSER_TARGET_PORT}
      targetPort: ${ADMINUSER_TARGET_PORT}
      nodePort: ${ADMINUSER_NODEPORT}
YAML
  open_fw_port "${ADMINUSER_NODEPORT}"
  ok "[api] 外部可用： http://$(hostname -I | awk '{print $1}'):${ADMINUSER_NODEPORT}/ping"
  ok "     （Notebook 內程式需監聽 0.0.0.0:${ADMINUSER_TARGET_PORT}；Pod 重建時 Service 會自動跟上）"
  if [[ "${ADMINUSER_PORTFORWARD}" == "true" ]]; then
    adminuser_pf_stop || true
    adminuser_pf_start || warn "[api] adminuser port-forward 可能未成功，請檢查 ${ADMINUSER_PF_LOG}"
  fi
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
  _ensure_kubelet_image_gc_disabled
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
  ensure_resource_quota
  ensure_tls_secret
  ensure_network_policy

  # IB/GPU
  install_network_operator
  install_gpu_operator

  # 生成 values.yaml
  _detect_resources
  _write_values_yaml
  _install_custom_templates

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

  # 建立 adminuser 專用 NodePort（免 Hub 登入）
  ensure_adminuser_nodeport

  # port-forward 小工具 & 診斷
  install_portforward_tool
  install_diag_tool

  local node_ip pf_url hub_nodeport_url admin_service_url pf_active="false"
  node_ip=$(hostname -I | awk '{print $1}')
  hub_nodeport_url="http://${node_ip}:${NODEPORT_FALLBACK_PORT}"
  pf_url="http://${PF_BIND_ADDR}:${PF_LOCAL_PORT}"
  admin_service_url="http://${node_ip}:${ADMINUSER_NODEPORT}"
  ACCESS_URL="$hub_nodeport_url"
  if [[ "${PF_AUTOSTART}" == "true" ]]; then
    pf_stop || true
    if pf_start; then
      ACCESS_URL="$pf_url"
      pf_active="true"
    fi
  fi

  _deploy_portal_page "$ACCESS_URL" "$hub_nodeport_url" "$pf_url" "$admin_service_url" "$pf_active"

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
▶ HTML 快速入口：/root/jhub/index.html（模板來源：$(pwd)/index.html）

▶ Adminuser API（免登入直連）：
    http://<node_ip>:${ADMINUSER_NODEPORT}/…   （Notebook 內請監聽 0.0.0.0:${ADMINUSER_TARGET_PORT}）
    若啟用 port-forward：${ADMINUSER_PF_BIND_ADDR}:${ADMINUSER_PF_PORT} → ${ADMINUSER_TARGET_PORT}
============================================================

【對外 API 提示】
  - 你在 Notebook 內監聽的服務（例如 8000）可由外部直接打：
      http://<node_ip>:${ADMINUSER_NODEPORT}/ping
  - 若改用 Hub 代理（需要登入 Cookie）：
      http://<node_ip>:${NODEPORT_FALLBACK_PORT}/user/<username>/proxy/${ADMINUSER_TARGET_PORT}/…

【常見故障快速檢查】
  1) DNS：若 coredns Pod 是 ImagePullBackOff，請確認已套用 ${COREDNS_IMAGE}
     - 查看：microk8s kubectl -n kube-system get deploy coredns -o yaml | grep image:
  2) Hub 狀態：sudo jhub-diag ${JHUB_NS}
  3) 18080/30080/32081 對外不通？檢查防火牆或自行開放：
     - firewalld：firewall-cmd --add-port=18080/tcp --permanent && firewall-cmd --add-port=${NODEPORT_FALLBACK_PORT}/tcp --permanent && firewall-cmd --add-port=${ADMINUSER_NODEPORT}/tcp --permanent && firewall-cmd --reload
     - ufw：ufw allow 18080/tcp && ufw allow ${NODEPORT_FALLBACK_PORT}/tcp && ufw allow ${ADMINUSER_NODEPORT}/tcp
EOF
}

main "$@"
