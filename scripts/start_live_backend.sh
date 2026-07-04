#!/usr/bin/env bash
set -euo pipefail

# NixOS/user profile PATH support for systemd user services.
export PATH="/run/current-system/sw/bin:${HOME}/.nix-profile/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

PORT="${1:-${GALLERY_BACKEND_PORT:-8788}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
BIN_DIR="${ROOT_DIR}/.bin"
PYTHON_BIN="${VENV_DIR}/bin/python"
PYTHON_TARGET_DIR="${ROOT_DIR}/.runtime/python-packages"
CONFIG_FILE="${ROOT_DIR}/live-config.json"
PAGES_ORIGIN="${GALLERY_PAGES_ORIGIN:-https://heavenlyxenusvr.github.io}"
PAGES_URL="${GALLERY_PAGES_PUBLIC_URL:-https://heavenlyxenusvr.github.io/Image-Gallery/}"
LOG_DIR="${ROOT_DIR}/.runtime"
UVICORN_LOG="${LOG_DIR}/uvicorn.log"
TUNNEL_LOG="${LOG_DIR}/cloudflared.log"
PID_FILE="${LOG_DIR}/live_backend.pid"
INSTANCE_LOCK_FILE="${LOG_DIR}/live-manager.lock"
AUTO_PUSH_CONFIG="${GALLERY_AUTO_PUSH_CONFIG:-1}"
PUSH_OFFLINE_CONFIG="${GALLERY_PUSH_OFFLINE_CONFIG:-0}"
CONFIG_PUSH_COOLDOWN_SECONDS="${GALLERY_CONFIG_PUSH_COOLDOWN_SECONDS:-120}"
LAST_PUSH_FILE="${LOG_DIR}/last-live-config-push"
TUNNEL_PROVIDER="${GALLERY_TUNNEL_PROVIDER:-auto}"
TUNNEL_READY_ATTEMPTS="${GALLERY_TUNNEL_READY_ATTEMPTS:-180}"
# Set GALLERY_NGROK_DOMAIN to your free static ngrok subdomain to get a stable URL.
# Claim one at https://dashboard.ngrok.com/domains (free, one per account).
NGROK_STATIC_DOMAIN="${GALLERY_NGROK_DOMAIN:-${NGROK_STATIC_DOMAIN:-}}"
# Per-project ngrok config (holds the account-specific authtoken)
NGROK_CONFIG_FILE="${GALLERY_NGROK_CONFIG:-}"
if [[ -n "${NGROK_CONFIG_FILE}" && ! "${NGROK_CONFIG_FILE}" = /* ]]; then
  NGROK_CONFIG_FILE="${ROOT_DIR}/${NGROK_CONFIG_FILE}"
fi

mkdir -p "${BIN_DIR}" "${LOG_DIR}"
echo "$$" > "${PID_FILE}"

current_live_url() {
  CONFIG_FILE_PATH="${CONFIG_FILE}" python3 <<'PY'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE_PATH"])
try:
    payload = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    print("")
else:
    print(str(payload.get("gallery_url") or "").strip())
PY
}

acquire_instance_lock() {
  exec {INSTANCE_LOCK_FD}> "${INSTANCE_LOCK_FILE}"
  if flock -n "${INSTANCE_LOCK_FD}"; then
    return 0
  fi

  local existing_url
  existing_url="$(current_live_url)"
  echo "Another Image Gallery live tunnel manager is already running."
  if [[ -n "${existing_url}" ]]; then
    echo "Current published live URL: ${existing_url}"
  else
    echo "Current published live URL is not available yet. Reuse the running manager instead of starting a second tunnel."
  fi
  exit 0
}

release_instance_lock() {
  if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
    flock -u "${INSTANCE_LOCK_FD}" || true
    eval "exec ${INSTANCE_LOCK_FD}>&-"
    INSTANCE_LOCK_FD=""
  fi
}

flush_local_dns_cache() {
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches >/dev/null 2>&1 || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --flush-caches >/dev/null 2>&1 || true
  fi
}

local_urls_json() {
  PORT="${PORT}" python3 <<'PY'
import json
import os
import socket

port = os.environ["PORT"]
urls = [f"http://127.0.0.1:{port}", f"http://localhost:{port}"]

try:
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.connect(("1.1.1.1", 80))
    urls.append(f"http://{udp.getsockname()[0]}:{port}")
    udp.close()
except Exception:
    pass

try:
    hostname = socket.gethostname()
    for family, *_rest, sockaddr in socket.getaddrinfo(hostname, None, family=socket.AF_INET, type=socket.SOCK_STREAM):
        ip = sockaddr[0]
        if ip.startswith("127."):
            continue
        urls.append(f"http://{ip}:{port}")
except Exception:
    pass

seen = set()
deduped = []
for url in urls:
    if url in seen:
        continue
    seen.add(url)
    deduped.append(url)

print(json.dumps(deduped))
PY
}

validate_config_json() {
  CONFIG_FILE_PATH="${CONFIG_FILE}" python3 <<'PY'
import json
import os
from pathlib import Path
path = Path(os.environ["CONFIG_FILE_PATH"])
json.loads(path.read_text(encoding="utf-8"))
PY
}

backend_ready() {
  curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${PORT}" | grep -q ":${PORT}"
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  return 1
}

kill_stale_port() {
  if [[ "${GALLERY_KILL_STALE_PORT:-0}" != "1" ]]; then
    return 0
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -ti tcp:"${PORT}" | xargs -r kill -TERM || true
  fi
}

write_config() {
  local gallery_url="$1"
  local local_urls
  local_urls="$(local_urls_json)"
  tmp_config="${CONFIG_FILE}.tmp.$$"
  cat > "${tmp_config}" <<EOF
{
  "gallery_url": "${gallery_url}",
  "status": "live",
  "local_urls": ${local_urls},
  "updated_at": "$(date -Is)"
}
EOF
  python3 -m json.tool "${tmp_config}" >/dev/null
  mv "${tmp_config}" "${CONFIG_FILE}"
}

write_offline_config() {
  local local_urls
  local_urls="$(local_urls_json)"
  tmp_config="${CONFIG_FILE}.tmp.$$"
  cat > "${tmp_config}" <<EOF
{
  "gallery_url": "",
  "status": "offline",
  "local_urls": ${local_urls},
  "updated_at": "$(date -Is)"
}
EOF
  python3 -m json.tool "${tmp_config}" >/dev/null
  mv "${tmp_config}" "${CONFIG_FILE}"
}

run_host_git() {
  if command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host git -C "${ROOT_DIR}" "$@"
  else
    git -C "${ROOT_DIR}" "$@"
  fi
}

config_meaningfully_changed() {
  local committed
  committed="$(run_host_git show HEAD:live-config.json 2>/dev/null || true)"
  COMMITTED_CONFIG_JSON="${committed}" CONFIG_FILE_PATH="${CONFIG_FILE}" python3 <<'PY'
import json, os, sys

def sig(raw):
    try:
        d = json.loads(raw)
    except Exception:
        return None
    return (
        str(d.get("gallery_url") or ""),
        str(d.get("status") or ""),
        sorted(str(u) for u in (d.get("local_urls") or [])),
    )

committed = sig(os.environ.get("COMMITTED_CONFIG_JSON") or "{}")
current = sig(open(os.environ["CONFIG_FILE_PATH"], encoding="utf-8").read())
sys.exit(0 if committed != current else 1)
PY
}

publish_config() {
  if [[ "${AUTO_PUSH_CONFIG}" != "1" ]]; then
    return
  fi
  if ! command -v git >/dev/null 2>&1 && ! command -v flatpak-spawn >/dev/null 2>&1; then
    echo "Skipping live-config push because git is unavailable." >&2
    return
  fi
  if ! run_host_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi
  # Compare only the fields that matter (gallery_url/status/local_urls), not the raw file diff —
  # write_config() always rewrites updated_at, so a raw `git diff` looks "changed" on every single
  # publish (even a same-URL service restart), which is what caused the git log's "Update live
  # backend URL" commit spam. Only push when something a client would actually care about differs.
  if ! config_meaningfully_changed; then
    echo "live-config.json content is unchanged (only updated_at differs); skipping no-op publish."
    return
  fi
  local now last_push
  now="$(date +%s)"
  last_push="$(cat "${LAST_PUSH_FILE}" 2>/dev/null || echo 0)"
  if [[ "$((now - last_push))" -lt "${CONFIG_PUSH_COOLDOWN_SECONDS}" ]]; then
    echo "Skipping live-config auto-push; last push was less than ${CONFIG_PUSH_COOLDOWN_SECONDS}s ago."
    return
  fi
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false run_host_git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "Skipping live-config auto-push because GitHub auth is unavailable; local file was still updated."
    return
  fi
  if ! run_host_git config user.email >/dev/null 2>&1 && ! git config --global user.email >/dev/null 2>&1; then
    echo "Skipping live-config auto-push because git user.email is not configured." >&2
    echo "Run: git config --global user.name 'HeavenlyXenusVR' && git config --global user.email 'heavenlyxenusvr@icloud.com'" >&2
    return
  fi
  if ! validate_config_json; then
    echo "Refusing to publish invalid live-config.json." >&2
    return
  fi
  echo "Publishing updated live-config.json to GitHub Pages..."
  run_host_git add live-config.json
  run_host_git commit -m "Update live backend URL" -- live-config.json || true
  if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false run_host_git push origin main; then date +%s > "${LAST_PUSH_FILE}"; else echo "Could not push live-config.json automatically. Push it manually when convenient." >&2; fi
}

publish_offline_config() {
  write_offline_config
  if [[ "${PUSH_OFFLINE_CONFIG}" == "1" ]]; then
    publish_config
  else
    echo "Offline live-config written locally only; not pushing offline state to GitHub Pages."
  fi
}

install_python_deps() {
  if [[ -x "${VENV_DIR}/bin/python" ]] && ! "${VENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1; then
    echo "Existing virtualenv cannot run pip; rebuilding ${VENV_DIR}..." >&2
    rm -rf "${VENV_DIR}"
  fi
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    if ! python3 -m venv "${VENV_DIR}"; then
      echo "python3 venv support is unavailable; installing dependencies into ${PYTHON_TARGET_DIR}." >&2
      rm -rf "${VENV_DIR}"
      mkdir -p "${PYTHON_TARGET_DIR}"
      python3 -m pip install --upgrade --target "${PYTHON_TARGET_DIR}" -r "${ROOT_DIR}/requirements.txt"
      PYTHON_BIN="python3"
      export PYTHONPATH="${PYTHON_TARGET_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
      return
    fi
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python"
  "${PYTHON_BIN}" -m pip install --upgrade pip
  "${PYTHON_BIN}" -m pip install -r "${ROOT_DIR}/requirements.txt"
}

cloudflared_bin() {
  if command -v cloudflared >/dev/null 2>&1; then
    command -v cloudflared
    return
  fi

  local local_bin="${BIN_DIR}/cloudflared"
  if [[ -x "${local_bin}" ]]; then
    echo "${local_bin}"
    return
  fi

  local machine
  machine="$(uname -m)"
  local arch="amd64"
  if [[ "${machine}" == "aarch64" || "${machine}" == "arm64" ]]; then
    arch="arm64"
  fi

  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  echo "Downloading cloudflared (${arch})..." >&2
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail "${url}" -o "${local_bin}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${local_bin}" "${url}"
  else
    echo "Need curl or wget to download cloudflared." >&2
    exit 1
  fi
  chmod +x "${local_bin}"
  echo "${local_bin}"
}

publish_live_url() {
  local gallery_url="$1"
  write_config "${gallery_url}"
  flush_local_dns_cache
  PUBLISHED_GALLERY_URL="${gallery_url}"
  publish_config
  echo
  echo "Live backend URL: ${gallery_url}"
  echo "Updated ${CONFIG_FILE}"
  echo "GitHub Pages front-end: ${PAGES_URL}"
  echo
  echo "Keep this script running while you want the live site connected."
  wait "${TUNNEL_PID}"
  exit $?
}

ngrok_bin() {
  for candidate in "${HOME}/.local/bin/ngrok" "${BIN_DIR}/ngrok"; do
    if [[ -x "${candidate}" ]]; then echo "${candidate}"; return; fi
  done
  if command -v ngrok >/dev/null 2>&1; then command -v ngrok; return; fi
  echo ""
}

start_ngrok_tunnel() {
  local bin
  bin="$(ngrok_bin)"
  if [[ -z "${bin}" ]]; then
    echo "ngrok binary not found; skipping ngrok tunnel." >&2; return 1
  fi
  local ngrok_log="${LOG_DIR}/ngrok.log"
  : > "${ngrok_log}"

  local cfg_flag=()
  if [[ -n "${NGROK_CONFIG_FILE}" && -f "${NGROK_CONFIG_FILE}" ]]; then
    cfg_flag=("--config=${NGROK_CONFIG_FILE}")
  fi

  if [[ -n "${NGROK_STATIC_DOMAIN}" ]]; then
    echo "Opening ngrok tunnel on static domain ${NGROK_STATIC_DOMAIN}..."
    "${bin}" http "${cfg_flag[@]}" "--domain=${NGROK_STATIC_DOMAIN}" --log=stdout --log-format=json "${PORT}" >"${ngrok_log}" 2>&1 &
  else
    echo "Opening ngrok tunnel (random URL — set GALLERY_NGROK_DOMAIN for a stable URL)..."
    "${bin}" http "${cfg_flag[@]}" --log=stdout --log-format=json "${PORT}" >"${ngrok_log}" 2>&1 &
  fi
  TUNNEL_PID="$!"

  local gallery_url=""
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "ngrok exited early. Last log lines:" >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
    fi
    gallery_url="$(python3 -c "
import sys, json
for line in open('${ngrok_log}'):
    try:
        d=json.loads(line)
        u=d.get('url','')
        if u.startswith('https://'): print(u); break
    except: pass
" 2>/dev/null || true)"
    if [[ -n "${gallery_url}" ]]; then
      echo "Waiting for ${gallery_url} to answer through ngrok..."
      for ((ready_attempt=1; ready_attempt<=TUNNEL_READY_ATTEMPTS; ready_attempt++)); do
        if curl -fsS --max-time 10 "${gallery_url}/api/health" >/dev/null 2>&1; then
          TUNNEL_LOG="${ngrok_log}"
          publish_live_url "${gallery_url}"
        fi
        sleep 1
      done
      echo "ngrok URL never became reachable. Last log lines:" >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
    fi
    sleep 0.5
  done
  echo "Timed out waiting for ngrok URL." >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
}

start_pinggy_tunnel() {
  echo "Opening Pinggy tunnel..."
  : > "${TUNNEL_LOG}"
  "${PYTHON_BIN}" "${ROOT_DIR}/scripts/start_pinggy_tunnel.py" --port "${PORT}" >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"

  local gallery_url=""
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "Pinggy tunnel exited early. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      return 1
    fi
    gallery_url="$(grep -Eo 'https://[^[:space:]]+\\.pinggy-free\\.link' "${TUNNEL_LOG}" | tail -1 || true)"
    if [[ -n "${gallery_url}" ]]; then
      echo "Waiting for ${gallery_url} to answer through Pinggy..."
      for ((ready_attempt=1; ready_attempt<=TUNNEL_READY_ATTEMPTS; ready_attempt++)); do
        if curl -fsS --max-time 10 "${gallery_url}/api/health" >/dev/null 2>&1; then
          publish_live_url "${gallery_url}"
        fi
        sleep 1
      done
      echo "Pinggy URL was created but never became reachable. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      return 1
    fi
    sleep 0.5
  done

  echo "Timed out waiting for Pinggy tunnel URL. Last log lines:" >&2
  tail -80 "${TUNNEL_LOG}" >&2 || true
  return 1
}

cleanup() {
  release_instance_lock
  if [[ -n "${PUBLISHED_GALLERY_URL:-}" ]] && grep -Fq "\"gallery_url\": \"${PUBLISHED_GALLERY_URL}\"" "${CONFIG_FILE}" 2>/dev/null; then
    publish_offline_config
  fi
  rm -f "${PID_FILE}"
  if [[ -n "${UVICORN_PID:-}" && "${STARTED_LOCAL_BACKEND:-0}" == "1" ]]; then
    kill "${UVICORN_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

acquire_instance_lock

install_python_deps
CLOUDFLARED="$(cloudflared_bin)"

export GALLERY_PAGES_PUBLIC_URL="${PAGES_URL}"
export GALLERY_CORS_ALLOWED_ORIGINS="${GALLERY_CORS_ALLOWED_ORIGINS:-${PAGES_ORIGIN},${PAGES_URL%/},http://127.0.0.1:${PORT},http://localhost:${PORT}}"
export GALLERY_DB_HOST="${GALLERY_DB_HOST:-127.0.0.1}"
export GALLERY_DB_USER="${GALLERY_DB_USER:-${DB_USER:-${MYSQL_USER:-botuser}}}"

cd "${ROOT_DIR}"
if backend_ready; then
  echo "Reusing existing Image Gallery backend on http://127.0.0.1:${PORT}"
else
  if port_in_use; then
    echo "Port ${PORT} is busy but the Image Gallery backend is not responding; attempting cleanup."
    kill_stale_port
    sleep 1
  fi
  if backend_ready; then
    echo "A healthy Image Gallery backend appeared on http://127.0.0.1:${PORT}; reusing it."
  else
    if port_in_use; then
      echo "Port ${PORT} is still busy and unavailable for the live backend." >&2
      exit 1
    fi
    echo "Starting Image Gallery backend on http://127.0.0.1:${PORT}"
    "${PYTHON_BIN}" -m uvicorn app.main:app --host 127.0.0.1 --port "${PORT}" >"${UVICORN_LOG}" 2>&1 &
    UVICORN_PID="$!"
    STARTED_LOCAL_BACKEND=1

    for _ in {1..40}; do
      if backend_ready; then
        break
      fi
      if ! kill -0 "${UVICORN_PID}" >/dev/null 2>&1; then
        echo "Backend exited early. Last log lines:" >&2
        tail -80 "${UVICORN_LOG}" >&2 || true
        exit 1
      fi
      sleep 0.5
    done
  fi
fi

if ! backend_ready; then
  echo "Image Gallery backend never became reachable on http://127.0.0.1:${PORT}" >&2
  publish_offline_config
  exit 1
fi

# Keep the local config truthful while a tunnel is being created, but avoid
# pushing a temporary offline state to GitHub right before the live URL push.
write_offline_config

# ── Tunnel provider dispatch ──────────────────────────────────────────────────
# Priority (auto mode): ngrok with static domain → Cloudflare quick tunnel → Pinggy
# Set GALLERY_TUNNEL_PROVIDER=ngrok|cloudflare|pinggy to force a specific provider.

if [[ "${TUNNEL_PROVIDER}" == "ngrok" ]] || \
   [[ "${TUNNEL_PROVIDER}" == "auto" && -n "${NGROK_STATIC_DOMAIN}" ]]; then
  start_ngrok_tunnel && exit 0 || true
fi

if [[ "${TUNNEL_PROVIDER}" == "cloudflare" || "${TUNNEL_PROVIDER}" == "auto" ]]; then
  echo "Opening Cloudflare quick tunnel..."
  "${CLOUDFLARED}" tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"

  GALLERY_URL=""
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "Tunnel exited early. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      break
    fi
    GALLERY_URL="$(grep -Eo 'https://[-a-zA-Z0-9.]+trycloudflare\.com' "${TUNNEL_LOG}" | tail -1 || true)"
    if [[ -n "${GALLERY_URL}" ]]; then
      echo "Waiting for ${GALLERY_URL} to answer through Cloudflare..."
      for ((ready_attempt=1; ready_attempt<=TUNNEL_READY_ATTEMPTS; ready_attempt++)); do
        if curl -fsS --max-time 10 "${GALLERY_URL}/api/health" >/dev/null 2>&1; then
          publish_live_url "${GALLERY_URL}"
        fi
        sleep 1
      done
      echo "Tunnel URL was created but never became reachable. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      break
    fi
    sleep 0.5
  done

  echo "Cloudflare quick tunnel did not become usable." >&2
fi

if [[ "${TUNNEL_PROVIDER}" == "pinggy" || "${TUNNEL_PROVIDER}" == "auto" ]]; then
  start_pinggy_tunnel
fi

publish_offline_config
exit 1
