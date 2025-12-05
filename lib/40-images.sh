# ---------- 離線鏡像側載 ----------
images_import(){
  if [[ -f "${CALICO_BUNDLE}" ]]; then log "[images] 匯入 Calico bundle：${CALICO_BUNDLE}"; "$MICROK8S" images import "${CALICO_BUNDLE}"; else warn "[images] 找不到 ${CALICO_BUNDLE}，Calico 可能線上拉取"; fi
  if [[ -f "${NOTEBOOK_TAR}" ]]; then
    local tar_repo=""
    if is_cmd jq && tar -tf "${NOTEBOOK_TAR}" manifest.json >/dev/null 2>&1; then
      tar_repo=$(tar -xf "${NOTEBOOK_TAR}" manifest.json -O | jq -r '.[0].RepoTags[0]' 2>/dev/null || true)
    fi
   log "[images] 匯入 Notebook 映像：${NOTEBOOK_TAR}"
   if "$MICROK8S" images import "${NOTEBOOK_TAR}"; then
     ok "[images] Notebook 映像匯入成功（microk8s images import）"
   else
     warn "[images] microk8s images import 失敗，改用 ctr fallback"
      if CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${NOTEBOOK_TAR}" >/dev/null 2>&1; then
        ok "[images] Notebook 映像匯入成功（ctr fallback）"
      else
        err "[images] Notebook tar 匯入失敗，無法匯入 ${NOTEBOOK_TAR}"
        return 1
      fi
    fi
    # 等待影像在 containerd 中可用
    sleep 10
    if ! _image_exists_locally "${SINGLEUSER_IMAGE}"; then
      log "[debug] ${SINGLEUSER_IMAGE} 尚未存在，嘗試從 docker.io 來源同步"
      local docker_prefix_ref="docker.io/${SINGLEUSER_IMAGE}"
      if _image_exists_locally "${docker_prefix_ref}"; then
        warn "[images] 找到 ${docker_prefix_ref}，同步標記為 ${SINGLEUSER_IMAGE}"
        CTR images tag "${docker_prefix_ref}" "${SINGLEUSER_IMAGE}" || true
      else
        warn "[images] 尚未找到 ${docker_prefix_ref}"
      fi
    fi
    if ! _image_exists_locally "${SINGLEUSER_IMAGE}"; then
      warn "[images] 匯入後仍找不到 ${SINGLEUSER_IMAGE}，將改以 docker.io 別名繼續"
      SINGLEUSER_IMAGE="docker.io/${SINGLEUSER_IMAGE}"
    fi
    local -a sync_targets=()
    if [[ -n "${tar_repo}" && "${tar_repo}" != "${SINGLEUSER_IMAGE}" ]]; then
      sync_targets+=("${tar_repo}")
    fi
    local docker_prefixed_image=""
    local image_components image_registry image_repo image_tag image_digest
    image_components="$(_split_image_components "${SINGLEUSER_IMAGE}")"
    local old_ifs="$IFS"
    IFS='|' read -r image_registry image_repo image_tag image_digest <<< "${image_components}"
    IFS="${old_ifs}"
    if [[ -z "${image_registry}" ]]; then
      docker_prefixed_image="docker.io/${image_repo}"
      if [[ -n "${image_tag}" ]]; then
        docker_prefixed_image+=":${image_tag}"
      fi
    fi
    if [[ -n "${docker_prefixed_image}" && "${docker_prefixed_image}" != "${SINGLEUSER_IMAGE}" ]]; then
      sync_targets+=("${docker_prefixed_image}")
    fi
    if ((${#sync_targets[@]})); then
      _sync_image_tags "${SINGLEUSER_IMAGE}" "${sync_targets[@]}"
    fi
    ok "[images] 成功驗證 Notebook 映像存在"
  else
    warn "[images] 找不到 ${NOTEBOOK_TAR}（不影響 Hub 部署，可之後再匯入）"
  fi
  if [[ -n "${HOSTPATH_PROVISIONER_TAR}" ]]; then
    if [[ -f "${HOSTPATH_PROVISIONER_TAR}" ]]; then
      log "[images] 匯入 HostPath Provisioner 映像：${HOSTPATH_PROVISIONER_TAR}"
      if "$MICROK8S" images import "${HOSTPATH_PROVISIONER_TAR}"; then
        ok "[images] HostPath 映像匯入成功（microk8s images import）"
      else
        warn "[images] microk8s images import 失敗，改用 ctr 匯入 HostPath 映像"
        if CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${HOSTPATH_PROVISIONER_TAR}" >/dev/null 2>&1; then
          ok "[images] HostPath 映像匯入成功（ctr fallback）"
        else
          warn "[images] HostPath tar 匯入失敗，請手動確認"
        fi
      fi
      if [[ -n "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
        local hostpath_repo=""
        if is_cmd jq && tar -tf "${HOSTPATH_PROVISIONER_TAR}" manifest.json >/dev/null 2>&1; then
          hostpath_repo=$(tar -xf "${HOSTPATH_PROVISIONER_TAR}" manifest.json -O | jq -r '.[0].RepoTags[0]' 2>/dev/null || true)
        fi
        if [[ -n "${hostpath_repo}" && "${hostpath_repo}" != "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
          local hostpath_source="${hostpath_repo}"
          if ! _image_exists_locally "${hostpath_source}" && [[ "${hostpath_repo}" != docker.io/* ]]; then
            local docker_pref="docker.io/${hostpath_repo}"
            if _image_exists_locally "${docker_pref}"; then
              hostpath_source="${docker_pref}"
            fi
          fi
          if _image_exists_locally "${hostpath_source}"; then
            warn "[images] HostPath tar repo (${hostpath_repo}) 與設定 ${HOSTPATH_PROVISIONER_IMAGE} 不同，嘗試重新 tag"
            CTR images tag "${hostpath_source}" "${HOSTPATH_PROVISIONER_IMAGE}" || true
          else
            warn "[images] 找不到 HostPath tar repo ${hostpath_repo} 對應映像，無法重新 tag"
          fi
        fi
      fi
    else
      warn "[images] 找不到 ${HOSTPATH_PROVISIONER_TAR}，HostPath Provisioner 可能需要線上拉取"
    fi
  elif [[ -n "${HOSTPATH_PROVISIONER_IMAGE}" ]]; then
    warn "[images] 未提供 ${HOSTPATH_PROVISIONER_TAR}，將直接使用 ${HOSTPATH_PROVISIONER_IMAGE} 線上拉取"
  fi
  if [[ -n "${COREDNS_TAR}" && -f "${COREDNS_TAR}" ]]; then log "[images] 匯入 CoreDNS 映像：${COREDNS_TAR}" || true; "$MICROK8S" images import "${COREDNS_TAR}" || warn "[images] CoreDNS tar 匯入失敗（略過）"; fi

  local -a extra_offline_tars=(
    "${GPU_OPERATOR_BUNDLE_TAR}"
    "${GPU_OPERATOR_CORE_TAR}"
    "${KUBE_SCHEDULER_TAR}"
    "${NFD_TAR}"
    "${NVIDIA_K8S_DEVICE_PLUGIN_TAR}"
    "${NVIDIA_CONTAINER_TOOLKIT_TAR}"
    "${NVIDIA_DCGM_EXPORTER_TAR}"
    "${PAUSE_IMAGE_TAR}"
    "${BUSYBOX_IMAGE_TAR}"
  )
  local extra_tar
  for extra_tar in "${extra_offline_tars[@]}"; do
    [[ -n "${extra_tar}" && -f "${extra_tar}" ]] || continue
    log "[images] 匯入離線映像：${extra_tar}"
    if "$MICROK8S" images import "${extra_tar}"; then
      ok "[images] 匯入成功：${extra_tar}"
      continue
    fi
    warn "[images] microk8s images import 失敗，改用 ctr 匯入 ${extra_tar}"
    if ! CONTAINERD_NAMESPACE=k8s.io "$MICROK8S" ctr images import "${extra_tar}" >/dev/null 2>&1; then
      warn "[images] 匯入 ${extra_tar} 失敗，請手動確認"
    fi
  done

  _ensure_image_local "${HUB_IMAGE}" "Hub" "${HUB_IMAGE_TAR}" || true
  _ensure_image_local "${PROXY_IMAGE}" "Proxy (CHP)" "${PROXY_IMAGE_TAR}" || true
}
