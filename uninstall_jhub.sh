#!/usr/bin/env bash
set -euo pipefail

# ==== 0) 停掉所有舊的 port-forward / 殘留 kubectl ====
echo "[pf] Killing port-forward / stray kubectl..."
pkill -f 'kubectl.*port-forward' 2>/dev/null || true
pkill -f 'microk8s.kubectl.*port-forward' 2>/dev/null || true

# ==== 1) 若 API 還活著，優雅地清掉 Helm releases & namespaces ====
echo "[k8s] Trying to gracefully uninstall releases/namespaces (if API is reachable)..."
if command -v microk8s >/dev/null 2>&1; then KCTL="microk8s kubectl"; else KCTL="kubectl"; fi
if $KCTL version --client >/dev/null 2>&1; then
  helm -n jhub uninstall jhub 2>/dev/null || true
  helm -n gpu-operator uninstall gpu-operator 2>/dev/null || true

  # 嘗試刪 namespace；卡住就移除 finalizers
  for NS in jhub gpu-operator; do
    $KCTL delete ns "$NS" --ignore-not-found --wait=false || true
    # 砍 finalizers（避免卡 "Terminating"）
    if $KCTL get ns "$NS" -o name 2>/dev/null; then
      $KCTL get ns "$NS" -o json \
        | jq 'del(.spec.finalizers)' \
        | $KCTL replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true
    fi
  done

  # 可選：刪一些常見 CRD（若存在）
  $KCTL get crd | awk '/nvidia/{print $1}' | xargs -r $KCTL delete crd || true
fi

# ==== 2) 徹底移除 MicroK8s ====
if snap list 2>/dev/null | grep -q '^microk8s\s'; then
  echo "[microk8s] Stopping and purging snap..."
  /snap/bin/microk8s stop || true
  snap remove --purge microk8s || true
fi

# 清掉 MicroK8s 殘檔（資料、預設儲存等）
echo "[microk8s] Removing leftover data dirs..."
rm -rf /var/snap/microk8s 2>/dev/null || true
rm -rf /var/lib/cloud/init/* 2>/dev/null || true  # 有些雲映像會把 snap 測試檔留這，無害但可清

# ==== 3) 清 CNI / iptables 殘留（小心網路中斷；遠端請先開 out-of-band）====
echo "[cni] Removing leftover CNI state..."
ip link del cni0 2>/dev/null || true
ip link del flannel.1 2>/dev/null || true
rm -rf /etc/cni/net.d/* 2>/dev/null || true
rm -rf /var/lib/cni/* 2>/dev/null || true

# ==== 4) 清 Helm/本機設定（可選）====
echo "[helm] Purging local helm caches (optional)..."
rm -rf ~/.cache/helm ~/.config/helm ~/.local/share/helm 2>/dev/null || true

# ==== 5) 清除 kubectl 本體（依實際安裝來源選一種；全跑也安全）====
echo "[kubectl] Removing kubectl if present..."
# a) snap alias → 移除
snap aliases 2>/dev/null | awk '$1=="kubectl"{print $1}' | xargs -r -I{} snap unalias {} 2>/dev/null || true
# b) snap 包 → 移除
snap list 2>/dev/null | awk '$1=="kubectl"{print $1}' | xargs -r -I{} snap remove {} 2>/dev/null || true
# c) apt 包 → 移除
if dpkg -l 2>/dev/null | grep -qE '^ii\s+kubectl\b'; then
  apt-get purge -y kubectl || true
  apt-get autoremove -y || true
fi
# d) 手動放的二進位
rm -f /usr/local/bin/kubectl /usr/bin/kubectl 2>/dev/null || true
hash -r 2>/dev/null || true

echo "[done] Deep purge complete. It is recommended to reboot now."

#jupyterhub 清除
# 1) 先把可能殘留的 GPU Operator 清掉
sudo helm -n gpu-operator uninstall gpu-operator || true
sudo kubectl delete ns gpu-operator --ignore-not-found --wait=true
# 2) 停 microk8s；若起不來也沒關係
sudo /snap/bin/microk8s stop || true
# 3) 完全移除 microk8s（含資料）
sudo snap remove --purge microk8s || true
sudo rm -rf /var/snap/microk8s /var/snap/microk8s/common || true
