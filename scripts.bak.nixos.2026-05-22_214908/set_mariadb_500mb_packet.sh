#!/usr/bin/env bash
set -euo pipefail

# Raises MariaDB max_allowed_packet for Image Gallery 500MB uploads.
# Run on the Zorin host where MariaDB is installed:
#   sudo bash scripts/set_mariadb_500mb_packet.sh

CONF_DIR="/etc/mysql/mariadb.conf.d"
CONF_FILE="$CONF_DIR/99-image-gallery-packet.cnf"
PACKET_VALUE="512M"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash scripts/set_mariadb_500mb_packet.sh" >&2
  exit 1
fi

mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<CNF
[mysqld]
max_allowed_packet=$PACKET_VALUE

[client]
max_allowed_packet=$PACKET_VALUE
CNF

systemctl restart mariadb
mysql -NBe "SHOW VARIABLES LIKE 'max_allowed_packet';" || true

echo "MariaDB max_allowed_packet configured at $PACKET_VALUE. Restart the image_gallery container next."
