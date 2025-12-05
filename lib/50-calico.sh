# ---------- Calico 換 quay.io ----------
wait_for_calico_ds(){
  log "[wait] 等待 kube-system 中的 calico-node DaemonSet 出現"
  for _ in {1..180}; do KCTL -n kube-system get ds calico-node >/dev/null 2>&1 && return 0; sleep 1; done
  warn "calico-node DS 尚未出現，之後會再嘗試 patch…"; return 1
}
patch_calico_use_quay(){
  [[ "${PATCH_CALICO}" != "true" ]] && { warn "[image] PATCH_CALICO=false，略過 Calico 變更"; return 0; }

  log "[image] 嘗試把 calico registry 換成 quay.io（沿用現有 tag）"
  local tmp=/tmp/calico-ds.json cur_tag node_img cni_img
  if ! KCTL -n kube-system get ds calico-node -o json > "$tmp" 2>/dev/null; then
    warn "找不到 calico-node DS，略過此次 patch"; return 0
  fi
  node_img=$(jq -r '.spec.template.spec.containers[] | select(.name=="calico-node").image' "$tmp")
  cni_img=$(jq -r '.spec.template.spec.initContainers[] | select(.name=="install-cni" or .name=="upgrade-ipam").image' "$tmp" | head -n1)
  cur_tag="${node_img##*:}"
  [[ -z "$cur_tag" || "$cur_tag" == "null" ]] && cur_tag="latest"

  jq \
    --arg t "$cur_tag" \
    '.spec.template.spec.containers |= (map(if .name=="calico-node" then .image=("quay.io/calico/node:"+$t) else . end)) |
     .spec.template.spec.initContainers |= (map(if (.name=="upgrade-ipam" or .name=="install-cni") then .image=("quay.io/calico/cni:"+$t) else . end))' \
    "$tmp" | KCTL apply -f -

  KCTL -n kube-system set image deploy/calico-kube-controllers calico-kube-controllers="quay.io/calico/kube-controllers:${cur_tag}" || true
  KCTL -n kube-system rollout status ds/calico-node --timeout=480s || true
  KCTL -n kube-system rollout status deploy/calico-kube-controllers --timeout=480s || true
}

