#!/usr/bin/env bash
# JupyterHub one-shot installer v4.6 (modular + offline side-load + coredns fix + logs + API proxy hints)
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
export JHUB_HOME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
: "${OFFLINE_IMAGE_DIR:=${SCRIPT_DIR}/offline-images}"

ENV_LOADER="${LIB_DIR}/env-loader.sh"
if [[ -r "${ENV_LOADER}" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${ENV_LOADER}"
  load_jhub_env "${SCRIPT_DIR}"
fi

MODULES=(
  "00-base.sh"
  "10-cluster.sh"
  "20-portforward.sh"
  "30-environment.sh"
  "40-images.sh"
  "50-calico.sh"
  "60-dns-storage.sh"
  "70-profiles.sh"
  "80-containerd.sh"
  "90-values.sh"
  "100-storage.sh"
  "110-gpu.sh"
  "120-cuda.sh"
  "130-nodeport.sh"
  "140-diag.sh"
  "150-mpi.sh"
)

for module in "${MODULES[@]}"; do
  module_path="${LIB_DIR}/${module}"
  if [[ -r "${module_path}" ]]; then
    # shellcheck source=/dev/null
    source "${module_path}"
  else
    printf '[mod] 無法讀取模組檔案：%s\n' "${module_path}" >&2
    exit 1
  fi
done

# 預載 RDMA 模組，避免 RSDP 找不到 rdma_cm/umad
ensure_rdma_modules(){
  [[ "${ENABLE_IB}" != "true" ]] && return 0
  if ! command -v modprobe >/dev/null 2>&1; then
    warn "[rdma] modprobe 不存在，無法預先載入模組"
    return 0
  fi
  for mod in rdma_cm rdma_ucm ib_umad ib_uverbs ib_core mlx5_ib; do
    modprobe "${mod}" 2>/dev/null || true
  done
  if [[ -c /dev/infiniband/rdma_cm ]]; then
    log "[rdma] 已載入 rdma_cm/ib_umad 等模組，/dev/infiniband/rdma_cm 就緒"
  else
    warn "[rdma] 未發現 /dev/infiniband/rdma_cm，請確認主機 RDMA 驅動已安裝"
  fi
}

# ---------- 主要流程 ----------
main(){
  require_root
  detect_os
  ensure_lowercase_hostname
  ensure_env
  validate_auth_config
  if [[ ! -d "${OFFLINE_IMAGE_DIR}" ]]; then
    warn "[offline] 找不到離線映像目錄 ${OFFLINE_IMAGE_DIR}，將自動建立（請先放入所需 tar 檔）"
    mkdir -p "${OFFLINE_IMAGE_DIR}"
  fi
  preflight_sysctl
  ensure_microk8s
  _ensure_kubelet_image_gc_disabled
  if is_rhel; then
    need_pkg curl jq tar ca-certificates iproute
  else
    need_pkg curl ca-certificates jq tar
  fi
  ensure_helm
  ensure_apiserver_ready
  ensure_cluster_nodes
  ensure_rdma_modules

  images_import

  if [[ "${DEBUG_INSTALL_IMAGES:-false}" == "true" ]]; then
    log "[debug] 已完成 images_import，排程後續步驟"
  fi

  wait_for_calico_ds || true
  patch_calico_use_quay

  ensure_dns_and_storage
  wait_all_nodes_ready

  # 先建 namespace 與本地 PV/PVC（Storage 與 Logs）
  KCTL get ns "${JHUB_NS}" >/dev/null 2>&1 || KCTL create ns "${JHUB_NS}"
  ensure_local_pv
  ensure_resource_quota
  ensure_tls_secret
  ensure_network_policy

  # IB/GPU
  install_network_operator
  install_gpu_operator
  install_mpi_operator
  ensure_mpi_user_rbac

  if [[ "${CUSTOM_STATIC_ENABLED}" == "auto" ]]; then
    if [[ -d "${CUSTOM_STATIC_SOURCE_DIR}" ]] && compgen -G "${CUSTOM_STATIC_SOURCE_DIR}/*" >/dev/null; then
      CUSTOM_STATIC_ENABLED="true"
      log "[custom] 偵測到自訂靜態資源目錄：${CUSTOM_STATIC_SOURCE_DIR}"
    else
      CUSTOM_STATIC_ENABLED="false"
    fi
  fi

  # 生成 values.yaml
  _detect_resources
  _write_values_yaml
  _install_custom_templates

  # 安裝 JupyterHub
  helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null 2>&1 || true
  helm repo update jupyterhub >/dev/null 2>&1 || true
  log "[act] 部署 JupyterHub chart ${JHUB_CHART_VERSION}"
  helm upgrade --cleanup-on-fail --install "${JHUB_RELEASE}" jupyterhub/jupyterhub \
    -n "${JHUB_NS}" --version "${JHUB_CHART_VERSION}" \
    -f ${JHUB_HOME}/values.yaml --timeout "${HELM_TIMEOUT}"

  log "[wait] 等待 Hub/Proxy 就緒"
  wait_rollout "${JHUB_NS}" deploy hub 900s
  wait_rollout "${JHUB_NS}" deploy proxy 600s
  KCTL -n "${JHUB_NS}" get pods,svc

  # 建立 adminuser 專用 NodePort（免 Hub 登入）
  ensure_adminuser_nodeport
  ensure_nginx_proxy

  # port-forward 小工具 & 診斷
  install_portforward_tool
  install_diag_tool

  local node_ip pf_url hub_nodeport_url admin_service_url https_url pf_active="false"
  node_ip=$(hostname -I | awk '{print $1}')
  hub_nodeport_url="http://${node_ip}:${NODEPORT_FALLBACK_PORT}"
  pf_url="http://${PF_BIND_ADDR}:${PF_LOCAL_PORT}"
  admin_service_url="http://${node_ip}:${ADMINUSER_NODEPORT}"
  https_url="${NGINX_PROXY_URL:-}"
  if [[ -n "${https_url}" ]]; then
    ACCESS_URL="${https_url}"
  else
    ACCESS_URL="${hub_nodeport_url}"
  fi
  if [[ "${PF_AUTOSTART}" == "true" ]]; then
    pf_stop || true
    if pf_start; then
      ACCESS_URL="$pf_url"
      pf_active="true"
    fi
  fi

  _deploy_portal_page "$ACCESS_URL" "$hub_nodeport_url" "$pf_url" "$admin_service_url" "$pf_active"

  # CUDA 冒煙（若側載）
  if [[ "${USE_GPU_OPERATOR}" == "true" ]]; then deploy_cuda_smoketest || true; fi

  local -a cluster_ip_arr=()
  if _cluster_enabled; then
    while IFS= read -r ip; do
      [[ -z "${ip}" ]] && continue
      cluster_ip_arr+=("${ip}")
    done < <(_cluster_ip_list)
  fi
  local cluster_nodes="單節點（預設）"
  if ((${#cluster_ip_arr[@]})); then
    cluster_nodes=$(IFS=', '; echo "${cluster_ip_arr[*]}")
  fi
  local auth_mode_display="${AUTH_MODE_NORMALIZED:-native}"
  case "${auth_mode_display}" in
    "github") auth_mode_display="github (GitHub OAuth)";;
    "azuread"|"azure"|"azure-ad") auth_mode_display="azuread (Azure AD OAuth)";;
    "ubilink") auth_mode_display="ubilink (Ubilink Cookie)";;
    *) auth_mode_display="native (內建帳號)";;
  esac
  local admin_users_display="${ADMIN_USERS_CSV:-${ADMIN_USER}}"
  local nginx_summary_line=""
  if [[ -n "${https_url}" ]]; then
    nginx_summary_line="▶ HTTPS 反向代理：${https_url}（Nginx → NodePort ${NODEPORT_FALLBACK_PORT}）"
  fi
  local firewall_https_cmd=""
  local ufw_https_cmd=""
  if [[ -n "${https_url}" ]]; then
    firewall_https_cmd=" && firewall-cmd --add-port=${NGINX_PROXY_HTTPS_PORT}/tcp --permanent"
    ufw_https_cmd=" && ufw allow ${NGINX_PROXY_HTTPS_PORT}/tcp"
  fi

  cat <<EOF

============================================================
✅ JupyterHub 安裝完成（offline side-load + Calico via quay + CoreDNS fix + JSON-in-YAML）
▶ 存取網址：${ACCESS_URL}
▶ 管理者（admin_users）：${admin_users_display}
▶ 認證模式：${auth_mode_display}
▶ 儲存 PVC：${PVC_SIZE}（SC: microk8s-hostpath + 本地 PV）
▶ SingleUser 映像：${SINGLEUSER_IMAGE}
▶ 掛載：/kubeflow_cephfs/jhub_storage/<username> → /workspace/storage；/var/log/jupyterhub → /var/log/jupyter
▶ Profiles：依 CPU=${CPU_TOTAL} / RAM=${MEM_GIB}Gi / GPU=${GPU_COUNT} 動態生成
▶ 背景 pf 工具：sudo jhub-portforward {start|stop|status}
▶ 診斷工具：sudo jhub-diag ${JHUB_NS}
▶ Service：NodePort:${NODEPORT_FALLBACK_PORT}
${nginx_summary_line}
▶ HTML 快速入口：${JHUB_HOME}/index.html（模板來源：$(pwd)/index.html）
▶ 叢集節點：${cluster_nodes}
▶ 多節點側載：Notebook/Calico/HostPath/CoreDNS 映像已自動同步到 worker（如檔案存在）

▶ Adminuser API（免登入直連）：
    http://<node_ip>:${ADMINUSER_NODEPORT}/…   （Notebook 內請監聽 0.0.0.0:${ADMINUSER_TARGET_PORT}）
    若啟用 port-forward：${ADMINUSER_PF_BIND_ADDR}:${ADMINUSER_PF_PORT} → ${ADMINUSER_TARGET_PORT}
============================================================

【對外 API 提示】
  - 你在 Notebook 內監聽的服務（例如 8000）可由外部直接打：
      http://<node_ip>:${ADMINUSER_NODEPORT}/ping
  - 若改用 Hub 代理（需要登入 Cookie）：
      http://<node_ip>:${NODEPORT_FALLBACK_PORT}/user/<username>/proxy/${ADMINUSER_TARGET_PORT}/…

【常見故障快速檢查】
  1) DNS：若 coredns Pod 是 ImagePullBackOff，請確認已套用 ${COREDNS_IMAGE}
     - 查看：microk8s kubectl -n kube-system get deploy coredns -o yaml | grep image:
  2) Hub 狀態：sudo jhub-diag ${JHUB_NS}
  3) 18080/30080/32081 對外不通？檢查防火牆或自行開放：
     - firewalld：firewall-cmd --add-port=18080/tcp --permanent && firewall-cmd --add-port=${NODEPORT_FALLBACK_PORT}/tcp --permanent && firewall-cmd --add-port=${ADMINUSER_NODEPORT}/tcp --permanent${firewall_https_cmd} && firewall-cmd --reload
     - ufw：ufw allow 18080/tcp && ufw allow ${NODEPORT_FALLBACK_PORT}/tcp && ufw allow ${ADMINUSER_NODEPORT}/tcp${ufw_https_cmd}
EOF
}

main "$@"
