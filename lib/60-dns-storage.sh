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

