#!/usr/bin/env bash
set -Eeuo pipefail
kit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(git -C "$kit" rev-parse --show-toplevel)
image=${1:?Usage: bash build.sh IMAGE_TAG}
cd "$kit"
sha256sum -c SHA256SUMS
mapfile -t upstream < <(python3 - <<'PY'
import json,re
m=json.load(open('upstream.json'))
assert re.fullmatch(r'v[0-9A-Za-z._-]+',m['version'])
assert re.fullmatch(r'[0-9a-f]{40}',m['commit'])
print(m['version']);print(m['commit'])
PY
)
[[ ${#upstream[@]} == 2 ]]
version=${upstream[0]}
base=${upstream[1]}
git -C "$source_dir" merge-base --is-ancestor "$base" HEAD
[[ $(git -C "$source_dir" rev-parse "${version}^{commit}") == "$base" ]]
git -C "$source_dir" diff --exit-code
git -C "$source_dir" diff --cached --exit-code
mkdir -p receipts
printf '%s\n' "${version}-local-refund1" > "$source_dir/VERSION"
bash "$kit/verify.sh" "$source_dir"
docker build --progress=plain --platform linux/amd64 \
  --label "local.new-api.upstream=$version" --label "local.new-api.base=$base" \
  --label 'local.new-api.patch=refund-atomic-v1' \
  --label "org.opencontainers.image.source=${IMAGE_SOURCE:-https://github.com/xdujiang/new-api}" \
  --label "org.opencontainers.image.revision=$(git -C "$source_dir" rev-parse HEAD)" \
  -t "$image" "$source_dir" 2>&1 | tee "$kit/receipts/build.log"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
printf '%s\n' "$image_id" > receipts/verified-image-id
printf 'image=%s\nimage_id=%s\nbase=%s\nupstream=%s\n' "$image" "$image_id" "$base" "$version" > receipts/build-info.txt
echo "Built and verified: $image ($image_id)"
