#!/usr/bin/env bash
set -Eeuo pipefail
release=$(cd -- "${1:?Release directory required}" && pwd)
[[ "$release" =~ ^/root/new-api-releases/[0-9]+-[0-9]+$ ]] || exit 1
case "$(docker info --format '{{.Architecture}}')" in
  amd64|x86_64) ;;
  *) echo 'This workflow currently builds linux/amd64 only'; exit 1 ;;
esac
cd "$release/kit"
sha256sum -c SHA256SUMS
mapfile -t values < <(python3 - "$release/release.json" <<'PY'
import json,re,sys
m=json.load(open(sys.argv[1]))
assert re.fullmatch(r'ghcr\.io/[a-z0-9_.-]+/new-api-local@sha256:[0-9a-f]{64}',m['image'])
assert re.fullmatch(r'sha256:[0-9a-f]{64}',m['image_id'])
print(m['image'])
print(m['image_id'])
PY
)
[[ ${#values[@]} == 2 ]]
image=${values[0]}
expected=${values[1]}
# GHCR read-only credentials are provisioned on the server, not passed through CI.
docker pull "$image"
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$expected" ]]
[[ $(cat receipts/verified-image-id) == "$expected" ]]
if [[ ${2:-false} == true ]]; then
  bash deploy.sh "$image" --upgrade
else
  bash deploy.sh "$image"
fi
