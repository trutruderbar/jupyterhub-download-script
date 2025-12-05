# ---------- Cluster Helpers ----------
CLUSTER_ADD_NODE_SUPPORTS_WORKER=""
_cluster_add_node_supports_worker(){
  if [[ "${CLUSTER_ADD_NODE_SUPPORTS_WORKER}" == "true" ]]; then
    return 0
  elif [[ "${CLUSTER_ADD_NODE_SUPPORTS_WORKER}" == "false" ]]; then
    return 1
  fi
  if "$MICROK8S" add-node --help 2>&1 | grep -q -- '--worker'; then
    CLUSTER_ADD_NODE_SUPPORTS_WORKER="true"
    return 0
  else
    CLUSTER_ADD_NODE_SUPPORTS_WORKER="false"
    return 1
  fi
}
_ha_cluster_enabled(){
  "$MICROK8S" status 2>/dev/null | grep -q 'ha-cluster\s\+.*enabled'
}
_cluster_ensure_ha(){
  _cluster_enabled || return 0
  _ha_cluster_enabled && return 0
  log "[cluster] 啟用 microk8s ha-cluster（加入 worker 節點必要條件）"
  if ! "$MICROK8S" enable ha-cluster >/tmp/microk8s-ha.log 2>&1; then
    err "[cluster] 啟用 ha-cluster 失敗，log："
    sed -n '1,120p' /tmp/microk8s-ha.log || true
    exit 1
  fi
  ok "[cluster] ha-cluster 已啟用"
}
_cluster_enabled(){
  local trimmed="${CLUSTER_NODE_IPS//[[:space:],]/}"
  [[ -n "${trimmed}" ]]
}
_k8s_node_count(){
  local count
  count=$("$MICROK8S" kubectl get nodes --no-headers 2>/dev/null | awk 'NF {c++} END {print c+0}')
  [[ -n "${count}" ]] || count=0
  printf '%s' "${count}"
}
_cluster_ip_list(){
  local raw="${CLUSTER_NODE_IPS//,/ }" token
  for token in ${raw}; do
    token="${token//[[:space:]]/}"
    [[ -z "${token}" ]] && continue
    printf '%s\n' "${token}"
  done
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
  "${cmd[@]}"
}
_cluster_scp(){
  local ip="$1" src="$2" dest="$3"
  local -a cmd=(scp -P "${CLUSTER_SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  [[ -n "${CLUSTER_SSH_KEY}" ]] && cmd+=(-i "${CLUSTER_SSH_KEY}")
  if [[ -n "${CLUSTER_SSH_OPTS}" ]]; then
    local -a extra=()
    IFS=' ' read -r -a extra <<< "${CLUSTER_SSH_OPTS}"
    cmd+=("${extra[@]}")
  fi
  cmd+=("${src}" "${CLUSTER_SSH_USER}@${ip}:${dest}")
  "${cmd[@]}"
}
_cluster_requirements(){
  _cluster_enabled || return 0
  if [[ -z "${CLUSTER_SSH_KEY}" ]]; then
    err "[cluster] 未設定 CLUSTER_SSH_KEY"; exit 1
  fi
  if [[ ! -f "${CLUSTER_SSH_KEY}" ]]; then
    err "[cluster] 找不到 SSH 私鑰：${CLUSTER_SSH_KEY}"
    exit 1
  fi
  if [[ ! -r "${CLUSTER_SSH_KEY}" ]]; then
    err "[cluster] SSH 私鑰不可讀：${CLUSTER_SSH_KEY}"
    exit 1
  fi
  if ! is_cmd ssh; then
    log "[cluster] 安裝 openssh client"
    if is_ubuntu; then
      need_pkg openssh-client
    else
      need_pkg openssh-clients
    fi
  fi
  chmod 600 "${CLUSTER_SSH_KEY}" >/dev/null 2>&1 || true
}
_cluster_remote_prepare(){
  local ip="$1"
  log "[cluster] 準備節點 ${ip}（安裝/同步 MicroK8s ${K8S_CHANNEL}）"
  local remote_runtime_fn
  remote_runtime_fn="$(declare -f _ensure_containerd_nvidia_runtime)"
  {
    printf '%s\n' "${remote_runtime_fn}"
    cat <<'EOF'
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
CHANNEL="${K8S_CHANNEL}"
HOSTNAME="$(hostname)"
if echo "${HOSTNAME}" | grep -q '[A-Z_]'; then
  echo "[remote][err] 節點 ${HOSTNAME} 含有大寫或底線，請先執行：sudo hostnamectl set-hostname ${HOSTNAME,,}" >&2
  exit 1
fi
if ! command -v snap >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
    systemctl enable --now snapd.socket
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y snapd || yum install -y snapd
    systemctl enable --now snapd.socket
    [ -d /snap ] || ln -s /var/lib/snapd/snap /snap
  elif command -v yum >/dev/null 2>&1; then
    yum install -y snapd
    systemctl enable --now snapd.socket
    [ -d /snap ] || ln -s /var/lib/snapd/snap /snap
  else
    echo "[cluster][warn] 無法自動安裝 snapd，請於 ${TARGET_IP} 手動安裝" >&2
  fi
fi
need_install=false
if snap list | grep -q '^microk8s\\s'; then
  current_status="$(microk8s status 2>&1 || true)"
  if echo "${current_status}" | grep -q 'This MicroK8s deployment is acting as a node in a cluster'; then
    echo "[remote] ${TARGET_IP} 仍綁在既有叢集，執行 microk8s leave/reset" >&2
    microk8s leave --force >/dev/null 2>&1 || true
    microk8s stop >/dev/null 2>&1 || true
    microk8s reset >/dev/null 2>&1 || true
    rm -f /var/snap/microk8s/common/cluster-info.yaml 2>/dev/null || true
    rm -rf /var/snap/microk8s/current/cluster 2>/dev/null || true
    need_install=true
  elif ! microk8s status --wait-ready --timeout 300 >/dev/null 2>&1; then
    echo "[remote] ${TARGET_IP} 現有 MicroK8s 無法就緒，重新安裝" >&2
    need_install=true
  else
    snap refresh microk8s --channel="${CHANNEL}" || true
  fi
else
  need_install=true
fi
if [ "${need_install}" = true ]; then
  snap remove --purge microk8s >/dev/null 2>&1 || true
  rm -rf /var/snap/microk8s 2>/dev/null || true
  snap install microk8s --classic --channel="${CHANNEL}"
fi
# 確保 containerd runtime 以 runc 為預設
shopt -s nullglob
bases=(/var/snap/microk8s/current/args /var/snap/microk8s/[0-9]*/args)
shopt -u nullglob
for base in "${bases[@]}"; do
  env_file="${base}/containerd-env"
  if [ -f "${env_file}" ]; then
    sed -i 's/nRUNTIME=.*//' "${env_file}" || true
    sed -i 's/nSNAPSHOTTER=.*//' "${env_file}" || true
    if grep -q '^RUNTIME=' "${env_file}"; then
      sed -i 's/^RUNTIME=.*/RUNTIME=runc/' "${env_file}" || true
    else
      printf '\nRUNTIME=runc\n' >> "${env_file}" || true
    fi
    if grep -q '^SNAPSHOTTER=' "${env_file}"; then
      sed -i 's/^SNAPSHOTTER=.*/SNAPSHOTTER=overlayfs/' "${env_file}" || true
    else
      printf 'SNAPSHOTTER=overlayfs\n' >> "${env_file}" || true
    fi
  fi
  [ -d "${base}" ] || continue
  for f in "${base}/containerd-template.toml" "${base}/containerd.toml"; do
    [ -f "$f" ] || continue
    sed -i 's/\${RUNTIME}/runc/g' "$f" || true
    sed -i 's/\${SNAPSHOTTER}/overlayfs/g' "$f" || true
    sed -i 's/\${RUNTIME_TYPE}/io.containerd.runc.v2/g' "$f" || true
  done
done
shopt -s nullglob
for conf in /etc/containerd/conf.d/*.toml; do
  [ -f "${conf}" ] || continue
  sed -i 's/\${SNAPSHOTTER}/overlayfs/g' "${conf}" || true
  sed -i 's/\${RUNTIME_TYPE}/io.containerd.runc.v2/g' "${conf}" || true
done
shopt -u nullglob
_ensure_containerd_nvidia_runtime
current_status="$(microk8s status 2>&1 || true)"
if echo "${current_status}" | grep -q 'This MicroK8s deployment is acting as a node in a cluster'; then
  echo "[remote] ${TARGET_IP} 仍綁在既有叢集，執行 microk8s leave/reset" >&2
  microk8s leave --force >/dev/null 2>&1 || true
  microk8s stop >/dev/null 2>&1 || true
  microk8s reset >/dev/null 2>&1 || true
  rm -f /var/snap/microk8s/common/cluster-info.yaml 2>/dev/null || true
  rm -rf /var/snap/microk8s/current/cluster 2>/dev/null || true
fi
microk8s stop >/dev/null 2>&1 || true
microk8s start
if ! microk8s status --wait-ready --timeout 1200; then
  echo "[remote] ${TARGET_IP} microk8s status --wait-ready 逾時，最近日志：" >&2
  journalctl -u snap.microk8s.daemon-containerd -u snap.microk8s.daemon-kubelite -n 80 >&2 || true
  exit 1
fi
EOF
  } | _cluster_ssh "${ip}" env TARGET_IP="${ip}" K8S_CHANNEL="${K8S_CHANNEL}" bash -s
}

_cluster_ensure_nvidia_runtime(){
  local ip="$1"
  [[ "${USE_GPU_OPERATOR}" == "true" ]] || return 0
  log "[cluster] 確認節點 ${ip} containerd 已註冊 nvidia runtime"
  local remote_runtime_fn
  remote_runtime_fn="$(declare -f _ensure_containerd_nvidia_runtime)"
  {
    printf '%s\n' "${remote_runtime_fn}"
    cat <<'EOF'
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
_ensure_containerd_nvidia_runtime
systemctl restart snap.microk8s.daemon-containerd
sleep 3
EOF
  } | _cluster_ssh "${ip}" env TARGET_IP="${ip}" bash -s
}
_cluster_sync_images(){
  local ip="$1"
  local -a tars=()
  [[ -n "${CALICO_BUNDLE}" && -f "${CALICO_BUNDLE}" ]] && tars+=("${CALICO_BUNDLE}")
  [[ -n "${NOTEBOOK_TAR}" && -f "${NOTEBOOK_TAR}" ]] && tars+=("${NOTEBOOK_TAR}")
  [[ -n "${HOSTPATH_PROVISIONER_TAR}" && -f "${HOSTPATH_PROVISIONER_TAR}" ]] && tars+=("${HOSTPATH_PROVISIONER_TAR}")
  [[ -n "${COREDNS_TAR}" && -f "${COREDNS_TAR}" ]] && tars+=("${COREDNS_TAR}")
  [[ -n "${HUB_IMAGE_TAR}" && -f "${HUB_IMAGE_TAR}" ]] && tars+=("${HUB_IMAGE_TAR}")
  [[ -n "${PROXY_IMAGE_TAR}" && -f "${PROXY_IMAGE_TAR}" ]] && tars+=("${PROXY_IMAGE_TAR}")
  (( ${#tars[@]} == 0 )) && return 0
  log "[cluster] 傳送離線映像到 ${ip}"
  local tar_path remote_path
  for tar_path in "${tars[@]}"; do
    remote_path="/tmp/$(basename "${tar_path}")"
    if _cluster_scp "${ip}" "${tar_path}" "${remote_path}"; then
      log "[cluster] 匯入 $(basename "${tar_path}") 至 ${ip}"
      _cluster_ssh "${ip}" "
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
if microk8s images import '${remote_path}' >/tmp/microk8s-img.log 2>&1; then
  rm -f '${remote_path}'
else
  if microk8s ctr images import '${remote_path}' >/tmp/microk8s-img.log 2>&1; then
    rm -f '${remote_path}'
  else
    cat /tmp/microk8s-img.log >&2 || true
    exit 1
  fi
fi
" || warn "[cluster] ${ip} 匯入 ${tar_path} 失敗"
    else
      warn "[cluster] 無法複製 ${tar_path} 到 ${ip}"
    fi
  done
}
_cluster_get_join_command(){
  local output join_line="" 
  local -a add_args=()
  if _cluster_add_node_supports_worker; then
    add_args+=(--worker)
  fi
  if join_line=$("$MICROK8S" add-node "${add_args[@]}" --format short 2>/dev/null); then
    join_line="$(echo "${join_line}" | head -n1 | xargs || true)"
  else
    join_line=""
  fi
  if [[ -z "${join_line}" ]]; then
    output=$("$MICROK8S" add-node "${add_args[@]}" 2>&1 || true)
    join_line=$(printf '%s\n' "${output}" | awk '{$1=$1; if ($1=="microk8s" && $2=="join"){print; exit}}')
  fi
  if [[ -z "${join_line}" ]]; then
    err "[cluster] 無法取得 microk8s join 指令，輸出：${output}"
    return 1
  fi
  if [[ "${join_line}" != *"--worker"* ]]; then
    join_line="${join_line} --worker"
  fi
  printf '%s\n' "${join_line}"
}
_cluster_join_node(){
  local ip="$1" join_cmd join_b64
  _cluster_ensure_ha
  join_cmd="$(_cluster_get_join_command)" || return 1
  join_b64=$(printf '%s' "${join_cmd}" | base64 -w0 2>/dev/null || printf '%s' "${join_cmd}" | base64)
  log "[cluster] 將節點 ${ip} 加入叢集"
  _cluster_ssh "${ip}" env JOIN_CMD_B64="${join_b64}" bash -s <<'EOF'
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
if ! command -v base64 >/dev/null 2>&1; then
  echo "[cluster][err] 缺少 base64 指令，請先安裝 coreutils/base64" >&2
  exit 1
fi
JOIN_CMD="$(printf '%s' "${JOIN_CMD_B64}" | base64 -d)"
microk8s leave --force >/dev/null 2>&1 || true
eval "${JOIN_CMD}"
EOF
}
_cluster_wait_ready(){
  local ip="$1"
  log "[cluster] 等待節點 ${ip} Ready"
  for _ in {1..60}; do
    local nodes_json node_ready node_name
    nodes_json=$(KCTL get nodes -o json 2>/dev/null || true)
    if [[ -n "${nodes_json}" ]]; then
      node_name=$(echo "${nodes_json}" | jq -r --arg ip "${ip}" '
        .items[] | select(.status.addresses[]?.address==$ip) | .metadata.name' 2>/dev/null | head -n1 || true)
      if [[ -n "${node_name}" ]]; then
        node_ready=$(echo "${nodes_json}" | jq -r --arg name "${node_name}" '
          .items[] | select(.metadata.name==$name) | .status.conditions[] | select(.type=="Ready") | .status' 2>/dev/null | head -n1 || true)
        if [[ "${node_ready}" == "True" ]]; then
          ok "[cluster] 節點 ${ip} (${node_name}) 已 Ready"
          return 0
        fi
      fi
    fi
    sleep 10
  done
  warn "[cluster] 節點 ${ip} 未在預期時間內 Ready，請手動檢查"
}
ensure_cluster_nodes(){
  _cluster_enabled || return 0
  _cluster_ensure_ha
  _cluster_requirements
  local -a existing_ips=()
  if "$MICROK8S" kubectl get nodes -o wide >/dev/null 2>&1; then
    mapfile -t existing_ips < <("$MICROK8S" kubectl get nodes -o wide | awk 'NR>1 {print $6}' | sort -u)
  fi
  local ip
  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    if printf '%s\n' "${existing_ips[@]}" | grep -Fx "${ip}" >/dev/null 2>&1; then
      ok "[cluster] 節點 ${ip} 已在叢集中，略過"
      _cluster_ensure_nvidia_runtime "${ip}"
      continue
    fi
    _cluster_remote_prepare "${ip}"
    _cluster_sync_images "${ip}" || true
    if _cluster_join_node "${ip}"; then
      _cluster_ensure_nvidia_runtime "${ip}"
      if ! _cluster_wait_ready "${ip}"; then
        warn "[cluster] 節點 ${ip} 未 Ready，嘗試 microk8s inspect"
        _cluster_ssh "${ip}" "microk8s inspect || true"
      fi
    else
      warn "[cluster] 加入節點 ${ip} 失敗，請手動確認"
    fi
  done < <(_cluster_ip_list)
}
