# ---------- 診斷小工具 ----------
install_diag_tool(){
  cat >/usr/local/bin/jhub-diag <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
NS="${1:-jhub}"
echo "== Pods in $NS =="; microk8s kubectl -n "$NS" get pods -o wide || true
echo "== CoreDNS =="; microk8s kubectl -n kube-system get deploy coredns; microk8s kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide || true
echo "== Events (last 50) =="; microk8s kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 50 || true
echo "== Hub describe (events last) =="; microk8s kubectl -n "$NS" describe pod -l component=hub | tail -n +1 || true
echo "== PVCs (wide) =="; microk8s kubectl -n "$NS" get pvc -o wide || true
echo "== StorageClasses =="; microk8s kubectl get sc || true
echo "== hostpath-provisioner events =="; \
  HP=$(microk8s kubectl -n kube-system get pod -l k8s-app=hostpath-provisioner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); \
  [[ -n "${HP:-}" ]] && microk8s kubectl -n kube-system describe pod "$HP" | egrep -i 'Image|Pull|Err|Fail|Mount|Reason|Warning' || true

echo "== GPU-Operator pods =="; microk8s kubectl -n gpu-operator get pods -o wide || true
echo "== GPU-Operator validator initContainers =="; \
  for P in $(microk8s kubectl -n gpu-operator get pod -l app=nvidia-operator-validator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
    echo "-- $P --"; microk8s kubectl -n gpu-operator get pod "$P" -o jsonpath='{range .spec.initContainers[*]}{.name}{" "}{end}{"\n"}' || true; \
  done
echo "== GPU-Operator validator logs (best-effort) =="; \
  for P in $(microk8s kubectl -n gpu-operator get pod -l app=nvidia-operator-validator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
    for C in $(microk8s kubectl -n gpu-operator get pod "$P" -o jsonpath='{range .spec.initContainers[*]}{.name}{" "}{end}'); do \
      echo "---- $P / $C ----"; microk8s kubectl -n gpu-operator logs "$P" -c "$C" --tail=120 || true; \
    done; \
  done
echo "== RuntimeClass / containerd check =="; \
  microk8s kubectl get runtimeclass nvidia || true; \
  grep -n 'nvidia' /var/snap/microk8s/current/args/containerd-template.toml || true
EOS
  chmod +x /usr/local/bin/jhub-diag
}

