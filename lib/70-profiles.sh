# ---------- CPU/GPU 偵測與 Profiles ----------
CPU_TOTAL=1; MEM_GIB=2; GPU_COUNT=0
_detect_resources(){
  is_cmd nproc && CPU_TOTAL=$(nproc --all 2>/dev/null || nproc || echo 1)
  [[ -r /proc/meminfo ]] && MEM_GIB=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 2)
  is_cmd nvidia-smi && GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | awk '{print $1+0}')
  log "[detect] CPU=${CPU_TOTAL} cores; MEM=${MEM_GIB}Gi; GPU=${GPU_COUNT}"
}
_render_profiles_json(){
  local cpu_base=4 mem_base=32; (( CPU_TOTAL < cpu_base )) && cpu_base=$CPU_TOTAL; (( MEM_GIB < mem_base )) && mem_base=$MEM_GIB
  (( cpu_base < 1 )) && cpu_base=1; (( mem_base < 2 )) && mem_base=2
  local ib_enabled="false" ib_resource_name ib_resource_count ib_resource_snippet=""
  if [[ "${ENABLE_IB}" == "true" ]]; then
    ib_enabled="true"
  fi
  ib_resource_name="${IB_RESOURCE_NAME:-rdma/rdma_shared_device}"
  ib_resource_count="$(_ensure_numeric_or_default "${IB_RESOURCE_COUNT:-1}" 1 "IB_RESOURCE_COUNT")"
  (( ib_resource_count<1 )) && ib_resource_count=1
  if [[ "${ib_enabled}" == "true" ]]; then
    ib_resource_snippet=$(printf ',"%s":%d' "${ib_resource_name}" "${ib_resource_count}")
  fi
  local arr; arr=$(printf '[{"display_name":"cpu-node","slug":"cpu-node","description":"0 GPU / %d cores / %dGi","kubespawner_override":{"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG","environment":{"CUDA_VISIBLE_DEVICES":"","NVIDIA_VISIBLE_DEVICES":"void","PYTORCH_ENABLE_MPS_FALLBACK":"1"}}}' "$cpu_base" "$mem_base" "$cpu_base" "$cpu_base" "$mem_base" "$mem_base")
  local targets=(1 2 4 8); local max_mem_cap=$(( MEM_GIB*80/100 )); (( max_mem_cap<4 )) && max_mem_cap=4; local reserve_cpu=1
  local cpu_cap=$(( CPU_TOTAL>reserve_cpu ? CPU_TOTAL-reserve_cpu : CPU_TOTAL )); local per_gpu_cpu=8; local per_gpu_mem=192
  for g in "${targets[@]}"; do
    (( g > GPU_COUNT )) && continue
    local want_cpu=$(( per_gpu_cpu*g )); local want_mem=$(( per_gpu_mem*g ))
    local use_cpu=$want_cpu; (( use_cpu>cpu_cap )) && use_cpu=$cpu_cap; (( use_cpu<1 )) && use_cpu=1
    local use_mem=$want_mem; (( use_mem>max_mem_cap )) && use_mem=$max_mem_cap; (( use_mem<4 )) && use_mem=4
    local resource_limits resource_guarantees
    resource_limits=$(printf '"nvidia.com/gpu":%d%s' "$g" "${ib_resource_snippet}")
    resource_guarantees=$(printf '"nvidia.com/gpu":%d%s' "$g" "${ib_resource_snippet}")
    arr+=$(printf ',{"display_name":"h100-%dv","description":"%d×GPU / %d cores / %dGi","kubespawner_override":{"extra_pod_config":{"runtimeClassName":"nvidia"},"extra_resource_limits":{%s},"extra_resource_guarantees":{%s},"environment":{"PYTORCH_CUDA_ALLOC_CONF":"expandable_segments:True"},"cpu_guarantee":%d,"cpu_limit":%d,"mem_guarantee":"%dG","mem_limit":"%dG"}}' "$g" "$g" "$use_cpu" "$use_mem" "${resource_limits}" "${resource_guarantees}" "$use_cpu" "$use_cpu" "$use_mem" "$use_mem")
  done; arr+=']'
  local json="$arr"
  if [[ "${ENABLE_MIG}" == "true" ]]; then
    local mig_cpu=${MIG_CPU_CORES:-8}; (( mig_cpu<1 )) && mig_cpu=1
    local mig_mem=${MIG_MEM_GIB:-64}; (( mig_mem<4 )) && mig_mem=4
    local mig_profile="${MIG_PROFILE_NAME:-MIG}"
    local mig_resource="${MIG_RESOURCE_NAME:-nvidia.com/mig-1g.10gb}"
    json=$(echo "$json" | jq -c --arg name "${mig_profile}" --arg res "${mig_resource}" --argjson cpu "$mig_cpu" --argjson mem "$mig_mem" '
      . + [{
        display_name: $name,
        slug: $name,
        description: ("MIG 1 slice / " + ($cpu|tostring) + " cores / " + ($mem|tostring) + "Gi"),
        kubespawner_override: {
          extra_pod_config: { runtimeClassName: "nvidia" },
          environment: {
            "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True"
          },
          extra_resource_limits: {($res):1},
          extra_resource_guarantees: {($res):1},
          cpu_guarantee: $cpu,
          cpu_limit: $cpu,
          mem_guarantee: ($mem|tostring + "G"),
          mem_limit: ($mem|tostring + "G")
        }
      }]
    ')
  fi
  if [[ "${ib_enabled}" == "true" ]]; then
    json=$(echo "$json" | jq -c --arg rn "${ib_resource_name}" --argjson rc "${ib_resource_count}" '
      map(
        if ((.kubespawner_override.extra_resource_limits // {}) | keys | any(. == "nvidia.com/gpu" or startswith("nvidia.com/mig"))) then
          .kubespawner_override.extra_resource_limits |= ((.//{}) + {($rn):$rc})
          | .kubespawner_override.extra_resource_guarantees |= ((.//{}) + {($rn):$rc})
        else . end
      )
    ')
  fi
  echo "$json"
}

_render_mig_manager_config(){
  local config_key="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
  local ids_raw="${MIG_TARGET_GPU_IDS:-0}"
  local profile="${MIG_TARGET_PROFILE:-1g.10gb}"
  local count
  count="$(_ensure_numeric_or_default "${MIG_TARGET_PROFILE_COUNT:-1}" 1 "MIG_TARGET_PROFILE_COUNT")"
  (( count < 1 )) && count=1
  # Normalize GPU ID list
  local -a ids=()
  IFS=',' read -ra ids <<< "${ids_raw}"
  local cleaned_ids=()
  for id in "${ids[@]}"; do
    local trimmed="${id// /}"
    [[ -z "${trimmed}" ]] && continue
    if [[ ! "${trimmed}" =~ ^[0-9]+$ ]]; then
      warn "[MIG] GPU ID '${trimmed}' 非整數，略過"
      continue
    fi
    cleaned_ids+=("${trimmed}")
  done
  if (( ${#cleaned_ids[@]} == 0 )); then
    warn "[MIG] 未提供有效的 MIG GPU ID，預設使用 GPU 0"
    cleaned_ids=(0)
  fi
  local yaml
  yaml="version: v1
mig-configs:
  all-disabled:
    - devices: all
      mig-enabled: false
  ${config_key}:
    - devices: all
      mig-enabled: false"
  local id
  for id in "${cleaned_ids[@]}"; do
    yaml+="
    - devices: [${id}]
      mig-enabled: true
      mig-devices:
        \"${profile}\": ${count}"
  done
  printf '%s\n' "${yaml}"
}

_label_mig_nodes(){
  local profile="${MIG_CONFIG_PROFILE:-jhub-single-mig}"
  local raw="${MIG_TARGET_NODES:-*}"
  local nodes=()
  if [[ "${raw}" == "*" || "${raw,,}" == "all" ]]; then
    mapfile -t nodes < <(KCTL get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  else
    IFS=',' read -ra nodes <<< "${raw}"
  fi
  if (( ${#nodes[@]} == 0 )); then
    warn "[MIG] 找不到可標記的節點，略過 nvidia.com/mig.config 標籤"
    return 0
  fi
  for node in "${nodes[@]}"; do
    local trimmed="${node// /}"
    [[ -z "${trimmed}" ]] && continue
    log "[GPU][MIG] Label 節點 ${trimmed} -> nvidia.com/mig.config=${profile}"
    if ! KCTL label node "${trimmed}" "nvidia.com/mig.config=${profile}" --overwrite; then
      warn "[MIG] 標記節點 ${trimmed} 失敗"
    fi
  done
}
