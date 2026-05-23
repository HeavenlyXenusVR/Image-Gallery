#!/usr/bin/env bash
set -euo pipefail

SERVICE_FILE="${HOME}/.config/systemd/user/image-gallery-live-backend.service"

run_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$@"
  elif command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host systemctl "$@"
  else
    return 0
  fi
}

run_systemctl --user disable --now image-gallery-live-backend.service >/dev/null 2>&1 || true
rm -f "${SERVICE_FILE}"
run_systemctl --user daemon-reload

echo "Removed image-gallery-live-backend.service."
