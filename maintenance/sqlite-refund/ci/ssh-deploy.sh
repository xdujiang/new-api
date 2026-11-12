#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$BUILD_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]
[[ "$SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'Use an IPv4 address or hostname'; exit 1; }
port=${SSH_PORT:-22}
[[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port > 0 && 10#$port < 65536 ))
[[ -n "$SSH_PRIVATE_KEY" && -n "$SSH_KNOWN_HOSTS" ]]
auth_dir=$(mktemp -d)
trap 'rm -f -- "$auth_dir/key" "$auth_dir/known_hosts"; rmdir -- "$auth_dir"' EXIT
printf '%s\n' "$SSH_PRIVATE_KEY" > "$auth_dir/key"
printf '%s\n' "$SSH_KNOWN_HOSTS" > "$auth_dir/known_hosts"
chmod 600 "$auth_dir/key" "$auth_dir/known_hosts"
opts=(-i "$auth_dir/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$auth_dir/known_hosts" -o ConnectTimeout=15)
target="root@$SSH_HOST"
remote="/root/new-api-releases/$BUILD_RUN_ID-$GITHUB_RUN_ID"
ssh -p "$port" "${opts[@]}" "$target" "umask 077; mkdir -p '$remote'"
scp -P "$port" "${opts[@]}" release/release-bundle.tar.gz "$target:$remote/release-bundle.tar.gz"
ssh -p "$port" "${opts[@]}" "$target" "tar -xzf '$remote/release-bundle.tar.gz' -C '$remote'"
# Use the artifact's scripts from the tested build, not possibly newer checkout scripts.
ssh -p "$port" "${opts[@]}" "$target" "bash '$remote/kit/ci/remote-deploy.sh' '$remote' '$ALLOW_UPGRADE'"
