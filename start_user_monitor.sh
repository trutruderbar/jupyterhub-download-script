#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Load jhub.env if available
if [[ -r "${ROOT_DIR}/lib/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${ROOT_DIR}/lib/env-loader.sh"
  load_jhub_env "${ROOT_DIR}"
fi

log() { echo "[user-monitor] $*"; }

# Use Port Mapper venv for all monitors (already contains FastAPI/Uvicorn/httpx)
PORT_MAPPER_DIR="${ROOT_DIR}/port_mapper"
VENV_DIR="${PORT_MAPPER_DIR}/.venv"
if [[ ! -d "${VENV_DIR}" ]]; then
  log "Creating virtualenv (${PYTHON_BIN}) at ${VENV_DIR}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip >/dev/null
log "Installing/updating Port Mapper requirements"
pip install -r "${PORT_MAPPER_DIR}/requirements.txt"

load_env_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$path"
    set +a
  fi
}

# ---- Port Mapper env (compatible with old start_port_mapper.sh) ----
if [[ ! -f "${PORT_MAPPER_DIR}/.env" && -f "${PORT_MAPPER_DIR}/.env.example" ]]; then
  cp "${PORT_MAPPER_DIR}/.env.example" "${PORT_MAPPER_DIR}/.env"
fi
load_env_file "${PORT_MAPPER_DIR}/.env"
load_env_file "${PORT_MAPPER_DIR}/.env.local"

HOST="${PORT_MAPPER_BIND:-0.0.0.0}"
PORT_MAPPER_PORT="${PORT_MAPPER_PORT:-32001}"
PORT_MAPPER_ROOT_PATH="${PORT_MAPPER_ROOT_PATH:-/services/port-mapper}"
PORT_MAPPER_PUBLIC_BASE_URL="${PORT_MAPPER_PUBLIC_BASE_URL:-${PORT_MAPPER_ROOT_PATH}}"

# ---- User Resource Monitor defaults ----
USER_RESOURCE_MONITOR_PORT="${USER_RESOURCE_MONITOR_PORT:-32002}"
USER_RESOURCE_MONITOR_ROOT_PATH="${USER_RESOURCE_MONITOR_ROOT_PATH:-/services/user-resource-monitor}"

# ---- User Logs Monitor defaults ----
USER_LOGS_MONITOR_PORT="${USER_LOGS_MONITOR_PORT:-32003}"
USER_LOGS_MONITOR_ROOT_PATH="${USER_LOGS_MONITOR_ROOT_PATH:-/services/user-logs-monitor}"

kill_existing() {
  local pattern="$1"
  local pids
  pids="$(pgrep -u "$(id -u)" -f "$pattern" || true)"
  if [[ -n "$pids" ]]; then
    log "Stopping existing process(es): $pids"
    kill $pids || true
  fi
}

start_uvicorn_bg() {
  local name="$1" app="$2" port="$3" root_path="$4" logfile="$5"
  kill_existing "uvicorn ${app}.*--port ${port}"
  log "Starting ${name} on ${HOST}:${port} root_path=${root_path}"
  setsid env \
    PORT_MAPPER_BIND="${HOST}" \
    PORT_MAPPER_PORT="${port}" \
    PORT_MAPPER_ROOT_PATH="${root_path}" \
    PORT_MAPPER_PUBLIC_BASE_URL="${root_path}" \
    USER_RESOURCE_MONITOR_ROOT_PATH="${USER_RESOURCE_MONITOR_ROOT_PATH}" \
    USER_LOGS_MONITOR_ROOT_PATH="${USER_LOGS_MONITOR_ROOT_PATH}" \
    python -m uvicorn "${app}" --host "${HOST}" --port "${port}" \
      --proxy-headers --forwarded-allow-ips="*" --root-path "${root_path}" \
      >"${logfile}" 2>&1 &
  echo $!
}

# Start services
PM_PID=$(start_uvicorn_bg "Port Mapper" "port_mapper.backend.app:app" "${PORT_MAPPER_PORT}" "${PORT_MAPPER_ROOT_PATH}" "${ROOT_DIR}/P_log.txt")
RM_PID=$(start_uvicorn_bg "User Resource Monitor" "user_resource_monitor.backend.app:app" "${USER_RESOURCE_MONITOR_PORT}" "${USER_RESOURCE_MONITOR_ROOT_PATH}" "${ROOT_DIR}/R_log.txt")
LM_PID=$(start_uvicorn_bg "User Logs Monitor" "user_logs_monitor.backend.app:app" "${USER_LOGS_MONITOR_PORT}" "${USER_LOGS_MONITOR_ROOT_PATH}" "${ROOT_DIR}/L_log.txt")

log "Started: port-mapper PID=${PM_PID}, resource-monitor PID=${RM_PID}, logs-monitor PID=${LM_PID}"
log "Service URLs:"
log "  Port Mapper:           ${PORT_MAPPER_ROOT_PATH}/app/"
log "  User Resource Monitor:${USER_RESOURCE_MONITOR_ROOT_PATH}/app/"
log "  User Logs Monitor:    ${USER_LOGS_MONITOR_ROOT_PATH}/app/"

