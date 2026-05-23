#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/nixos/configuration.nix"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found. This script is for NixOS." >&2
  exit 1
fi

sudo cp -a "$CONFIG" "$CONFIG.bak.image-gallery-deps.$(date +%F_%H%M%S)"

add_pkg() {
  local pkg="$1"
  grep -q "^[[:space:]]*$pkg[[:space:]]*$" "$CONFIG" || \
    sudo sed -i "/environment.systemPackages = with pkgs; \[/a\\    $pkg" "$CONFIG"
}

# Core runtime/tools used by Image Gallery live scripts.
add_pkg bash
add_pkg git
add_pkg gh
add_pkg cloudflared
add_pkg curl
add_pkg wget
add_pkg jq
add_pkg dnsutils
add_pkg iproute2
add_pkg procps
add_pkg findutils
add_pkg coreutils
add_pkg gnugrep
add_pkg gnused
add_pkg gawk
add_pkg rsync
add_pkg python311
add_pkg python311Packages.pip
add_pkg nodejs
add_pkg mariadb

# Useful for image processing / gallery maintenance scripts.
add_pkg imagemagick
add_pkg ffmpeg
add_pkg exiftool

# Remove old/renamed package names if any slipped in.
sudo sed -i '/^[[:space:]]*python311Full[[:space:]]*$/d' "$CONFIG"

# Ensure flakes/new nix command are available for profile/debug workflows.
grep -q 'nix.settings.experimental-features' "$CONFIG" || sudo sed -i '/system.stateVersion/a\
\
  nix.settings.experimental-features = [ "nix-command" "flakes" ];' "$CONFIG"

echo "Added/verified Image Gallery NixOS dependencies in $CONFIG"
echo "Next: sudo nixos-rebuild dry-build && sudo nixos-rebuild switch"
