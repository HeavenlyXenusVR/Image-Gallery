#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/image-gallery-live-backend.service"

run_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$@"
  elif command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host systemctl "$@"
  else
    echo "systemctl is required to install the live backend service." >&2
    exit 1
  fi
}

mkdir -p "${SERVICE_DIR}"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Image Gallery live backend and GitHub Pages tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ROOT_DIR}
Environment=GALLERY_SERVICE_START_BACKEND_IF_MISSING=1
ExecStart=/usr/bin/env bash -lc 'cd "${ROOT_DIR}" && exec bash ./scripts/start_live_tunnel_service.sh 8788'
Restart=always
RestartSec=15
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF

run_systemctl --user daemon-reload
run_systemctl --user enable --now image-gallery-live-backend.service

if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "${USER}" >/dev/null 2>&1 || true
elif command -v flatpak-spawn >/dev/null 2>&1; then
  flatpak-spawn --host loginctl enable-linger "${USER}" >/dev/null 2>&1 || true
fi

echo "Installed ${SERVICE_FILE}"
run_systemctl --user --no-pager status image-gallery-live-backend.service
