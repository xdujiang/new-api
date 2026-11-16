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
image=$(jq -er '.image | select(type == "string")' "$release/release.json")
expected=$(jq -er '.image_id | select(type == "string")' "$release/release.json")
[[ "$image" =~ ^ghcr\.io/[a-z0-9_.-]+/new-api-local@sha256:[0-9a-f]{64}$ ]]
[[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]]
# GHCR read-only credentials are provisioned on the server, not passed through CI.
docker pull "$image"
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$expected" ]]
[[ $(cat receipts/verified-image-id) == "$expected" ]]
if [[ ${2:-false} == true ]]; then
  bash deploy.sh "$image" --upgrade
else
  bash deploy.sh "$image"
fi
