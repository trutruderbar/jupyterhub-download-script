#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load repo-wide env (jhub.env) if present.
if [[ -r "${ROOT_DIR}/lib/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${ROOT_DIR}/lib/env-loader.sh"
  load_jhub_env "${ROOT_DIR}"
fi

MODE="${HEALTHCHECK_MODE:-fix}" # fix | check | dry-run
for arg in "$@"; do
  case "${arg}" in
    --check|--check-only) MODE="check" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help)
      cat <<'EOF'
Usage: ./healthcheck_selfheal.sh [--check|--dry-run]

Modes:
  (default)  fix      Detect issues and restart affected components.
  --check    check    Detect issues only; no restart.
  --dry-run  dry-run  Print what would be restarted; no restart.

Environment:
  HEALTHCHECK_MODE=fix|check|dry-run
  HEAL_UNKNOWN_PODS=true|false
  HEAL_UNKNOWN_PODS_ALL=true|false
  HEAL_UNKNOWN_USER_PODS=true|false
EOF
      exit 0
      ;;
  esac
done

ts() { date '+%F %T'; }
log() { printf '[%s][health] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s][health][WARN] %s\n' "$(ts)" "$*" >&2; }
ok() { printf '[%s][health][OK] %s\n' "$(ts)" "$*"; }

SUDO_OK="false"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO_OK="true"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO_OK="true"
fi

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return $?
  fi
  if [[ "${SUDO_OK}" == "true" ]]; then
    sudo -n "$@"
    return $?
  fi
  warn "需要 root/sudo 才能執行：$*"
  return 126
}

run_or_plan() {
  if [[ "${MODE}" == "check" ]]; then
    return 0
  fi
  if [[ "${MODE}" == "dry-run" ]]; then
    warn "[dry-run] would run: $*"
    return 0
  fi
  "$@"
}

run_or_plan_root() {
  if [[ "${MODE}" == "check" ]]; then
    return 0
  fi
  if [[ "${MODE}" == "dry-run" ]]; then
    warn "[dry-run] would run (root): $*"
    return 0
  fi
  as_root "$@"
}

detect_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1
}

read_env_value() {
  # read_env_value FILE KEY DEFAULT
  local file="$1" key="$2" default="$3"
  [[ -f "${file}" ]] || { printf '%s' "${default}"; return 0; }
  local line value
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || { printf '%s' "${default}"; return 0; }
  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value:-${default}}"
}

curl_ok() {
  local url="$1"
  curl -fsS --max-time 3 "${url}" >/dev/null 2>&1
}

declare -a COMPOSE=()
if detect_cmd docker && docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif detect_cmd docker-compose; then
  COMPOSE=(docker-compose)
fi

compose_available() { ((${#COMPOSE[@]})); }

kctl() {
  if detect_cmd microk8s; then
    if microk8s kubectl "$@" >/dev/null 2>&1; then
      microk8s kubectl "$@"
      return 0
    fi
    as_root microk8s kubectl "$@"
    return $?
  fi
  if detect_cmd kubectl; then
    kubectl "$@"
    return $?
  fi
  warn "找不到 kubectl/microk8s，略過 K8S 檢查"
  return 127
}

microk8s_ready() {
  detect_cmd microk8s || return 127
  microk8s status --wait-ready >/dev/null 2>&1 && return 0
  as_root microk8s status --wait-ready >/dev/null 2>&1
}

repair_microk8s() {
  detect_cmd microk8s || return 127
  run_or_plan_root microk8s start >/dev/null 2>&1 || true
  run_or_plan_root microk8s status --wait-ready >/dev/null 2>&1 || true
}

rollout_status() {
  local ns="$1" kind="$2" name="$3" timeout="$4"
  kctl -n "${ns}" rollout status "${kind}/${name}" --timeout="${timeout}" >/dev/null 2>&1
}

rollout_restart() {
  local ns="$1" kind="$2" name="$3"
  run_or_plan kctl -n "${ns}" rollout restart "${kind}/${name}" >/dev/null 2>&1 || true
}

restart_by_label() {
  # restart_by_label NS KIND LABEL_SELECTOR
  local ns="$1" kind="$2" selector="$3"
  run_or_plan kctl -n "${ns}" rollout restart "${kind}" -l "${selector}" >/dev/null 2>&1 || true
}

issues=0
fixed=0

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_jhub_user_pod() {
  local ns="$1" pod="$2"

  # Fast path by name (common in Z2JH)
  if [[ "${pod}" == jupyter-* ]]; then
    return 0
  fi

  # Label-based detection (more reliable if naming differs)
  local username component
  username="$(kctl -n "${ns}" get pod "${pod}" -o jsonpath="{.metadata.labels['hub.jupyter.org/username']}" 2>/dev/null || true)"
  component="$(kctl -n "${ns}" get pod "${pod}" -o jsonpath="{.metadata.labels['component']}" 2>/dev/null || true)"
  [[ -n "${username}" || "${component}" == "singleuser-server" ]]
}

ns_is_managed_for_unknown_heal() {
  local ns="$1"
  if is_truthy "${HEAL_UNKNOWN_PODS_ALL:-false}"; then
    return 0
  fi
  case "${ns}" in
    kube-system) return 0 ;;
    "${JHUB_NS:-jhub}") return 0 ;;
    gpu-operator) [[ "${USE_GPU_OPERATOR:-false}" == "true" ]] && return 0 ;;
    nvidia-network-operator) [[ "${ENABLE_IB:-false}" == "true" ]] && return 0 ;;
    "${MPI_OPERATOR_NAMESPACE:-mpi-operator}") [[ "${ENABLE_MPI_OPERATOR:-false}" == "true" ]] && return 0 ;;
  esac
  return 1
}

check_unknown_pods() {
  local lines
  lines="$(kctl get pods -A --no-headers 2>/dev/null | awk '$4=="Unknown" || $4=="ContainerStatusUnknown" {print $1, $2, $4}' || true)"
  if [[ -z "${lines}" ]]; then
    ok "k8s: no Unknown pods"
    return 0
  fi

  warn "k8s: Unknown pods detected"
  issues=$((issues + 1))

  if [[ "${MODE}" == "check" ]]; then
    return 1
  fi
  if ! is_truthy "${HEAL_UNKNOWN_PODS:-true}"; then
    warn "k8s: HEAL_UNKNOWN_PODS=false，僅偵測不修復"
    return 1
  fi

  local ns pod status
  local healed_any="false"
  local heal_user_pods="false"
  if is_truthy "${HEAL_UNKNOWN_USER_PODS:-false}"; then
    heal_user_pods="true"
  fi

  while read -r ns pod status; do
    [[ -n "${ns}" && -n "${pod}" ]] || continue
    if ! ns_is_managed_for_unknown_heal "${ns}"; then
      warn "k8s: Unknown pod outside managed namespaces (ns=${ns} pod=${pod})"
      continue
    fi

    if [[ "${ns}" == "${JHUB_NS:-jhub}" ]] && is_jhub_user_pod "${ns}" "${pod}"; then
      if [[ "${heal_user_pods}" != "true" ]]; then
        warn "k8s: Unknown user pod skipped (ns=${ns} pod=${pod}); set HEAL_UNKNOWN_USER_PODS=true to delete"
        continue
      fi
    fi

    warn "k8s: deleting Unknown pod (ns=${ns} pod=${pod} status=${status})"
    run_or_plan kctl -n "${ns}" delete pod "${pod}" --force --grace-period=0 >/dev/null 2>&1 || true
    healed_any="true"
  done <<<"${lines}"

  if [[ "${healed_any}" == "true" ]]; then
    fixed=$((fixed + 1))
    ok "k8s: Unknown pod cleanup triggered"
  fi
  return 1
}

check_nginx() {
  [[ "${ENABLE_NGINX_PROXY:-false}" == "true" ]] || return 0
  if detect_cmd systemctl; then
    if systemctl is-active --quiet nginx >/dev/null 2>&1; then
      ok "nginx: active"
      return 0
    fi
  else
    if pgrep -x nginx >/dev/null 2>&1; then
      ok "nginx: running"
      return 0
    fi
  fi

  warn "nginx: not running"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    if detect_cmd systemctl; then
      run_or_plan_root systemctl restart nginx >/dev/null 2>&1 || true
    elif detect_cmd service; then
      run_or_plan_root service nginx restart >/dev/null 2>&1 || true
    else
      run_or_plan_root nginx >/dev/null 2>&1 || true
    fi
    sleep 1
    if (detect_cmd systemctl && systemctl is-active --quiet nginx >/dev/null 2>&1) || pgrep -x nginx >/dev/null 2>&1; then
      ok "nginx: restarted"
      fixed=$((fixed + 1))
      return 0
    fi
    warn "nginx: restart failed"
  fi
  return 1
}

stop_usage_portal() {
  local target_cwd="${ROOT_DIR}/usage_monitoring/backend"
  local pids="" pid cwd
  pids="$(pgrep -f 'python -m app\.main' || true)"
  for pid in ${pids}; do
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    [[ "${cwd}" == "${target_cwd}" ]] || continue
    run_or_plan_root kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
  sleep 2
  pids="$(pgrep -f 'python -m app\.main' || true)"
  for pid in ${pids}; do
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    [[ "${cwd}" == "${target_cwd}" ]] || continue
    run_or_plan_root kill -KILL "${pid}" >/dev/null 2>&1 || true
  done

  # Also stop the sudo wrapper if it is still around.
  pids="$(pgrep -f 'sudo nohup \./start_usage_portal\.sh' || true)"
  for pid in ${pids}; do
    run_or_plan_root kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
}

start_usage_portal() {
  # Keep behavior consistent with existing deployment: run via sudo/nohup.
  run_or_plan_root nohup "${ROOT_DIR}/start_usage_portal.sh" >/tmp/usage_portal.log 2>&1 &
}

check_usage_portal() {
  local env_file="${ROOT_DIR}/usage_monitoring/.env"
  local port host url
  host="$(read_env_value "${env_file}" "APP_HOST" "127.0.0.1")"
  port="$(read_env_value "${env_file}" "APP_PORT" "29781")"
  url="http://${host}:${port}/health"
  if curl_ok "${url}"; then
    ok "usage-portal: healthy (${url})"
    return 0
  fi

  warn "usage-portal: unhealthy (${url})"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    stop_usage_portal
    start_usage_portal
    for _ in {1..20}; do
      if curl_ok "${url}"; then
        ok "usage-portal: restarted"
        fixed=$((fixed + 1))
        return 0
      fi
      sleep 1
    done
    warn "usage-portal: restart timed out; see /tmp/usage_portal.log"
  fi
  return 1
}

check_usage_db() {
  local compose_file="${ROOT_DIR}/usage_monitoring/docker-compose.yml"
  [[ -f "${compose_file}" ]] || return 0
  if ! compose_available; then
    warn "usage-portal db: docker compose 不存在，略過檢查"
    return 0
  fi

  local id status rc=0
  id="$(as_root "${COMPOSE[@]}" -f "${compose_file}" ps -q db 2>/dev/null)" || rc=$?
  if [[ "${rc}" -eq 126 ]]; then
    warn "usage-portal db: 需要 sudo 才能檢查 docker，略過"
    return 0
  fi
  id="${id:-}"
  if [[ -z "${id}" ]]; then
    warn "usage-portal db: container missing"
    issues=$((issues + 1))
    if [[ "${MODE}" != "check" ]]; then
      run_or_plan_root "${COMPOSE[@]}" -f "${compose_file}" up -d >/dev/null 2>&1 || true
      fixed=$((fixed + 1))
    fi
    return 1
  fi

  status="$(as_root docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${id}" 2>/dev/null || true)"
  if [[ "${status}" == "healthy" || "${status}" == "running" ]]; then
    ok "usage-portal db: ${status}"
    return 0
  fi
  warn "usage-portal db: ${status:-unknown}"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    run_or_plan_root "${COMPOSE[@]}" -f "${compose_file}" up -d >/dev/null 2>&1 || true
    fixed=$((fixed + 1))
  fi
  return 1
}

restart_user_monitors() {
  local run_user
  run_user="$(id -un)"
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    run_user="${SUDO_USER}"
  fi
  if [[ "${run_user}" != "$(id -un)" ]]; then
    run_or_plan_root sudo -n -u "${run_user}" "${ROOT_DIR}/start_user_monitor.sh" >/dev/null 2>&1 || true
  else
    run_or_plan "${ROOT_DIR}/start_user_monitor.sh" >/dev/null 2>&1 || true
  fi
}

check_user_monitors() {
  local pm_env="${ROOT_DIR}/port_mapper/.env"
  local pm_env_local="${ROOT_DIR}/port_mapper/.env.local"

  local port_pm port_rm port_lm
  port_pm="$(read_env_value "${pm_env}" "PORT_MAPPER_PORT" "32001")"
  port_pm="$(read_env_value "${pm_env_local}" "PORT_MAPPER_PORT" "${port_pm}")"
  port_rm="${USER_RESOURCE_MONITOR_PORT:-32002}"
  port_lm="${USER_LOGS_MONITOR_PORT:-32003}"

  local ok_all="true"
  if ! curl_ok "http://127.0.0.1:${port_pm}/openapi.json"; then
    warn "port-mapper: unhealthy (port=${port_pm})"
    ok_all="false"
  fi
  if ! curl_ok "http://127.0.0.1:${port_rm}/openapi.json"; then
    warn "user-resource-monitor: unhealthy (port=${port_rm})"
    ok_all="false"
  fi
  if ! curl_ok "http://127.0.0.1:${port_lm}/openapi.json"; then
    warn "user-logs-monitor: unhealthy (port=${port_lm})"
    ok_all="false"
  fi

  if [[ "${ok_all}" == "true" ]]; then
    ok "user-monitors: healthy"
    return 0
  fi

  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    restart_user_monitors
    sleep 2
    if curl_ok "http://127.0.0.1:${port_pm}/openapi.json" \
      && curl_ok "http://127.0.0.1:${port_rm}/openapi.json" \
      && curl_ok "http://127.0.0.1:${port_lm}/openapi.json"; then
      ok "user-monitors: restarted"
      fixed=$((fixed + 1))
      return 0
    fi
    warn "user-monitors: restart failed; see P_log.txt/R_log.txt/L_log.txt"
  fi
  return 1
}

check_k8s() {
  if ! kctl version --request-timeout=5s >/dev/null 2>&1; then
    warn "k8s: kubectl not ready"
    issues=$((issues + 1))
    if [[ "${MODE}" != "check" ]]; then
      repair_microk8s
      if kctl version --request-timeout=10s >/dev/null 2>&1; then
        ok "k8s: recovered"
        fixed=$((fixed + 1))
        return 0
      fi
    fi
    warn "k8s: still unhealthy"
    return 1
  fi
  ok "k8s: api reachable"
  return 0
}

check_k8s_coredns() {
  # Best-effort; only meaningful on microk8s/kube-system.
  if ! rollout_status kube-system deployment coredns 5s; then
    warn "k8s: coredns not ready"
    issues=$((issues + 1))
    if [[ "${MODE}" != "check" ]]; then
      rollout_restart kube-system deployment coredns
      if rollout_status kube-system deployment coredns 180s; then
        ok "k8s: coredns restarted"
        fixed=$((fixed + 1))
        return 0
      fi
    fi
    warn "k8s: coredns still not ready"
    return 1
  fi
  ok "k8s: coredns ready"
  return 0
}

check_jupyterhub_core() {
  local ns="${JHUB_NS:-jhub}"
  if ! rollout_status "${ns}" deployment hub 5s; then
    warn "jupyterhub: hub not ready (ns=${ns})"
    issues=$((issues + 1))
    if [[ "${MODE}" != "check" ]]; then
      rollout_restart "${ns}" deployment hub
      if rollout_status "${ns}" deployment hub 900s; then
        ok "jupyterhub: hub restarted"
        fixed=$((fixed + 1))
      else
        warn "jupyterhub: hub still not ready"
      fi
    fi
  else
    ok "jupyterhub: hub ready"
  fi

  if ! rollout_status "${ns}" deployment proxy 5s; then
    warn "jupyterhub: proxy not ready (ns=${ns})"
    issues=$((issues + 1))
    if [[ "${MODE}" != "check" ]]; then
      rollout_restart "${ns}" deployment proxy
      if rollout_status "${ns}" deployment proxy 600s; then
        ok "jupyterhub: proxy restarted"
        fixed=$((fixed + 1))
      else
        warn "jupyterhub: proxy still not ready"
      fi
    fi
  else
    ok "jupyterhub: proxy ready"
  fi
}

check_gpu_operator() {
  [[ "${USE_GPU_OPERATOR:-false}" == "true" ]] || return 0
  local ns="gpu-operator"
  if ! kctl get ns "${ns}" >/dev/null 2>&1; then
    warn "gpu-operator: namespace missing (${ns})"
    issues=$((issues + 1))
    return 1
  fi
  local bad
  bad="$(kctl -n "${ns}" get pods --no-headers 2>/dev/null | awk '$3 ~ /(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|CreateContainerConfigError|RunContainerError)/ {print}' || true)"
  if [[ -z "${bad}" ]]; then
    ok "gpu-operator: pods OK"
    return 0
  fi
  warn "gpu-operator: pod failures detected"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    restart_by_label "${ns}" deployment "app.kubernetes.io/instance=gpu-operator"
    restart_by_label "${ns}" daemonset "app.kubernetes.io/instance=gpu-operator"
    fixed=$((fixed + 1))
  fi
  return 1
}

check_network_operator() {
  [[ "${ENABLE_IB:-false}" == "true" ]] || return 0
  local ns="nvidia-network-operator"
  if ! kctl get ns "${ns}" >/dev/null 2>&1; then
    warn "network-operator: namespace missing (${ns})"
    issues=$((issues + 1))
    return 1
  fi
  local bad
  bad="$(kctl -n "${ns}" get pods --no-headers 2>/dev/null | awk '$3 ~ /(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|CreateContainerConfigError|RunContainerError)/ {print}' || true)"
  if [[ -z "${bad}" ]]; then
    ok "network-operator: pods OK"
    return 0
  fi
  warn "network-operator: pod failures detected"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    restart_by_label "${ns}" deployment "app.kubernetes.io/instance=network-operator"
    restart_by_label "${ns}" daemonset "app.kubernetes.io/instance=network-operator"
    fixed=$((fixed + 1))
  fi
  return 1
}

check_mpi_operator() {
  [[ "${ENABLE_MPI_OPERATOR:-false}" == "true" ]] || return 0
  local ns="${MPI_OPERATOR_NAMESPACE:-mpi-operator}"
  if ! kctl get ns "${ns}" >/dev/null 2>&1; then
    warn "mpi-operator: namespace missing (${ns})"
    issues=$((issues + 1))
    return 1
  fi
  if rollout_status "${ns}" deployment mpi-operator 5s; then
    ok "mpi-operator: ready"
    return 0
  fi
  warn "mpi-operator: not ready"
  issues=$((issues + 1))
  if [[ "${MODE}" != "check" ]]; then
    rollout_restart "${ns}" deployment mpi-operator
    if rollout_status "${ns}" deployment mpi-operator 300s; then
      ok "mpi-operator: restarted"
      fixed=$((fixed + 1))
      return 0
    fi
  fi
  warn "mpi-operator: still not ready"
  return 1
}

main() {
  log "mode=${MODE}"

  check_nginx || true
  check_usage_db || true
  check_usage_portal || true
  check_user_monitors || true

  if check_k8s; then
    check_unknown_pods || true
    check_k8s_coredns || true
    check_jupyterhub_core || true
    check_gpu_operator || true
    check_network_operator || true
    check_mpi_operator || true
  fi

  if [[ "${issues}" -eq 0 ]]; then
    ok "all healthy"
    return 0
  fi
  if [[ "${MODE}" == "check" || "${MODE}" == "dry-run" ]]; then
    warn "issues=${issues} (no auto-fix in mode=${MODE})"
    return 1
  fi
  if [[ "${fixed}" -gt 0 ]]; then
    warn "issues=${issues}, fixed=${fixed} (some may still require manual action)"
  else
    warn "issues=${issues}, fixed=0"
  fi
  return 1
}

main
