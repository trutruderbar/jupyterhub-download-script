# ---------- Port-forward 工具 ----------
pf_stop(){ [[ -f "${PF_PROXY_PID}" ]] && kill "$(cat "${PF_PROXY_PID}")" 2>/dev/null || true; rm -f "${PF_PROXY_PID}" 2>/dev/null || true; }
pf_start(){
  mkdir -p "$(dirname "${PF_PROXY_LOG}")"
  : > "${PF_PROXY_LOG}"
  local check_host="${PF_BIND_ADDR}"; [[ "${PF_BIND_ADDR}" == "0.0.0.0" ]] && check_host="127.0.0.1"
  local endpoints_ready=false
  for _ in {1..60}; do
    if "$MICROK8S" kubectl -n "${JHUB_NS}" get endpoints proxy-public -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -q '.'; then
      endpoints_ready=true
      break
    fi
    sleep 2
  done
  [[ "${endpoints_ready}" != "true" ]] && warn "[pf] proxy-public 未曝光 endpoints，仍嘗試 port-forward"
  local max_attempts=5 attempt=1
  while (( attempt <= max_attempts )); do
    nohup "$MICROK8S" kubectl -n "${JHUB_NS}" port-forward svc/proxy-public --address "${PF_BIND_ADDR}" "${PF_LOCAL_PORT}:80" >"${PF_PROXY_LOG}" 2>&1 &
    echo $! > "${PF_PROXY_PID}"
    local pid
    pid="$(cat "${PF_PROXY_PID}")"
    local port_ready=false
    for _ in {1..30}; do
      if (exec 3<>/dev/tcp/${check_host}/${PF_LOCAL_PORT}) >/dev/null 2>&1; then
        ok "[pf] ${check_host}:${PF_LOCAL_PORT} 已連通（pid ${pid}）"
        return 0
      fi
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    [[ -f "${PF_PROXY_PID}" ]] && kill "${pid}" >/dev/null 2>&1 || true
    rm -f "${PF_PROXY_PID}" >/dev/null 2>&1 || true
    if (( attempt < max_attempts )); then
      warn "[pf] 第 ${attempt} 次 port-forward 失敗，5 秒後重試..."
      sleep 5
      : > "${PF_PROXY_LOG}"
      ((attempt++))
      continue
    fi
    break
  done
  warn "[pf] 啟動疑似失敗，最近 log："; tail -n 50 "${PF_PROXY_LOG}" || true; return 1
}
adminuser_pf_stop(){ [[ -f "${ADMINUSER_PF_PID}" ]] && kill "$(cat "${ADMINUSER_PF_PID}")" 2>/dev/null || true; rm -f "${ADMINUSER_PF_PID}" 2>/dev/null || true; }
adminuser_pf_start(){
  local addr="${ADMINUSER_PF_BIND_ADDR}"
  [[ -z "${addr}" ]] && addr="127.0.0.1"
  mkdir -p "$(dirname "${ADMINUSER_PF_LOG}")"
  : > "${ADMINUSER_PF_LOG}"
  nohup bash -s -- "${JHUB_NS}" "$addr" "${ADMINUSER_PF_PORT}" "${ADMINUSER_TARGET_PORT}" "${ADMINUSER_PF_LOG}" "$MICROK8S" >"${ADMINUSER_PF_LOG}" 2>&1 <<'EOS' &
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
NS="$1"
ADDR="$2"
HOST_PORT="$3"
TARGET_PORT="$4"
LOG_FILE="$5"
MICROK8S_BIN="$6"
echo "[pf] waiting for endpoints..." >>"$LOG_FILE"
while true; do
  if "$MICROK8S_BIN" kubectl -n "$NS" get endpoints adminuser-fastapi-np -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -q '.'; then
    echo "[pf] endpoint ready, starting port-forward" >>"$LOG_FILE"
    break
  fi
  sleep 5
done
exec "$MICROK8S_BIN" kubectl -n "$NS" port-forward svc/adminuser-fastapi-np --address "$ADDR" "$HOST_PORT:$TARGET_PORT"
EOS
  echo $! > "${ADMINUSER_PF_PID}"
  for _ in {1..60}; do
    if (exec 3<>/dev/tcp/${addr}/${ADMINUSER_PF_PORT}) >/dev/null 2>&1; then
      ok "[api] adminuser port-forward ${addr}:${ADMINUSER_PF_PORT}→${ADMINUSER_TARGET_PORT} 已啟動（pid $(cat ${ADMINUSER_PF_PID})）"
      return 0
    fi
    sleep 2
  done
  warn "[api] adminuser port-forward 尚未建立（可能等待 singleuser pod 啟動），背景工作會持續重試"
  return 1
}
install_portforward_tool(){
  cat >/usr/local/bin/jhub-portforward <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
: "${JHUB_HOME:=${HOME}/jhub}"
NS="__JHUB_NS__"; BIND_ADDR="__PF_BIND_ADDR__"; LOCAL_PORT="__PF_LOCAL_PORT__"
PID="__PF_PROXY_PID__"; LOG="__PF_PROXY_LOG__"; M="/snap/bin/microk8s"
start(){
  [[ -f "$PID" ]] && kill "$(cat "$PID")" 2>/dev/null || true
  rm -f "$PID"
  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"
  local view_host="$BIND_ADDR"
  [[ "$BIND_ADDR" = "0.0.0.0" ]] && view_host="127.0.0.1"
  local endpoints_ready=false
  for _ in {1..60}; do
    if "$M" kubectl -n "$NS" get endpoints proxy-public -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -q '.'; then
      endpoints_ready=true
      break
    fi
    sleep 2
  done
  [[ "$endpoints_ready" != "true" ]] && echo "[pf] proxy-public endpoint 尚未準備好，仍嘗試啟動 port-forward..." >&2
  local max_attempts=5 attempt=1
  while (( attempt <= max_attempts )); do
    nohup "$M" kubectl -n "$NS" port-forward svc/proxy-public --address "$BIND_ADDR" "$LOCAL_PORT:80" >"$LOG" 2>&1 &
    echo $! > "$PID"
    local pid
    pid="$(cat "$PID")"
    local success=false
    for _ in {1..30}; do
      if (exec 3<>/dev/tcp/${view_host}/${LOCAL_PORT}) >/dev/null 2>&1; then
        success=true
        break
      fi
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if [[ "$success" == "true" ]]; then
      echo "port-forward started (pid $pid). Open http://$view_host:$LOCAL_PORT"
      return 0
    fi
    [[ -f "$PID" ]] && kill "$pid" >/dev/null 2>&1 || true
    rm -f "$PID"
    if (( attempt < max_attempts )); then
      echo "[pf] 第 $attempt 次啟動失敗，5 秒後重試..." >&2
      sleep 5
      : > "$LOG"
      ((attempt++))
      continue
    fi
    break
  done
  tail -n 50 "$LOG" >&2 || true
  echo "port-forward failed" >&2
  exit 1
}
stop(){ [[ -f "$PID" ]] && kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; echo "port-forward stopped."; }
status(){ if ss -ltn | grep -q ":${LOCAL_PORT} " ; then
  echo "running → http://$BIND_ADDR:$LOCAL_PORT"
else echo "not running"; exit 1; fi; }
case "${1:-status}" in start) start;; stop) stop;; status) status;; *) echo "Usage: jhub-portforward {start|stop|status}"; exit 2;; esac
EOS
  sed -i "s|__JHUB_NS__|${JHUB_NS}|g; s|__PF_BIND_ADDR__|${PF_BIND_ADDR}|g; s|__PF_LOCAL_PORT__|${PF_LOCAL_PORT}|g; s|__PF_PROXY_PID__|${PF_PROXY_PID}|g; s|__PF_PROXY_LOG__|${PF_PROXY_LOG}|g" /usr/local/bin/jhub-portforward
  chmod +x /usr/local/bin/jhub-portforward
}

