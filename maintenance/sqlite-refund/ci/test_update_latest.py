"""Validate public updater provenance and download failures without Docker."""
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("updater", pathlib.Path(__file__).resolve().parents[1] / "update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class PublicUpdaterTests(unittest.TestCase):
    def test_only_successful_build_of_image_revision_is_accepted(self):
        run = {"id": 123, "head_sha": "a" * 40, "head_repository": {"full_name": "xdujiang/new-api"}, "path": ".github/workflows/sqlite-refund-build.yml", "head_branch": "sqlite-refund-rc51", "event": "push", "status": "completed", "conclusion": "success"}
        with patch.object(updater, "download", return_value=json.dumps({"workflow_runs": [run]}).encode()):
            self.assertEqual(updater.verified_build("a" * 40)["id"], 123)
        for field, value in [("head_sha", "b" * 40), ("head_repository", {"full_name": "other/new-api"}), ("event", "pull_request"), ("conclusion", "failure"), ("status", "in_progress"), ("path", ".github/workflows/other.yml"), ("head_branch", "main")]:
            with self.subTest(field=field), patch.object(updater, "download", return_value=json.dumps({"workflow_runs": [{**run, field: value}]}).encode()):
                with self.assertRaises(ValueError):
                    updater.verified_build("a" * 40)

    def test_pinned_kit_and_checksums(self):
        files = {"deploy.sh": b"deploy", "rollback.sh": b"rollback", "upstream.json": b"{}"}
        manifest = "".join(hashlib.sha256(value).hexdigest() + "  " + name + "\n" for name, value in files.items()).encode()

        def fetch(url):
            self.assertIn("/" + "a" * 40 + "/maintenance/sqlite-refund/", url)
            return manifest if url.endswith("/SHA256SUMS") else files[url.rsplit("/", 1)[1]]

        with tempfile.TemporaryDirectory() as directory, patch.object(updater, "download", side_effect=fetch):
            updater.download_kit("a" * 40, pathlib.Path(directory))
            self.assertEqual((pathlib.Path(directory) / "deploy.sh").read_bytes(), b"deploy")
        files["deploy.sh"] = b"tampered"
        with tempfile.TemporaryDirectory() as directory, patch.object(updater, "download", side_effect=fetch):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                updater.download_kit("a" * 40, pathlib.Path(directory))
            self.assertFalse((pathlib.Path(directory) / "deploy.sh").exists())

    def test_manifest_cannot_escape_release_directory(self):
        for path in ["../deploy.sh", "/root/deploy.sh", "ci/../../deploy.sh", "ci\\deploy.sh"]:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                manifest = ("a" * 64 + "  " + path + "\n").encode()
                with patch.object(updater, "download", return_value=manifest), self.assertRaises(ValueError):
                    updater.download_kit("a" * 40, pathlib.Path(directory))

    def test_registry_image_requires_expected_source_and_immutable_reference(self):
        image = {"Id": "sha256:" + "1" * 64, "Architecture": "amd64", "Os": "linux", "RepoDigests": [updater.IMAGE_NAME + "@sha256:" + "2" * 64], "Config": {"Labels": {"org.opencontainers.image.source": "https://github.com/xdujiang/new-api", "org.opencontainers.image.revision": "a" * 40, "local.new-api.patch": "refund-atomic-v1"}}}
        self.assertEqual(updater.checked_image(image)[0], "a" * 40)
        for field, value in [("RepoDigests", []), ("Architecture", "arm64"), ("Config", {"Labels": {"org.opencontainers.image.source": "https://github.com/other/new-api"}})]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                updater.checked_image({**image, field: value})


if __name__ == "__main__":
    unittest.main()
