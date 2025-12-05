# ---------- 基礎環境 ----------
ensure_env(){
  export PATH="/snap/bin:/usr/local/bin:$PATH"
  [[ -f /etc/profile.d/snap_path.sh ]] || { echo 'export PATH="/snap/bin:/usr/local/bin:$PATH"' >/etc/profile.d/snap_path.sh; chmod 644 /etc/profile.d/snap_path.sh; }
  export KUBECONFIG="${KUBECONFIG_PATH}"
}
validate_auth_config(){
  local mode="${AUTH_MODE,,}"
  mode="${mode//[[:space:]]/}"
  case "${mode}" in
    ""|"native"|"nativeauthenticator")
      AUTH_MODE_NORMALIZED="native"
      ;;
    "github")
      AUTH_MODE_NORMALIZED="github"
      if [[ -z "${GITHUB_CLIENT_ID}" ]]; then
        err "[auth] AUTH_MODE=github 需要設定 GITHUB_CLIENT_ID"
        exit 1
      fi
      if [[ -z "${GITHUB_CLIENT_SECRET}" ]]; then
        err "[auth] AUTH_MODE=github 需要設定 GITHUB_CLIENT_SECRET"
        exit 1
      fi
      if [[ -z "${GITHUB_CALLBACK_URL}" ]]; then
        err "[auth] AUTH_MODE=github 需要設定 GITHUB_CALLBACK_URL（GitHub OAuth App 回呼 URL）"
        exit 1
      fi
      ;;
    "azure"|"azuread"|"azure-ad")
      AUTH_MODE_NORMALIZED="azuread"
      if [[ -z "${AZUREAD_CLIENT_ID}" ]]; then
        err "[auth] AUTH_MODE=azuread 需要設定 AZUREAD_CLIENT_ID（Azure AD 應用程式 ID）"
        exit 1
      fi
      if [[ -z "${AZUREAD_CLIENT_SECRET}" ]]; then
        err "[auth] AUTH_MODE=azuread 需要設定 AZUREAD_CLIENT_SECRET（Azure AD 應用程式密鑰）"
        exit 1
      fi
      if [[ -z "${AZUREAD_CALLBACK_URL}" ]]; then
        err "[auth] AUTH_MODE=azuread 需要設定 AZUREAD_CALLBACK_URL（Azure AD redirect URI）"
        exit 1
      fi
      if [[ -z "${AZUREAD_TENANT_ID}" ]]; then
        warn "[auth] AZUREAD_TENANT_ID 未設定，將預設使用 multi-tenant 模式 tenant_id=common"
        AZUREAD_TENANT_ID="common"
      fi
      ;;
    "ubilink"|"ubilink-cookie"|"billing")
      AUTH_MODE_NORMALIZED="ubilink"
      if [[ -z "${UBILINK_AUTH_ME_URL}" ]]; then
        err "[auth] AUTH_MODE=ubilink 需要設定 UBILINK_AUTH_ME_URL（驗證 API）"
        exit 1
      fi
      if [[ -n "${UBILINK_HTTP_TIMEOUT_SECONDS}" ]]; then
        if ! [[ "${UBILINK_HTTP_TIMEOUT_SECONDS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          err "[auth] UBILINK_HTTP_TIMEOUT_SECONDS 必須為數值（單位：秒）"
          exit 1
        fi
      else
        UBILINK_HTTP_TIMEOUT_SECONDS=5
      fi
      ;;
    *)
      err "[auth] 不支援的 AUTH_MODE='${AUTH_MODE}'（可用值：native、github、azuread 或 ubilink）"
      exit 1
      ;;
  esac
}
_ensure_kubelet_image_gc_disabled(){
  local kubelet_args="/var/snap/microk8s/current/args/kubelet"
  [[ -f "${kubelet_args}" ]] || return 0
  local updated=false
  if grep -q -- '--image-gc-high-threshold=' "${kubelet_args}"; then
    if ! grep -q -- '--image-gc-high-threshold=100' "${kubelet_args}"; then
      sed -i 's/--image-gc-high-threshold=[^[:space:]]*/--image-gc-high-threshold=100/' "${kubelet_args}"
      updated=true
    fi
  else
    echo "--image-gc-high-threshold=100" >> "${kubelet_args}"
    updated=true
  fi
  if grep -q -- '--image-gc-low-threshold=' "${kubelet_args}"; then
    if ! grep -q -- '--image-gc-low-threshold=99' "${kubelet_args}"; then
      sed -i 's/--image-gc-low-threshold=[^[:space:]]*/--image-gc-low-threshold=99/' "${kubelet_args}"
      updated=true
    fi
  else
    echo "--image-gc-low-threshold=99" >> "${kubelet_args}"
    updated=true
  fi
  if [[ "${updated}" == true ]]; then
    log "[kubelet] 調整 image GC 門檻（high=100, low=99），避免自動回收側載映像"
    if command -v snapctl >/dev/null 2>&1; then
      if ! snap restart microk8s.daemon-kubelite >/dev/null 2>&1; then
        warn "[kubelet] snap restart microk8s.daemon-kubelite 失敗，請手動確認"
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      if ! systemctl restart snap.microk8s.daemon-kubelet.service; then
        warn "[kubelet] systemctl 重啟 kubelet 失敗，請手動確認"
      fi
    else
      warn "[kubelet] 找不到 snapctl/systemctl，請手動重啟 kubelet"
    fi
  fi
}
pkg_install(){
  detect_os
  if is_ubuntu; then
    apt-get update -y || return $?
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || return $?
  elif is_rhel; then
    local rc=0
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y "$@" || rc=$?
      if (( rc != 0 )) && command -v yum >/dev/null 2>&1; then
        rc=0
        yum install -y "$@" || rc=$?
      fi
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "$@" || rc=$?
    else
      rc=1
    fi
    return $rc
  else
    err "[pkg] 僅支援 Ubuntu 或 Red Hat 系列套件管理"
    return 1
  fi
}
need_pkg(){
  local miss=()
  for p in "$@"; do
    if ! is_cmd "$p"; then
      miss+=("$p")
    fi
  done
  if ((${#miss[@]})); then
    pkg_install "${miss[@]}"
    return $?
  fi
  return 0
}
ensure_helm(){
  if ! is_cmd helm; then if is_cmd snap; then snap install helm --classic || true; fi; fi
  if ! is_cmd helm; then
    curl -fsSL "https://get.helm.sh/helm-${HELM_TARBALL_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz
    tar -C /tmp -xzf /tmp/helm.tgz; install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; rm -rf /tmp/linux-amd64 /tmp/helm.tgz
  fi
  helm version --short >/dev/null
}
preflight_sysctl(){
  log "[preflight] 關閉 swap / 載入 overlay, br_netfilter / 設定 ip_forward"
  swapoff -a || true; modprobe overlay || true; modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-k8s.conf <<'SYS'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
SYS
  sysctl --system >/dev/null 2>&1 || true
}
ensure_microk8s(){
  if ! is_cmd snap; then
    log "[act] 安裝 snapd"
    if is_ubuntu; then
      pkg_install snapd
      systemctl enable --now snapd.socket
    else
      pkg_install snapd snapd-selinux || true
      systemctl enable --now snapd.socket
      [[ -e /snap ]] || ln -s /var/lib/snapd/snap /snap
    fi
    sleep 2
  fi
  if snap list | grep -q '^microk8s\s'; then
    if ! "$MICROK8S" status --wait-ready >/dev/null 2>&1; then
      warn "[microk8s] 現有 MicroK8s 狀態不穩，執行 reinstall"
      snap remove --purge microk8s || true
      rm -rf /var/snap/microk8s 2>/dev/null || true
    fi
  fi
  if ! snap list | grep -q '^microk8s\s'; then
    log "[act] 安裝 MicroK8s (${K8S_CHANNEL})"
    snap install microk8s --channel="${K8S_CHANNEL}" --classic
  fi
  # 確保 containerd default runtime 已實際展開為 runc
  [[ "${FORCE_RUNC}" == "true" ]] && _force_containerd_runtime_runc
  "$MICROK8S" status --wait-ready --timeout 600 || { err "[microk8s] 服務啟動失敗"; exit 1; }
  ok "[ok] MicroK8s 就緒"
}
ensure_apiserver_ready(){
  log "[wait] 等待 MicroK8s API 就緒（最多 420s）"
  for _ in {1..70}; do "$MICROK8S" kubectl get --raw='/readyz' >/dev/null 2>&1 && { ok "[ok] apiserver /readyz OK"; return 0; }; sleep 6; done
  warn "[warn] apiserver /readyz 未就緒，但繼續嘗試後續步驟"
}
