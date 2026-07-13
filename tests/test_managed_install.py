import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.managed_install import (
    InstallPaths,
    ManagedInstaller,
    ManagedInstallError,
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


class CandidateAndActivationTests(unittest.TestCase):
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
        self.commit = "a" * 40
        self.revision = Revision("stable", "refs/tags/v0.7.0", self.commit)

    def make_candidate(self, name="candidate", version="0.7.0"):
        candidate = self.root / name
        for manifest in (
            ".codex-plugin/plugin.json",
            ".cursor-plugin/plugin.json",
            ".claude-plugin/plugin.json",
        ):
            path = candidate / manifest
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"version": version}), encoding="utf-8")
        for relative in (
            "bin/install-codex",
            "bin/install-cursor",
            "bin/install-trae",
            "bin/doctor",
            "bin/dev-workflow",
            "skills/dev-workflow/SKILL.md",
            "skills/external-agent/SKILL.md",
            "skills/grill-me/SKILL.md",
        ):
            path = candidate / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")
        return candidate

    def test_validate_candidate_requires_matching_manifests_and_commit(self):
        candidate = self.make_candidate()
        manager = ManagedInstaller(
            self.paths,
            "https://example.test/tiers.git",
            runner=mock.Mock(return_value=self.commit + "\n"),
        )
        self.assertEqual("0.7.0", manager.validate_candidate(candidate, self.revision))

        (candidate / ".cursor-plugin/plugin.json").write_text(
            json.dumps({"version": "0.6.0"}), encoding="utf-8"
        )
        with self.assertRaisesRegex(ManagedInstallError, "manifest versions"):
            manager.validate_candidate(candidate, self.revision)

    def test_validate_candidate_rejects_tag_version_and_required_file_mismatch(self):
        candidate = self.make_candidate()
        manager = ManagedInstaller(
            self.paths,
            "https://example.test/tiers.git",
            runner=mock.Mock(return_value=self.commit + "\n"),
        )
        wrong_tag = Revision("stable", "refs/tags/v0.8.0", self.commit)
        with self.assertRaisesRegex(ManagedInstallError, "tag version"):
            manager.validate_candidate(candidate, wrong_tag)

        (candidate / "skills/grill-me/SKILL.md").unlink()
        with self.assertRaisesRegex(ManagedInstallError, "required file"):
            manager.validate_candidate(candidate, self.revision)

    def test_lock_fails_immediately_when_an_update_is_in_progress(self):
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")
        self.paths.install_root.mkdir(parents=True)
        self.paths.lock_dir.mkdir()
        with self.assertRaisesRegex(ManagedInstallError, "already in progress"):
            with manager.update_lock():
                self.fail("contended lock must not be entered")

    def test_successful_activation_switches_current_and_writes_complete_state(self):
        candidate = self.make_candidate()
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")
        manager.validate_candidate = mock.Mock(return_value="0.7.0")
        manager.run_platform_installers = mock.Mock()
        manager.run_doctor = mock.Mock()

        state = manager.activate_candidate(candidate, self.revision, ["trae", "cursor", "codex"])

        self.assertEqual(candidate.resolve(), self.paths.current.resolve())
        self.assertEqual(1, state["schema_version"])
        self.assertEqual("stable", state["channel"])
        self.assertEqual(["codex", "cursor", "trae"], state["platforms"])
        self.assertEqual("refs/tags/v0.7.0", state["active_ref"])
        self.assertEqual(self.commit, state["active_commit"])
        self.assertEqual("0.7.0", state["manifest_version"])
        self.assertIn("updated_at", state)

    def test_failed_activation_restores_previous_version_and_state(self):
        old = self.make_candidate("old", version="0.6.0")
        candidate = self.make_candidate()
        self.paths.install_root.mkdir(parents=True)
        self.paths.current.symlink_to(old, target_is_directory=True)
        previous = {
            "schema_version": 1,
            "channel": "stable",
            "platforms": ["codex"],
            "active_commit": "b" * 40,
            "future_key": "preserve",
        }
        self.paths.state_file.write_text(json.dumps(previous), encoding="utf-8")
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")
        manager.validate_candidate = mock.Mock(return_value="0.7.0")
        manager.run_platform_installers = mock.Mock(
            side_effect=[ManagedInstallError("simulated installer failure"), None]
        )
        manager.run_doctor = mock.Mock()

        with self.assertRaisesRegex(ManagedInstallError, "simulated installer failure"):
            manager.activate_candidate(candidate, self.revision, ["codex"])

        self.assertEqual(old.resolve(), self.paths.current.resolve())
        self.assertEqual(previous, manager.load_state())
        self.assertEqual(2, manager.run_platform_installers.call_count)
        rollback_call = manager.run_platform_installers.call_args_list[1]
        self.assertEqual(old.resolve(), rollback_call.args[0])
        self.assertEqual(["codex"], rollback_call.args[1])

    def test_failed_first_activation_leaves_no_current_or_state(self):
        candidate = self.make_candidate()
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")
        manager.validate_candidate = mock.Mock(return_value="0.7.0")
        manager.run_platform_installers = mock.Mock()
        manager.run_doctor = mock.Mock(side_effect=ManagedInstallError("simulated doctor failure"))

        with self.assertRaisesRegex(ManagedInstallError, "simulated doctor failure"):
            manager.activate_candidate(candidate, self.revision, ["cursor"])

        self.assertFalse(os.path.lexists(self.paths.current))
        self.assertFalse(self.paths.state_file.exists())

    def test_failed_first_activation_restores_preexisting_command_symlink(self):
        candidate = self.make_candidate()
        foreign_command = self.root / "previous-dev-workflow"
        foreign_command.write_text("previous\n", encoding="utf-8")
        self.paths.bin_dir.mkdir(parents=True)
        self.paths.command_link.symlink_to(foreign_command)
        original_target = os.readlink(self.paths.command_link)
        manager = ManagedInstaller(self.paths, "https://example.test/tiers.git")
        manager.validate_candidate = mock.Mock(return_value="0.7.0")
        manager.run_platform_installers = mock.Mock()
        manager.run_doctor = mock.Mock(side_effect=ManagedInstallError("simulated doctor failure"))

        with self.assertRaisesRegex(ManagedInstallError, "simulated doctor failure"):
            manager.activate_candidate(candidate, self.revision, ["codex"])

        self.assertTrue(self.paths.command_link.is_symlink())
        self.assertEqual(original_target, os.readlink(self.paths.command_link))


if __name__ == "__main__":
    unittest.main()
