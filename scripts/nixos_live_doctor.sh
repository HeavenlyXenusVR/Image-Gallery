#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8788}"
export PATH="/run/current-system/sw/bin:${HOME}/.nix-profile/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

echo "Image Gallery NixOS live doctor"
echo "Root: $ROOT_DIR"
echo "Port: $PORT"
echo

check_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf '[ok] %-12s %s\n' "$name" "$(command -v "$name")"
  else
    printf '[missing] %-12s\n' "$name"
  fi
}

for cmd in bash python3 git gh cloudflared curl jq ss systemctl node npm mariadb; do
  check_cmd "$cmd"
done

echo
cd "$ROOT_DIR"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[ok] git work tree"
  git remote -v | sed -n '1,4p'
else
  echo "[warn] not a git work tree"
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    echo "[ok] gh authenticated"
  else
    echo "[warn] gh is installed but not authenticated. Run: gh auth login"
  fi
fi

if git config user.email >/dev/null 2>&1 || git config --global user.email >/dev/null 2>&1; then
  echo "[ok] git identity configured"
else
  echo "[warn] git identity missing. Run: git config --global user.name 'HeavenlyXenusVR'; git config --global user.email 'heavenlyxenusvr@icloud.com'"
fi

[[ -f .env ]] && echo "[ok] .env exists" || echo "[warn] .env missing"
[[ -f requirements.txt ]] && echo "[ok] requirements.txt exists" || echo "[warn] requirements.txt missing"
[[ -f package.json ]] && echo "[ok] package.json exists" || echo "[warn] package.json missing"

echo
if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
  echo "[ok] local backend responding on :${PORT}/api/health"
elif curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
  echo "[warn] port :${PORT} responds, but /api/health did not return success"
else
  echo "[info] local backend not responding on :${PORT}"
fi

echo
if ss -ltnp | grep -q ":${PORT}"; then
  echo "[info] listener on :${PORT}:"
  ss -ltnp | grep ":${PORT}" || true
else
  echo "[info] no listener on :${PORT}"
fi
