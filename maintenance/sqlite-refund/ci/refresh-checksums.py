#!/usr/bin/env python3
"""Refresh the static kit manifest without including runtime data or secrets."""
import hashlib
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
excluded = {".git", "sources", "receipts", "release", ".ssh", "__pycache__"}
files = []
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if not path.is_file() or any(part in excluded for part in relative.parts):
        continue
    if path.name == "SHA256SUMS" or path.name == "container.json" or path.suffix in {".env", ".zip", ".gz", ".pyc"}:
        continue
    if path.is_symlink():
        raise ValueError(f"Unexpected symlink: {relative}")
    files.append((relative.as_posix(), path))
manifest = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + name + "\n" for name, path in sorted(files))
(root / "SHA256SUMS").write_text(manifest, encoding="utf-8", newline="\n")
print(f"Updated {len(files)} static file checksums")
