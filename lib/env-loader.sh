#!/usr/bin/env bash
# shellcheck shell=bash

# load_jhub_env BASE_DIR
# BASE_DIR should point to repository root where jhub.env resides.
load_jhub_env(){
  local base_dir="$1"
  local env_file="${JHUB_ENV_FILE:-${base_dir}/jhub.env}"
  if [[ -f "${env_file}" ]]; then
    # Export everything defined in env_file so child scripts inherit.
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}
