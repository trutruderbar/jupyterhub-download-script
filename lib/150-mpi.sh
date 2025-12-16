# ---------- MPI Operator 與每用戶隔離命名空間/RBAC ----------

_mpi_sanitize_name(){
  local raw="${1,,}"
  raw="${raw//[^a-z0-9-]/-}"
  # 壓縮連續連字號並移除開頭/結尾的 -
  while [[ "${raw}" == *--* ]]; do raw="${raw//--/-}"; done
  raw="${raw##-}"
  raw="${raw%%-}"
  [[ -z "${raw}" ]] && raw="user"
  printf '%s' "${raw}"
}

_mpi_user_list(){
  local raw="${MPI_USERS_CSV:-}"
  if [[ -z "${raw}" ]]; then
    raw="${ADMIN_USERS_CSV:-${ADMIN_USER:-}}"
  fi
  raw="${raw//,/ }"
  local -a uniq=()
  local token seen
  for token in ${raw}; do
    token="${token//[[:space:]]/}"
    [[ -z "${token}" ]] && continue
    if [[ -z "${seen}" || ! "${seen}" =~ (^|,)"${token}"(,|$) ]]; then
      uniq+=("${token}")
      seen="${seen},${token}"
    fi
  done
  printf '%s\n' "${uniq[@]}"
}

install_mpi_operator(){
  [[ "${ENABLE_MPI_OPERATOR}" != "true" ]] && return 0
  local ns="${MPI_OPERATOR_NAMESPACE:-mpi-operator}"
  local manifest="${MPI_OPERATOR_MANIFEST_URL:-}"
  if [[ -z "${manifest}" ]]; then
    warn "[MPI] 未提供 MPI_OPERATOR_MANIFEST_URL，略過安裝"
    return 0
  fi
  if KCTL -n "${ns}" get deploy mpi-operator >/dev/null 2>&1; then
    log "[MPI] mpi-operator 已存在於 ${ns}，略過重新安裝"
    return 0
  fi
  log "[MPI] 套用 MPI Operator manifest (${manifest}) → namespace ${ns}"
  if ! KCTL apply -f "${manifest}"; then
    warn "[MPI] 套用 MPI Operator manifest 失敗，請檢查 URL 或網路：${manifest}"
    return 0
  fi
  # 等 deployment ready
  KCTL -n "${ns}" rollout status deploy/mpi-operator --timeout=300s >/dev/null 2>&1 || warn "[MPI] mpi-operator rollout 可能未完成，請手動確認"
}

ensure_mpi_user_rbac(){
  [[ "${ENABLE_MPI_OPERATOR}" != "true" ]] && return 0
  [[ "${ENABLE_MPI_USER_NS}" != "true" ]] && return 0
  local sa_prefix="${MPI_USER_SERVICE_ACCOUNT_PREFIX:-jhub-mpi-sa}"
  local ns_prefix="${MPI_USER_NAMESPACE_PREFIX:-mpi}"
  local rq_cpu="${MPI_NS_REQUESTS_CPU:-64}"
  local rq_mem="${MPI_NS_REQUESTS_MEMORY:-256Gi}"
  local rq_gpu="${MPI_NS_GPUS:-8}"
  local rq_pods="${MPI_NS_PODS:-32}"
  local lr_cpu="${MPI_NS_LIMITS_CPU:-64}"
  local lr_mem="${MPI_NS_LIMITS_MEMORY:-256Gi}"
  local user
  local any_user=0
  while IFS= read -r user; do
    [[ -z "${user}" ]] && continue
    any_user=1
    local safe_user ns sa_name
    safe_user="$(_mpi_sanitize_name "${user}")"
    ns="${ns_prefix}-${safe_user}"
    sa_name="${sa_prefix}-${safe_user}"
    log "[MPI] 建立使用者隔離資源 user=${user} ns=${ns} sa=${sa_name}"
    cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    mpi.owner: "${safe_user}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa_name}
  namespace: ${JHUB_NS}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mpi-quota
  namespace: ${ns}
spec:
  hard:
    requests.cpu: "${rq_cpu}"
    requests.memory: "${rq_mem}"
    limits.cpu: "${lr_cpu}"
    limits.memory: "${lr_mem}"
    nvidia.com/gpu: "${rq_gpu}"
    pods: "${rq_pods}"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: mpi-defaults
  namespace: ${ns}
spec:
  limits:
  - type: Container
    default:
      cpu: "${lr_cpu}"
      memory: "${lr_mem}"
    defaultRequest:
      cpu: "${rq_cpu}"
      memory: "${rq_mem}"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mpi-owner
  namespace: ${ns}
rules:
- apiGroups: ["kubeflow.org"]
  resources: ["mpijobs"]
  verbs: ["create","get","list","watch","delete","patch","update"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["create","get","list","watch","delete","patch","update"]
- apiGroups: [""]
  resources: ["pods","pods/log","pods/exec","services","configmaps","secrets","events"]
  verbs: ["create","get","list","watch","delete","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mpi-owner-${safe_user}
  namespace: ${ns}
subjects:
- kind: ServiceAccount
  name: ${sa_name}
  namespace: ${JHUB_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: mpi-owner
YAML
  done < <(_mpi_user_list)
  if (( any_user == 0 )); then
    warn "[MPI] MPI_USERS_CSV / ADMIN_USERS_CSV 未設定；未建立任何 MPI 命名空間與 RBAC"
  fi
}
