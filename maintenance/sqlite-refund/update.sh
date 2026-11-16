#!/usr/bin/env bash
# Public VPS updater; runtime dependencies: Bash, Docker, curl, jq, flock, tar.
set -Eeuo pipefail

repository=xdujiang/new-api
image_name=ghcr.io/xdujiang/new-api-local

fail() { echo "Update stopped: $*" >&2; return 1; }

fetch() {
  curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 --retry 2 "$1"
}

check_image() {
  jq -e --arg source "https://github.com/$repository" --arg prefix "$image_name@sha256:" '
    .[0] as $i | ($i.Config.Labels // {}) as $l |
    [($i.RepoDigests // [])[] | select(startswith($prefix)) | select(test("@sha256:[0-9a-f]{64}$"))] as $refs |
    if $i.Architecture == "amd64" and $i.Os == "linux" and
       $l["org.opencontainers.image.source"] == $source and
       $l["local.new-api.patch"] == "refund-atomic-v1" and
       (($l["org.opencontainers.image.revision"] // "") | test("^[0-9a-f]{40}$")) and
       (($l["local.new-api.base"] // "") | test("^[0-9a-f]{40}$")) and
       (($l["local.new-api.upstream"] // "") | test("^v[0-9A-Za-z._-]+$")) and
       ($i.Id | test("^sha256:[0-9a-f]{64}$")) and ($refs | length == 1)
    then {image:$refs[0], image_id:$i.Id, maintenance_commit:$l["org.opencontainers.image.revision"],
          upstream_version:$l["local.new-api.upstream"], upstream_commit:$l["local.new-api.base"]}
    else error("Unexpected image source, architecture, labels or immutable reference") end
  ' "$1"
}

verified_build() {
  local revision=$1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { fail 'Invalid source revision'; return 1; }
  fetch "https://api.github.com/repos/$repository/actions/runs?head_sha=$revision&status=success&per_page=50" |
    jq -e --arg revision "$revision" --arg repository "$repository" '
      [.workflow_runs[] | select(
        .head_sha == $revision and .head_repository.full_name == $repository and
        .path == ".github/workflows/sqlite-refund-build.yml" and
        (.head_branch | startswith("sqlite-refund-")) and
        (.event == "push" or .event == "workflow_dispatch") and
        .status == "completed" and .conclusion == "success" and
        (.id | type == "number" and . > 0 and floor == .)
      )] | first // error("No completed successful build matches latest; wait for Actions and retry")
    '
}

download_kit() {
  local revision=$1 destination=$2 base line digest name
  local -A seen=()
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { fail 'Invalid source revision'; return 1; }
  base="https://raw.githubusercontent.com/$repository/$revision/maintenance/sqlite-refund"
  fetch "$base/SHA256SUMS" > "$destination/SHA256SUMS" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9_./-]+)$ ]] || { fail 'Invalid deployment manifest'; return 1; }
    digest=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    if [[ "$name" == /* || "$name" == */ || "$name" == *//* || "/$name/" == */../* || "/$name/" == */./* || -n ${seen[$name]:-} ]]; then
      fail 'Unsafe or duplicate deployment manifest path'; return 1
    fi
    seen[$name]=1
    mkdir -p -- "$(dirname -- "$destination/$name")" || return 1
    fetch "$base/$name" > "$destination/$name" || return 1
    printf '%s  %s\n' "$digest" "$destination/$name" | sha256sum -c - >/dev/null || return 1
  done < "$destination/SHA256SUMS"
  [[ -n ${seen[deploy.sh]:-} && -n ${seen[rollback.sh]:-} && -n ${seen[upstream.json]:-} ]] || fail 'Incomplete deployment manifest'
}

update_main() {
  local upgrade=0 tool temporary revision reference image_id run_id kit release
  case ${1:-} in
    '') [[ $# == 0 ]] || return 1 ;;
    --upgrade) [[ $# == 1 ]] || return 1; upgrade=1 ;;
    -h|--help) echo 'Usage: bash update.sh [--upgrade]'; return 0 ;;
    *) fail 'Usage: bash update.sh [--upgrade]'; return 1 ;;
  esac
  [[ $(id -u) == 0 ]] || { fail 'Run as root on the Docker server'; return 1; }
  for tool in docker curl jq flock tar sha256sum; do
    command -v "$tool" >/dev/null || { fail "Required command not found: $tool"; return 1; }
  done
  umask 077
  exec 9>/run/lock/new-api-public-update.lock
  flock -n 9 || { fail 'Another public-image update is running'; return 1; }
  temporary=$(mktemp -d)
  update_temporary=$temporary
  trap 'rm -rf -- "$update_temporary"' EXIT
  docker pull "$image_name:latest"
  docker image inspect "$image_name:latest" > "$temporary/image.json"
  check_image "$temporary/image.json" > "$temporary/verified-image.json"
  revision=$(jq -er '.maintenance_commit' "$temporary/verified-image.json")
  reference=$(jq -er '.image' "$temporary/verified-image.json")
  image_id=$(jq -er '.image_id' "$temporary/verified-image.json")
  verified_build "$revision" > "$temporary/build.json"
  run_id=$(jq -er '.id' "$temporary/build.json")
  docker inspect new-api > "$temporary/current.json"
  if jq -e --arg image_id "$image_id" '.[0] | .Image == $image_id and .State.Running == true' "$temporary/current.json" >/dev/null; then
    echo "Already running latest: $reference"
    rm -rf -- "$temporary"; trap - EXIT
    return 0
  fi
  release="/root/new-api-releases/$run_id-$(date +%s%N)"
  kit="$release/kit"
  mkdir -p -- "$kit"
  download_kit "$revision" "$kit"
  grep -Fxq '# runtime: bash-jq-v1' "$kit/deploy.sh" || { fail 'Latest still has the older deployment runtime. Wait for the shell build to finish and retry.'; return 1; }
  jq -e --slurpfile image "$temporary/verified-image.json" '
    .version == $image[0].upstream_version and .commit == $image[0].upstream_commit
  ' "$kit/upstream.json" >/dev/null || { fail 'Image and deployment baselines differ'; return 1; }
  jq --argjson run_id "$run_id" '. + {build_run_id:$run_id}' "$temporary/verified-image.json" > "$release/verification.json"
  mkdir "$kit/receipts"
  printf '%s\n' "$image_id" > "$kit/receipts/verified-image-id"
  echo "Verified build: https://github.com/$repository/actions/runs/$run_id"
  echo "Candidate: $reference"
  echo "Deployment files: $kit"
  if (( upgrade )); then
    bash "$kit/deploy.sh" "$image_id" --upgrade
  else
    bash "$kit/deploy.sh" "$image_id"
  fi
  rm -rf -- "$temporary"; trap - EXIT
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  update_main "$@"
fi
