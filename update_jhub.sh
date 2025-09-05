#!/usr/bin/env bash
# update_jhub.sh — JupyterHub 安全升級 / 或僅同步 Service（MicroK8s 版）
# 特色：
#   - 不會刪除 singleuser pods（除非你加 --restart-singleuser）
#   - --svc-only：只建立/更新 adminuser 的 NodePort Service + 開防火牆，完全不動 Helm
#
# 用法：
#   sudo ./update_jhub.sh -f /root/jhub/values.yaml            # 套用 values.yaml 到現有 release
#   sudo ./update_jhub.sh --svc-only                            # 只同步 Service（零風險）
#   sudo ./update_jhub.sh --dry-run                             # 試跑，不套用
#   sudo ./update_jhub.sh -V 4.2.0                              # 指定 chart 版本
#   sudo ./update_jhub.sh --restart-singleuser                  # 升級後重啟所有 singleuser（會中斷使用者）

set -euo pipefail

###### ========= 預設參數 =========
NAMESPACE="${NAMESPACE:-jhub}"
RELEASE="${RELEASE:-jhub}"
CHART="${CHART:-jupyterhub/jupyterhub}"
VALUES="${VALUES:-/root/jhub/values.yaml}"
CHART_VERSION="${CHART_VERSION:-}"          # 例：4.2.0（空白=用 repo 預設）
TIMEOUT="${TIMEOUT:-25m0s}"
ATOMIC="${ATOMIC:-true}"
DRY_RUN="false"
RESTART_SINGLEUSER="false"
NO_DIFF="false"
SVC_ONLY="false"

# 跟你的安裝腳本對齊
MICROK8S="${MICROK8S:-/snap/bin/microk8s}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/var/snap/microk8s/current/credentials/client.config}"

# adminuser 專用 Service（保持與安裝腳本相同）
ADMIN_USER="${ADMIN_USER:-adminuser}"
ADMINUSER_TARGET_PORT="${ADMINUSER_TARGET_PORT:-8000}"
ADMINUSER_NODEPORT="${ADMINUSER_NODEPORT:-32081}"

###### ========= 共用工具 =========
log(){  echo -e "\e[1;36m$*\e[0m"; }
ok(){   echo -e "\e[1;32m$*\e[0m"; }
warn(){ echo -e "\e[1;33m$*\e[0m"; }
err(){  echo -e "\e[1;31m$*\e[0m" 1>&2; }

require_root(){ [[ $EUID -eq 0 ]] || { err "請用 sudo 執行：sudo $0"; exit 1; }; }
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
KCTL(){ "$MICROK8S" kubectl "$@"; }

usage(){
cat <<USAGE
Usage: $0 [options]
  -n, --namespace NS          (default: ${NAMESPACE})
  -r, --release   NAME        (default: ${RELEASE})
  -c, --chart     CHART       (default: ${CHART})
  -f, --values    FILE        (default: ${VALUES})
  -V, --chart-version VER     (default: repo default)
  -t, --timeout   DURATION    (default: ${TIMEOUT})
      --dry-run               Dry-run only (no changes applied)
      --restart-singleuser    Delete all singleuser pods after upgrade (disruptive)
      --no-diff               Skip helm diff
      --svc-only              Only ensure adminuser NodePort Service & firewall (no helm)
  -h, --help
Env:
  MICROK8S=${MICROK8S}  KUBECONFIG_PATH=${KUBECONFIG_PATH}  HELM_BIN=<path/to/helm>
  ADMIN_USER=${ADMIN_USER}  ADMINUSER_TARGET_PORT=${ADMINUSER_TARGET_PORT}  ADMINUSER_NODEPORT=${ADMINUSER_NODEPORT}
USAGE
}

###### ========= 參數解析 =========
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2;;
    -r|--release) RELEASE="$2"; shift 2;;
    -c|--chart) CHART="$2"; shift 2;;
    -f|--values) VALUES="$2"; shift 2;;
    -V|--chart-version) CHART_VERSION="$2"; shift 2;;
    -t|--timeout) TIMEOUT="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    --restart-singleuser) RESTART_SINGLEUSER="true"; shift;;
    --no-diff) NO_DIFF="true"; shift;;
    --svc-only) SVC_ONLY="true"; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

###### ========= 前置 =========
require_root
export PATH="/snap/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HELM_BIN="${HELM_BIN:-}"
if [[ -z "${HELM_BIN}" ]]; then
  if is_cmd helm; then
    HELM_BIN="$(command -v helm)"
  elif [[ -x /snap/bin/helm ]]; then
    HELM_BIN="/snap/bin/helm"
  elif [[ -x /usr/local/bin/helm ]]; then
    HELM_BIN="/usr/local/bin/helm"
  else
    HELM_BIN=""
  fi
fi

[[ -x "$MICROK8S" ]] || { err "找不到 microk8s：$MICROK8S"; exit 1; }
export KUBECONFIG="$KUBECONFIG_PATH"

# --- 只同步 Service 的函式（不動 Helm） ---
open_fw_port(){
  local p="$1"
  if is_cmd firewall-cmd; then
    firewall-cmd --add-port="${p}"/tcp --permanent || true
    firewall-cmd --reload || true
  fi
  if is_cmd ufw; then
    ufw allow "${p}"/tcp || true
  fi
}
ensure_adminuser_nodeport(){
  log "[svc] 建立/更新 adminuser NodePort Service → ${ADMINUSER_NODEPORT}"
  cat <<YAML | KCTL apply -f -
apiVersion: v1
kind: Service
metadata:
  name: adminuser-fastapi-np
  namespace: ${NAMESPACE}
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
  ok "[svc] 外部可用： http://$(hostname -I | awk '{print $1}'):${ADMINUSER_NODEPORT}/ping"
  KCTL -n "${NAMESPACE}" get svc adminuser-fastapi-np -o wide
  KCTL -n "${NAMESPACE}" get endpoints adminuser-fastapi-np -o wide || true
}

if [[ "$SVC_ONLY" == "true" ]]; then
  ensure_adminuser_nodeport
  ok "✅ 已同步 Service；未觸碰 Helm/HUB/Proxy/singleuser。"
  exit 0
fi

# --- 以下為 Helm 升級 ---
[[ -n "$HELM_BIN" ]] || { err "找不到 helm，請先安裝（snap install helm --classic）或設 HELM_BIN 路徑"; exit 1; }
[[ -r "$VALUES" ]] || { err "找不到 values 檔：$VALUES"; exit 1; }

log "[env] NAMESPACE=$NAMESPACE RELEASE=$RELEASE CHART=$CHART VALUES=$VALUES TIMEOUT=$TIMEOUT"
[[ -n "$CHART_VERSION" ]] && log "[env] CHART_VERSION=$CHART_VERSION"
log "[env] HELM_BIN=$HELM_BIN  MICROK8S=$MICROK8S  KUBECONFIG=$KUBECONFIG"
log "[env] PATH=$PATH"

# YAML 檢查（可選）
if is_cmd yq; then
  yq eval . "$VALUES" >/dev/null || { err "YAML 語法錯誤：$VALUES"; exit 1; }
fi

# repo
if ! "$HELM_BIN" repo list | grep -q 'jupyterhub'; then
  "$HELM_BIN" repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null || true
fi
"$HELM_BIN" repo update >/dev/null || true

# template 檢查
if [[ -n "$CHART_VERSION" ]]; then
  "$HELM_BIN" template "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" --version "$CHART_VERSION" >/dev/null
else
  "$HELM_BIN" template "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" >/dev/null
fi

# diff（若有插件）
if [[ "$NO_DIFF" != "true" ]] && "$HELM_BIN" plugin list 2>/dev/null | grep -q '^diff'; then
  if [[ -n "$CHART_VERSION" ]] ; then
    "$HELM_BIN" diff upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" --version "$CHART_VERSION" || true
  else
    "$HELM_BIN" diff upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" || true
  fi
fi

# dry-run
if [[ "$DRY_RUN" == "true" ]]; then
  if [[ -n "$CHART_VERSION" ]]; then
    "$HELM_BIN" upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" \
      --version "$CHART_VERSION" --timeout "$TIMEOUT" --dry-run --debug
  else
    "$HELM_BIN" upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" \
      --timeout "$TIMEOUT" --dry-run --debug
  fi
  ok "[done] dry-run 完成"; exit 0
fi

# 正式升級（不送出 proxy.replicaCount）
UP_ARGS=(upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$VALUES" --timeout "$TIMEOUT")
[[ -n "$CHART_VERSION" ]] && UP_ARGS+=("--version" "$CHART_VERSION")
[[ "$ATOMIC" == "true" ]] && UP_ARGS+=("--atomic") || UP_ARGS+=("--cleanup-on-fail")
"$HELM_BIN" "${UP_ARGS[@]}"

# 等候 Hub/Proxy 滾動
KCTL -n "$NAMESPACE" rollout status deploy/hub   --timeout=900s || warn "[warn] hub rollout 等候超時"
KCTL -n "$NAMESPACE" rollout status deploy/proxy --timeout=600s || warn "[warn] proxy rollout 等候超時"

# 顯示資源
KCTL -n "$NAMESPACE" get deploy,svc | sed -e '1,1s/^/[jhub] /'
KCTL -n "$NAMESPACE" get pods -o wide | sed -e '1,1s/^/[pods] /'

# 可選：重啟所有 singleuser（會中斷使用者）
if [[ "$RESTART_SINGLEUSER" == "true" ]]; then
  warn "[warn] 刪除所有 singleuser pods（使用者會被重啟）"
  KCTL -n "$NAMESPACE" delete pod -l component=singleuser-server --wait=false || true
fi

# 最後再保險同步一次 adminuser 的 NodePort（不影響 Helm）
ensure_adminuser_nodeport

ok "✅ 升級完成。singleuser pods 不會被刪；若改了 singleuser 設定，新的啟動才會套用。"
