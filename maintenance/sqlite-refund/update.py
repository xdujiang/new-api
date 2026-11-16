#!/usr/bin/env python3
"""Update the existing VPS from public latest after verifying its build."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

REPOSITORY = "xdujiang/new-api"
IMAGE_NAME = "ghcr.io/xdujiang/new-api-local"
KIT_PATH = "maintenance/sqlite-refund"


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "new-api-public-updater"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def verified_build(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Image has no valid source revision")
    query = urllib.parse.urlencode({"head_sha": revision, "status": "success", "per_page": 50})
    data = json.loads(download(f"https://api.github.com/repos/{REPOSITORY}/actions/runs?{query}"))
    for run in data["workflow_runs"]:
        if (
            run["head_sha"] == revision
            and run["head_repository"]["full_name"] == REPOSITORY
            and run["path"] == ".github/workflows/sqlite-refund-build.yml"
            and run["head_branch"].startswith("sqlite-refund-")
            and run["event"] in {"push", "workflow_dispatch"}
            and run["status"] == "completed"
            and run["conclusion"] == "success"
        ):
            if not isinstance(run["id"], int) or run["id"] <= 0:
                raise ValueError("Invalid build ID")
            return run
    raise ValueError("No completed successful build matches latest. Wait for Actions to finish and retry.")


def download_kit(revision, destination):
    base = f"https://raw.githubusercontent.com/{REPOSITORY}/{revision}/{KIT_PATH}"
    manifest = download(base + "/SHA256SUMS")
    entries = []
    for line in manifest.decode("utf-8").splitlines():
        digest, name = line.split("  ", 1)
        path = pathlib.PurePosixPath(name)
        if (
            not re.fullmatch(r"[0-9a-f]{64}", digest)
            or path.is_absolute()
            or ".." in path.parts
            or "\\" in name
            or not path.parts
            or name != path.as_posix()
        ):
            raise ValueError("Invalid deployment manifest path or checksum")
        entries.append((digest, name))
    names = [name for _, name in entries]
    if len(names) != len(set(names)) or not {"deploy.sh", "rollback.sh", "upstream.json"} <= set(names):
        raise ValueError("Incomplete or duplicate deployment manifest")
    for digest, name in entries:
        content = download(base + "/" + urllib.parse.quote(name, safe="/"))
        if hashlib.sha256(content).hexdigest() != digest:
            raise ValueError(f"Deployment checksum mismatch: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    (destination / "SHA256SUMS").write_bytes(manifest)


def checked_image(image):
    labels = image["Config"].get("Labels") or {}
    if image["Architecture"] != "amd64" or image["Os"] != "linux":
        raise ValueError("Expected linux/amd64 image")
    if labels.get("org.opencontainers.image.source") != f"https://github.com/{REPOSITORY}":
        raise ValueError("Unexpected image source")
    if labels.get("local.new-api.patch") != "refund-atomic-v1":
        raise ValueError("Image is missing the expected refund patch label")
    revision = labels.get("org.opencontainers.image.revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid source revision")
    references = [d for d in image.get("RepoDigests", []) if re.fullmatch(re.escape(IMAGE_NAME) + r"@sha256:[0-9a-f]{64}", d)]
    if len(references) != 1 or not re.fullmatch(r"sha256:[0-9a-f]{64}", image["Id"]):
        raise ValueError("Image must have exactly one immutable registry reference")
    return revision, references[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upgrade", action="store_true", help="Cross-version migration has already been rehearsed")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError("Run as root on the Docker server")
    for tool in ("docker", "bash", "curl", "tar", "sha256sum"):
        if not shutil.which(tool):
            raise ValueError(f"Required command not found: {tool}")
    import fcntl

    os.umask(0o077)
    # Keep the lock until the child deployment process exits.
    with open("/run/lock/new-api-public-update.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another public-image update is already running") from error
        subprocess.run(["docker", "pull", IMAGE_NAME + ":latest"], check=True)
        image = json.loads(subprocess.check_output(["docker", "image", "inspect", IMAGE_NAME + ":latest"]))[0]
        revision, reference = checked_image(image)
        build = verified_build(revision)
        current = json.loads(subprocess.check_output(["docker", "inspect", "new-api"]))[0]
        if current["Image"] == image["Id"] and current["State"]["Running"]:
            print(f"Already running latest: {reference}", flush=True)
            return
        directory = pathlib.Path("/root/new-api-releases") / f"{build['id']}-{time.time_ns()}"
        kit = directory / "kit"
        kit.mkdir(parents=True, exist_ok=False)
        download_kit(revision, kit)
        upstream = json.loads((kit / "upstream.json").read_text())
        labels = image["Config"]["Labels"]
        if upstream["version"] != labels.get("local.new-api.upstream") or upstream["commit"] != labels.get("local.new-api.base"):
            raise ValueError("Image and deployment source baselines do not match")
        receipt = {"image": reference, "image_id": image["Id"], "maintenance_commit": revision, "build_run_id": build["id"]}
        (directory / "verification.json").write_text(json.dumps(receipt, indent=2) + "\n")
        (kit / "receipts").mkdir()
        # Issue the deployment receipt only after matching the trusted registry,
        # successful build, pinned source manifest, and baseline labels.
        (kit / "receipts" / "verified-image-id").write_text(image["Id"] + "\n")
        print(f"Verified build: https://github.com/{REPOSITORY}/actions/runs/{build['id']}", flush=True)
        print(f"Candidate: {reference}", flush=True)
        print(f"Deployment files: {kit}", flush=True)
        command = ["bash", str(kit / "deploy.sh"), image["Id"]]
        if args.upgrade:
            command.append("--upgrade")
        subprocess.run(command, check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Update stopped: {error}")
