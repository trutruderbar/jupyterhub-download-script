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

# Hub / Proxy 映像（離線可放置 tar 檔供匯入）
: "${HUB_IMAGE:=quay.io/jupyterhub/k8s-hub:${JHUB_CHART_VERSION}}"
: "${HUB_IMAGE_PULL_POLICY:=IfNotPresent}"
: "${HUB_IMAGE_TAR:=${OFFLINE_IMAGE_DIR}/k8s-hub-${JHUB_CHART_VERSION}.tar}"
: "${PROXY_IMAGE:=quay.io/jupyterhub/configurable-http-proxy:4.6.3}"
: "${PROXY_IMAGE_PULL_POLICY:=IfNotPresent}"
: "${PROXY_IMAGE_TAR:=${OFFLINE_IMAGE_DIR}/configurable-http-proxy-4.6.3.tar}"
: "${AUTO_PULL_CORE_IMAGES:=false}"

# Singleuser Notebook 映像（建議先用你已擴充的離線鏡像）
: "${SINGLEUSER_IMAGE:=myorg3/pytorch-jhub:24.10}"
: "${SINGLEUSER_IMAGE_PULL_POLICY:=IfNotPresent}"
: "${PVC_SIZE:=20Gi}"
: "${SINGLEUSER_STORAGE_CLASS:=microk8s-hostpath}"
: "${SHARED_STORAGE_ENABLED:=true}"
: "${SHARED_STORAGE_SIZE:=1Ti}"
: "${SHARED_STORAGE_PATH:=./Storage}"
: "${HOSTPATH_PROVISIONER_IMAGE:=docker.io/cdkbot/hostpath-provisioner:1.5.0}"
: "${HOSTPATH_PROVISIONER_TAR:=${OFFLINE_IMAGE_DIR}/hostpath-provisioner-1.5.0.tar}"

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

# === 統一驅動模式（新的高層開關，舊參數仍可覆蓋） ===
# auto：預設。主機已有驅動→host；否則→dkms（更通用）。必要時你也可手動指定 host/dkms/precompiled。
: "${GPU_DRIVER_MODE:=auto}"          # auto | host | dkms | precompiled
# dkms 模式若是 Debian/Ubuntu，會自動裝當前 kernel headers（可關閉）
: "${GPU_DKMS_INSTALL_HEADERS:=true}"

: "${ENABLE_IB:=false}"               # true 則安裝 NVIDIA Network Operator（不額外套 CR）
: "${NETWORK_OPERATOR_VERSION:=}"     # 例如 24.7.0（留空用最新 chart）
: "${IB_NIC_POLICY_NAME:=nic-cluster-policy}"
: "${IB_NIC_POLICY_TEMPLATE_FILE:=}"
: "${IB_NIC_POLICY_CRD_WAIT_SECONDS:=180}"
: "${IB_RSDP_REPOSITORY:=quay.io/k8snetworkplumbingwg}"
: "${IB_RSDP_IMAGE:=k8s-rdma-shared-dev-plugin}"
: "${IB_RSDP_VERSION:=v1.5.2}"
: "${IB_RSDP_IMAGE_TAR:=${OFFLINE_IMAGE_DIR}/k8s-rdma-shared-dev-plugin-${IB_RSDP_VERSION}.tar}"
: "${IB_RESOURCE_NAME:=rdma/rdma_shared_device}"  # 配合 rdmaSharedDevicePlugin 的 resourceName
: "${IB_RESOURCE_COUNT:=1}"                        # 每個 Pod 預設要的 RDMA device 數量（GPU/MIG profile 用）
: "${JHUB_FRAME_ANCESTORS:=http://${DEFAULT_HOST_IP} http://localhost:8080}"

# Ingress / TLS
: "${ENABLE_INGRESS:=false}"
: "${INGRESS_HOST:=${DEFAULT_HOST_IP}}"
: "${INGRESS_TLS_SECRET:=jhub-tls}"
: "${TLS_CERT_FILE:=}"
: "${TLS_KEY_FILE:=}"
: "${INGRESS_ANNOTATIONS_JSON:=}"

: "${ENABLE_NGINX_PROXY:=false}"
: "${NGINX_PROXY_HTTP_PORT:=80}"
: "${NGINX_PROXY_HTTPS_PORT:=443}"
: "${NGINX_PROXY_SERVER_NAME:=${INGRESS_HOST}}"
: "${NGINX_PROXY_UPSTREAM_HOST:=${DEFAULT_HOST_IP}}"
: "${NGINX_PROXY_UPSTREAM_PORT:=${NODEPORT_FALLBACK_PORT}}"
: "${NGINX_PROXY_CERT_FILE:=${TLS_CERT_FILE}}"
: "${NGINX_PROXY_KEY_FILE:=${TLS_KEY_FILE}}"
: "${NGINX_PROXY_HTTP_MODE:=proxy}"    # proxy | redirect

: "${CUSTOM_STATIC_SOURCE_DIR:=${SCRIPT_DIR}/image}"
: "${LOGIN_LOGO_PATH:=${CUSTOM_STATIC_SOURCE_DIR}/login-logo.png}"
: "${CUSTOM_STATIC_ENABLED:=auto}"     # auto | true | false
: "${CUSTOM_STATIC_CONFIGMAP:=hub-custom-static}"
: "${CUSTOM_STATIC_MOUNT_PATH:=/usr/local/share/jupyterhub/static/custom}"
: "${CUSTOM_STATIC_LOGO_NAME:=login-logo.png}"

: "${ALLOW_ALL_USERS:=true}"

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

# Usage portal driven per-user limits
: "${ENABLE_USAGE_LIMIT_ENFORCER:=true}"
: "${USAGE_PORTAL_URL:=http://${DEFAULT_HOST_IP}:29781}"
: "${USAGE_PORTAL_TOKEN:=}"
: "${USAGE_PORTAL_TIMEOUT_SECONDS:=5}"

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

# 身份驗證
: "${AUTH_MODE:=native}"               # native | github | azuread
: "${ADMIN_USERS_CSV:=adminuser,tony.test}"               # 逗號分隔管理員帳號，預設沿用 ADMIN_USER
: "${ALLOWED_USERS_CSV:=}"             # native 模式可自訂允許登入名單
: "${GITHUB_CLIENT_ID:=}"
: "${GITHUB_CLIENT_SECRET:=}"
: "${GITHUB_CALLBACK_URL:=}"
: "${GITHUB_ALLOWED_ORGS:=}"           # 例如 my-org 或 my-org:team
: "${GITHUB_ALLOWED_USERS:=}"          # 逗號分隔 Github 帳號；留空則不額外限制
: "${GITHUB_SCOPES:=read:org}"         # 逗號分隔 OAuth scopes
: "${AZUREAD_CLIENT_ID:=}"
: "${AZUREAD_CLIENT_SECRET:=}"
: "${AZUREAD_CALLBACK_URL:=}"
: "${AZUREAD_TENANT_ID:=common}"       # multi-tenant=common，可改成實際租戶 ID
: "${AZUREAD_ALLOWED_TENANTS:=}"       # 逗號分隔 tenant ID；空字串＝不限制
: "${AZUREAD_ALLOWED_USERS:=}"         # 逗號分隔 UPN/email；空字串＝不限制
: "${AZUREAD_SCOPES:=openid,profile,offline_access}"
: "${AZUREAD_LOGIN_SERVICE:=Azure AD}"
: "${UBILINK_AUTH_ME_URL:=https://billing.ubilink.ai/api/auth/me}"
: "${UBILINK_LOGIN_URL:=https://billing.ubilink.ai/login}"
: "${UBILINK_LOGIN_SERVICE:=Ubilink 單點登入}"
: "${UBILINK_HTTP_TIMEOUT_SECONDS:=5}"

# 自訂映像與命名伺服器
: "${ALLOWED_CUSTOM_IMAGES:=}"
: "${ALLOW_NAMED_SERVERS:=true}"
: "${NAMED_SERVER_LIMIT:=5}"
# 離線側載檔名（存在才會載入）
: "${CALICO_VERSION:=v3.25.1}"
: "${CALICO_BUNDLE:=${OFFLINE_IMAGE_DIR}/calico-v3.25.1-bundle.tar}"
: "${NOTEBOOK_TAR:=${OFFLINE_IMAGE_DIR}/jhub_24.10_3.tar}"
: "${COREDNS_TAR:=${OFFLINE_IMAGE_DIR}/coredns_v1.10.1.tar}"                  # 可選：例如 ./coredns_v1.10.1.tar（含 registry.k8s.io/coredns/coredns:v1.10.1）

: "${GPU_OPERATOR_BUNDLE_TAR:=${OFFLINE_IMAGE_DIR}/gpu-operator-bundle-v25.10.0.tar}"
: "${GPU_OPERATOR_CORE_TAR:=${OFFLINE_IMAGE_DIR}/gpu-operator-v25.10.0.tar}"
: "${KUBE_SCHEDULER_TAR:=${OFFLINE_IMAGE_DIR}/kube-scheduler-v1.30.11.tar}"
: "${NFD_TAR:=${OFFLINE_IMAGE_DIR}/nfd-v0.18.2.tar}"
: "${NVIDIA_K8S_DEVICE_PLUGIN_TAR:=${OFFLINE_IMAGE_DIR}/nvidia-k8s-device-plugin-v0.18.0.tar}"
: "${NVIDIA_CONTAINER_TOOLKIT_TAR:=${OFFLINE_IMAGE_DIR}/nvidia-container-toolkit-v1.18.0.tar}"
: "${NVIDIA_DCGM_EXPORTER_TAR:=${OFFLINE_IMAGE_DIR}/nvidia-dcgm-exporter-4.4.1-4.6.0-distroless.tar}"
: "${PAUSE_IMAGE_TAR:=${OFFLINE_IMAGE_DIR}/pause-3.7.tar}"
: "${BUSYBOX_IMAGE_TAR:=${OFFLINE_IMAGE_DIR}/busybox-1.28.4.tar}"
: "${COREDNS_IMAGE:=registry.k8s.io/coredns/coredns:v1.10.1}"

# --- 新增：讓 adminuser 的單人伺服器可直接對外（免 Hub 登入） ---
: "${EXPOSE_ADMINUSER_NODEPORT:=true}"   # true=建立 NodePort 服務
: "${ADMINUSER_TARGET_PORT:=8000}"       # Notebook 內 FastAPI 監聽埠
: "${ADMINUSER_NODEPORT:=32081}"         # 對外固定 NodePort (30000-32767)
: "${ADMINUSER_PORTFORWARD:=false}"      # true=另外以 port-forward 映射本機
: "${ADMINUSER_PF_PORT:=18081}"          # adminuser port-forward 本機埠
: "${ADMINUSER_PF_BIND_ADDR:=127.0.0.1}" # adminuser port-forward 綁定位址

# 多節點叢集設定（以 SSH 加入 worker 節點）
: "${CLUSTER_NODE_IPS:=}"                # 空字串=單節點；要啟用叢集再填 IP 清單
: "${CLUSTER_SSH_USER:=root}"            # SSH 使用者
: "${CLUSTER_SSH_KEY:=./id_rsa}"     # SSH 私鑰路徑
: "${CLUSTER_SSH_PORT:=22}"              # SSH 連接埠
: "${CLUSTER_SSH_OPTS:=}"                # 其他 SSH 參數（例如 -o ProxyJump=...）

: "${PATCH_CALICO:=false}"
: "${FORCE_RUNC:=false}"
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
_image_digest(){
  local ref="$1"
  [[ -z "${ref}" ]] && return 0
  local digest=""
  digest="$(CTR images ls | awk -v image="${ref}" '$1==image {print $3; exit}' 2>/dev/null || true)"
  printf '%s' "${digest}"
}
_sync_image_tags(){
  local source="$1"; shift
  local target
  [[ -z "${source}" ]] && return 0
  if ! _image_exists_locally "${source}"; then
    warn "[images] 無法同步標籤，來源映像不存在：${source}"
    return 1
  fi
  local source_digest
  source_digest="$(_image_digest "${source}")"
  for target in "$@"; do
    [[ -z "${target}" || "${target}" == "${source}" ]] && continue
    local target_digest=""
    target_digest="$(_image_digest "${target}")"
    if [[ -n "${target_digest}" && -n "${source_digest}" && "${target_digest}" == "${source_digest}" ]]; then
      continue
    fi
    if CTR images tag "${source}" "${target}"; then
      log "[images] 標籤同步：${source} → ${target}"
    else
      warn "[images] 無法同步標籤至 ${target}"
    fi
  done
}
_ensure_image_local(){
  local image="$1" label="${2:-image}" tar_path="${3:-}" imported="false"
  if _image_exists_locally "${image}"; then
    ok "[images] ${label} 映像已存在：${image}"
    return 0
  fi
  if [[ -n "${tar_path}" ]]; then
    if [[ -f "${tar_path}" ]]; then
      log "[images] 匯入 ${label} 映像（tar）：${tar_path}"
      if "$MICROK8S" images import "${tar_path}"; then
        imported="true"
      else
        warn "[images] microk8s images import 失敗，嘗試 ctr 匯入 ${tar_path}"
        if CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${tar_path}" >/dev/null 2>&1; then
          imported="true"
        else
          warn "[images] 匯入 ${tar_path} 失敗"
        fi
      fi
    else
      warn "[images] 找不到 ${label} tar：${tar_path}"
    fi
  fi
  if ! _image_exists_locally "${image}" && [[ "${AUTO_PULL_CORE_IMAGES}" == "true" ]]; then
    log "[images] 預先拉取 ${label} 映像：${image}"
    if CTR images pull "${image}"; then
      imported="true"
    else
      warn "[images] 拉取 ${image} 失敗"
    fi
  fi
  if _image_exists_locally "${image}"; then
    ok "[images] ${label} 映像已可用：${image}"
    return 0
  fi
  warn "[images] ${label} 映像仍缺少：${image}"
  return 1
}
OS_FAMILY=""
detect_os(){
  [[ -n "${OS_FAMILY}" ]] && return 0
  local id="" id_like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    id="${ID,,}"
    id_like="${ID_LIKE,,}"
  elif [[ -r /etc/redhat-release ]]; then
    id="rhel"
  elif [[ -r /etc/debian_version ]]; then
    id="debian"
  fi
  case "${id}" in
    ubuntu|debian)
      OS_FAMILY="ubuntu"
      ;;
    rhel|centos|rocky|almalinux|redhatenterpriseserver|ol|oraclelinux|scientific|fedora)
      OS_FAMILY="rhel"
      ;;
    *)
      if [[ "${id_like}" == *"debian"* ]]; then
        OS_FAMILY="ubuntu"
      elif [[ "${id_like}" == *"rhel"* ]] || [[ "${id_like}" == *"centos"* ]] || [[ "${id_like}" == *"fedora"* ]]; then
        OS_FAMILY="rhel"
      fi
      ;;
  esac
  if [[ -z "${OS_FAMILY}" ]]; then
    err "[os] 僅支援 Ubuntu 與 Red Hat 系列（偵測 ID=${id:-?}, ID_LIKE=${id_like:-?}）"
    exit 1
  fi
}
require_root(){ [[ $EUID -eq 0 ]] || { err "請用 sudo 執行：sudo $0"; exit 1; }; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_rhel(){ detect_os; [[ "${OS_FAMILY}" == "rhel" ]]; }
is_ubuntu(){ detect_os; [[ "${OS_FAMILY}" == "ubuntu" ]]; }
KCTL(){ "$MICROK8S" kubectl "$@"; }
CTR(){ CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr "$@"; }
wait_rollout(){ KCTL -n "$1" rollout status "$2/$3" --timeout="${4:-600s}" || true; }
kapply_from_dryrun(){
  local namespace="$1"
  shift
  KCTL -n "${namespace}" create "$@" --dry-run=client -o yaml | KCTL apply -f -
}
ensure_lowercase_hostname(){
  local host
  host="$(hostname)"
  if [[ "${host}" =~ [A-Z_] ]]; then
    err "[host] 節點名稱 ${host} 含大寫或底線，Kubernetes 會拒絕註冊。請先執行：sudo hostnamectl set-hostname ${host,,}"
    exit 1
  fi
}
_force_containerd_runtime_runc(){
  local -a bases=()
  local updated_env="false" updated_tpl="false" updated_conf="false"
  shopt -s nullglob
  bases=(/var/snap/microk8s/current/args /var/snap/microk8s/[0-9]*/args)
  shopt -u nullglob
  local base
  for base in "${bases[@]}"; do
    [[ -d "${base}" ]] || continue
    local env_file="${base}/containerd-env"
    if [[ -f "${env_file}" ]]; then
      if grep -q '^RUNTIME=' "${env_file}"; then
        if ! grep -q '^RUNTIME=runc$' "${env_file}"; then
          sed -i 's/^RUNTIME=.*/RUNTIME=runc/' "${env_file}" 2>/dev/null || true
          updated_env="true"
        fi
      else
        printf '\nRUNTIME=runc\n' >> "${env_file}" 2>/dev/null || true
        updated_env="true"
      fi
      if grep -q '^SNAPSHOTTER=' "${env_file}"; then
        if ! grep -q '^SNAPSHOTTER=overlayfs$' "${env_file}"; then
          sed -i 's/^SNAPSHOTTER=.*/SNAPSHOTTER=overlayfs/' "${env_file}" 2>/dev/null || true
          updated_env="true"
        fi
      else
        printf 'SNAPSHOTTER=overlayfs\n' >> "${env_file}" 2>/dev/null || true
        updated_env="true"
      fi
    fi
    local f
    for f in "${base}/containerd-template.toml" "${base}/containerd.toml"; do
      [[ -f "${f}" ]] || continue
      if grep -q '\${RUNTIME}' "${f}"; then
        sed -i 's/\${RUNTIME}/runc/g' "${f}" 2>/dev/null || true
        updated_tpl="true"
      fi
      if grep -q '\${SNAPSHOTTER}' "${f}"; then
        sed -i 's/\${SNAPSHOTTER}/overlayfs/g' "${f}" 2>/dev/null || true
        updated_tpl="true"
      fi
      if grep -q '\${RUNTIME_TYPE}' "${f}"; then
        sed -i 's/\${RUNTIME_TYPE}/io.containerd.runc.v2/g' "${f}" 2>/dev/null || true
        updated_tpl="true"
      fi
    done
  done

  shopt -s nullglob
  local conf
  for conf in /etc/containerd/conf.d/*.toml; do
    [[ -f "${conf}" ]] || continue
    if grep -q '\${SNAPSHOTTER}' "${conf}"; then
      sed -i 's/\${SNAPSHOTTER}/overlayfs/g' "${conf}" 2>/dev/null || true
      updated_conf="true"
    fi
    if grep -q '\${RUNTIME_TYPE}' "${conf}"; then
      sed -i 's/\${RUNTIME_TYPE}/io.containerd.runc.v2/g' "${conf}" 2>/dev/null || true
      updated_conf="true"
    fi
  done
  shopt -u nullglob

  if [[ "${updated_env}" == "true" || "${updated_tpl}" == "true" || "${updated_conf}" == "true" ]]; then
    log "[containerd] 調整 runtime=snapshots (runc/overlayfs)，重新載入 microk8s containerd"
    if command -v snapctl >/dev/null 2>&1; then
      snapctl restart microk8s.daemon-containerd >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl restart snap.microk8s.daemon-containerd.service >/dev/null 2>&1 || true
    fi
  fi
}

wait_all_nodes_ready(){
  log "[wait] 等待所有節點 Ready（最多 15 分鐘）"
  for i in {1..90}; do
    not_ready=$(KCTL get nodes -o json 2>/dev/null | jq -r '
      [.items[] | any(.status.conditions[]; .type=="Ready" and .status!="True")] | any' 2>/dev/null)
    [[ "$not_ready" == "false" ]] && { ok "[ok] 所有節點均為 Ready"; return 0; }
    sleep 10
  done
  warn "[wait] 節點仍未全部 Ready，後續安裝可能失敗（請先修 CNI/Calico 再重跑）"
}
