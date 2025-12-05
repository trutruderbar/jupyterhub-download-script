# ---------- PV/PVC：Storage & Logs ----------
ensure_local_pv(){
  local storage_dir="${SHARED_STORAGE_PATH:-./Storage}"
  [[ "${storage_dir}" != /* ]] && storage_dir="$(pwd)/${storage_dir#./}"
  KCTL get ns "${JHUB_NS}" >/dev/null 2>&1 || KCTL create ns "${JHUB_NS}"
  mkdir -p "${storage_dir}" /var/log/jupyterhub
  chown -R 1000:100 "${storage_dir}" || true
  chmod 0777 "${storage_dir}" || true
  if [[ "${SHARED_STORAGE_ENABLED}" == "true" ]]; then
    cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: { name: storage-local-pv }
spec:
  capacity: { storage: ${SHARED_STORAGE_SIZE} }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: "${storage_dir}" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: storage-local-pvc, namespace: ${JHUB_NS} }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: ${SHARED_STORAGE_SIZE} } }
  volumeName: storage-local-pv
  storageClassName: ""
---
YAML
  else
    warn "[storage] SHARED_STORAGE_ENABLED=false，略過共享 Storage PV/PVC 建立"
  fi
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: { name: jhub-logs-pv }
spec:
  capacity: { storage: 50Gi }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: "/var/log/jupyterhub" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: jhub-logs-pvc, namespace: ${JHUB_NS} }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: 50Gi } }
  volumeName: jhub-logs-pv
  storageClassName: ""
YAML
}

ensure_resource_quota(){
  [[ "${ENABLE_RESOURCE_QUOTA}" != "true" ]] && return 0
  log "[quota] 套用 ResourceQuota / LimitRange"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: jhub-quota
  namespace: ${JHUB_NS}
spec:
  hard:
    requests.cpu: "${RQ_REQUESTS_CPU}"
    requests.memory: "${RQ_REQUESTS_MEMORY}"
    limits.cpu: "${RQ_LIMITS_CPU}"
    limits.memory: "${RQ_LIMITS_MEMORY}"
    pods: "${RQ_PODS}"
    nvidia.com/gpu: "${RQ_GPUS}"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: jhub-defaults
  namespace: ${JHUB_NS}
spec:
  limits:
  - type: Container
    default:
      cpu: "${LIMITRANGE_DEFAULT_CPU}"
      memory: "${LIMITRANGE_DEFAULT_MEMORY}"
    defaultRequest:
      cpu: "${LIMITRANGE_DEFAULT_CPU}"
      memory: "${LIMITRANGE_DEFAULT_MEMORY}"
    max:
      cpu: "${LIMITRANGE_MAX_CPU}"
      memory: "${LIMITRANGE_MAX_MEMORY}"
YAML
}

ensure_tls_secret(){
  [[ "${ENABLE_INGRESS}" != "true" ]] && return 0
  if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" && -f "${TLS_CERT_FILE}" && -f "${TLS_KEY_FILE}" ]]; then
    log "[tls] 建立/更新 TLS Secret ${INGRESS_TLS_SECRET}"
    kapply_from_dryrun "${JHUB_NS}" secret tls "${INGRESS_TLS_SECRET}" \
      --cert="${TLS_CERT_FILE}" --key="${TLS_KEY_FILE}"
  else
    warn "[tls] 未提供 TLS_CERT_FILE/TLS_KEY_FILE 或檔案不存在，請確認 secret/${INGRESS_TLS_SECRET} 已建立"
  fi
}

ensure_network_policy(){
  [[ "${ENABLE_NETWORK_POLICY}" != "true" ]] && return 0
  log "[netpol] 建立預設 NetworkPolicy"
  cat <<YAML | KCTL apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hub-internal-access
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/component: hub
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${JHUB_NS}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: singleuser-default
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      component: singleuser-server
  policyTypes: ["Ingress","Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          hub.jupyter.org/component: proxy
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${JHUB_NS}
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
  - {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-proxy
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/component: proxy
  policyTypes: ["Ingress","Egress"]
  ingress:
  - {}
  egress:
  - {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-adminuser
  namespace: ${JHUB_NS}
spec:
  podSelector:
    matchLabels:
      hub.jupyter.org/username: ${ADMIN_USER}
      component: singleuser-server
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: ${ADMINUSER_TARGET_PORT}
YAML
}

ensure_nginx_proxy(){
  [[ "${ENABLE_NGINX_PROXY}" != "true" ]] && return 0
  log "[nginx] 設定 Nginx 反向代理 (${NGINX_PROXY_HTTPS_PORT} → ${NGINX_PROXY_UPSTREAM_PORT})"
  if ! need_pkg nginx; then
    warn "[nginx] 安裝 nginx 失敗，略過反向代理部署"
    return 0
  fi
  local default_conf="" default_conf_candidates=(
    "/etc/nginx/conf.d/default.conf"
    "/etc/nginx/conf.d/default.conf.rpmsave"
    "/etc/nginx/conf.d/welcome.conf"
    "/etc/nginx/sites-enabled/default"
  )
  for candidate in "${default_conf_candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      default_conf="${candidate}"
      break
    fi
  done
  if [[ -n "${default_conf}" ]]; then
    local backup="${default_conf}.bak"
    if [[ ! -f "${backup}" ]]; then
      mv "${default_conf}" "${backup}" 2>/dev/null || cp "${default_conf}" "${backup}" 2>/dev/null || true
    fi
    rm -f "${default_conf}" 2>/dev/null || true
    log "[nginx] 已停用預設站台 ${default_conf}（備份至 ${backup}），避免 default_server 衝突"
  fi
  local server_name="${NGINX_PROXY_SERVER_NAME:-${DEFAULT_HOST_IP}}"
  local existing_default=""
  existing_default="$(grep -R --no-messages 'default_server' /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf 2>/dev/null | grep -v 'jhub.conf' || true)"
  local http_listen="${NGINX_PROXY_HTTP_PORT}"
  local https_listen="${NGINX_PROXY_HTTPS_PORT} ssl http2"
  if [[ -z "${existing_default// }" ]]; then
    http_listen+=" default_server"
    https_listen+=" default_server"
  else
    log "[nginx] 偵測到既有 default_server，jhub.conf 將不再指定 default_server（請確保 Host 指向 ${server_name}）"
  fi
  local conf="/etc/nginx/conf.d/jhub.conf"
  local ssl_dir="/etc/nginx/jhub"
  local cert_src="${NGINX_PROXY_CERT_FILE}"
  local key_src="${NGINX_PROXY_KEY_FILE}"
  local cert="${cert_src}"
  local key="${key_src}"
  install -d -m 0755 "${ssl_dir}"
  if [[ -n "${cert}" && -n "${key}" && -f "${cert}" && -f "${key}" ]]; then
    :
  else
    if [[ -n "${cert_src}" || -n "${key_src}" ]]; then
      warn "[nginx] 指定的 NGINX_PROXY_CERT_FILE/NGINX_PROXY_KEY_FILE 找不到，改用自簽名憑證"
    fi
    cert="${ssl_dir}/jhub-selfsigned.crt"
    key="${ssl_dir}/jhub-selfsigned.key"
    if [[ ! -f "${cert}" || ! -f "${key}" ]]; then
      log "[nginx] 未提供 TLS 憑證，生成自簽名憑證 ${cert}"
      if ! need_pkg openssl; then
        warn "[nginx] openssl 缺失且安裝失敗，無法生成自簽名憑證，略過反向代理"
        return 0
      fi
      openssl req -x509 -nodes -newkey rsa:4096 -days 730 \
        -keyout "${key}" -out "${cert}" \
        -subj "/CN=${server_name}" >/dev/null 2>&1
    fi
  fi
  install -m 0644 "${cert}" "${ssl_dir}/cert.pem" 2>/dev/null || cp "${cert}" "${ssl_dir}/cert.pem"
  install -m 0600 "${key}" "${ssl_dir}/key.pem" 2>/dev/null || cp "${key}" "${ssl_dir}/key.pem"
  cert="${ssl_dir}/cert.pem"
  key="${ssl_dir}/key.pem"
  {
    if [[ "${NGINX_PROXY_HTTP_MODE}" == "redirect" ]]; then
      cat <<HTTP
server {
  listen ${http_listen};
  server_name ${server_name};
  return 301 https://\$host\$request_uri;
}
HTTP
    else
      cat <<HTTP
server {
  listen ${http_listen};
  server_name ${server_name};
  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port ${NGINX_PROXY_HTTPS_PORT};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_buffering off;
    proxy_read_timeout 300s;
    proxy_pass http://${NGINX_PROXY_UPSTREAM_HOST}:${NGINX_PROXY_UPSTREAM_PORT};
  }
}
HTTP
    fi
    cat <<HTTPS
server {
  listen ${https_listen};
  server_name ${server_name};
  ssl_certificate ${cert};
  ssl_certificate_key ${key};
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 4h;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;
  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port ${NGINX_PROXY_HTTPS_PORT};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_buffering off;
    proxy_read_timeout 300s;
    proxy_pass http://${NGINX_PROXY_UPSTREAM_HOST}:${NGINX_PROXY_UPSTREAM_PORT};
  }
}
HTTPS
  } > "${conf}"
  nginx -t >/dev/null
  local started=false
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl enable nginx >/dev/null 2>&1; then
      log "[nginx] 已設定 systemd 開機自啟"
    else
      warn "[nginx] systemctl enable 失敗（可能缺少 [Install] 區段），略過自動啟動"
    fi
    if systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1; then
      started=true
    fi
  fi
  if [[ "${started}" != true && -n "$(command -v service 2>/dev/null)" ]]; then
    if service nginx restart >/dev/null 2>&1 || service nginx start >/dev/null 2>&1; then
      started=true
    fi
  fi
  if [[ "${started}" != true ]]; then
    if nginx >/dev/null 2>&1; then
      started=true
    else
      warn "[nginx] 無法啟動 nginx，請手動執行 systemctl start nginx 或檢查 /var/log/nginx/error.log"
    fi
  fi
  open_fw_port "${NGINX_PROXY_HTTP_PORT}"
  open_fw_port "${NGINX_PROXY_HTTPS_PORT}"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    ok "[ok] Nginx 反向代理已啟用"
  elif pgrep -x nginx >/dev/null 2>&1; then
    ok "[ok] Nginx 程序已啟動"
  else
    warn "[nginx] 尚未偵測到 nginx 執行中，請手動檢查服務狀態"
  fi
  if [[ "${NGINX_PROXY_HTTPS_PORT}" == "443" ]]; then
    NGINX_PROXY_URL="https://${server_name}"
  else
    NGINX_PROXY_URL="https://${server_name}:${NGINX_PROXY_HTTPS_PORT}"
  fi
}

