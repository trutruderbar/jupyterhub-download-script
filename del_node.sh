#!/usr/bin/env bash
#
# del_node.sh - helper to cordon/drain/remove a MicroK8s worker node and, if desired,
#               remotely uninstall MicroK8s on that host.

set -euo pipefail

: "${SINGLEUSER_IMAGE:=myorg3/pytorch-jhub:24.10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ -r "${LIB_DIR}/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${LIB_DIR}/env-loader.sh"
  load_jhub_env "${SCRIPT_DIR}"
fi

require_root(){
  if [[ $EUID -ne 0 ]]; then
    echo "[err] Please run this script as root (sudo ./del_node.sh)." >&2
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

ask_yes_no(){
  local prompt="$1" default="${2:-y}" reply hint
  if [[ "${default,,}" == "y" ]]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi
  read -rp "${prompt} ${hint} " reply
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" ]]
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

require_root
if ! command_exists microk8s; then
  echo "[err] microk8s command not found on this host." >&2
  exit 1
fi

read -rp "Enter the Kubernetes node name to remove: " NODE_NAME
NODE_NAME="${NODE_NAME:-}"
if [[ -z "${NODE_NAME}" ]]; then
  echo "[err] Node name is required." >&2
  exit 1
fi

echo "[info] Target node: ${NODE_NAME}"
if microk8s kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
  if ask_yes_no "Cordon and drain this node before removal?" "y"; then
    echo "[info] Cordoning ${NODE_NAME}"
    microk8s kubectl cordon "${NODE_NAME}"
    echo "[info] Draining ${NODE_NAME} (ignoring DaemonSets, deleting emptyDir data)"
    microk8s kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=10m
  else
    echo "[warn] Skipping drain — ensure workloads are migrated manually."
  fi
else
  echo "[warn] Node ${NODE_NAME} not found in kubectl output; skipping drain."
fi

REMOVE_FLAGS=()
if ask_yes_no "Node unreachable or already offline (use --force with microk8s remove-node)?" "n"; then
  REMOVE_FLAGS+=(--force)
fi

echo "[info] Removing node ${NODE_NAME} from the MicroK8s cluster..."
microk8s remove-node "${NODE_NAME}" "${REMOVE_FLAGS[@]}"

if microk8s kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
  echo "[warn] Node still appears in kubectl list; give it a minute or run 'microk8s kubectl delete node ${NODE_NAME}' manually if needed."
else
  echo "[info] Node ${NODE_NAME} no longer present in the cluster."
fi

if ask_yes_no "Do you want to remotely uninstall MicroK8s on that worker via SSH?" "n"; then
  ensure_cmd sshpass sshpass
  read -rp "Enter worker IP address: " REMOTE_HOST
  REMOTE_HOST="${REMOTE_HOST:-}"
  if [[ -z "${REMOTE_HOST}" ]]; then
    echo "[err] Worker IP is required for remote cleanup." >&2
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

  SSH_PASS_FILE="$(mktemp)"
  trap 'rm -f "$SSH_PASS_FILE"' EXIT
  printf '%s' "${REMOTE_PASS}" > "${SSH_PASS_FILE}"
  chmod 600 "${SSH_PASS_FILE}"
  SSHPASS_CMD=(sshpass -f "${SSH_PASS_FILE}")
  SSH_BASE_OPTS=(-p "${REMOTE_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

  echo "[info] Connecting to ${SSH_TARGET} for remote cleanup..."
  if ! "${SSHPASS_CMD[@]}" ssh "${SSH_BASE_OPTS[@]}" "${SSH_TARGET}" true >/dev/null 2>&1; then
    echo "[err] Unable to connect to ${SSH_TARGET}. Manual cleanup required." >&2
    exit 1
  fi

  read -r -d '' REMOTE_SCRIPT <<'SCRIPT'
set -euo pipefail
cleanup(){
  local target="$1"
  if [[ -e "${target}" ]]; then
    rm -rf "${target}" || true
  fi
}

if command -v microk8s >/dev/null 2>&1; then
  microk8s leave --force >/dev/null 2>&1 || true
  microk8s stop >/dev/null 2>&1 || true
  microk8s reset >/dev/null 2>&1 || true
  snap remove microk8s --purge >/dev/null 2>&1 || true
fi
cleanup /var/snap/microk8s
cleanup /var/snap/microk8s/common
cleanup /var/snap/microk8s/current/cluster
cleanup /var/snap/microk8s/current/var/kubernetes/backend
rm -f /var/snap/microk8s/common/cluster-info.yaml /var/snap/microk8s/current/cluster-info.yaml 2>/dev/null || true
cleanup /usr/local/nvidia
cleanup /tmp/offline-import-*
cleanup /tmp/nvidia-toolkit-*
echo "[remote] MicroK8s data removed."
SCRIPT

  REMOTE_RUNNER="bash -s"
  if [[ "${REMOTE_USER}" != "root" ]]; then
    REMOTE_RUNNER="sudo bash -s"
  fi
  "${SSHPASS_CMD[@]}" ssh "${SSH_BASE_OPTS[@]}" "${SSH_TARGET}" "${REMOTE_RUNNER}" <<<"${REMOTE_SCRIPT}"
  echo "[info] Remote cleanup on ${SSH_TARGET} completed."
fi

ensure_local_dual_tag

echo
echo "==============================================="
echo "✅ Node removal routine finished for '${NODE_NAME}'."
echo "▶ Verify remaining nodes: microk8s kubectl get nodes -o wide"
echo "▶ Check workloads/logs:   microk8s kubectl get pods -A"
echo "==============================================="
