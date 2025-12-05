# ---------- IB / GPU ----------
install_network_operator(){
  [[ "${ENABLE_IB}" != "true" ]] && return 0
  _ensure_ib_images
  log "[IB] 安裝 NVIDIA Network Operator（不套用自訂 CR）"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update nvidia >/dev/null 2>&1 || true
  local args=(--namespace nvidia-network-operator --create-namespace)
  [[ -n "${NETWORK_OPERATOR_VERSION}" ]] && args+=(--version "${NETWORK_OPERATOR_VERSION}")
  helm upgrade --install network-operator nvidia/network-operator "${args[@]}" || warn "[IB] Network Operator 安裝有誤，先略過（之後可手動調整）"
  ensure_nic_cluster_policy
}

_ib_crds=(
  nicclusterpolicies.nvdp.nvidia.com
  macvlannetworks.mellanox.com
  ipoibnetworks.mellanox.com
  hostdevicenetworks.mellanox.com
)

_wait_for_ib_crds(){
  local wait_seconds="${IB_NIC_POLICY_CRD_WAIT_SECONDS:-180}"
  local deadline=$((SECONDS + wait_seconds))
  while (( SECONDS < deadline )); do
    local missing=0
    local crd
    for crd in "${_ib_crds[@]}"; do
      if ! KCTL get crd "${crd}" >/dev/null 2>&1; then
        missing=1
        break
      fi
    done
    if (( missing == 0 )); then
      for crd in "${_ib_crds[@]}"; do
        KCTL wait --for=condition=Established --timeout=60s "crd/${crd}" >/dev/null 2>&1 || true
      done
      return 0
    fi
    sleep 6
  done
  warn "[IB] Network Operator CRD 尚未全部建立"
  return 1
}

_ib_bool(){
  local value="${1,,}"
  if [[ "${value}" == "true" ]]; then
    printf "true"
  else
    printf "false"
  fi
}

_wait_for_ib_crd(){
  local crd="$1"
  local wait_seconds="${IB_NIC_POLICY_CRD_WAIT_SECONDS:-180}"
  local deadline=$((SECONDS + wait_seconds))
  while (( SECONDS < deadline )); do
    if KCTL get crd "${crd}" >/dev/null 2>&1; then
      KCTL wait --for=condition=Established --timeout=60s "crd/${crd}" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 6
  done
  warn "[IB] ${crd} 尚未建立"
  return 1
}

_ensure_ib_images(){
  [[ "${ENABLE_IB}" != "true" ]] && return 0
  local image="${IB_RSDP_REPOSITORY}/${IB_RSDP_IMAGE}:${IB_RSDP_VERSION}"
  local tar="${IB_RSDP_IMAGE_TAR:-}"
  _ensure_image_local "${image}" "rdmaSharedDevicePlugin" "${tar}"
}

ensure_nic_cluster_policy(){
  [[ "${ENABLE_IB}" != "true" ]] && return 0
  local policy_name="${IB_NIC_POLICY_NAME}"
  if ! _wait_for_ib_crds; then
    return 0
  fi
  if KCTL get nicclusterpolicy "${policy_name}" >/dev/null 2>&1; then
    log "[IB] NicClusterPolicy ${policy_name} 已存在，略過建立"
    return 0
  fi
  if [[ -n "${IB_NIC_POLICY_TEMPLATE_FILE}" ]]; then
    if [[ -f "${IB_NIC_POLICY_TEMPLATE_FILE}" ]]; then
      log "[IB] 套用 NicClusterPolicy 模板：${IB_NIC_POLICY_TEMPLATE_FILE}"
      local rendered
      if command -v envsubst >/dev/null 2>&1; then
        rendered="$(envsubst <"${IB_NIC_POLICY_TEMPLATE_FILE}")"
      else
        rendered="$(cat "${IB_NIC_POLICY_TEMPLATE_FILE}")"
      fi
      printf '%s\n' "${rendered}" | KCTL apply -f -
      return 0
    else
      warn "[IB] 找不到 IB_NIC_POLICY_TEMPLATE_FILE=${IB_NIC_POLICY_TEMPLATE_FILE}，改用預設 NicClusterPolicy"
      IB_NIC_POLICY_TEMPLATE_FILE=""
    fi
  fi
  warn "[IB] 未提供 NicClusterPolicy 模板，請設定 IB_NIC_POLICY_TEMPLATE_FILE"
}
ensure_runtimeclass_nvidia(){
  KCTL get runtimeclass nvidia >/dev/null 2>&1 && return 0
  cat <<'YAML' | KCTL apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: { name: nvidia }
handler: nvidia
YAML
}

_detect_gpu_driver_mode(){
  # 輸出：在 stdout 印出最後決定的模式（host/dkms/precompiled）
  local mode="${GPU_DRIVER_MODE}"
  if [[ "${mode}" == "auto" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
      mode="host"
    else
      mode="dkms"
    fi
  fi
  printf '%s' "${mode}"
}

_maybe_install_kernel_headers(){
  [[ "${GPU_DKMS_INSTALL_HEADERS}" == "true" ]] || return 0
  if grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "linux-headers-$(uname -r)" mokutil >/dev/null 2>&1 || true
  fi
}

install_gpu_operator(){
  [[ "${USE_GPU_OPERATOR}" != "true" ]] && return 0
  KCTL -n kube-system delete ds nvidia-device-plugin-daemonset --ignore-not-found >/dev/null 2>&1 || true
  log "[GPU] 安裝 NVIDIA GPU Operator"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update nvidia >/dev/null 2>&1 || true
  # 避免與 microk8s 的 nvidia addon 衝突
  if microk8s status 2>/dev/null | grep -qE 'addons:.*nvidia: +enabled'; then
    warn "[GPU] 偵測到 microk8s addon 'nvidia' 已啟用，先停用以免衝突"
    microk8s disable nvidia || true
  fi
  _ensure_containerd_nvidia_runtime

  local ARGS=(--install --wait gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace)
  # Toolkit / CDI（MicroK8s containerd 路徑）
  if [[ "${GPU_OPERATOR_DISABLE_TOOLKIT}" != "true" ]]; then
    ARGS+=(--set toolkit.enabled=true)
    ARGS+=(--set cdi.enabled=false)
    ARGS+=(--set cdi.default=false)
    ARGS+=(--set operator.defaultRuntime=containerd)
    ARGS+=(--set toolkit.env[0].name=CONTAINERD_CONFIG --set toolkit.env[0].value="/var/snap/microk8s/current/args/containerd.toml")
    ARGS+=(--set toolkit.env[1].name=CONTAINERD_SOCKET --set toolkit.env[1].value="/var/snap/microk8s/common/run/containerd.sock")
    ARGS+=(--set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS --set toolkit.env[2].value=nvidia)
  fi
  # CUDA validator 會跑額外 workload；在多節點環境偶爾會因資源同步慢而卡住，統一改為只跑基本檢查
  ARGS+=(--set validator.env[0].name=WITH_WORKLOAD --set-string validator.env[0].value="false")
  ARGS+=(--set validator.cuda.env[0].name=WITH_WORKLOAD --set-string validator.cuda.env[0].value="false")

  # 決定驅動模式（優先採 GPU_DRIVER_MODE，若為 auto 則主機有驅動→host；否則 dkms）
  local MODE; MODE="$(_detect_gpu_driver_mode)"
  case "${MODE}" in
    host)
      log "[GPU] 使用 host 驅動模式（不佈署 driver）"
      ARGS+=(--set driver.enabled=false)
      ;;
    dkms)
      log "[GPU] 使用 dkms 驅動模式（編譯匹配當前 kernel）"
      _maybe_install_kernel_headers
      ARGS+=(--set driver.enabled=true)
      ARGS+=(--set driver.usePrecompiled=false)
      # 若你仍想指定版本，可沿用舊變數 GPU_OPERATOR_DRIVER_VERSION
      [[ -n "${GPU_OPERATOR_DRIVER_VERSION}" ]] && ARGS+=(--set-string driver.version="${GPU_OPERATOR_DRIVER_VERSION}")
      [[ -n "${GPU_OPERATOR_DRIVER_PKG_MANAGER}" ]] && ARGS+=(--set-string driver.manager="${GPU_OPERATOR_DRIVER_PKG_MANAGER}")
      [[ -n "${GPU_OPERATOR_DRIVER_RUNFILE_URL}" ]] && ARGS+=(--set-string driver.runfile.url="${GPU_OPERATOR_DRIVER_RUNFILE_URL}")
      ;;
    precompiled)
      log "[GPU] 使用 precompiled 驅動模式（預編驅動；需 kernel/版本對得上）"
      ARGS+=(--set driver.enabled=true)
      ARGS+=(--set driver.usePrecompiled=true)
      [[ -n "${GPU_OPERATOR_DRIVER_VERSION}" ]] && ARGS+=(--set-string driver.version="${GPU_OPERATOR_DRIVER_VERSION}")
      [[ -n "${GPU_OPERATOR_DRIVER_PKG_MANAGER}" ]] && ARGS+=(--set-string driver.manager="${GPU_OPERATOR_DRIVER_PKG_MANAGER}")
      [[ -n "${GPU_OPERATOR_DRIVER_RUNFILE_URL}" ]] && ARGS+=(--set-string driver.runfile.url="${GPU_OPERATOR_DRIVER_RUNFILE_URL}")
      ;;
    *)
      warn "[GPU] 未知 GPU_DRIVER_MODE='${MODE}'，回退為 host"
      ARGS+=(--set driver.enabled=false)
      ;;
  esac
  if [[ "${ENABLE_MIG}" == "true" ]]; then
    local gpu_ns="gpu-operator"
    local mig_cm="${MIG_CONFIGMAP_NAME:-jhub-mig-config}"
    local mig_default="${MIG_CONFIG_DEFAULT:-all-disabled}"
    local mig_profile="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
    if [[ "${mig_default}" != "all-disabled" && -n "${mig_default}" ]]; then
      warn "[MIG] MIG_CONFIG_DEFAULT=${mig_default} 不被 GPU Operator 接受，改為 all-disabled"
      mig_default="all-disabled"
    fi
    log "[GPU][MIG] 生成 MIG Manager ConfigMap (${mig_cm}/${mig_profile})"
    KCTL get ns "${gpu_ns}" >/dev/null 2>&1 || KCTL create ns "${gpu_ns}"
    local mig_config
    mig_config="$(_render_mig_manager_config)"
    cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${mig_cm}
  namespace: ${gpu_ns}
data:
  config.yaml: |
$(printf '%s\n' "${mig_config}" | _indent 4)
YAML
    ARGS+=(--set migManager.enabled=true)
    ARGS+=(--set-string mig.strategy="${MIG_STRATEGY}")
    ARGS+=(--set-string migManager.config.create=false)
    ARGS+=(--set-string migManager.config.name="${mig_cm}")
    ARGS+=(--set-string migManager.config.default="${mig_default}")
    log "[GPU][MIG] MIG_CONFIG_DEFAULT=${mig_default}；將自動標記節點以套用 ${mig_profile}"
    _label_mig_nodes
  else
    # 明確關閉 MIG 相關元件，避免預設值觸發 GPU 驗證失敗
    ARGS+=(--set migManager.enabled=false)
    ARGS+=(--set-string mig.strategy=none)
  fi
  [[ -n "${GPU_OPERATOR_VERSION}" ]] && ARGS+=(--version "${GPU_OPERATOR_VERSION}")
  helm upgrade "${ARGS[@]}"
  ensure_runtimeclass_nvidia
}
