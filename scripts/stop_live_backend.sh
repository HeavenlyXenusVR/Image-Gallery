#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/.runtime"
SERVICE_NAME="image-gallery-live-backend.service"
PID_FILES=(
  "${RUNTIME_DIR}/live_backend.pid"
  "${RUNTIME_DIR}/live_tunnel_service.pid"
)

run_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$@"
  elif command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host systemctl "$@"
  else
    return 1
  fi
}

stop_user_service() {
  if run_systemctl --user is-active --quiet "${SERVICE_NAME}" >/dev/null 2>&1; then
    echo "Stopping ${SERVICE_NAME}..."
    run_systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi
}

stop_pid_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "${file}" 2>/dev/null || true)"
  if [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]]; then
    rm -f "${file}"
    echo "Removed invalid pid file ${file}."
    return 0
  fi

  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "Stopping Image Gallery live process ${pid} from ${file##*/}..."
    kill "${pid}" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      echo "Process ${pid} did not exit after TERM; forcing it down."
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  else
    echo "Live process ${pid} from ${file##*/} was not running."
  fi

  rm -f "${file}"
  return 0
}

stop_user_service

stopped=0
for file in "${PID_FILES[@]}"; do
  if stop_pid_file "${file}"; then
    stopped=1
  fi
done

if [[ "${stopped}" != "1" ]]; then
  echo "No Image Gallery live backend pid files found."
else
  echo "Image Gallery live backend/tunnel stop request complete."
fi
