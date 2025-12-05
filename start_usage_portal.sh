#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${ROOT_DIR}/lib"
if [[ -r "${LIB_DIR}/env-loader.sh" ]]; then
  # shellcheck source=lib/env-loader.sh
  source "${LIB_DIR}/env-loader.sh"
  load_jhub_env "${ROOT_DIR}"
fi
USAGE_DIR="$ROOT_DIR/usage_monitoring"
ENV_FILE="$USAGE_DIR/.env"
VENV_DIR="$USAGE_DIR/.venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"
COMPOSE_CMD="docker compose"
if ! $COMPOSE_CMD version >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
fi

log() {
  echo "[usage-portal] $*"
}

if [[ ! -d "$USAGE_DIR" ]]; then
  log "usage_monitoring 目錄不存在，請確認專案結構"
  exit 1
fi

if [[ ! -f "$ENV_FILE" && -f "$USAGE_DIR/.env.example" ]]; then
  cp "$USAGE_DIR/.env.example" "$ENV_FILE"
  log "已建立預設 .env，請視需要調整：$ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

log "啟動 PostgreSQL (docker compose)"
(cd "$USAGE_DIR" && $COMPOSE_CMD up -d)

if [[ ! -d "$VENV_DIR" ]]; then
  log "建立虛擬環境 ($PYTHON_BIN)"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip >/dev/null
log "安裝/更新 Python 套件"
pip install -r "$USAGE_DIR/backend/requirements.txt"

log "啟動 FastAPI 服務 (Ctrl+C 可結束)"
cd "$USAGE_DIR/backend"
exec python -m app.main "$@"
