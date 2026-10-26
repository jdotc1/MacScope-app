from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts.dependencies import materialize_lumen_submodule as subject


class LumenMaterializationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="lumen-materialization-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "macscope"
        self.seed = self.root / "lumen"
        self.target = self.source / "ThirdParty/Lumen"
        for repository in (self.source, self.seed):
            repository.mkdir()
            self.git(repository, "init", "--quiet")
            self.git(repository, "config", "user.name", "Fixture")
            self.git(repository, "config", "user.email", "fixture@example.invalid")
        self.git(self.seed, "remote", "add", "origin", "https://github.com/jdotc1/Lumen.git")
        (self.seed / "Package.swift").write_text("// pinned package\n")
        self.git(self.seed, "add", "Package.swift")
        self.git(self.seed, "commit", "--quiet", "-m", "Pinned package")
        self.pin = self.git(self.seed, "rev-parse", "HEAD")
        self.write_contract()
        self.addCleanup(mock.patch.stopall)

    def git(self, repository: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments], text=True,
            capture_output=True, check=True,
            env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull},
        )
        return result.stdout.strip()

    def write_contract(self, *, url: str = "https://github.com/jdotc1/Lumen.git",
                       pin: str | None = None) -> None:
        (self.source / ".gitmodules").write_text(
            '[submodule "ThirdParty/Lumen"]\n\tpath = ThirdParty/Lumen\n\turl = ' + url + "\n"
        )
        self.git(self.source, "add", ".gitmodules")
        self.git(self.source, "update-index", "--add", "--cacheinfo",
                 "160000", pin or self.pin, "ThirdParty/Lumen")
        self.git(self.source, "commit", "--quiet", "-m", "Pin dependency")

    def run_materializer(self, seed: Path | None = None) -> tuple[int, str, str]:
        output, error = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(error):
            arguments = ["--source-root", str(self.source),
                         "--seed-repository", str(seed or self.seed)]
            try:
                code = subject.main(arguments)
            except SystemExit as exit_status:
                code = exit_status.code
        return code, output.getvalue(), error.getvalue()

    def prepare_previous_checkout(self) -> None:
        self.previous_pin = self.pin
        self.assertEqual(self.run_materializer()[0], 0)
        (self.seed / "Package.swift").write_text("// upgraded pinned package\n")
        self.git(self.seed, "add", "Package.swift")
        self.git(self.seed, "commit", "--quiet", "-m", "Upgraded package")
        self.pin = self.git(self.seed, "rev-parse", "HEAD")
        self.write_contract()

    def assert_previous_checkout_preserved(self, seed: Path | None = None) -> None:
        index_before = (self.target / ".git/index").read_bytes()
        package_before = (self.target / "Package.swift").read_bytes()
        code, _, _ = self.run_materializer(seed)
        self.assertNotEqual(code, 0)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.previous_pin)
        self.assertEqual((self.target / "Package.swift").read_bytes(), package_before)
        self.assertEqual((self.target / ".git/index").read_bytes(), index_before)

    def test_clean_published_previous_pin_moves_to_new_pin_using_only_local_commit_bytes(self) -> None:
        self.prepare_previous_checkout()
        (self.seed / "Package.swift").write_text("// dirty seed must not be copied\n")
        trace = self.root / "upgrade-trace.log"
        with mock.patch.dict(os.environ, {"GIT_TRACE": str(trace)}):
            code, output, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        receipt = json.loads(output)
        self.assertEqual(receipt["action"], "updated")
        self.assertEqual(receipt["previous_commit"], self.previous_pin)
        self.assertEqual(receipt["commit"], self.pin)
        self.assertIs(receipt["network_used"], False)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)
        self.assertEqual((self.target / "Package.swift").read_text(), "// upgraded pinned package\n")
        self.assertEqual(self.git(self.source, "status", "--porcelain"), "")
        self.assertFalse((self.target / ".git/objects/info/alternates").exists())
        commands = trace.read_text()
        self.assertNotIn("git-remote-http", commands)
        self.assertNotIn("ssh ", commands)
        self.assertNotIn("--force", commands)
        code, output, error = self.run_materializer(self.root / "missing-seed")
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(output)["action"], "reused")

    def prepare_previous_checkout_with_xcode_state(self) -> None:
        # Lumen's own .gitignore lists the state Xcode/SwiftPM regenerate.
        (self.seed / ".gitignore").write_text(".build/\n.swiftpm/\n")
        self.git(self.seed, "add", ".gitignore")
        self.git(self.seed, "commit", "--quiet", "-m", "Ignore tool state")
        self.pin = self.git(self.seed, "rev-parse", "HEAD")
        self.write_contract()
        self.prepare_previous_checkout()
        workspace = self.target / ".swiftpm/xcode/package.xcworkspace"
        workspace.mkdir(parents=True)
        (workspace / "contents.xcworkspacedata").write_text("<Workspace/>\n")
        (self.target / ".build").mkdir()
        (self.target / ".build/workspace-state.json").write_text("{}\n")

    def test_xcode_swiftpm_state_is_regenerable_not_dirt(self) -> None:
        self.prepare_previous_checkout_with_xcode_state()
        code, output, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        receipt = json.loads(output)
        self.assertEqual((receipt["action"], receipt["previous_commit"]), ("updated", self.previous_pin))
        self.assertEqual(receipt["removed_regenerable"], [".build", ".swiftpm"])
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)
        self.assertFalse((self.target / ".swiftpm").exists())
        self.assertFalse((self.target / ".build").exists())
        # A checkout already at the pin is reused (no seed needed) the same way.
        (self.target / ".swiftpm").mkdir()
        code, output, error = self.run_materializer(self.root / "missing-seed")
        self.assertEqual(code, 0, error)
        receipt = json.loads(output)
        self.assertEqual((receipt["action"], receipt["removed_regenerable"]), ("reused", [".swiftpm"]))

    def test_xcode_swiftpm_state_does_not_excuse_real_changes(self) -> None:
        self.prepare_previous_checkout_with_xcode_state()
        package = self.target / "Package.swift"
        package.write_text("// tracked local edit\n")
        self.assert_previous_checkout_preserved()
        self.assertTrue((self.target / ".swiftpm/xcode/package.xcworkspace").is_dir())
        package.write_text("// pinned package\n")
        (self.target / "keep.txt").write_text("untracked user data\n")
        self.assert_previous_checkout_preserved()
        self.assertTrue((self.target / ".build/workspace-state.json").is_file())
        (self.target / "keep.txt").unlink()
        # Not ignored by the checkout: untracked content, never removed.
        (self.target / ".gitignore").write_text("")
        self.assert_previous_checkout_preserved()
        self.assertTrue((self.target / ".swiftpm").is_dir())

    def test_pin_comes_from_the_committed_gitlink(self) -> None:
        self.prepare_previous_checkout()
        code, output, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(output)["commit"], self.pin)
        self.assertEqual(json.loads(output)["previous_commit"], self.previous_pin)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)

    def test_upgrade_preserves_dirty_and_staged_previous_checkout(self) -> None:
        self.prepare_previous_checkout()
        package = self.target / "Package.swift"
        package.write_text("// preserve modified previous checkout\n")
        self.assert_previous_checkout_preserved()
        self.git(self.target, "add", "Package.swift")
        self.assert_previous_checkout_preserved()

    def test_upgrade_preserves_untracked_and_ignored_previous_files(self) -> None:
        self.prepare_previous_checkout()
        marker = self.target / "keep.txt"
        marker.write_text("untracked user data\n")
        self.assert_previous_checkout_preserved()
        self.assertEqual(marker.read_text(), "untracked user data\n")
        (self.target / ".git/info/exclude").write_text("keep.txt\n")
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
        self.assert_previous_checkout_preserved()
        self.assertEqual(marker.read_text(), "untracked user data\n")

    def test_upgrade_preserves_previous_checkout_when_seed_is_missing_wrong_or_incomplete(self) -> None:
        self.prepare_previous_checkout()
        trace = self.root / "failed-upgrade-trace.log"
        with mock.patch.dict(os.environ, {"GIT_TRACE": str(trace)}):
            self.assert_previous_checkout_preserved(self.root / "missing-seed")
            self.git(self.seed, "remote", "set-url", "origin", "https://example.invalid/other.git")
            self.assert_previous_checkout_preserved()
            empty_seed = self.root / "empty-seed"
            empty_seed.mkdir()
            self.git(empty_seed, "init", "--quiet")
            self.git(empty_seed, "remote", "add", "origin", "https://github.com/jdotc1/Lumen.git")
            self.assert_previous_checkout_preserved(empty_seed)
        self.assertNotIn("git-remote-http", trace.read_text())
        self.assertNotIn("ssh ", trace.read_text())

    def test_unpublished_local_commit_is_preserved(self) -> None:
        self.prepare_previous_checkout()
        self.git(self.target, "config", "user.name", "Fixture")
        self.git(self.target, "config", "user.email", "fixture@example.invalid")
        (self.target / "Package.swift").write_text("// user committed state\n")
        self.git(self.target, "add", "Package.swift")
        self.git(self.target, "commit", "--quiet", "-m", "Unapproved local commit")
        self.previous_pin = self.git(self.target, "rev-parse", "HEAD")
        self.assert_previous_checkout_preserved()

    def test_upgrade_rejects_hidden_physical_edits_and_preserves_index_flags(self) -> None:
        self.prepare_previous_checkout()
        package = self.target / "Package.swift"
        for flag in ("--skip-worktree", "--assume-unchanged"):
            with self.subTest(flag=flag):
                self.git(self.target, "update-index", flag, "Package.swift")
                package.write_text("// hidden modified previous bytes\n")
                self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
                self.assert_previous_checkout_preserved()
                package.write_text("// pinned package\n")
                self.assert_previous_checkout_preserved()
                self.git(self.target, "update-index", flag.replace("--", "--no-", 1), "Package.swift")
        self.git(self.target, "config", "core.filemode", "false")
        package.chmod(0o755)
        self.assert_previous_checkout_preserved()
        self.assertEqual(package.stat().st_mode & 0o777, 0o755)

    def test_upgrade_supports_absorbed_submodule_git_file(self) -> None:
        self.prepare_previous_checkout()
        self.git(self.source, "submodule", "absorbgitdirs", "--", "ThirdParty/Lumen")
        git_file = (self.target / ".git").read_bytes()
        code, output, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(output)["action"], "updated")
        self.assertEqual((self.target / ".git").read_bytes(), git_file)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)

    def test_materializes_exact_pin_from_local_objects_without_dirty_seed_bytes(self) -> None:
        (self.seed / "Package.swift").write_text("// uncommitted changes must not be copied\n")
        code, output, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)
        self.assertEqual((self.target / "Package.swift").read_text(), "// pinned package\n")
        self.assertEqual(self.git(self.target, "remote", "get-url", "origin"),
                         "https://github.com/jdotc1/Lumen.git")
        self.assertEqual(self.git(self.source, "status", "--porcelain"), "")
        self.assertFalse((self.target / ".git/objects/info/alternates").exists())
        self.assertEqual(json.loads(output)["network_used"], False)

    def test_owner_only_modes_from_a_restrictive_umask_are_normalized(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        package = self.target / "Package.swift"
        package.chmod(0o600)
        code, output, error = self.run_materializer(self.root / "missing-seed")
        self.assertEqual(code, 0, error)
        receipt = json.loads(output)
        self.assertEqual(receipt["action"], "reused")
        self.assertEqual(receipt["normalized_modes"], 1)
        self.assertEqual(package.stat().st_mode & 0o777, 0o644)

    def test_materialization_under_umask_077_leaves_canonical_modes(self) -> None:
        previous = os.umask(0o077)
        self.addCleanup(os.umask, previous)
        self.assertEqual(self.run_materializer()[0], 0)
        self.assertEqual((self.target / "Package.swift").stat().st_mode & 0o777, 0o644)

    def test_correct_materialization_is_reused_without_seed(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        identity = (self.target / "Package.swift").stat().st_ino
        code, output, error = self.run_materializer(self.root / "missing-seed")
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(output)["action"], "reused")
        self.assertEqual((self.target / "Package.swift").stat().st_ino, identity)

    def test_native_submodule_git_file_layout_is_reused(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        self.git(self.source, "submodule", "absorbgitdirs", "--", "ThirdParty/Lumen")
        self.assertTrue((self.target / ".git").is_file())
        code, output, error = self.run_materializer(self.root / "missing-seed")
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(output)["action"], "reused")

    def test_inherited_url_rewrite_cannot_turn_local_seed_import_into_network(self) -> None:
        trace = self.root / "git-trace.log"
        with mock.patch.dict(os.environ, {
            "GIT_TRACE": str(trace), "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "url.https://example.invalid/not-authorized/.insteadOf",
            "GIT_CONFIG_VALUE_0": str(self.seed),
        }):
            code, _, error = self.run_materializer()
        self.assertEqual(code, 0, error)
        commands = trace.read_text()
        self.assertNotIn("git-remote-https", commands)
        self.assertNotIn("not-authorized", commands)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)

    def test_missing_commit_in_seed_does_not_fall_back_to_origin(self) -> None:
        empty_seed = self.root / "empty-seed"
        empty_seed.mkdir()
        self.git(empty_seed, "init", "--quiet")
        self.git(empty_seed, "remote", "add", "origin", "https://github.com/jdotc1/Lumen.git")
        code, _, _ = self.run_materializer(empty_seed)
        self.assertNotEqual(code, 0)
        self.assertFalse(self.target.exists())

    def test_unknown_parent_pin_fails_before_creating_target(self) -> None:
        self.write_contract(pin="a" * 40)
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("seed", error)
        self.assertFalse(self.target.exists())

    def test_wrong_committed_url_fails_before_creating_target(self) -> None:
        self.write_contract(url="https://example.invalid/other.git")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("URL", error)
        self.assertFalse(self.target.exists())

    def test_uncommitted_gitmodules_cannot_override_committed_authority(self) -> None:
        (self.source / ".gitmodules").write_text("# modified\n")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn(".gitmodules", error)
        self.assertFalse(self.target.exists())

    def test_wrong_seed_url_fails_without_importing_objects(self) -> None:
        self.git(self.seed, "remote", "set-url", "origin", "https://example.invalid/other.git")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("seed", error)
        self.assertFalse(self.target.exists())

    def test_missing_seed_fails_closed_without_network(self) -> None:
        trace = self.root / "git-trace.log"
        with mock.patch.dict(os.environ, {"GIT_TRACE": str(trace), "GIT_TERMINAL_PROMPT": "0"}):
            code, _, error = self.run_materializer(self.root / "missing-seed")
        self.assertNotEqual(code, 0)
        self.assertIn("seed", error)
        self.assertFalse(self.target.exists())
        commands = trace.read_text() if trace.exists() else ""
        self.assertNotIn("git-remote-https", commands)
        self.assertNotIn("git-remote-http", commands)
        self.assertNotIn("ssh ", commands)

    def test_dirty_existing_target_is_preserved_and_rejected(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        marker = self.target / "Package.swift"
        marker.write_text("// preserve user edit\n")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("dirty", error)
        self.assertEqual(marker.read_text(), "// preserve user edit\n")

    def test_wrong_existing_pin_is_preserved_without_reset(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        self.git(self.target, "config", "user.name", "Fixture")
        self.git(self.target, "config", "user.email", "fixture@example.invalid")
        (self.target / "Package.swift").write_text("// other committed state\n")
        self.git(self.target, "add", "Package.swift")
        self.git(self.target, "commit", "--quiet", "-m", "Other commit")
        existing = self.git(self.target, "rev-parse", "HEAD")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("pin", error)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), existing)

    def test_replacement_commit_cannot_hide_changed_pinned_checkout_bytes(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        self.git(self.target, "config", "user.name", "Fixture")
        self.git(self.target, "config", "user.email", "fixture@example.invalid")
        package = self.target / "Package.swift"
        package.write_text("// replacement bytes\n")
        self.git(self.target, "add", "Package.swift")
        self.git(self.target, "commit", "--quiet", "-m", "Replacement commit")
        replacement = self.git(self.target, "rev-parse", "HEAD")
        self.git(self.target, "checkout", "--quiet", "--detach", self.pin)
        self.git(self.target, "replace", self.pin, replacement)
        self.git(self.target, "read-tree", "--reset", "-u", "HEAD")
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.pin)
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
        self.assertEqual(package.read_text(), "// replacement bytes\n")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0, "Replacement refs must not redefine the approved commit's bytes")
        self.assertIn("dirty", error)
        self.assertEqual(package.read_text(), "// replacement bytes\n")

    def test_skip_worktree_cannot_hide_changed_checkout_bytes(self) -> None:
        self.assert_hidden_index_change_rejected("--skip-worktree")

    def test_assume_unchanged_cannot_hide_changed_checkout_bytes(self) -> None:
        self.assert_hidden_index_change_rejected("--assume-unchanged")

    def test_clean_flagged_files_are_reused_without_modifying_index(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        for flag in ("--skip-worktree", "--assume-unchanged"):
            with self.subTest(flag=flag):
                self.git(self.target, "update-index", flag, "Package.swift")
                index_before = (self.target / ".git/index").read_bytes()
                code, output, error = self.run_materializer()
                self.assertEqual(code, 0, error)
                self.assertEqual(json.loads(output)["action"], "reused")
                self.assertEqual((self.target / ".git/index").read_bytes(), index_before)
                self.git(self.target, "update-index", flag.replace("--", "--no-", 1), "Package.swift")

    def assert_hidden_index_change_rejected(self, flag: str) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        self.git(self.target, "update-index", flag, "Package.swift")
        package = self.target / "Package.swift"
        package.write_text("// hidden modified bytes\n")
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
        index_before = (self.target / ".git/index").read_bytes()
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0, "Index flags must not hide changed physical bytes")
        self.assertIn("dirty", error)
        self.assertEqual(package.read_text(), "// hidden modified bytes\n")
        self.assertEqual((self.target / ".git/index").read_bytes(), index_before)

    def test_disabled_filemode_cannot_hide_changed_executable_mode(self) -> None:
        self.assertEqual(self.run_materializer()[0], 0)
        self.git(self.target, "config", "core.filemode", "false")
        package = self.target / "Package.swift"
        package.chmod(0o755)
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0, "Physical executable mode must match the approved blob")
        self.assertIn("dirty", error)
        self.assertEqual(package.stat().st_mode & 0o777, 0o755)

    def test_existing_unknown_directory_is_preserved(self) -> None:
        self.target.mkdir(parents=True)
        marker = self.target / "keep.txt"
        marker.write_text("not ours\n")
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("existing", error)
        self.assertEqual(marker.read_text(), "not ours\n")

    def test_symlink_destination_is_not_followed(self) -> None:
        self.target.parent.mkdir()
        external = self.root / "external"
        external.mkdir()
        self.target.symlink_to(external, target_is_directory=True)
        code, _, error = self.run_materializer()
        self.assertNotEqual(code, 0)
        self.assertIn("symlink", error)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(list(external.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
