#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root'; exit 1; }
state=$(cd -- "${1:?Usage: bash rollback.sh BACKUP_STATE_DIRECTORY}" && pwd)
[[ "$state" == /root/new-api/backups/* && -f "$state/old-name" ]] || { echo 'Unexpected rollback state'; exit 1; }
if [[ -f "$state/cross-version" && $(cat "$state/cross-version") == 1 ]]; then
  [[ ${2:-} == --data-restored ]] || { echo 'Cross-version rollback requires restoring the stopped database backup first. Follow README, then pass --data-restored.'; exit 1; }
fi
old=$(cat "$state/old-name")
[[ "$old" =~ ^new-api-before-[0-9]{8}-[0-9]{6}$ ]] || exit 1
docker inspect "$old" >/dev/null
if docker inspect new-api >/dev/null 2>&1; then
  actual=$(docker inspect --format '{{.Image}}' new-api)
  [[ "$actual" == $(cat "$state/new-image-id") ]] || { echo 'Current container differs from this deployment. Refusing rollback.'; exit 1; }
  docker update --restart=no new-api >/dev/null
  docker stop -t 60 new-api
  # Preserve the failed container for diagnosis; do not delete containers or data.
  docker rename new-api "new-api-failed-$(date +%Y%m%d-%H%M%S)"
fi
docker rename "$old" new-api
docker update --restart unless-stopped new-api >/dev/null
docker start new-api
echo 'Original container restored. Database was retained, not overwritten by the backup.'
echo 'Check http://127.0.0.1:28659/api/status and container logs.'
