#!/usr/bin/env bash
set -Eeuo pipefail
kit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$kit/update.sh"
# The caller provides a scratch directory; tests never touch production paths.
scratch=${1:?Usage: bash test-update-latest.sh SCRATCH_DIRECTORY}
mkdir -p "$scratch/fixtures" "$scratch/good" "$scratch/tampered" "$scratch/unsafe"
fixtures=$(cd "$scratch/fixtures" && pwd)
revision=$(printf 'a%.0s' {1..40})
digest=$(printf '1%.0s' {1..64})
expect_failure() {
  if "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi
}
jq -n --arg revision "$revision" --arg digest "$digest" '[{
  Id:("sha256:"+$digest), Architecture:"amd64", Os:"linux",
  RepoDigests:[("ghcr.io/xdujiang/new-api-local@sha256:"+$digest)],
  Config:{Labels:{"org.opencontainers.image.source":"https://github.com/xdujiang/new-api",
    "org.opencontainers.image.revision":$revision,"local.new-api.patch":"refund-atomic-v1",
    "local.new-api.base":$revision,"local.new-api.upstream":"v1.0.0-rc.51"}}
}]' > "$fixtures/image.json"
check_image "$fixtures/image.json" >/dev/null
jq '.[0].Config.Labels["org.opencontainers.image.source"]="https://github.com/other/new-api"' "$fixtures/image.json" > "$fixtures/wrong-image.json"
expect_failure check_image "$fixtures/wrong-image.json" >/dev/null 2>&1
jq -n --arg revision "$revision" '{workflow_runs:[{id:123,head_sha:$revision,
  head_repository:{full_name:"xdujiang/new-api"},path:".github/workflows/sqlite-refund-build.yml",
  head_branch:"sqlite-refund-rc51",event:"push",status:"completed",conclusion:"success"}]}' > "$fixtures/runs.json"
fetch() {
  case $1 in
    https://api.github.com/*) cat "$fixtures/runs.json" ;;
    "https://raw.githubusercontent.com/xdujiang/new-api/$revision/maintenance/sqlite-refund/"*) cat "$fixtures/${1##*/}" ;;
    *) echo 'Unexpected download URL' >&2; return 1 ;;
  esac
}
verified_build "$revision" | jq -e '.id == 123' >/dev/null
jq '.workflow_runs[0].event="pull_request"' "$fixtures/runs.json" > "$fixtures/changed.json"
mv "$fixtures/changed.json" "$fixtures/runs.json"
expect_failure verified_build "$revision" >/dev/null 2>&1
printf 'deploy\n' > "$fixtures/deploy.sh"
printf 'rollback\n' > "$fixtures/rollback.sh"
printf '{}\n' > "$fixtures/upstream.json"
(cd "$fixtures"; sha256sum --text deploy.sh rollback.sh upstream.json) > "$fixtures/SHA256SUMS"
download_kit "$revision" "$scratch/good"
cmp "$fixtures/deploy.sh" "$scratch/good/deploy.sh"
printf 'tampered\n' > "$fixtures/deploy.sh"
expect_failure download_kit "$revision" "$scratch/tampered" >/dev/null 2>&1
printf '%s  ../escaped.sh\n' "$digest" > "$fixtures/SHA256SUMS"
expect_failure download_kit "$revision" "$scratch/unsafe" >/dev/null 2>&1
[[ ! -e "$scratch/escaped.sh" ]]

# Environment export must reject multiline values and preserve literal secrets.
printf '%s\n' '[{"Config":{"Env":["TZ=Asia/Shanghai","VALUE=a=b$literal"]}}]' > "$fixtures/container.json"
env_filter='.[0].Config.Env // [] | all(.[]; type == "string" and (contains("\n") or contains("\r") | not))'
jq -e "$env_filter" "$fixtures/container.json" >/dev/null
jq -r '.[0].Config.Env // [] | .[]' "$fixtures/container.json" > "$fixtures/container.env"
grep -Fxq 'VALUE=a=b$literal' "$fixtures/container.env"
jq '.[0].Config.Env += ["BAD=line1\nline2"]' "$fixtures/container.json" > "$fixtures/multiline.json"
expect_failure jq -e "$env_filter" "$fixtures/multiline.json" >/dev/null 2>&1
echo 'Shell updater provenance, checksums, path safety and environment checks passed'
