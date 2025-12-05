#!/usr/bin/env bash
# cleanup_jhub_microk8s.sh
# 徹底清除：JupyterHub(Helm) + GPU/Network Operator + jhub命名空間/PV/PVC + 本機掛載目錄 + port-forward
#           + MicroK8s + CNI殘留 + containerd影像 + 本機 helm/kubectl 殘件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ -r "${LIB_DIR}/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${LIB_DIR}/env-loader.sh"
  load_jhub_env "${SCRIPT_DIR}"
fi

### ========= 使用方式與選項 =========
KEEP_STORAGE=false      # 保留 ./Storage 與 /var/log/jupyterhub
KEEP_IMAGES=false       # 保留 containerd 影像
NO_HELM=true            # 【改成預設跳過 Helm 卸載】避免等待/timeout
NO_OPERATORS=false      # 預設仍清理 Operators（可用 --no-operators 跳過）
FORCE=true              # 預設強制清乾淨（會移除 finalizers）
DRY_RUN=false

DEFAULT_HOST_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')"
if [[ -z "${DEFAULT_HOST_IP}" ]] && command -v ip >/dev/null 2>&1; then
  DEFAULT_HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
[[ -z "${DEFAULT_HOST_IP}" ]] && DEFAULT_HOST_IP="localhost"

: "${MICROK8S_API_HOST:=${DEFAULT_HOST_IP}}"
: "${CLUSTER_NODE_IPS:=}"
: "${CLUSTER_SSH_USER:=root}"
: "${CLUSTER_SSH_KEY:=./id_rsa}"
: "${CLUSTER_SSH_PORT:=22}"
: "${CLUSTER_SSH_OPTS:=}"
: "${NODEPORT_FALLBACK_PORT:=30080}"
: "${PF_LOCAL_PORT:=18080}"
: "${ADMINUSER_NODEPORT:=32081}"
: "${ADMINUSER_PF_PORT:=18081}"
: "${PORTAL_ROOT_DIR:=/root/jhub}"
: "${PORTAL_CONFIG_PATH:=$(pwd)/portal-config.js}"
: "${JHUB_NS:=jhub}"

for arg in "$@"; do
  case "$arg" in
    --keep-storage)  KEEP_STORAGE=true ;;
    --keep-images)   KEEP_IMAGES=true ;;
    --no-helm)       NO_HELM=true ;;
    --no-operators)  NO_OPERATORS=true ;;
    --no-force)      FORCE=false ;;
    --dry-run)       DRY_RUN=true ;;
    -h|--help)
      cat <<'USAGE'
用法：sudo bash cleanup_jhub_microk8s.sh [options]

選項：
  --keep-storage   保留本機掛載資料夾（./Storage 與 /var/log/jupyterhub）
  --keep-images    保留 containerd 影像，不刪本機側載映像
  --no-helm        跳過 Helm 卸載（預設為跳過，建議保留）
  --no-operators   跳過 GPU/Network Operator 清除
  --no-force       不做強制 finalizers 移除等激進手段
  --dry-run        只顯示將會執行的動作，不實際變更
USAGE
      exit 0
      ;;
  esac
done

### ========= 工具/環境偵測 =========
log(){ echo -e "\e[1;36m$*\e[0m"; }
ok(){ echo -e "\e[1;32m$*\e[0m"; }
warn(){ echo -e "\e[1;33m$*\e[0m"; }
err(){ echo -e "\e[1;31m$*\e[0m" 1>&2; }

ensure_env(){
  export PATH="/snap/bin:/usr/local/bin:$PATH"
  [[ -f /etc/profile.d/snap_path.sh ]] || { echo 'export PATH="/snap/bin:/usr/local/bin:$PATH"' >/etc/profile.d/snap_path.sh; chmod 644 /etc/profile.d/snap_path.sh; }
  export KUBECONFIG="/var/snap/microk8s/current/credentials/client.config"
  local cfg="$KUBECONFIG"
  if [[ -f "$cfg" ]] && ! grep -q "https://${MICROK8S_API_HOST}:16443" "$cfg"; then
    if $DRY_RUN; then
      echo "[dry-run] update kubeconfig server → https://${MICROK8S_API_HOST}:16443"
    else
      sed -i "s#server: https://[^:]*:16443#server: https://${MICROK8S_API_HOST}:16443#g" "$cfg" || true
    fi
  fi
}
ensure_env

is_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_deb(){ [ -f /etc/debian_version ]; }
is_rhel(){ [ -f /etc/redhat-release ] || grep -qi 'rhel' /etc/os-release 2>/dev/null; }

# 優先用 microk8s kubectl；沒有就用 kubectl
if is_cmd microk8s; then
  KCTL="microk8s kubectl"
  CTR="microk8s ctr"
else
  KCTL="kubectl"
  CTR="ctr"
fi
HELM_BIN="helm"

run(){ $DRY_RUN && { echo "[dry-run] $*"; return 0; } || eval "$*"; }

_delete_namespace(){
  local ns="$1"
  [[ -z "${ns}" ]] && return 0
  # 修正：當 --no-operators 時才跳過 operator 命名空間
  if $NO_OPERATORS && [[ "${ns}" == "gpu-operator" || "${ns}" == "nvidia-network-operator" ]]; then
    warn "[k8s] skip namespace ${ns}（--no-operators 啟用）"
    return 0
  fi
  if $DRY_RUN; then
    echo "[dry-run] kubectl delete ns ${ns}"
    return 0
  fi
  if ! $KCTL get ns "${ns}" >/dev/null 2>&1; then
    return 0
  fi
  log "[k8s] 刪除 namespace ${ns}"
  $KCTL delete ns "${ns}" --ignore-not-found --wait=false || true

  # 等待短暫時間，若仍存在則強制刪除或移除 finalizers
  for _ in {1..30}; do
    sleep 2
    if ! $KCTL get ns "${ns}" >/dev/null 2>&1; then
      return 0
    fi
    phase="$($KCTL get ns "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    [[ "${phase}" == "Terminating" || -z "${phase}" ]] && continue
  done

  warn "[k8s] namespace ${ns} 仍在 Terminating，嘗試移除 finalizers"
  remove_finalizers "${ns}" || true

  # 再試一次快速強制刪除
  $KCTL delete ns "${ns}" --force --grace-period=0 --ignore-not-found || true
}

_cluster_enabled(){
  local trimmed="${CLUSTER_NODE_IPS//[[:space:],]/}"
  [[ -n "${trimmed}" ]]
}
_cluster_ip_list(){
  local raw="${CLUSTER_NODE_IPS//,/ }" token
  for token in ${raw}; do
    token="${token//[[:space:]]/}"
    [[ -z "${token}" ]] && continue
    printf '%s\n' "${token}"
  done
}
_cluster_requirements(){
  _cluster_enabled || return 0
  if [[ -z "${CLUSTER_SSH_KEY}" || ! -f "${CLUSTER_SSH_KEY}" ]]; then
    err "[cluster] 找不到 SSH 私鑰（CLUSTER_SSH_KEY=${CLUSTER_SSH_KEY})"
    exit 1
  fi
  if ! is_cmd ssh; then
    if is_deb; then apt-get update -y >/dev/null 2>&1; apt-get install -y openssh-client >/dev/null 2>&1; fi
    if is_rhel; then dnf install -y openssh-clients >/dev/null 2>&1 || yum install -y openssh-clients >/dev/null 2>&1; fi
  fi
  chmod 600 "${CLUSTER_SSH_KEY}" >/dev/null 2>&1 || true
}
_cluster_ssh(){
  local ip="$1"; shift
  local -a cmd=(ssh -p "${CLUSTER_SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  [[ -n "${CLUSTER_SSH_KEY}" ]] && cmd+=(-i "${CLUSTER_SSH_KEY}")
  if [[ -n "${CLUSTER_SSH_OPTS}" ]]; then
    local -a extra=()
    IFS=' ' read -r -a extra <<< "${CLUSTER_SSH_OPTS}"
    cmd+=("${extra[@]}")
  fi
  cmd+=("${CLUSTER_SSH_USER}@${ip}")
  cmd+=("$@")
  if $DRY_RUN; then
    echo "[dry-run][remote ${ip}] ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}"
}

cleanup_remote_nodes(){
  _cluster_enabled || return 0
  _cluster_requirements
  log "[cluster] 清理遠端節點：${CLUSTER_NODE_IPS}"
  local ip
  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    log "[cluster] 處理節點 ${ip}"
    _cluster_ssh "${ip}" bash -s <<'EOF' || warn "[cluster] ${ip} 清理可能失敗"
set -euo pipefail
if command -v microk8s >/dev/null 2>&1; then
  microk8s leave --force >/dev/null 2>&1 || true
  microk8s stop >/dev/null 2>&1 || true
  microk8s reset >/dev/null 2>&1 || true
fi
if command -v snap >/dev/null 2>&1; then
  snap remove --purge microk8s >/dev/null 2>&1 || true
fi
rm -rf /var/snap/microk8s 2>/dev/null || true
rm -rf /var/snap/microk8s/current/cluster 2>/dev/null || true
rm -rf /var/snap/microk8s/current/var/kubernetes/backend 2>/dev/null || true
rm -f /var/snap/microk8s/common/cluster-info.yaml /var/snap/microk8s/current/cluster-info.yaml 2>/dev/null || true
rm -rf /root/jhub /var/log/jupyterhub 2>/dev/null || true
rm -f /usr/local/bin/jhub-portforward /usr/local/bin/jhub-diag 2>/dev/null || true
rm -f /var/run/jhub-pf.pid /var/run/jhub-adminuser-pf.pid 2>/dev/null || true
rm -f /var/log/jhub-port-forward.log /var/log/jhub-adminuser-port-forward.log 2>/dev/null || true
EOF
  done < <(_cluster_ip_list)
}

close_fw_port(){
  local p="$1"
  [[ -z "${p}" ]] && return 0
  if is_rhel && is_cmd firewall-cmd; then
    run "firewall-cmd --remove-port=${p}/tcp --permanent || true"
    run "firewall-cmd --reload || true"
  elif is_cmd ufw; then
    if ufw status 2>/dev/null | grep -q "${p}/tcp"; then
      run "yes | ufw delete allow ${p}/tcp >/dev/null || ufw delete allow ${p}/tcp || true"
    fi
  elif is_cmd iptables; then
    run "iptables -D INPUT -p tcp --dport ${p} -j ACCEPT 2>/dev/null || true"
    run "ip6tables -D INPUT -p tcp --dport ${p} -j ACCEPT 2>/dev/null || true"
  elif is_cmd nft; then
    local handles
    handles="$(nft --numeric list chain inet filter input 2>/dev/null | awk '/tcp dport '"${p}"'/ {for(i=1;i<=NF;i++) if(\$i==\"handle\"){print $(i+1)}}')"
    for h in $handles; do
      run "nft delete rule inet filter input handle ${h} 2>/dev/null || true"
    done
  fi
}
cleanup_firewall(){
  log "[fw] 收回開放的 NodePort / port-forward 防火牆規則"
  close_fw_port "${NODEPORT_FALLBACK_PORT}"
  close_fw_port "${ADMINUSER_NODEPORT}"
  close_fw_port "${PF_LOCAL_PORT}"
  close_fw_port "${ADMINUSER_PF_PORT}"
}

cleanup_portal_assets(){
  log "[portal] 移除 Portal 與模板"
  if [[ -d "${PORTAL_ROOT_DIR}" ]]; then
    run "rm -rf '${PORTAL_ROOT_DIR}' || true"
  fi
  if [[ -f "${PORTAL_CONFIG_PATH}" ]] && grep -q 'window.JUPYTER_PORTAL' "${PORTAL_CONFIG_PATH}" 2>/dev/null; then
    run "rm -f '${PORTAL_CONFIG_PATH}' || true"
  fi
  if [[ -f "$(pwd)/index.html" ]] && grep -q 'JupyterHub 快速入口' "$(pwd)/index.html" 2>/dev/null; then
    run "rm -f '$(pwd)/index.html' || true"
  fi
}

cleanup_local_tools(){
  log "[tools] 移除 jhub-portforward / jhub-diag 工具"
  run "rm -f /usr/local/bin/jhub-portforward /usr/local/bin/jhub-diag 2>/dev/null || true"
  run "rm -f /var/run/jhub-pf.pid /var/run/jhub-adminuser-pf.pid 2>/dev/null || true"
  run "rm -f /var/log/jhub-port-forward.log /var/log/jhub-adminuser-port-forward.log 2>/dev/null || true"
}

cleanup_sysctl_file(){
  local sysctl_file="/etc/sysctl.d/99-k8s.conf"
  if [[ -f "${sysctl_file}" ]] && grep -q 'net.bridge.bridge-nf-call-iptables' "${sysctl_file}" 2>/dev/null; then
    log "[sysctl] 移除 ${sysctl_file}"
    run "rm -f '${sysctl_file}' || true"
    run "sysctl --system >/dev/null 2>&1 || true"
  fi
}

### ========= 輔助：移除 namespace 卡在 Terminating（finalizers） =========
remove_finalizers(){
  local ns="$1"
  $DRY_RUN && { echo "[dry-run] remove_finalizers $ns"; return 0; }
  # 使用 kubectl patch（不依賴 jq）
  $KCTL patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  $KCTL patch namespace "$ns" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
}

### ========= 0) 停掉 port-forward / 雜散 kubectl =========
stop_port_forwards(){
  log "[pf] 停止所有 port-forward / 雜散 kubectl"
  run "pkill -f 'kubectl.*port-forward' 2>/dev/null || true"
  run "pkill -f 'microk8s.kubectl.*port-forward' 2>/dev/null || true"
}

### ========= 1) 先嘗試優雅清掉 Helm releases / 命名空間 =========
helm_uninstall_all(){
  $NO_HELM && { warn "[helm] 已啟用 --no-helm（預設）；跳過 helm 卸載"; return 0; }
  if ! is_cmd "$HELM_BIN"; then warn "[helm] 未安裝 helm，略過"; return 0; fi

  log "[helm] 卸載 JupyterHub / Operators（若存在；不等待 hooks）"
  if $HELM_BIN -n "${JHUB_NS}" status jhub >/dev/null 2>&1; then
    run "$HELM_BIN -n ${JHUB_NS} uninstall jhub --no-hooks --wait=false --timeout 60s || true"
  else
    warn "[helm] release jhub 不存在，略過卸載"
  fi
  if ! $NO_OPERATORS; then
    if $HELM_BIN -n gpu-operator status gpu-operator >/dev/null 2>&1; then
      run "$HELM_BIN -n gpu-operator uninstall gpu-operator --no-hooks --wait=false --timeout 60s || true"
    else
      warn "[helm] release gpu-operator 不存在，略過卸載"
    fi
    if $HELM_BIN -n nvidia-network-operator status network-operator >/dev/null 2>&1; then
      run "$HELM_BIN -n nvidia-network-operator uninstall network-operator --no-hooks --wait=false --timeout 60s || true"
    else
      warn "[helm] release network-operator 不存在，略過卸載"
    fi
  fi
}

delete_namespaces_and_crds(){
  log "[k8s] 刪除命名空間與相關 CRDs"
  _delete_namespace "${JHUB_NS}"
  if ! $NO_OPERATORS; then
    _delete_namespace "gpu-operator"
    _delete_namespace "nvidia-network-operator"
  fi

  # 移除 RuntimeClass nvidia（若有）
  run "$KCTL delete runtimeclass nvidia --ignore-not-found || true"

  # NVIDIA 相關 CRDs（若有）
  if ! $NO_OPERATORS; then
    if $KCTL get crd >/dev/null 2>&1; then
      local crds
      crds="$($KCTL get crd -o name | grep -E 'nvidia|nicclusterpolicies|clusterpolicies' || true)"
      if [ -n "$crds" ]; then
        while read -r crd; do
          [ -n "$crd" ] && run "$KCTL delete $crd --ignore-not-found || true"
        done <<< "$crds"
      fi
    fi
  fi

  # 如有卡 Terminating，且允許 FORCE，移除 finalizers
  if $FORCE; then
    remove_finalizers "${JHUB_NS}"
    $NO_OPERATORS || { remove_finalizers "gpu-operator"; remove_finalizers "nvidia-network-operator"; }
  fi
}

### ========= 2) 刪 jhub 專用 PV / PVC 與本機目錄 =========
delete_jhub_pv_pvc_and_dirs(){
  log "[storage] 刪除 jhub PV/PVC（storage-local, jhub-logs）"
  run "$KCTL -n ${JHUB_NS} delete pvc storage-local-pvc jhub-logs-pvc --ignore-not-found || true"
  run "$KCTL delete pv storage-local-pv jhub-logs-pv --ignore-not-found || true"

  if ! $KEEP_STORAGE; then
    log "[fs] 刪本機掛載資料夾（./Storage, /var/log/jupyterhub）"
    run "rm -rf \"$(pwd)/Storage\" 2>/dev/null || true"
    run "rm -rf /var/log/jupyterhub 2>/dev/null || true"
  else
    warn "[fs] 保留本機掛載資料夾（--keep-storage）"
  fi
}

### ========= 3) 清理 CNI 與網路殘留（避免 namespace 清不乾淨） =========
cleanup_cni_leftovers(){
  log "[cni] 移除 CNI 殘留（介面/狀態檔）"
  run "ip link del cni0 2>/dev/null || true"
  run "ip link del flannel.1 2>/dev/null || true"
  run "rm -rf /etc/cni/net.d/* 2>/dev/null || true"
  run "rm -rf /var/lib/cni/* 2>/dev/null || true"
  # 注意：不大動 iptables/路由，以免把主機網路弄斷。Calico/其他 CNI 遷移/移除時多半要清這些目錄。
}

### ========= 4) 刪除（MicroK8s）containerd 影像 =========
cleanup_images(){
  $KEEP_IMAGES && { warn "[images] 保留 containerd 影像（--keep-images）"; return 0; }
  if ! is_cmd ${CTR%%\ *}; then warn "[images] 找不到 ctr/microk8s ctr，略過"; return 0; fi
  log "[images] 清理與此次部署相關的映像（k8s.io namespace）"
  # 僅刪常見關聯影像；若要全部刪，可改成逐一 rm
  local patterns="nvcr-extended/pytorch|nvcr.io/nvidia/pytorch|coredns/coredns|quay.io/calico|quay.io/jupyterhub|docker.io/jupyterhub|nvcr.io|nvidia/"
  local imgs
  imgs="$($CTR -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep -E "$patterns" || true)"
  if [ -n "$imgs" ]; then
    while read -r img; do
      [ -n "$img" ] && run "$CTR -n k8s.io images rm \"$img\" || true"
    done <<< "$imgs"
  fi
}

### ========= 5) 卸載 MicroK8s（snap）與殘檔 =========
purge_microk8s(){
  if is_cmd microk8s || snap list 2>/dev/null | grep -q '^microk8s\s'; then
    log "[microk8s] 停用並移除 MicroK8s（snap）"
    run "/snap/bin/microk8s stop || true"
    run "snap remove --purge microk8s || true"
  fi
  log "[microk8s] 清理資料目錄"
  run "rm -rf /var/snap/microk8s 2>/dev/null || true"
}

### ========= 6) 清理 helm/kubectl 本機殘件（可選） =========
purge_local_tools(){
  log "[helm] 清理本機 helm 快取與設定（可選）"
  run "rm -rf ~/.cache/helm ~/.config/helm ~/.local/share/helm 2>/dev/null || true"

  log "[kubectl] 清理本機 kubectl（若希望）"
  # 移除 snap alias 與 snap 版 kubectl（如有）
  run "snap aliases 2>/dev/null | awk '\$1==\"kubectl\"{print \$1}' | xargs -r -I{} snap unalias {} 2>/dev/null || true"
  run "snap list 2>/dev/null | awk '\$1==\"kubectl\"{print \$1}' | xargs -r -I{} snap remove {} 2>/dev/null || true"
  # apt 版 kubectl（Debian/Ubuntu）
  if is_deb && dpkg -l 2>/dev/null | grep -qE '^ii\s+kubectl\b'; then
    run "apt-get purge -y kubectl || true"
    run "apt-get autoremove -y || true"
  fi
  # 手動放的二進位
  run "rm -f /usr/local/bin/kubectl /usr/bin/kubectl 2>/dev/null || true"
  run "hash -r 2>/dev/null || true"
}

### ========= 主流程 =========
log "[config] NO_HELM=${NO_HELM} NO_OPERATORS=${NO_OPERATORS} KEEP_STORAGE=${KEEP_STORAGE} KEEP_IMAGES=${KEEP_IMAGES} FORCE=${FORCE} DRY_RUN=${DRY_RUN}"
stop_port_forwards
cleanup_local_tools
cleanup_firewall
helm_uninstall_all
delete_namespaces_and_crds
delete_jhub_pv_pvc_and_dirs
cleanup_portal_assets
cleanup_cni_leftovers
cleanup_images
cleanup_remote_nodes
purge_microk8s
purge_local_tools
cleanup_sysctl_file

ok "[done] 清除完成。建議重開機以確保網路/容器 runtime 狀態乾淨。"
