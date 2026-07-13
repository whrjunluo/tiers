import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.managed_install import (
    InstallPaths,
    ManagedInstaller,
    Revision,
    latest_semver_tag,
    parse_semver_tag,
)


class SemverTagTests(unittest.TestCase):
    def test_parse_semver_tag_accepts_only_release_tags(self):
        self.assertEqual((0, 7, 0), parse_semver_tag("v0.7.0"))
        for tag in ("0.7.0", "v0.7", "v0.7.0-rc1", "v1.2.3.4", "release-v1.2.3"):
            with self.subTest(tag=tag):
                self.assertIsNone(parse_semver_tag(tag))

    def test_latest_semver_tag_uses_numeric_order(self):
        tags = ["v0.6.9", "v0.7.0", "v0.10.0", "v0.9.12", "v0.11.0-rc1"]
        self.assertEqual("v0.10.0", latest_semver_tag(tags))


class InstallPathsTests(unittest.TestCase):
    def test_defaults_follow_xdg_style_layout(self):
        paths = InstallPaths.from_env({}, home=Path("/tmp/example-home"))
        root = Path("/tmp/example-home/.local/share/dev-workflow")
        self.assertEqual(root, paths.install_root)
        self.assertEqual(root / "source.git", paths.source_git)
        self.assertEqual(root / "versions", paths.versions)
        self.assertEqual(root / "current", paths.current)
        self.assertEqual(root / "install.json", paths.state_file)
        self.assertEqual(root / "update.lock", paths.lock_dir)
        self.assertEqual(Path("/tmp/example-home/.local/bin"), paths.bin_dir)
        self.assertEqual(paths.bin_dir / "dev-workflow", paths.command_link)

    def test_environment_overrides_install_and_bin_roots(self):
        paths = InstallPaths.from_env(
            {
                "DEV_WORKFLOW_INSTALL_ROOT": "/managed/root",
                "DEV_WORKFLOW_BIN_DIR": "/managed/bin",
            },
            home=Path("/unused"),
        )
        self.assertEqual(Path("/managed/root"), paths.install_root)
        self.assertEqual(Path("/managed/bin/dev-workflow"), paths.command_link)


class ManagedRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.paths = InstallPaths.from_env(
            {
                "DEV_WORKFLOW_INSTALL_ROOT": str(self.root / "install"),
                "DEV_WORKFLOW_BIN_DIR": str(self.root / "bin"),
            },
            home=self.root,
        )

    def test_stable_and_edge_resolution_use_expected_refs(self):
        runner = mock.Mock()
        runner.side_effect = [
            "v0.6.9\nv0.7.0\nv0.7.0-rc1\n",
            "a" * 40 + "\n",
            "b" * 40 + "\n",
        ]
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git", runner=runner)

        stable = manager.resolve_revision("stable")
        edge = manager.resolve_revision("edge")

        self.assertEqual(Revision("stable", "refs/tags/v0.7.0", "a" * 40), stable)
        self.assertEqual(Revision("edge", "refs/remotes/origin/main", "b" * 40), edge)
        self.assertIn("refs/tags/v0.7.0^{commit}", runner.call_args_list[1].args[0])
        self.assertIn("refs/remotes/origin/main^{commit}", runner.call_args_list[2].args[0])

    def test_state_write_is_atomic_and_preserves_unknown_fields(self):
        self.paths.install_root.mkdir(parents=True)
        self.paths.state_file.write_text(
            json.dumps({"schema_version": 1, "future_key": {"keep": True}, "channel": "stable"}),
            encoding="utf-8",
        )
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")

        manager.write_state({"channel": "edge", "active_commit": "c" * 40})

        state = manager.load_state()
        self.assertEqual("edge", state["channel"])
        self.assertEqual("c" * 40, state["active_commit"])
        self.assertEqual({"keep": True}, state["future_key"])
        self.assertFalse(any(self.paths.install_root.glob(".install.json.*")))

    def test_ensure_repository_clones_once_then_fetches(self):
        runner = mock.Mock(return_value="")
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git", runner=runner)

        manager.ensure_repository()
        self.paths.source_git.mkdir(parents=True)
        manager.ensure_repository()

        clone = runner.call_args_list[0].args[0]
        fetch = runner.call_args_list[1].args[0]
        self.assertEqual("git", clone[0])
        self.assertIn("--bare", clone)
        self.assertEqual("git", fetch[0])
        self.assertIn("fetch", fetch)


if __name__ == "__main__":
    unittest.main()
