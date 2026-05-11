#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${1:-http://127.0.0.1:8788}"
DB_NAME="${GALLERY_DB_SCHEMA:-image_gallery}"

echo "Prewarming thumbnails from $DB_NAME via $BASE_URL"

ids="$(sudo mariadb -N "$DB_NAME" -e "
SELECT id
FROM media_items
WHERE media_kind='image'
  AND (deleted_at IS NULL OR deleted_at = '0000-00-00 00:00:00')
ORDER BY id DESC;
" 2>/dev/null || sudo mariadb -N "$DB_NAME" -e "
SELECT id
FROM media_items
WHERE media_kind='image'
ORDER BY id DESC;
")"

count=0
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  count=$((count + 1))
  printf '[%s] thumb media_id=%s\n' "$count" "$id"
  curl -fsS "$BASE_URL/api/media/$id/thumb?w=520" -o /dev/null || true
done <<< "$ids"

echo "Done. Requested $count thumbnails."
