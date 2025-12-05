# ---------- 對外 NodePort（adminuser 專用）與防火牆 ----------
open_fw_port(){
  local p="$1"
  if is_rhel && is_cmd firewall-cmd; then
    firewall-cmd --add-port="${p}"/tcp --permanent || true
    firewall-cmd --reload || true
  elif is_cmd ufw; then
    ufw allow "${p}"/tcp || true
  elif is_cmd nft; then
    nft list tables | grep -q '^table inet filter$' || nft add table inet filter || true
    if ! nft list chain inet filter input >/dev/null 2>&1; then
      nft add chain inet filter input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
    fi
    if ! nft list ruleset | grep -q "tcp dport ${p}.*accept"; then
      nft add rule inet filter input tcp dport ${p} counter accept 2>/dev/null || true
    fi
  elif is_cmd iptables; then
    if ! iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT || true
    fi
    if is_cmd ip6tables && ! ip6tables -C INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null; then
      ip6tables -I INPUT -p tcp --dport "${p}" -j ACCEPT || true
    fi
  fi
}
ensure_adminuser_nodeport(){
  [[ "${EXPOSE_ADMINUSER_NODEPORT}" != "true" ]] && return 0
  log "[api] 建立 adminuser 的 NodePort 對外服務（免登入） → ${ADMINUSER_NODEPORT}"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: Service
metadata:
  name: adminuser-fastapi-np
  namespace: ${JHUB_NS}
  labels: { app: adminuser-fastapi-np }
spec:
  type: NodePort
  selector:
    hub.jupyter.org/username: ${ADMIN_USER}
    component: singleuser-server
  ports:
    - name: http
      port: ${ADMINUSER_TARGET_PORT}
      targetPort: ${ADMINUSER_TARGET_PORT}
      nodePort: ${ADMINUSER_NODEPORT}
YAML
  open_fw_port "${ADMINUSER_NODEPORT}"
  ok "[api] 外部可用： http://$(hostname -I | awk '{print $1}'):${ADMINUSER_NODEPORT}/ping"
  ok "     （Notebook 內程式需監聽 0.0.0.0:${ADMINUSER_TARGET_PORT}；Pod 重建時 Service 會自動跟上）"
  if [[ "${ADMINUSER_PORTFORWARD}" == "true" ]]; then
    adminuser_pf_stop || true
    adminuser_pf_start || warn "[api] adminuser port-forward 可能未成功，請檢查 ${ADMINUSER_PF_LOG}"
  fi
}

