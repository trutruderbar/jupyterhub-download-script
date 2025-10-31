#!/usr/bin/env bash
# cleanup_jhub_microk8s.sh
# 徹底清除：JupyterHub(Helm) + GPU/Network Operator + jhub命名空間/PV/PVC + 本機掛載目錄 + port-forward
#           + MicroK8s + CNI殘留 + containerd影像 + 本機 helm/kubectl 殘件
set -euo pipefail

### ========= 使用方式與選項 =========
KEEP_STORAGE=false      # 保留 ./Storage 與 /var/log/jupyterhub
KEEP_IMAGES=false       # 保留 containerd 影像
NO_HELM=false           # 不執行 helm 卸載
NO_OPERATORS=false      # 不處理 GPU/Network Operator
FORCE=true              # 預設強制清乾淨
DRY_RUN=false
DEFAULT_HOST_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')"
if [[ -z "${DEFAULT_HOST_IP}" ]] && command -v ip >/dev/null 2>&1; then
  DEFAULT_HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
fi
[[ -z "${DEFAULT_HOST_IP}" ]] && DEFAULT_HOST_IP="localhost"

: "${MICROK8S_API_HOST:=${DEFAULT_HOST_IP}}"

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
  --no-helm        跳過 Helm 卸載（若你已手動卸載）
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

### ========= 輔助：移除 namespace 卡在 Terminating（finalizers） =========
remove_finalizers(){
  local ns="$1"
  $DRY_RUN && { echo "[dry-run] remove_finalizers $ns"; return 0; }
  if $KCTL get ns "$ns" -o json >/dev/null 2>&1; then
    # 將 finalizers 清空再 finalize（避免卡住）
    $KCTL get ns "$ns" -o json \
      | jq 'del(.spec.finalizers)' \
      | $KCTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
  fi
}

### ========= 0) 停掉 port-forward / 雜散 kubectl =========
stop_port_forwards(){
  log "[pf] 停止所有 port-forward / 雜散 kubectl"
  run "pkill -f 'kubectl.*port-forward' 2>/dev/null || true"
  run "pkill -f 'microk8s.kubectl.*port-forward' 2>/dev/null || true"
}

### ========= 1) 先嘗試優雅清掉 Helm releases / 命名空間 =========
helm_uninstall_all(){
  $NO_HELM && { warn "[helm] 跳過 helm 卸載（--no-helm）"; return 0; }
  if ! is_cmd "$HELM_BIN"; then warn "[helm] 未安裝 helm，略過"; return 0; fi

  log "[helm] 卸載 JupyterHub / Operators（若存在）"
  if $HELM_BIN -n jhub status jhub >/dev/null 2>&1; then
    run "$HELM_BIN -n jhub uninstall jhub || true"
  else
    warn "[helm] release jhub 不存在，略過卸載"
  fi
  if ! $NO_OPERATORS; then
    if $HELM_BIN -n gpu-operator status gpu-operator >/dev/null 2>&1; then
      run "$HELM_BIN -n gpu-operator uninstall gpu-operator || true"
    else
      warn "[helm] release gpu-operator 不存在，略過卸載"
    fi
    if $HELM_BIN -n nvidia-network-operator status network-operator >/dev/null 2>&1; then
      run "$HELM_BIN -n nvidia-network-operator uninstall network-operator || true"
    else
      warn "[helm] release network-operator 不存在，略過卸載"
    fi
  fi
}

delete_namespaces_and_crds(){
  log "[k8s] 刪除命名空間與相關 CRDs"
  # 刪除 jhub / operators 命名空間（非阻塞）
  run "$KCTL delete ns jhub --ignore-not-found --wait=false || true"
  $NO_OPERATORS || run "$KCTL delete ns gpu-operator nvidia-network-operator --ignore-not-found --wait=false || true"

  # 移除 RuntimeClass nvidia（若有）
  run "$KCTL delete runtimeclass nvidia --ignore-not-found || true"

  # NVIDIA 相關 CRDs（若有）
  if ! $NO_OPERATORS; then
    # GPU/Network Operator 常見 CRD 名稱包含 'nvidia' 關鍵字
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
    remove_finalizers "jhub"
    $NO_OPERATORS || { remove_finalizers "gpu-operator"; remove_finalizers "nvidia-network-operator"; }
  fi
}

### ========= 2) 刪 jhub 專用 PV / PVC 與本機目錄 =========
delete_jhub_pv_pvc_and_dirs(){
  log "[storage] 刪除 jhub PV/PVC（storage-local, jhub-logs）"
  run "$KCTL -n jhub delete pvc storage-local-pvc jhub-logs-pvc --ignore-not-found || true"
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
  local patterns="nvcr-extended/pytorch|nvcr.io/nvidia/pytorch|coredns/coredns|quay.io/calico|nvcr.io|nvidia/"
  local imgs
  imgs="$($CTR -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep -E "$patterns" || true)"
  if [ -n "$imgs" ]; then
    while read -r img; do
      [ -n "$img" ] && run "$CTR -n k8s.io images rm \"$img\" || true"
    done <<< "$imgs"
  fi
  # containerd 的 ctr images rm 用法可參考指令參考文件。:contentReference[oaicite:3]{index=3}
}

### ========= 5) 卸載 MicroK8s（snap）與殘檔 =========
purge_microk8s(){
  if is_cmd microk8s || snap list 2>/dev/null | grep -q '^microk8s\s'; then
    log "[microk8s] 停用並移除 MicroK8s（snap）"
    run "/snap/bin/microk8s stop || true"
    run "snap remove --purge microk8s || true"   # snap 官方建議用 remove --purge 完全移除
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
stop_port_forwards
helm_uninstall_all
delete_namespaces_and_crds
delete_jhub_pv_pvc_and_dirs
cleanup_cni_leftovers
cleanup_images
purge_microk8s
purge_local_tools

ok "[done] 清除完成。建議重開機以確保網路/容器 runtime 狀態乾淨。"
