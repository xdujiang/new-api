#!/usr/bin/env python3
"""Package the tested kit, receipt and digest; never production configuration."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import tarfile

root = pathlib.Path.cwd()
stage = root / "release" / "stage"
stage.mkdir(parents=True, exist_ok=False)
kit = stage / "kit"
kit.mkdir()
for line in (root / "SHA256SUMS").read_text().splitlines():
    _, relative = line.split("  ", 1)
    source = root / relative
    destination = kit / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
shutil.copyfile(root / "SHA256SUMS", kit / "SHA256SUMS")
(kit / "receipts").mkdir()
receipt = (root / "receipts" / "verified-image-id").read_text().strip()
shutil.copyfile(root / "receipts" / "verified-image-id", kit / "receipts" / "verified-image-id")
tag = os.environ["IMAGE_TAG"]
image = json.loads(subprocess.check_output(["docker", "image", "inspect", tag]))[0]
assert image["Id"] == receipt
name = tag.rsplit(":", 1)[0]
digests = [d for d in image["RepoDigests"] if d.startswith(name + "@sha256:")]
assert len(digests) == 1
assert re.fullmatch(re.escape(name + "@sha256:") + "[0-9a-f]{64}", digests[0])
upstream = json.loads((root / "upstream.json").read_text())
metadata = {
    "image": digests[0],
    "image_id": receipt,
    "upstream_version": upstream["version"],
    "upstream_commit": upstream["commit"],
    "maintenance_commit": os.environ["GITHUB_SHA"],
    "build_run_id": os.environ["GITHUB_RUN_ID"],
}
(stage / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
with tarfile.open(root / "release" / "release-bundle.tar.gz", "w:gz") as archive:
    for path in sorted(stage.iterdir()):
        archive.add(path, arcname=path.name)
print(json.dumps(metadata, indent=2))
