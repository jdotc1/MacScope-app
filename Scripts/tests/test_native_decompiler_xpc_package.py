from __future__ import annotations

import ast

import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIRECT_ROOT = ROOT / "Scripts" / "native-decompiler-direct"
STAGE_PATH = ROOT / "Scripts" / "native-decompiler-xpc" / "stage_verified_package.py"
for path in (str(DIRECT_ROOT), str(ROOT)):
    if path not in sys.path:
        sys.path.insert(0, path)

import sleigh_package  # noqa: E402
from Scripts.tests.test_sleigh_native_package import SleighPackageFixture, canonical_manifest  # noqa: E402


def load_stage_module():
    specification = importlib.util.spec_from_file_location("stage_verified_package", STAGE_PATH)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


class StageVerifiedPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        package = self.source / "package"
        package.mkdir()
        SleighPackageFixture(package).create()
        (self.source / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(canonical_manifest(package)) + "\n",
            encoding="utf-8",
        )
        self.destination = self.root / "staged"
        self.input_list = self.root / "inputs.xcfilelist"
        self.output_list = self.root / "outputs.xcfilelist"

    def stage(self):
        return load_stage_module().stage_verified_package(
            source_materialization_root=self.source,
            destination_materialization_root=self.destination,
            input_file_list=self.input_list,
            output_file_list=self.output_list,
        )

    def test_closed_tree_reuses_digest_evidence_and_detects_later_mutation(self) -> None:
        module = load_stage_module()
        descriptor = os.open(self.source, module._directory_open_flags())
        self.addCleanup(os.close, descriptor)
        first = module._closed_tree_snapshot(descriptor)
        evidence = {relative: (fields[4], digest) for relative, kind, fields, digest in first if kind == "file"}
        with mock.patch.object(module.os, "read", side_effect=AssertionError("unchanged source bytes read again")):
            self.assertEqual(module._closed_tree_snapshot(descriptor, prior_snapshot=first), first)
            self.assertEqual(module._closed_tree_snapshot(descriptor, digest_evidence=evidence), first)
            omitted = dict(evidence)
            omitted.pop("MATERIALIZATION.json")
            with self.assertRaisesRegex(module.PackageStageError, "receipt-bound"):
                module._closed_tree_snapshot(descriptor, digest_evidence=omitted)
            library = self.source / "package/lib/libdecomp.a"
            metadata = library.stat()
            library.write_bytes(b"x" * metadata.st_size)
            os.utime(library, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            with self.assertRaisesRegex(module.PackageStageError, "changed"):
                module._closed_tree_snapshot(descriptor, prior_snapshot=first)

    def test_shared_view_does_not_bless_old_copy_and_reuses_new_staging_receipt(self) -> None:
        module = load_stage_module()
        source = self.source.resolve()
        descriptor = os.open(source, module._directory_open_flags())
        try:
            snapshot = module._closed_tree_snapshot(descriptor)
        finally:
            os.close(descriptor)
        accepted = {
            "identity": json.loads((source / "MATERIALIZATION.json").read_text()),
            "files": {relative: (fields[4], digest) for relative, kind, fields, digest in snapshot if kind == "file"},
        }
        old_copy = self.root / "old-copy"
        shutil.copytree(source, old_copy)
        receipts = self.root.resolve() / "receipts"
        receipts.mkdir(mode=0o700)

        def admit_source(path):
            if path != source:
                raise module.PackageStageError("consumer is not the receipt-bound shared view")
            return accepted

        with mock.patch.dict(os.environ, {
            "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
            "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
        }), mock.patch.object(module, "_reused_source_receipt", side_effect=admit_source), \
             mock.patch.object(module, "_checked_verify", wraps=module._checked_verify) as verify:
            with self.assertRaisesRegex(module.PackageStageError, "receipt-bound"):
                module._open_verified_materialization(old_copy, "existing package resource")
            self.assertEqual(verify.call_count, 0)
            module.stage_verified_package(source, self.destination, self.input_list, self.output_list)
            self.assertEqual(verify.call_count, 1)
            with mock.patch.object(module.os, "read", side_effect=AssertionError("verified staged bytes rehashed")):
                anchor = module._open_verified_materialization(self.destination, "existing package resource")
                os.close(anchor[1])
                self.assertEqual(verify.call_count, 1)
                library = self.destination / "package/lib/libdecomp.a"
                metadata = library.stat()
                # Metadata-only drift (new mtime/ctime) keeps the content receipt
                # valid across runs, with no rehash and no re-verification.
                os.utime(library, ns=(1, 1))
                self.assertNotEqual(library.stat().st_ctime_ns, metadata.st_ctime_ns)
                anchor = module._open_verified_materialization(self.destination, "existing package resource")
                os.close(anchor[1])
                self.assertEqual(verify.call_count, 1)
                library.write_bytes(b"x" * (metadata.st_size + 1))
                with self.assertRaisesRegex(module.PackageStageError, "changed"):
                    module._open_verified_materialization(self.destination, "existing package resource")

    def assert_stage_rejected(self, expression: str) -> None:
        module = load_stage_module()
        with self.assertRaisesRegex(module.PackageStageError, expression):
            module.stage_verified_package(
                source_materialization_root=self.source,
                destination_materialization_root=self.destination,
                input_file_list=self.input_list,
                output_file_list=self.output_list,
            )
        self.assertFalse(self.destination.exists())

    def test_stages_complete_verified_root_and_emits_sorted_external_file_lists(self) -> None:
        self.stage()
        self.assertEqual(sleigh_package.verify_materialization(self.destination), sleigh_package.verify_materialization(self.source))
        self.assertEqual({item.name for item in self.destination.iterdir()}, {"MATERIALIZATION.json", "package"})
        inputs = self.input_list.read_text(encoding="utf-8").splitlines()
        outputs = self.output_list.read_text(encoding="utf-8").splitlines()
        self.assertEqual(inputs, sorted(inputs, key=os.fsencode))
        self.assertEqual(outputs, sorted(outputs, key=os.fsencode))
        self.assertTrue(inputs[0].endswith("/MATERIALIZATION.json"))
        self.assertTrue(outputs[0].endswith("/MATERIALIZATION.json"))
        self.assertFalse((self.destination / ".stage-complete").exists())

    def test_stages_all_apple_silicon_critical_resources_with_identity(self) -> None:
        source_identity = sleigh_package.verify_materialization(self.source)
        staged_identity = self.stage()
        verified_staged_identity = sleigh_package.verify_materialization(self.destination)
        relative_paths = (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
        )
        for relative_path in relative_paths:
            with self.subTest(relative_path=relative_path):
                self.assertEqual(
                    (self.destination / "package" / relative_path).read_bytes(),
                    (self.source / "package" / relative_path).read_bytes(),
                )
        self.assertEqual(staged_identity, source_identity)
        self.assertEqual(
            verified_staged_identity["package"]["treeSha256"],
            source_identity["package"]["treeSha256"],
        )
        self.assertEqual(
            sleigh_package.canonical_json(verified_staged_identity),
            sleigh_package.canonical_json(source_identity),
        )

    def test_rejects_missing_or_unverified_source_before_creating_destination(self) -> None:
        shutil.rmtree(self.source)
        self.assert_stage_rejected("source")
        self.source.mkdir()
        self.assert_stage_rejected("verification")

    def test_rejects_source_root_and_nested_symlinks(self) -> None:
        linked_root = self.root / "linked-source"
        try:
            linked_root.symlink_to(self.source, target_is_directory=True)
        except OSError:
            self.skipTest("symlinks unavailable")
        module = load_stage_module()
        with self.assertRaisesRegex(module.PackageStageError, "ordinary directory"):
            module.stage_verified_package(linked_root, self.destination, self.input_list, self.output_list)
        linked_root.unlink()
        (self.source / "package" / "linked-header").symlink_to(
            self.source / "package" / "include/sleigh/ghidra/libdecomp.hh"
        )
        self.assert_stage_rejected("link")

    def test_rejects_source_hard_links_and_special_files(self) -> None:
        header = self.source / "package" / "include/sleigh/ghidra/libdecomp.hh"
        os.link(header, self.root / "external-header-alias")
        self.assert_stage_rejected("hard-linked")
        (self.root / "external-header-alias").unlink()
        fifo = self.source / "package" / "not-regular"
        try:
            os.mkfifo(fifo)
        except (AttributeError, OSError):
            self.skipTest("special files unavailable")
        self.assert_stage_rejected("verification")

    def test_rejects_unexpected_entries_and_path_escape(self) -> None:
        (self.source / "unexpected").write_text("no", encoding="utf-8")
        self.assert_stage_rejected("verification")
        (self.source / "unexpected").unlink()
        link = self.source / "package" / "escaped"
        try:
            link.symlink_to("../MATERIALIZATION.json")
        except OSError:
            self.skipTest("symlinks unavailable")
        self.assert_stage_rejected("link")

    def test_rejects_preexisting_destination_without_overwriting_it(self) -> None:
        self.destination.mkdir()
        sentinel = self.destination / "sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        module = load_stage_module()
        with self.assertRaisesRegex(module.PackageStageError, "already exists"):
            module.stage_verified_package(self.source, self.destination, self.input_list, self.output_list)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_rejects_preexisting_file_lists_without_overwriting_them(self) -> None:
        for existing, other in (
            (self.input_list, self.output_list),
            (self.output_list, self.input_list),
        ):
            with self.subTest(existing=existing.name):
                try:
                    existing.write_text("preserve\n", encoding="utf-8")
                    module = load_stage_module()
                    with self.assertRaisesRegex(module.PackageStageError, "already exists"):
                        module.stage_verified_package(
                            self.source,
                            self.destination,
                            self.input_list,
                            self.output_list,
                        )
                    self.assertEqual(existing.read_text(encoding="utf-8"), "preserve\n")
                    self.assertFalse(other.exists())
                    self.assertFalse(self.destination.exists())
                finally:
                    if self.destination.exists():
                        shutil.rmtree(self.destination)
                    for candidate in (self.input_list, self.output_list):
                        if candidate.exists():
                            candidate.unlink()

    def test_rejects_canonical_identical_file_list_paths_before_mutation(self) -> None:
        alias_parent = self.root / "lists"
        alias_parent.mkdir()
        aliased_input = alias_parent / ".." / "same.xcfilelist"
        output = self.root / "same.xcfilelist"
        before = {item.name for item in self.root.iterdir()}
        module = load_stage_module()
        with self.assertRaisesRegex(module.PackageStageError, "distinct"):
            module.stage_verified_package(
                self.source,
                self.destination,
                aliased_input,
                output,
            )
        self.assertEqual({item.name for item in self.root.iterdir()}, before)
        self.assertFalse(self.destination.exists())
        self.assertFalse(output.exists())

    def test_published_package_is_completely_reverified_before_success(self) -> None:
        module = load_stage_module()
        original = module._write_bytes_exclusively
        tampered = False

        def publish_then_tamper(*arguments, **keywords):
            nonlocal tampered
            result = original(*arguments, **keywords)
            label = arguments[3] if len(arguments) > 3 else keywords.get("label")
            if label == "output file list" and not tampered:
                with (self.destination / "package/lib/libdecomp.a").open("ab") as stream:
                    stream.write(b"post-publish-tamper")
                tampered = True
            return result

        with mock.patch.object(module, "_write_bytes_exclusively", side_effect=publish_then_tamper):
            with self.assertRaises(module.PackageStageError):
                module.stage_verified_package(
                    self.source,
                    self.destination,
                    self.input_list,
                    self.output_list,
                )

        self.assertTrue(tampered)
        self.assertTrue(self.destination.is_dir())
        self.assertTrue(self.input_list.is_file())
        self.assertTrue(self.output_list.is_file())
        self.assertTrue(
            (self.destination / "package/lib/libdecomp.a")
            .read_bytes()
            .endswith(b"post-publish-tamper")
        )
        self.assertFalse(list(self.root.glob(".staged.quarantine-*")))

    def test_success_rejects_post_validation_destination_parent_substitution(self) -> None:
        module = load_stage_module()
        publication_parent = self.root / "publication"
        publication_parent.mkdir()
        destination = publication_parent / "staged"
        saved_parent = self.root / "saved-publication"
        original_revalidate = module._revalidate_anchored_materialization
        published_validations = 0
        substituted = False

        def substitute_after_final_package_validation(*arguments, **keywords):
            nonlocal published_validations, substituted
            result = original_revalidate(*arguments, **keywords)
            label = arguments[4] if len(arguments) > 4 else keywords.get("label")
            if label == "published package":
                published_validations += 1
                if published_validations == 1:
                    publication_parent.rename(saved_parent)
                    publication_parent.mkdir()
                    destination.mkdir()
                    (destination / "foreign-marker").write_text(
                        "preserve\n",
                        encoding="utf-8",
                    )
                    substituted = True
            return result

        with mock.patch.object(
            module,
            "_revalidate_anchored_materialization",
            side_effect=substitute_after_final_package_validation,
        ):
            with self.assertRaises(module.PackageStageError):
                module.stage_verified_package(
                    self.source,
                    destination,
                    self.input_list,
                    self.output_list,
                )

        self.assertTrue(substituted)
        self.assertEqual(
            (destination / "foreign-marker").read_text(encoding="utf-8"),
            "preserve\n",
        )
        self.assertFalse(list(publication_parent.glob(".staged.quarantine-*")))

    def test_rejects_source_identity_mismatch_after_copy(self) -> None:
        module = load_stage_module()
        original = module._verify
        calls = 0

        def mismatched(path, *arguments, **keywords):
            nonlocal calls
            calls += 1
            value = original(path, *arguments, **keywords)
            if calls == 2:
                value = dict(value)
                value["sleighVersion"] = "forged"
            return value

        with mock.patch.object(module, "_verify", side_effect=mismatched):
            with self.assertRaisesRegex(module.PackageStageError, "identity"):
                module.stage_verified_package(self.source, self.destination, self.input_list, self.output_list)
        self.assertTrue(self.destination.is_dir())

    def test_detects_source_mutation_during_copy_and_preserves_partial_stage(self) -> None:
        module = load_stage_module()
        original = module._copy_file
        mutated = False

        def copy_then_mutate(*arguments):
            nonlocal mutated
            original(*arguments)
            if not mutated:
                mutated = True
                with (self.source / "package/lib/libdecomp.a").open("ab") as stream:
                    stream.write(b"mutation")

        with mock.patch.object(module, "_copy_file", side_effect=copy_then_mutate):
            with self.assertRaisesRegex(module.PackageStageError, "source changed"):
                module.stage_verified_package(self.source, self.destination, self.input_list, self.output_list)
        self.assertTrue(self.destination.is_dir())

    def test_intermediate_parent_symlink_substitution_is_never_copied_through(self) -> None:
        module = load_stage_module()
        original = module._copy_file
        substituted = False
        copied_through_substitution = False

        def substitute_parent_then_copy(*arguments):
            nonlocal substituted, copied_through_substitution
            if isinstance(arguments[0], int):
                relative = pathlib.Path(arguments[1])
            else:
                relative = pathlib.Path(arguments[0]).resolve().relative_to(self.source.resolve())
            is_nested_header = relative.parts[:2] == ("package", "include")
            if is_nested_header and not substituted:
                actual = self.source / "package/include"
                moved = self.source / "package/include-real"
                actual.rename(moved)
                actual.symlink_to(moved, target_is_directory=True)
                substituted = True
            result = original(*arguments)
            if is_nested_header and substituted:
                copied_through_substitution = True
            return result

        with mock.patch.object(module, "_copy_file", side_effect=substitute_parent_then_copy):
            with self.assertRaises(module.PackageStageError):
                module.stage_verified_package(
                    self.source,
                    self.destination,
                    self.input_list,
                    self.output_list,
                )
        self.assertTrue(substituted)
        self.assertFalse(copied_through_substitution)
        self.assertTrue(self.destination.is_dir())

    def test_rejects_unsafe_complete_and_canonical_paths_before_mutation(self) -> None:
        module = load_stage_module()
        cases = (
            (self.root / "source\nname", self.destination, self.input_list, self.output_list),
            (self.source, self.root / "staged\rname", self.input_list, self.output_list),
            (self.source, self.destination, self.root / "inputs\nlist", self.output_list),
            (self.source, self.destination, self.input_list, self.root / "outputs\x00list"),
        )
        for source, destination, input_list, output_list in cases:
            with self.subTest(paths=(source, destination, input_list, output_list)):
                before = {item.name for item in self.root.iterdir()}
                with self.assertRaises(Exception) as observed:
                    module.stage_verified_package(source, destination, input_list, output_list)
                self.assertIsInstance(observed.exception, module.PackageStageError)
                self.assertRegex(str(observed.exception), "unsafe")
                self.assertEqual({item.name for item in self.root.iterdir()}, before)

        bad_parent = self.root / "canonical\nparent"
        bad_parent.mkdir()
        clean_alias = self.root / "clean-alias"
        try:
            clean_alias.symlink_to(bad_parent, target_is_directory=True)
        except OSError:
            self.skipTest("symlinks unavailable")
        before = {item.name for item in self.root.iterdir()}
        with self.assertRaisesRegex(module.PackageStageError, "unsafe"):
            module.stage_verified_package(
                self.source,
                clean_alias / "staged",
                self.input_list,
                self.output_list,
            )
        self.assertEqual({item.name for item in self.root.iterdir()}, before)

    def test_rejects_verifier_failure_before_copy(self) -> None:
        module = load_stage_module()
        with mock.patch.object(module, "_verify", side_effect=sleigh_package.PackageContractError("rejected")):
            with self.assertRaisesRegex(module.PackageStageError, "verification"):
                module.stage_verified_package(self.source, self.destination, self.input_list, self.output_list)
        self.assertFalse(self.destination.exists())

    def test_rejects_post_copy_verifier_failure_and_preserves_partial_stage(self) -> None:
        module = load_stage_module()
        original = module._verify
        calls = 0

        def fail_staged(path, *arguments, **keywords):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise sleigh_package.PackageContractError("staged rejected")
            return original(path, *arguments, **keywords)

        with mock.patch.object(module, "_verify", side_effect=fail_staged):
            with self.assertRaisesRegex(module.PackageStageError, "verification"):
                module.stage_verified_package(self.source, self.destination, self.input_list, self.output_list)
        self.assertTrue(self.destination.is_dir())

    def test_destination_parent_substitution_during_copy_never_writes_outside_temp_root(self) -> None:
        module = load_stage_module()
        relative = pathlib.PurePosixPath(
            "package/include/sleigh/ghidra/libdecomp.hh"
        )
        destination_root = self.root / "copy-root"
        destination_root.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "sleigh/ghidra").mkdir(parents=True)
        original_open = os.open
        substituted = False

        def substitute_after_intermediate_open(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal substituted
            if dir_fd is None:
                descriptor = original_open(path, flags, mode)
            else:
                descriptor = original_open(path, flags, mode, dir_fd=dir_fd)
            if path == "include" and dir_fd is not None and not substituted:
                parent_fields = os.fstat(dir_fd)
                destination_package = destination_root / "package"
                if destination_package.exists():
                    package_fields = destination_package.lstat()
                    if (parent_fields.st_dev, parent_fields.st_ino) == (
                        package_fields.st_dev,
                        package_fields.st_ino,
                    ):
                        include = destination_package / "include"
                        include.rename(destination_package / "include-owned")
                        include.symlink_to(outside, target_is_directory=True)
                        substituted = True
            return descriptor

        source_descriptor = os.open(self.source, module._directory_open_flags())
        destination_descriptor = os.open(
            destination_root,
            module._directory_open_flags(),
        )
        try:
            with mock.patch.object(
                module.os,
                "open",
                side_effect=substitute_after_intermediate_open,
            ):
                module._copy_file(
                    source_descriptor,
                    relative,
                    destination_descriptor,
                    {},
                )
        finally:
            os.close(destination_descriptor)
            os.close(source_descriptor)

        self.assertTrue(substituted)
        self.assertFalse(
            (outside / "sleigh/ghidra/libdecomp.hh").exists(),
            "copy followed a substituted intermediate destination directory",
        )
        self.assertTrue(
            (
                destination_root
                / "package/include-owned/sleigh/ghidra/libdecomp.hh"
            ).is_file()
        )

    def test_copy_dup_failure_restores_file_descriptor_count(self) -> None:
        module = load_stage_module()
        destination_root = self.root / "dup-failure-root"
        destination_root.mkdir()
        source_descriptor = os.open(self.source, module._directory_open_flags())
        destination_descriptor = os.open(
            destination_root,
            module._directory_open_flags(),
        )
        original_dup = os.dup

        def fail_destination_dup(descriptor):
            if descriptor == destination_descriptor:
                raise OSError("injected destination descriptor duplication failure")
            return original_dup(descriptor)

        try:
            baseline = len(os.listdir("/dev/fd"))
            with mock.patch.object(
                module.os,
                "dup",
                side_effect=fail_destination_dup,
            ):
                with self.assertRaisesRegex(OSError, "duplication failure"):
                    module._copy_file(
                        source_descriptor,
                        pathlib.PurePosixPath("MATERIALIZATION.json"),
                        destination_descriptor,
                        {},
                    )
            self.assertEqual(len(os.listdir("/dev/fd")), baseline)
        finally:
            os.close(destination_descriptor)
            os.close(source_descriptor)

    def test_later_file_list_anchor_failure_restores_fd_count_in_both_modes(self) -> None:
        for mode in ("create", "open-existing"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_stage_module()
                root = pathlib.Path(temporary_directory)
                source = root / "source"
                package = source / "package"
                package.mkdir(parents=True)
                SleighPackageFixture(package).create()
                (source / "MATERIALIZATION.json").write_text(
                    sleigh_package.canonical_json(canonical_manifest(package)) + "\n",
                    encoding="utf-8",
                )
                destination = root / "staged"
                input_list = root / "inputs.xcfilelist"
                output_list = root / "outputs.xcfilelist"
                if mode == "open-existing":
                    module.stage_verified_package(
                        source,
                        destination,
                        input_list,
                        output_list,
                    )
                    shutil.rmtree(destination)

                calls: list[str] = []
                if mode == "create":
                    original = module._write_bytes_exclusively
                    function_name = "_write_bytes_exclusively"
                else:
                    original = module._open_anchored_file
                    function_name = "_open_anchored_file"

                def fail_output_anchor(*arguments, **keywords):
                    label = arguments[-1] if arguments else keywords["label"]
                    calls.append(label)
                    if label == "output file list":
                        raise module.PackageStageError(
                            "injected later file-list anchor failure"
                        )
                    return original(*arguments, **keywords)

                baseline = len(os.listdir("/dev/fd"))
                with mock.patch.object(
                    module,
                    function_name,
                    side_effect=fail_output_anchor,
                ):
                    with self.assertRaisesRegex(
                        module.PackageStageError,
                        "later file-list anchor failure",
                    ):
                        module.stage_verified_package(
                            source,
                            destination,
                            input_list,
                            output_list,
                            publish_file_lists=mode == "create",
                        )

                self.assertEqual(calls, ["input file list", "output file list"])
                self.assertEqual(len(os.listdir("/dev/fd")), baseline)

    def test_early_destination_parent_validation_failures_restore_fd_count(self) -> None:
        for failure in ("canonical-destination", "input-file-list", "output-file-list"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_stage_module()
                root = pathlib.Path(temporary_directory)
                source = root / "source"
                package = source / "package"
                package.mkdir(parents=True)
                SleighPackageFixture(package).create()
                (source / "MATERIALIZATION.json").write_text(
                    sleigh_package.canonical_json(canonical_manifest(package)) + "\n",
                    encoding="utf-8",
                )
                destination_parent = root / "destination-parent"
                destination_parent.mkdir()
                destination = destination_parent / "staged"
                input_list = root / "inputs.xcfilelist"
                output_list = root / "outputs.xcfilelist"
                destination_parent_opened = False
                original_open_directory = module._open_anchored_directory
                original_canonical = module._canonical_path
                original_file_list = module._ensure_external_file_list

                def observe_destination_parent(path, label):
                    nonlocal destination_parent_opened
                    result = original_open_directory(path, label)
                    if label == "destination parent":
                        destination_parent_opened = True
                    return result

                def fail_canonical(path, label, *args, **kwargs):
                    if (
                        failure == "canonical-destination"
                        and label == "destination materialization root"
                    ):
                        raise module.PackageStageError(
                            "injected canonical destination validation failure"
                        )
                    return original_canonical(path, label, *args, **kwargs)

                def fail_file_list(path, roots, label):
                    if failure == label.replace(" ", "-"):
                        raise module.PackageStageError(
                            f"injected {label} validation failure"
                        )
                    return original_file_list(path, roots, label)

                baseline = len(os.listdir("/dev/fd"))
                with mock.patch.object(
                    module,
                    "_open_anchored_directory",
                    side_effect=observe_destination_parent,
                ), mock.patch.object(
                    module,
                    "_canonical_path",
                    side_effect=fail_canonical,
                ), mock.patch.object(
                    module,
                    "_ensure_external_file_list",
                    side_effect=fail_file_list,
                ):
                    with self.assertRaisesRegex(
                        module.PackageStageError,
                        "injected .* validation failure",
                    ):
                        module.stage_verified_package(
                            source,
                            destination,
                            input_list,
                            output_list,
                        )

                self.assertTrue(destination_parent_opened)
                self.assertEqual(len(os.listdir("/dev/fd")), baseline)
                self.assertFalse(destination.exists())
                self.assertFalse(input_list.exists())
                self.assertFalse(output_list.exists())

    def test_does_not_contain_acquisition_or_materializer_invocation(self) -> None:
        forbidden = (
            "curl",
            "wget",
            "git clone",
            "download",
            "materializer",
            "extract_sleigh_package",
            "subprocess",
            "urlopen",
        )
        # Scope this boundary to the shipping resource stager and its imported
        # verifier, not the neighboring offline builders and qualification tools.
        integration_files = (
            STAGE_PATH,
            STAGE_PATH.parent / "stage_xcode_resources.py",
        )
        self.assertIn(STAGE_PATH, integration_files)
        for item in integration_files:
            source = item.read_text(encoding="utf-8").casefold()
            for token in forbidden:
                self.assertNotIn(token, source, f"{token!r} appears in {item}")

        verifier = DIRECT_ROOT / "sleigh_package.py"
        allowed_imports = {
            "__future__", "argparse", "concurrent.futures", "dataclasses",
            "hashlib", "importlib.util", "json", "os", "pathlib", "re",
            "sleigh_package", "stat", "sys", "typing",
        }
        for item in (*integration_files, verifier):
            tree = ast.parse(item.read_text(encoding="utf-8"))
            imported = {
                name
                for node in ast.walk(tree)
                for name in (
                    [alias.name for alias in node.names] if isinstance(node, ast.Import)
                    else [node.module] if isinstance(node, ast.ImportFrom)
                    else []
                )
            }
            self.assertLessEqual(imported, allowed_imports, f"unreviewed staging import in {item}")
        resource_stager = integration_files[1].read_text(encoding="utf-8")
        self.assertIn('STAGER_PATH = SCRIPT_ROOT / "stage_verified_package.py"', resource_stager)
        self.assertIn('from sleigh_package import PackageContractError, verify_materialization', STAGE_PATH.read_text())

    def test_file_lists_are_deterministic_across_identical_stages(self) -> None:
        self.stage()
        first_inputs = self.input_list.read_bytes()
        first_outputs = self.output_list.read_bytes()
        shutil.rmtree(self.destination)
        self.input_list.unlink()
        self.output_list.unlink()
        self.stage()
        self.assertEqual(first_inputs, self.input_list.read_bytes())
        self.assertEqual(first_outputs, self.output_list.read_bytes())


if __name__ == "__main__":
    unittest.main()
