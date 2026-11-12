#!/usr/bin/env bash
set -Eeuo pipefail
kit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd -- "${1:?Usage: bash verify.sh SOURCE_DIRECTORY}" && pwd)
export PATCH_SOURCE="$source_dir"
export GO_BUILDER
GO_BUILDER=$(awk '$1=="FROM" && $2 ~ /^golang:/ {print $2; exit}' "$source_dir/Dockerfile")
[[ -n "$GO_BUILDER" ]] || { echo 'Cannot identify upstream Go builder'; exit 1; }
mkdir -p "$kit/receipts"
project="newapi-refund-test-$$"
compose=(docker compose -p "$project" -f "$kit/compose.verify.yaml")
cleanup() { "${compose[@]}" down --volumes --remove-orphans; }
trap cleanup EXIT
"${compose[@]}" up -d --wait mysql postgres
"${compose[@]}" run --build --rm tests 2>&1 | tee "$kit/receipts/verification-$(date +%Y%m%d-%H%M%S).log"
