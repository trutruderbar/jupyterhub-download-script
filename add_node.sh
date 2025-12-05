#!/usr/bin/env bash
#
# add_node.sh - helper to onboard an additional MicroK8s worker node.
# The script:
#   * prompts for SSH target (user / IP / password / port)
#   * prepares the remote host (packages, snapd, MicroK8s channel match)
#   * optionally syncs /usr/local/nvidia/toolkit
#   * runs microk8s join --worker and waits until the node is Ready
#   * copies offline *.tar images and imports them on the worker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${OFFLINE_IMAGE_DIR:=${SCRIPT_DIR}/offline-images}"
: "${SINGLEUSER_IMAGE:=myorg3/pytorch-jhub:24.10}"
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ -r "${LIB_DIR}/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${LIB_DIR}/env-loader.sh"
  load_jhub_env "${SCRIPT_DIR}"
fi

require_root(){
  if [[ $EUID -ne 0 ]]; then
    echo "[err] This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

command_exists(){ command -v "$1" >/dev/null 2>&1; }

PKG_CACHE_UPDATED=""
install_pkg(){
  local pkg="$1"
  if command_exists apt-get; then
    if [[ -z "${PKG_CACHE_UPDATED}" ]]; then
      apt-get update -y
      PKG_CACHE_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  elif command_exists dnf; then
    dnf install -y "$pkg" || yum install -y "$pkg"
  elif command_exists yum; then
    yum install -y "$pkg"
  else
    echo "[err] Unsupported package manager; please install ${pkg} manually." >&2
    exit 1
  fi
}

ensure_cmd(){
  local cmd="$1" pkg="${2:-$1}"
  if command_exists "$cmd"; then
    return 0
  fi
  echo "[info] Installing dependency: ${pkg}"
  install_pkg "$pkg"
}

ensure_ha_cluster(){
  if microk8s status --wait-ready >/dev/null 2>&1 && microk8s status 2>/dev/null | grep -q 'ha-cluster.*enabled'; then
    return 0
  fi
  echo "[info] Enabling microk8s ha-cluster"
  microk8s enable ha-cluster
}

get_microk8s_channel(){
  local track
  track="$(snap list microk8s 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${track}" ]]; then
    track="latest/stable"
  fi
  echo "${track}"
}

supports_worker_flag(){
  if microk8s add-node --help 2>&1 | grep -q -- '--worker'; then
    return 0
  fi
  return 1
}

generate_join_command(){
  local cmd=""
  if supports_worker_flag; then
    cmd="$(microk8s add-node --worker --format short | head -n1 | xargs || true)"
  else
    cmd="$(microk8s add-node --format short | head -n1 | xargs || true)"
  fi
  if [[ -z "${cmd}" ]]; then
    cmd="$(microk8s add-node 2>&1 | awk '/microk8s join / {print; exit}')"
  fi
  if [[ -z "${cmd}" ]]; then
    echo "[err] Unable to obtain microk8s join command." >&2
    exit 1
  fi
  echo "${cmd}"
}

base64_encode(){
  local data="$1"
  if base64 --help 2>&1 | grep -q -- '--wrap'; then
    printf '%s' "$data" | base64 -w0
  else
    printf '%s' "$data" | base64
  fi
}

wait_for_node_ready(){
  local node="$1" max_checks=60 ready=""
  echo "[info] Waiting for node ${node} to become Ready (this can take several minutes)..."
  for ((i=1; i<=max_checks; i++)); do
    if microk8s kubectl get node "${node}" >/dev/null 2>&1; then
      ready="$(microk8s kubectl get node "${node}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
      if [[ "${ready}" == "True" ]]; then
        echo "[info] Node ${node} is Ready."
        return 0
      fi
    fi
    sleep 10
  done
  echo "[warn] Node ${node} did not reach Ready state in the expected time. Check 'microk8s kubectl get nodes' manually." >&2
  return 1
}

require_root
if ! command_exists microk8s; then
  echo "[err] microk8s command not found on this host." >&2
  exit 1
fi
ensure_cmd sshpass sshpass
ensure_cmd rsync rsync

if [[ ! -d "${OFFLINE_IMAGE_DIR}" ]]; then
  echo "[warn] Offline image directory ${OFFLINE_IMAGE_DIR} not found. Image import step will be skipped."
fi

read -rp "Enter worker IP address: " REMOTE_HOST
REMOTE_HOST="${REMOTE_HOST:-}"
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "[err] Worker IP is required." >&2
  exit 1
fi
read -rp "Enter SSH username [root]: " REMOTE_USER
REMOTE_USER="${REMOTE_USER:-root}"
read -rsp "Enter SSH password: " REMOTE_PASS; echo
if [[ -z "${REMOTE_PASS}" ]]; then
  echo "[err] SSH password cannot be empty." >&2
  exit 1
fi
read -rp "Enter SSH port [22]: " REMOTE_PORT
REMOTE_PORT="${REMOTE_PORT:-22}"

K8S_CHANNEL="$(get_microk8s_channel)"
echo "[info] Local microk8s channel: ${K8S_CHANNEL}"
ensure_ha_cluster

SSH_PASS_FILE="$(mktemp)"
trap 'rm -f "$SSH_PASS_FILE"' EXIT
printf '%s' "${REMOTE_PASS}" > "${SSH_PASS_FILE}"
chmod 600 "${SSH_PASS_FILE}"
SSHPASS_CMD=(sshpass -f "${SSH_PASS_FILE}")
SSH_BASE_OPTS=(-p "${REMOTE_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
RSYNC_SSH="ssh -p ${REMOTE_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

remote_exec(){
  local cmd="$1"
  "${SSHPASS_CMD[@]}" ssh "${SSH_BASE_OPTS[@]}" "${SSH_TARGET}" "${cmd}"
}

remote_sudo(){
  local script="$1"
  local runner="bash -s"
  if [[ "${REMOTE_USER}" != "root" ]]; then
    runner="sudo bash -s"
  fi
  "${SSHPASS_CMD[@]}" ssh "${SSH_BASE_OPTS[@]}" "${SSH_TARGET}" "${runner}" <<<"${script}"
}

install_nfs_client(){
  remote_sudo "$(cat <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
install_pkg(){
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg" || yum install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  else
    echo "[remote][warn] 找不到可用的套件管理器，無法安裝 ${pkg}" >&2
    exit 1
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  install_pkg nfs-common
else
  install_pkg nfs-utils
fi
EOS
)"
}

ensure_local_dual_tag(){
  local image="${SINGLEUSER_IMAGE:-}"
  [[ -z "${image}" ]] && return 0
  local first_segment="${image%%/*}"
  if [[ "${image}" == docker.io/* || "${first_segment}" == "localhost" || "${first_segment}" == *.* || "${first_segment}" == *:* ]]; then
    return 0
  fi
  local docker_alias="docker.io/${image}"
  if microk8s ctr --namespace k8s.io images ls --quiet | grep -Fx "${image}" >/dev/null 2>&1; then
    CONTAINERD_NAMESPACE=k8s.io microk8s ctr images tag "${image}" "${docker_alias}" >/dev/null 2>&1 || true
  fi
}

echo "[info] Verifying SSH connectivity..."
if ! remote_exec "true" >/dev/null 2>&1; then
  echo "[err] Unable to connect to ${SSH_TARGET}. Please verify credentials and network access." >&2
  exit 1
fi

echo "[info] Ensuring NFS 用戶端已安裝..."
install_nfs_client

REMOTE_SHORT_HOST="$(remote_exec "hostname -s" | tr -d '\r')"
REMOTE_SHORT_HOST="${REMOTE_SHORT_HOST:-worker}"
REMOTE_HOSTNAME_LOWER="${REMOTE_SHORT_HOST,,}"
if [[ "${REMOTE_SHORT_HOST}" =~ [A-Z_] ]]; then
  echo "[err] Remote hostname '${REMOTE_SHORT_HOST}' contains uppercase letters or underscores. Please run 'sudo hostnamectl set-hostname ${REMOTE_HOSTNAME_LOWER}' on the worker and rerun this script." >&2
  exit 1
fi
REMOTE_HOME="$(remote_exec "printf %s \"\$HOME\"" | tr -d '\r')"
REMOTE_HOME="${REMOTE_HOME:-/home/${REMOTE_USER}}"
REMOTE_OFFLINE_STAGE="${REMOTE_HOME%/}/offline-import-$(date +%s)"
REMOTE_STAGE_REMOVE="true"
REMOTE_OFFLINE_CACHE_DIR="${REMOTE_HOME%/}/offline-images"
REMOTE_NVIDIA_STAGE="${REMOTE_HOME%/}/nvidia-toolkit-$(date +%s)"

HAS_OFFLINE_TARS=0
local_tar_names=()
if [[ -d "${OFFLINE_IMAGE_DIR}" ]]; then
  if compgen -G "${OFFLINE_IMAGE_DIR}/*.tar" >/dev/null 2>&1; then
    while IFS= read -r -d '' tar_path; do
      local_tar_names+=("$(basename "${tar_path}")")
    done < <(find "${OFFLINE_IMAGE_DIR}" -maxdepth 1 -type f -name '*.tar' -print0)
    if ((${#local_tar_names[@]})); then
      HAS_OFFLINE_TARS=1
    fi
  fi
fi

HAVE_LOCAL_TOOLKIT=0
if [[ -x /usr/local/nvidia/toolkit/nvidia-container-runtime ]]; then
  HAVE_LOCAL_TOOLKIT=1
fi

prepare_template=$(cat <<'SCRIPT'
set -euo pipefail
CHANNEL="__CHANNEL__"
echo "[remote] Preparing node with MicroK8s channel ${CHANNEL}"

PKG_MANAGER=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
fi

if [[ -z "${PKG_MANAGER}" ]]; then
  echo "[remote][err] Unsupported distribution (need apt, dnf, or yum)." >&2
  exit 1
fi

if [[ "${PKG_MANAGER}" == "apt" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y snapd curl jq rsync iproute2 runc
  systemctl enable --now snapd.socket
else
  if [[ "${PKG_MANAGER}" == "dnf" ]]; then
    dnf install -y snapd curl jq rsync iproute runc || true
  else
    yum install -y snapd curl jq rsync iproute runc || true
  fi
  systemctl enable --now snapd.socket
  if [[ ! -e /snap ]]; then
    ln -s /var/lib/snapd/snap /snap || true
  fi
fi

if hostname | grep -q '[A-Z_]'; then
  new_name="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')"
  echo "[remote][err] Hostname contains uppercase/underscore. Please run: sudo hostnamectl set-hostname ${new_name}" >&2
  exit 12
fi

# 清掉殘留叢集狀態，避免卡在舊的 dqlite/cluster-info
if snap list microk8s >/dev/null 2>&1; then
  status="$(microk8s status 2>&1 || true)"
  if grep -q 'acting as a node in a cluster' <<<"${status}"; then
    microk8s leave --force >/dev/null 2>&1 || true
  fi
  microk8s stop >/dev/null 2>&1 || true
  microk8s reset --destroy-storage >/dev/null 2>&1 || true
  rm -f /var/snap/microk8s/common/cluster-info.yaml /var/snap/microk8s/current/cluster-info.yaml
  rm -rf /var/snap/microk8s/current/cluster
  rm -rf /var/snap/microk8s/current/var/kubernetes/backend
fi

if snap list microk8s >/dev/null 2>&1; then
  status="$(microk8s status 2>&1 || true)"
  if grep -q 'acting as a node in a cluster' <<<"${status}"; then
    microk8s leave --force >/dev/null 2>&1 || true
    microk8s stop >/dev/null 2>&1 || true
    microk8s reset >/dev/null 2>&1 || true
    rm -f /var/snap/microk8s/common/cluster-info.yaml
    rm -rf /var/snap/microk8s/current/cluster
  fi
  snap refresh microk8s --classic --channel="${CHANNEL}"
else
  snap install microk8s --classic --channel="${CHANNEL}"
fi

shopt -s nullglob
bases=(/var/snap/microk8s/current/args /var/snap/microk8s/[0-9]*/args)
shopt -u nullglob
for base in "${bases[@]}"; do
  env_file="${base}/containerd-env"
  if [[ -f "${env_file}" ]]; then
    if grep -q '^RUNTIME=' "${env_file}"; then
      sed -i 's/^RUNTIME=.*/RUNTIME=runc/' "${env_file}"
    else
      printf '\nRUNTIME=runc\n' >> "${env_file}"
    fi
    if grep -q '^SNAPSHOTTER=' "${env_file}"; then
      sed -i 's/^SNAPSHOTTER=.*/SNAPSHOTTER=overlayfs/' "${env_file}"
    else
      printf 'SNAPSHOTTER=overlayfs\n' >> "${env_file}"
    fi
  fi
  [[ -d "${base}" ]] || continue
  for cfg in "${base}/containerd-template.toml" "${base}/containerd.toml"; do
    [[ -f "${cfg}" ]] || continue
    if ! grep -Fq '/etc/containerd/conf.d/*.toml' "${cfg}"; then
      tmp="$(mktemp)"
      printf 'imports = ["/etc/containerd/conf.d/*.toml"]\n\n' > "${tmp}"
      cat "${cfg}" >> "${tmp}"
      mv "${tmp}" "${cfg}"
    fi
  done
done

microk8s stop >/dev/null 2>&1 || true
microk8s start
if ! microk8s status --wait-ready --timeout 1200; then
  echo "[remote][err] microk8s failed to become ready." >&2
  exit 1
fi

# 若啟用 IB/RDMA，可預先載入常見模組，避免 RSDP 找不到 rdma_cm/umad
for mod in rdma_cm rdma_ucm ib_umad ib_uverbs ib_core mlx5_ib; do
  modprobe "${mod}" 2>/dev/null || true
done
SCRIPT
)

prepare_script="${prepare_template//__CHANNEL__/$K8S_CHANNEL}"
echo "[info] Preparing remote host ${REMOTE_HOST}..."
remote_sudo "${prepare_script}"

if [[ "${HAVE_LOCAL_TOOLKIT}" -eq 1 ]]; then
  echo "[info] Syncing NVIDIA container toolkit to ${REMOTE_HOST}"
  remote_exec "rm -rf '${REMOTE_NVIDIA_STAGE}'"
  "${SSHPASS_CMD[@]}" rsync -a -e "${RSYNC_SSH}" /usr/local/nvidia/ "${SSH_TARGET}:${REMOTE_NVIDIA_STAGE}/"
  runtime_sync_script=$(cat <<'SCRIPT'
set -euo pipefail
REMOTE_STAGE="__REMOTE_STAGE__"
mkdir -p /usr/local/nvidia
rsync -a "${REMOTE_STAGE}/" /usr/local/nvidia/
rm -rf "${REMOTE_STAGE}"
SCRIPT
)
  runtime_sync_script="${runtime_sync_script//__REMOTE_STAGE__/$REMOTE_NVIDIA_STAGE}"
  remote_sudo "${runtime_sync_script}"

  nvidia_runtime_template=$(cat <<'SCRIPT'
set -euo pipefail
mkdir -p /etc/containerd/conf.d
cat <<'TOML' >/etc/containerd/conf.d/99-nvidia.toml
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri"]
    enable_cdi = true

    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "nvidia"
      snapshotter = "overlayfs"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-cdi]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-cdi.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime.cdi"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-container-runtime.options]
            BinaryName = "nvidia-container-runtime"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-legacy]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia-legacy.options]
            BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime.legacy"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
TOML
systemctl restart snap.microk8s.daemon-containerd
sleep 3
SCRIPT
)
  remote_sudo "${nvidia_runtime_template}"
else
  echo "[warn] /usr/local/nvidia/toolkit not found locally; GPU runtime will not be configured on the worker."
fi

JOIN_CMD="$(generate_join_command)"
JOIN_CMD_B64="$(base64_encode "${JOIN_CMD}")"
join_script_template=$(cat <<'SCRIPT'
set -euo pipefail
JOIN_CMD="$(printf '%s' '__JOIN_CMD_B64__' | base64 -d)"
microk8s leave --force >/dev/null 2>&1 || true
eval "${JOIN_CMD}"
microk8s status --wait-ready --timeout 900
SCRIPT
)
join_script="${join_script_template//__JOIN_CMD_B64__/$JOIN_CMD_B64}"
echo "[info] Running microk8s join on ${REMOTE_HOST}..."
remote_sudo "${join_script}"

wait_for_node_ready "${REMOTE_HOSTNAME_LOWER}" || true

if [[ "${HAS_OFFLINE_TARS}" -eq 1 ]]; then
  REMOTE_OFFLINE_STAGE="${REMOTE_OFFLINE_CACHE_DIR}"
  REMOTE_STAGE_REMOVE="false"
  remote_exec "mkdir -p '${REMOTE_OFFLINE_STAGE}'"
  missing_remote=()
  for tar_name in "${local_tar_names[@]}"; do
    if ! remote_exec "[[ -f '${REMOTE_OFFLINE_STAGE}/${tar_name}' ]]"; then
      missing_remote+=("${tar_name}")
    fi
  done
  if ((${#missing_remote[@]} == 0)); then
    echo "[info] Remote ${REMOTE_OFFLINE_STAGE} already has all ${#local_tar_names[@]} image tar files; skipping transfer."
  else
    echo "[info] Remote ${REMOTE_OFFLINE_STAGE} is missing ${#missing_remote[@]} tar file(s): ${missing_remote[*]}"
    for tar_name in "${missing_remote[@]}"; do
      src_path="${OFFLINE_IMAGE_DIR%/}/${tar_name}"
      if [[ -f "${src_path}" ]]; then
        echo "[info] Syncing ${tar_name} to ${REMOTE_OFFLINE_STAGE}"
        "${SSHPASS_CMD[@]}" rsync -a -e "${RSYNC_SSH}" "${src_path}" "${SSH_TARGET}:${REMOTE_OFFLINE_STAGE}/"
      else
        echo "[warn] Local tar not found: ${src_path}" >&2
      fi
    done
  fi
  import_template=$(cat <<'SCRIPT'
set -euo pipefail
REMOTE_STAGE="__REMOTE_STAGE__"
REMOVE_STAGE="__REMOVE_STAGE__"
if ! compgen -G "${REMOTE_STAGE}/*.tar" >/dev/null 2>&1; then
  echo "[remote] No tar files found in ${REMOTE_STAGE}"
  exit 0
fi
SINGLEUSER_IMAGE="__SINGLEUSER_IMAGE__"
for tar in "${REMOTE_STAGE}"/*.tar; do
  [[ -f "${tar}" ]] || continue
  echo "[remote] Importing $(basename "${tar}")"
  if microk8s images import "${tar}"; then
    continue
  fi
  echo "[remote] microk8s images import failed for ${tar}, falling back to ctr"
  CONTAINERD_NAMESPACE=k8s.io microk8s ctr images import "${tar}" || echo "[remote][warn] Unable to import ${tar}"
done
if [[ -n "${SINGLEUSER_IMAGE}" ]]; then
  docker_alias=""
  first_segment="${SINGLEUSER_IMAGE%%/*}"
  if [[ "${SINGLEUSER_IMAGE}" != docker.io/* && "${first_segment}" != "localhost" && "${first_segment}" != *.* && "${first_segment}" != *:* ]]; then
    docker_alias="docker.io/${SINGLEUSER_IMAGE}"
  fi
  if [[ -n "${docker_alias}" && "${docker_alias}" != "${SINGLEUSER_IMAGE}" ]]; then
    if microk8s ctr --namespace k8s.io images ls --quiet | grep -Fx "${SINGLEUSER_IMAGE}" >/dev/null 2>&1; then
      CONTAINERD_NAMESPACE=k8s.io microk8s ctr images tag "${SINGLEUSER_IMAGE}" "${docker_alias}" >/dev/null 2>&1 || true
    fi
  fi
fi
if [[ "${REMOVE_STAGE}" == "true" ]]; then
  rm -rf "${REMOTE_STAGE}"
fi
SCRIPT
)
  import_script="${import_template//__REMOTE_STAGE__/$REMOTE_OFFLINE_STAGE}"
  import_script="${import_script//__SINGLEUSER_IMAGE__/$SINGLEUSER_IMAGE}"
  import_script="${import_script//__REMOVE_STAGE__/$REMOTE_STAGE_REMOVE}"
  remote_sudo "${import_script}"
else
  echo "[warn] No *.tar files found in ${OFFLINE_IMAGE_DIR}; skipping image import."
fi

ensure_local_dual_tag

echo
echo "==============================================="
echo "✅ Worker node '${REMOTE_HOSTNAME_LOWER}' onboarding complete."
echo "▶ SSH target      : ${SSH_TARGET}"
echo "▶ MicroK8s channel: ${K8S_CHANNEL}"
echo "▶ Offline images  : $( [[ ${HAS_OFFLINE_TARS} -eq 1 ]] && echo 'synced' || echo 'skipped' )"
echo
echo "Next steps:"
echo "  microk8s kubectl get nodes -o wide"
echo "  microk8s kubectl get pods -A -o wide | grep ${REMOTE_HOSTNAME_LOWER}"
echo "==============================================="
