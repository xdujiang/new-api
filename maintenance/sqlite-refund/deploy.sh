#!/usr/bin/env bash
# runtime: bash-jq-v1
set -Eeuo pipefail
umask 077
kit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image=${1:?Usage: bash deploy.sh IMAGE}
[[ $(id -u) == 0 ]] || { echo 'Run as root on the Docker server'; exit 1; }
for tool in docker jq curl tar; do command -v "$tool" >/dev/null; done
image_id=$(docker image inspect --format '{{.Id}}' "$image")
[[ -f "$kit/receipts/verified-image-id" && $(cat "$kit/receipts/verified-image-id") == "$image_id" ]] || { echo 'Image has no matching build/test receipt. Run build.sh first.'; exit 1; }
upstream=$(docker image inspect --format '{{index .Config.Labels "local.new-api.upstream"}}' "$image")
current=$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:28659/api/status | jq -er '.data.version | select(type == "string" and length > 0)')
cross_version=0
if [[ "$current" != "$upstream" && "$current" != "$upstream-local-refund1" ]]; then
  [[ ${2:-} == --upgrade ]] || { echo "Running $current, candidate based on $upstream. Read the cross-version upgrade procedure, stage the migration, then use --upgrade."; exit 1; }
  cross_version=1
fi
docker inspect new-api | jq -e '
  .[0] | (.Mounts | length == 1) and
  (.Mounts[0] | .Destination == "/data" and .Type == "bind" and .Source == "/root/new-api/data") and
  (.HostConfig.PortBindings == {"3000/tcp":[{"HostIp":"127.0.0.1","HostPort":"28659"}]}) and
  (.HostConfig.NetworkMode == "default" or .HostConfig.NetworkMode == "bridge") and
  (.State.Running == true)
' >/dev/null || { echo 'Unexpected container mounts, ports, network or state'; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S)
state="/root/new-api/backups/$stamp"
mkdir -p "$state"
chmod 700 "$state"
old="new-api-before-$stamp"
docker inspect new-api > "$state/container.json"
jq -e '.[0].Config.Env // [] | all(.[]; type == "string" and (contains("\n") or contains("\r") | not))' "$state/container.json" >/dev/null || { echo 'Multiline env requires manual deployment'; exit 1; }
jq -r '.[0].Config.Env // [] | .[]' "$state/container.json" > "$state/container.env"
printf '%s\n' "$old" > "$state/old-name"
printf '%s\n' "$image_id" > "$state/new-image-id"
printf '%s\n' "$upstream" > "$state/upstream-version"
printf '%s\n' "$cross_version" > "$state/cross-version"
switched=0
recover() {
  rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 )); then
    if (( switched && cross_version )); then
      echo "Cross-version deployment failed; database may have migrated. No automatic rollback. State: $state"
      docker update --restart=no new-api >/dev/null 2>&1 || true
      docker stop -t 60 new-api >/dev/null 2>&1 || true
      echo 'Keep clients stopped. Follow README to restore the stopped backup and original container.'
    elif (( switched )); then
      echo "Deployment failed; restoring original container. Backup: $state"
      bash "$kit/rollback.sh" "$state" || echo "Automatic rollback failed; inspect $state and restore manually."
    else
      docker update --restart unless-stopped new-api >/dev/null || true
      docker start new-api >/dev/null || true
    fi
  fi
  exit "$rc"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo 'Stop clients and incoming requests during the maintenance window.'
docker update --restart=no new-api >/dev/null
docker stop -t 60 new-api
tar -czf "$state/data.tar.gz" -C /root/new-api data
tar -tzf "$state/data.tar.gz" >/dev/null
docker rename new-api "$old"
switched=1
docker run --name new-api -d --restart unless-stopped \
  -p 127.0.0.1:28659:3000 --env-file "$state/container.env" \
  -v /root/new-api/data:/data "$image_id"
healthy=0
for ((attempt=0; attempt<30; attempt++)); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:28659/api/status | \
      jq -e --arg expected "$upstream-local-refund1" '.success == true and .data.version == $expected' >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 2
done
(( healthy )) || { echo 'Candidate did not pass startup check'; exit 1; }
docker logs --since 2m --tail 80 new-api > "$state/startup.log" 2>&1
echo "Startup check passed. Backup and rollback state: $state"
echo "Rollback: bash '$kit/rollback.sh' '$state'"
echo 'Now verify a successful request and a controlled failed-request refund with a test account.'
