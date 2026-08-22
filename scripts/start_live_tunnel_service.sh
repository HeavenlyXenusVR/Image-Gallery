#!/usr/bin/env bash
set -euo pipefail

# NixOS/user profile PATH support for systemd user services.
export PATH="/run/current-system/sw/bin:${HOME}/.nix-profile/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

PORT="${1:-8789}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read_env_value() {
  local key="$1"
  local env_file="${ROOT_DIR}/.env"
  [[ -f "${env_file}" ]] || return 0
  grep -E "^${key}=" "${env_file}" | tail -n 1 | cut -d= -f2- | sed -e 's/^\"//' -e 's/\"$//' -e "s/^'//" -e "s/'$//" || true
}
BIN_DIR="${ROOT_DIR}/.bin"
CONFIG_FILE="${ROOT_DIR}/live-config.json"
LOG_DIR="${ROOT_DIR}/.runtime"
TUNNEL_LOG="${LOG_DIR}/cloudflared-service.log"
PID_FILE="${LOG_DIR}/live_tunnel_service.pid"
INSTANCE_LOCK_FILE="${LOG_DIR}/live-manager.lock"
AUTO_PUSH_CONFIG="${GALLERY_AUTO_PUSH_CONFIG:-1}"
PUSH_OFFLINE_CONFIG="${GALLERY_PUSH_OFFLINE_CONFIG:-0}"
CONFIG_PUSH_COOLDOWN_SECONDS="${GALLERY_CONFIG_PUSH_COOLDOWN_SECONDS:-120}"
LAST_PUSH_FILE="${LOG_DIR}/last-live-config-push"
TUNNEL_PROVIDER="${GALLERY_TUNNEL_PROVIDER:-$(read_env_value GALLERY_TUNNEL_PROVIDER)}"
TUNNEL_PROVIDER="${TUNNEL_PROVIDER:-auto}"
NGROK_STATIC_DOMAIN="${GALLERY_NGROK_DOMAIN:-$(read_env_value GALLERY_NGROK_DOMAIN)}"
NGROK_CONFIG_FILE="${GALLERY_NGROK_CONFIG:-$(read_env_value GALLERY_NGROK_CONFIG)}"
if [[ -n "${NGROK_CONFIG_FILE}" && ! "${NGROK_CONFIG_FILE}" = /* ]]; then
  NGROK_CONFIG_FILE="${ROOT_DIR}/${NGROK_CONFIG_FILE}"
fi
PAGES_ORIGIN="${GALLERY_PAGES_ORIGIN:-https://heavenlyxenusvr.github.io}"
PAGES_URL="${GALLERY_PAGES_PUBLIC_URL:-https://heavenlyxenusvr.github.io/Image-Gallery/}"
MAX_TUNNEL_START_ATTEMPTS="${GALLERY_MAX_TUNNEL_START_ATTEMPTS:-12}"
TUNNEL_READY_ATTEMPTS="${GALLERY_TUNNEL_READY_ATTEMPTS:-900}"
QUICK_TUNNEL_URL_ATTEMPTS="${GALLERY_QUICK_TUNNEL_URL_ATTEMPTS:-180}"
CLOUDFLARE_PROTOCOL="${GALLERY_CLOUDFLARE_PROTOCOL:-http2}"
CLOUDFLARE_TUNNEL_TOKEN="${GALLERY_CLOUDFLARE_TUNNEL_TOKEN:-$(read_env_value GALLERY_CLOUDFLARE_TUNNEL_TOKEN)}"
CLOUDFLARE_PUBLIC_URL="${GALLERY_CLOUDFLARE_PUBLIC_URL:-$(read_env_value GALLERY_CLOUDFLARE_PUBLIC_URL)}"
GLOBAL_TUNNEL_STATE_DIR="${HOME}/.local/state/cloudflare-quick-tunnels"
GLOBAL_TUNNEL_LOCK_FILE="${GLOBAL_TUNNEL_STATE_DIR}/create.lock"
GLOBAL_TUNNEL_NEXT_ALLOWED_FILE="${GLOBAL_TUNNEL_STATE_DIR}/next-allowed-epoch"
GLOBAL_SUCCESS_COOLDOWN_SECONDS="${GALLERY_CLOUDFLARE_SUCCESS_COOLDOWN_SECONDS:-180}"
GLOBAL_FAILURE_COOLDOWN_SECONDS="${GALLERY_CLOUDFLARE_FAILURE_COOLDOWN_SECONDS:-300}"
GLOBAL_RATE_LIMIT_COOLDOWN_SECONDS="${GALLERY_CLOUDFLARE_RATE_LIMIT_COOLDOWN_SECONDS:-900}"

mkdir -p "${BIN_DIR}" "${LOG_DIR}" "${GLOBAL_TUNNEL_STATE_DIR}"
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
  echo "Another Nyxframe live tunnel manager is already running."
  if [[ -n "${existing_url}" ]]; then
    echo "Current published live URL: ${existing_url}"
  else
    echo "Current published live URL is not available yet. Reuse the running service instead of starting a second tunnel manager."
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

write_config() {
  local gallery_url="$1"
  local local_urls
  local_urls="$(local_urls_json)"
  tmp_config="${CONFIG_FILE}.tmp.$$"
  cat > "${tmp_config}" <<JSON
{
  "gallery_url": "${gallery_url}",
  "status": "live",
  "local_urls": ${local_urls},
  "updated_at": "$(date -Is)"
}
JSON
  python3 -m json.tool "${tmp_config}" >/dev/null
  mv "${tmp_config}" "${CONFIG_FILE}"
}

write_offline_config() {
  local local_urls
  local_urls="$(local_urls_json)"
  tmp_config="${CONFIG_FILE}.tmp.$$"
  cat > "${tmp_config}" <<JSON
{
  "gallery_url": "",
  "status": "offline",
  "local_urls": ${local_urls},
  "updated_at": "$(date -Is)"
}
JSON
  python3 -m json.tool "${tmp_config}" >/dev/null
  mv "${tmp_config}" "${CONFIG_FILE}"
}

run_git() {
  if command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host git -C "${ROOT_DIR}" "$@"
  else
    git -C "${ROOT_DIR}" "$@"
  fi
}

config_meaningfully_changed() {
  local committed
  committed="$(run_git show HEAD:live-config.json 2>/dev/null || true)"
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
    echo "GALLERY_AUTO_PUSH_CONFIG is disabled; live-config.json was updated locally only."
    return
  fi
  if ! command -v git >/dev/null 2>&1 && ! command -v flatpak-spawn >/dev/null 2>&1; then
    echo "Skipping live-config push because git is unavailable." >&2
    return
  fi
  if ! run_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipping live-config push because ${ROOT_DIR} is not a git work tree." >&2
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
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false run_git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "Skipping live-config auto-push because GitHub auth is unavailable; local file was still updated."
    return
  fi
  if ! run_git config user.email >/dev/null 2>&1 && ! git config --global user.email >/dev/null 2>&1; then
    echo "Skipping live-config auto-push because git user.email is not configured." >&2
    echo "Run: git config --global user.name 'HeavenlyXenusVR' && git config --global user.email 'heavenlyxenusvr@icloud.com'" >&2
    return
  fi
  if ! validate_config_json; then
    echo "Refusing to publish invalid live-config.json." >&2
    return
  fi
  echo "Publishing updated live-config.json to GitHub Pages..."
  run_git add live-config.json
  run_git commit -m "Update live backend URL" -- live-config.json || true
  if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false run_git push origin main; then date +%s > "${LAST_PUSH_FILE}"; else echo "Could not push live-config.json automatically." >&2; fi
}

publish_offline_config() {
  write_offline_config
  if [[ "${PUSH_OFFLINE_CONFIG}" == "1" ]]; then
    publish_config
  else
    echo "Offline live-config written locally only; not pushing offline state to GitHub Pages."
  fi
}

ngrok_bin() {
  for candidate in "${HOME}/.local/bin/ngrok" "${BIN_DIR}/ngrok"; do
    if [[ -x "${candidate}" ]]; then echo "${candidate}"; return; fi
  done
  if command -v ngrok >/dev/null 2>&1; then command -v ngrok; return; fi
  echo ""
}

start_ngrok_tunnel() {
  local health_path="$1"
  local bin
  bin="$(ngrok_bin)"
  if [[ -z "${bin}" ]]; then
    echo "ngrok binary not found; falling through to Cloudflare." >&2; return 1
  fi
  local cfg_flag=()
  if [[ -n "${NGROK_CONFIG_FILE}" && -f "${NGROK_CONFIG_FILE}" ]]; then
    cfg_flag=("--config=${NGROK_CONFIG_FILE}")
  fi
  local ngrok_log="${LOG_DIR}/ngrok.log"
  : > "${ngrok_log}"
  if [[ -n "${NGROK_STATIC_DOMAIN}" ]]; then
    echo "Opening ngrok tunnel on static domain ${NGROK_STATIC_DOMAIN}..."
    "${bin}" http "${cfg_flag[@]}" "--domain=${NGROK_STATIC_DOMAIN}" --log=stdout --log-format=json "127.0.0.1:${PORT}" >"${ngrok_log}" 2>&1 &
  else
    echo "Opening ngrok tunnel (random URL — set NGROK_DOMAIN for a stable URL)..."
    "${bin}" http "${cfg_flag[@]}" --log=stdout --log-format=json "127.0.0.1:${PORT}" >"${ngrok_log}" 2>&1 &
  fi
  TUNNEL_PID="$!"
  local tunnel_url=""
  # Wait up to 40s for ngrok to log its tunnel URL
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "ngrok exited early. Last log:" >&2; tail -20 "${ngrok_log}" >&2 || true; return 1
    fi
    tunnel_url="$(python3 -c "
import json
for line in open('${ngrok_log}'):
    try:
        d=json.loads(line)
        if d.get('url','').startswith('https://'): print(d['url']); break
    except: pass
" 2>/dev/null || true)"
    if [[ -n "${tunnel_url}" ]]; then
      # Announce immediately — static domain never changes, so publish before health check
      announce_live_url "${tunnel_url}"
      echo "ngrok tunnel is live at ${tunnel_url}. Waiting for health check (up to 120s)..."
      for ((r=1; r<=120; r++)); do
        if curl -fsS --max-time 8 "${tunnel_url}${health_path}" >/dev/null 2>&1; then
          echo "ngrok health check passed."
          break
        fi
        if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
          echo "ngrok exited before health check passed." >&2
          TUNNEL_PID=""
          return 1
        fi
        sleep 1
      done
      # Keep the static tunnel running even if health check timed out — never fall through
      echo "Holding ngrok tunnel open (systemd will restart on exit)..."
      wait "${TUNNEL_PID}"
      local rc=$?
      TUNNEL_PID=""
      return ${rc}
    fi
    sleep 0.5
  done
  echo "Timed out waiting for ngrok URL." >&2; tail -20 "${ngrok_log}" >&2 || true; return 1
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
  local machine arch url
  machine="$(uname -m)"
  arch="amd64"
  if [[ "${machine}" == "aarch64" || "${machine}" == "arm64" ]]; then
    arch="arm64"
  fi
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
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

release_global_tunnel_slot() {
  if [[ -n "${GLOBAL_TUNNEL_SLOT_FD:-}" ]]; then
    flock -u "${GLOBAL_TUNNEL_SLOT_FD}" || true
    eval "exec ${GLOBAL_TUNNEL_SLOT_FD}>&-"
    GLOBAL_TUNNEL_SLOT_FD=""
  fi
}

cleanup() {
  release_instance_lock
  release_global_tunnel_slot
  rm -f "${PID_FILE}"
  if [[ -n "${PUBLISHED_GALLERY_URL:-}" ]] && grep -Fq "\"gallery_url\": \"${PUBLISHED_GALLERY_URL}\"" "${CONFIG_FILE}" 2>/dev/null; then
    publish_offline_config
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

acquire_instance_lock

tunnel_retry_delay() {
  local attempt="$1"
  if (( attempt <= 2 )); then
    echo 30
  elif (( attempt <= 5 )); then
    echo 90
  else
    echo 180
  fi
}

tunnel_was_rate_limited() {
  grep -Fq 'status_code="429 Too Many Requests"' "${TUNNEL_LOG}" 2>/dev/null
}

log_tunnel_failure_details() {
  echo "Tunnel exited early. Last log lines:" >&2
  tail -80 "${TUNNEL_LOG}" >&2 || true
  if tunnel_was_rate_limited; then
    echo "Cloudflare quick tunnel creation is being rate-limited. Waiting before retrying." >&2
  fi
}

set_global_tunnel_cooldown() {
  local seconds="$1"
  printf '%s\n' "$(( $(date +%s) + seconds ))" > "${GLOBAL_TUNNEL_NEXT_ALLOWED_FILE}"
}

acquire_global_tunnel_slot() {
  mkdir -p "${GLOBAL_TUNNEL_STATE_DIR}"
  exec {GLOBAL_TUNNEL_SLOT_FD}> "${GLOBAL_TUNNEL_LOCK_FILE}"
  flock "${GLOBAL_TUNNEL_SLOT_FD}"
  local next_allowed=0 now wait_seconds
  if [[ -f "${GLOBAL_TUNNEL_NEXT_ALLOWED_FILE}" ]]; then
    read -r next_allowed < "${GLOBAL_TUNNEL_NEXT_ALLOWED_FILE}" || next_allowed=0
  fi
  now="$(date +%s)"
  if (( next_allowed > now )); then
    wait_seconds="$(( next_allowed - now ))"
    echo "Cloudflare quick tunnel cooldown active; waiting ${wait_seconds}s before requesting a new public URL."
    sleep "${wait_seconds}"
  fi
}

resolve_public_ipv4s() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short @1.1.1.1 "${host}" A 2>/dev/null | awk 'NF'
    return
  fi
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

cloudflare_url_ready() {
  local public_url="$1"
  local health_path="$2"
  local host="${public_url#https://}"
  host="${host%%/*}"

  if curl -fsS --max-time 10 "${public_url}${health_path}" >/dev/null 2>&1; then
    return 0
  fi

  local ip
  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    if curl -gfsS --max-time 10 --resolve "${host}:443:${ip}" "${public_url}${health_path}" >/dev/null 2>&1; then
      return 0
    fi
  done < <(resolve_public_ipv4s "${host}")

  return 1
}

announce_live_url() {
  local gallery_url="$1"
  if [[ "${PUBLISHED_GALLERY_URL:-}" == "${gallery_url}" ]]; then
    return
  fi
  write_config "${gallery_url}"
  flush_local_dns_cache
  PUBLISHED_GALLERY_URL="${gallery_url}"
  publish_config
  echo "Live backend URL: ${gallery_url}"
  echo "GitHub Pages frontend: ${PAGES_URL}"
}

wait_for_public_readiness() {
  local gallery_url="$1"
  local health_path="$2"
  local ready_attempt
  for ((ready_attempt=1; ready_attempt<=TUNNEL_READY_ATTEMPTS; ready_attempt++)); do
    if cloudflare_url_ready "${gallery_url}" "${health_path}"; then
      echo "Cloudflare public URL is answering: ${gallery_url}"
      return 0
    fi
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      return 1
    fi
    sleep 1
  done
  echo "Cloudflare has not answered yet for ${gallery_url}, but the tunnel is still running. Keeping it alive to give propagation more time."
  return 0
}

start_named_cloudflare_tunnel() {
  local public_url="$1"
  local token="$2"
  local health_path="$3"

  if [[ -z "${token}" || -z "${public_url}" ]]; then
    return 1
  fi

  echo "Starting named Cloudflare tunnel for ${public_url}"
  : > "${TUNNEL_LOG}"
  "${CLOUDFLARED}" tunnel --no-autoupdate run --token "${token}" --url "http://127.0.0.1:${PORT}" >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"

  announce_live_url "${public_url}"
  wait_for_public_readiness "${public_url}" "${health_path}" || {
    echo "Named Cloudflare tunnel exited before it became reachable." >&2
    tail -80 "${TUNNEL_LOG}" >&2 || true
    return 1
  }

  wait "${TUNNEL_PID}"
  local _exit=$?
  TUNNEL_PID=""
  return ${_exit}
}

CLOUDFLARED="$(cloudflared_bin)"

# Wait up to 5 minutes for the Lua backend (nyxframe-lua.service) to
# appear -- on a fresh boot it can take a little while after the unit starts.
echo "Waiting for Nyxframe backend on http://127.0.0.1:${PORT} (up to 300s)"
for _ in {1..150}; do
  if backend_ready; then
    break
  fi
  sleep 2
done

if ! backend_ready; then
  echo "Nyxframe backend did not become reachable on port ${PORT}." >&2
  echo "Check: systemctl --user status nyxframe-lua.service" >&2
  publish_offline_config
  exit 1
fi

# Write offline config locally before acquiring the public URL so the frontend
# does not keep hitting a stale URL while a new tunnel is being negotiated.
write_offline_config

# ── static: hostname is routed externally (e.g. via the lumisound-bridge
# Cloudflare tunnel's ingress rules) — just publish the URL and idle ──
if [[ "${TUNNEL_PROVIDER}" == "static" ]]; then
  if [[ -n "${CLOUDFLARE_PUBLIC_URL}" ]]; then
    announce_live_url "${CLOUDFLARE_PUBLIC_URL}"
  fi
  while true; do
    sleep 300
    if ! backend_ready; then
      echo "Backend not responding; exiting so systemd can restart cleanly." >&2
      exit 1
    fi
  done
fi

# ── ngrok: static domain, no reconnect loop needed (systemd restarts on exit) ──
if [[ "${TUNNEL_PROVIDER}" == "ngrok" ]] || \
   [[ "${TUNNEL_PROVIDER}" == "auto" && -n "${NGROK_STATIC_DOMAIN}" ]]; then
  start_ngrok_tunnel "/api/health" && exit 0
  # Static domain: never fall through to Cloudflare — a random Cloudflare URL
  # overwrites the stable ngrok URL in live-config.json, breaking GitHub Pages.
  # Exit so systemd restarts the service and ngrok retries the static domain.
  echo "ngrok static tunnel exited; letting systemd restart." >&2
  exit 1
fi

if [[ "${TUNNEL_PROVIDER}" == "cloudflare" || "${TUNNEL_PROVIDER}" == "auto" ]]; then
  # --- Named tunnel: stable URL, reconnect loop on drops ---
  if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" && -n "${CLOUDFLARE_PUBLIC_URL}" ]]; then
    while true; do
      start_named_cloudflare_tunnel "${CLOUDFLARE_PUBLIC_URL}" "${CLOUDFLARE_TUNNEL_TOKEN}" "/api/health" || true
      echo "Named Cloudflare tunnel exited; reconnecting in 10s..." >&2
      sleep 10
      if ! backend_ready; then
        echo "Backend not responding after named tunnel exit; waiting up to 60s..." >&2
        for _ in {1..30}; do backend_ready && break; sleep 2; done
      fi
      if ! backend_ready; then
        echo "Backend did not recover; exiting so systemd can restart cleanly." >&2
        exit 1
      fi
    done
  fi

  # --- Quick tunnel: outer reconnect loop so a died tunnel is immediately retried ---
  while true; do
    TUNNEL_CONNECTED_AND_DIED=0
    for ((attempt=1; attempt<=MAX_TUNNEL_START_ATTEMPTS; attempt++)); do
      acquire_global_tunnel_slot
      echo "Opening Cloudflare quick tunnel to http://127.0.0.1:${PORT} (attempt ${attempt}/${MAX_TUNNEL_START_ATTEMPTS})"
      : > "${TUNNEL_LOG}"
      "${CLOUDFLARED}" tunnel --no-autoupdate --protocol "${CLOUDFLARE_PROTOCOL}" --url "http://127.0.0.1:${PORT}" >"${TUNNEL_LOG}" 2>&1 &
      TUNNEL_PID="$!"

      GALLERY_URL=""
      for _ in $(seq 1 "${QUICK_TUNNEL_URL_ATTEMPTS}"); do
        if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
          break
        fi
        GALLERY_URL="$(grep -Eo 'https://[-a-zA-Z0-9.]+trycloudflare\.com' "${TUNNEL_LOG}" | tail -1 || true)"
        if [[ -n "${GALLERY_URL}" ]]; then
          break
        fi
        sleep 1
      done

      if [[ -z "${GALLERY_URL}" ]]; then
        log_tunnel_failure_details
        if tunnel_was_rate_limited; then
          set_global_tunnel_cooldown "${GLOBAL_RATE_LIMIT_COOLDOWN_SECONDS}"
        else
          set_global_tunnel_cooldown "${GLOBAL_FAILURE_COOLDOWN_SECONDS}"
        fi
        release_global_tunnel_slot
      else
        set_global_tunnel_cooldown "${GLOBAL_SUCCESS_COOLDOWN_SECONDS}"
        release_global_tunnel_slot
        announce_live_url "${GALLERY_URL}"
        wait_for_public_readiness "${GALLERY_URL}" "/api/health" || {
          echo "Cloudflare quick tunnel died before it became reachable." >&2
          tail -80 "${TUNNEL_LOG}" >&2 || true
          publish_offline_config
          if tunnel_was_rate_limited; then
            set_global_tunnel_cooldown "${GLOBAL_RATE_LIMIT_COOLDOWN_SECONDS}"
          else
            set_global_tunnel_cooldown "${GLOBAL_FAILURE_COOLDOWN_SECONDS}"
          fi
          continue
        }

        # Tunnel was live and has now exited — immediately try a new one.
        wait "${TUNNEL_PID}"
        TUNNEL_PID=""
        TUNNEL_CONNECTED_AND_DIED=1
        echo "Cloudflare quick tunnel exited; requesting a new tunnel URL..." >&2
        write_offline_config
        if ! backend_ready; then
          echo "Backend not responding after quick tunnel exit; waiting up to 60s..." >&2
          for _ in {1..30}; do backend_ready && break; sleep 2; done
        fi
        if ! backend_ready; then
          echo "Backend did not recover; exiting so systemd can restart cleanly." >&2
          exit 1
        fi
        break  # break inner for-loop; outer while-true retries immediately
      fi

      if (( attempt < MAX_TUNNEL_START_ATTEMPTS )); then
        retry_delay="$(tunnel_retry_delay "${attempt}")"
        echo "Retrying Cloudflare quick tunnel startup in ${retry_delay}s..."
        sleep "${retry_delay}"
      fi
    done

    # If we exhausted all attempts without ever connecting, pause before retrying.
    if (( !TUNNEL_CONNECTED_AND_DIED )); then
      echo "Exceeded Cloudflare quick tunnel startup attempts; waiting 300s before full retry..." >&2
      publish_offline_config
      sleep 300
    fi
  done
fi

publish_offline_config
echo "Tunnel provider not configured or all retry paths exhausted." >&2
exit 1
