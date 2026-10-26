"""Focused, build-free coverage for the isolated native sanitizer profile."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_sleigh_native_package import SleighPackageFixture, sleigh_package
import sleigh_sanitizer_profile


class SleighSanitizerProfileTests(unittest.TestCase):
    @staticmethod
    def archive_bytes(members: dict[str, bytes], *, extended: bool = True) -> bytes:
        archive = b"!<arch>\n"
        for name, payload in members.items():
            label = name + "/"
            if extended:
                encoded = name.encode("utf-8") + b"\x00" * 3
                label = "#1/" + str(len(encoded))
                payload = encoded + payload
            header = (f"{label:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n").encode("ascii")
            archive += header + payload + (b"\n" if len(payload) % 2 else b"")
        return archive

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.materialization = self.root / "materialization"
        self.package = self.materialization / "package"
        self.package.mkdir(parents=True)
        SleighPackageFixture(self.package).create()
        for target, archive in (("sleigh_decomp", "libdecomp.a"), ("sleigh_sla", "libsla.a")):
            payload = ("instrumented object " + target).encode("utf-8")
            object_file = self.root / ("src/CMakeFiles/" + target + ".dir/unit.cc.o")
            object_file.parent.mkdir(parents=True)
            object_file.write_bytes(payload)
            (self.package / "lib" / archive).write_bytes(self.archive_bytes({
                "__.SYMDEF": b"index", "unit.cc.o": payload,
            }))
        self.analysis = sleigh_package.analyze_package(self.package)
        self.compiler = self.root / "clang++"
        self.compiler.write_text("compiler")
        self.sdk = self.root / "MacOSX27.2.sdk"
        self.sdk.mkdir()
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.2"}')
        self.toolchain = {
            "compiler": {"path": str(self.compiler), "sha256": "a" * 64,
                         "version": "Apple clang version 21.0.0"},
            "cmake": {"path": "/tools/cmake", "sha256": "b" * 64,
                      "version": "cmake version 4.1.0"},
            "ninja": {"path": "/tools/ninja", "sha256": "c" * 64,
                      "version": "1.13.1"},
        }

    def instrumentation(self, profile: str = "address") -> dict:
        return {
            "profile": profile,
            "compileCommandsSha256": "d" * 64,
            "sdkRoot": str(self.sdk),
            "sdkSettingsSha256": "e" * 64,
            "translationUnitCounts": {"sleigh_decomp": 1, "sleigh_sla": 1},
            "archiveSha256": {name: self.analysis["criticalFileSha256"][name]
                              for name in ("lib/libdecomp.a", "lib/libsla.a")},
        }

    def manifest(self, profile: str = "address") -> dict:
        try:
            return sleigh_package.source_materialization_value(
                self.analysis, self.toolchain, sanitizer=profile,
                instrumentation=self.instrumentation(profile),
            )
        except TypeError as error:
            self.fail(f"explicit sanitizer materialization profile is unavailable: {error}")

    def save(self, value: dict) -> None:
        (self.materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n"
        )

    def test_schema_three_requires_the_exact_explicit_profile(self) -> None:
        for profile in ("address", "undefined"):
            with self.subTest(profile=profile):
                value = self.manifest(profile)
                self.assertEqual(value["schemaVersion"], 3)
                self.save(value)
                self.assertEqual(sleigh_package.verify_materialization(
                    self.materialization, expected_sanitizer=profile), value)
                for other in ("none", "undefined" if profile == "address" else "address"):
                    with self.assertRaises(sleigh_package.PackageContractError):
                        sleigh_package.verify_materialization(
                            self.materialization, expected_sanitizer=other)

    def test_production_schemas_remain_default_only(self) -> None:
        for value in (
            sleigh_package.source_materialization_value(self.analysis, self.toolchain),
            sleigh_package.materialization_value(
                sleigh_package.APPROVED_ARTIFACTS["macos-arm64"], self.analysis),
        ):
            self.save(value)
            sleigh_package.verify_materialization(self.materialization)
            with self.assertRaises(sleigh_package.PackageContractError):
                sleigh_package.verify_materialization(
                    self.materialization, expected_sanitizer="address")
            value["sanitizer"] = "address"
            self.save(value)
            with self.assertRaises(sleigh_package.PackageContractError):
                sleigh_package.verify_materialization(self.materialization)

    def test_schema_three_rejects_receipt_mutations(self) -> None:
        original = self.manifest()
        mutations = [
            lambda v: v.pop("sanitizer"),
            lambda v: v.update(sanitizer="address,undefined"),
            lambda v: v["sourceBuild"]["instrumentation"].update(profile="undefined"),
            lambda v: v["sourceBuild"]["instrumentation"].update(extra=True),
            lambda v: v["sourceBuild"]["instrumentation"].update(sdkRoot="relative"),
            lambda v: v["sourceBuild"]["instrumentation"].update(compileCommandsSha256="x"),
            lambda v: v["sourceBuild"]["instrumentation"]["translationUnitCounts"].update(sleigh_sla=True),
            lambda v: v["sourceBuild"]["instrumentation"]["translationUnitCounts"].update(sleigh_sla=0),
            lambda v: v["sourceBuild"]["instrumentation"]["archiveSha256"].update({"lib/libsla.a": "f" * 64}),
            lambda v: v["sourceBuild"]["patches"][0].update(sha256="f" * 64),
        ]
        for mutate in mutations:
            value = copy.deepcopy(original)
            mutate(value)
            self.save(value)
            with self.assertRaises(sleigh_package.PackageContractError):
                sleigh_package.verify_materialization(
                    self.materialization, expected_sanitizer="address")

    def test_cli_requires_explicit_matching_profile(self) -> None:
        self.save(self.manifest())
        verifier = Path(sleigh_package.__file__).with_name("verify_sleigh_package.py")
        for profile, success in ((None, False), ("none", False), ("address", True),
                                 ("undefined", False), ("address,undefined", False)):
            arguments = [sys.executable, "-B", str(verifier), "verify",
                         "--materialization-root", str(self.materialization)]
            if profile is not None:
                arguments += ["--expected-sanitizer", profile]
            result = subprocess.run(arguments, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            if success:
                self.assertEqual(json.loads(result.stdout)["sanitizer"], "address")

    def test_cli_rejects_incomplete_producer_revalidation(self) -> None:
        self.save(self.manifest())
        verifier = Path(sleigh_package.__file__).with_name("verify_sleigh_package.py")
        result = subprocess.run([
            sys.executable, "-B", str(verifier), "verify",
            "--materialization-root", str(self.materialization),
            "--expected-sanitizer", "address", "--compiler", str(self.compiler),
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("producer revalidation requires", result.stderr)

    def commands(self, profile: str = "address") -> list[dict]:
        extra = "-fno-omit-frame-pointer" if profile == "address" else "-fno-sanitize-recover=all"
        return [{"directory": str(self.root), "file": str(self.root / (target + ".cc")),
                 "arguments": [str(self.compiler), "-fsanitize=" + profile, extra,
                               "-O1", "-g", "-DNDEBUG", "-arch", "arm64",
                               "-isysroot", str(self.sdk), "-mmacosx-version-min=27.0",
                               "-o", "src/CMakeFiles/" + target + ".dir/unit.cc.o",
                               "-c", str(self.root / (target + ".cc"))]}
                for target in ("sleigh_decomp", "sleigh_sla")]

    def inspect(self, commands: list[dict], profile: str = "address", *,
                symbols: bool = True) -> dict:
        path = self.root / "compile_commands.json"
        path.write_text(json.dumps(commands))
        def metadata(argv: list[str]) -> str:
            if "-t" in argv:
                return subprocess.run(argv, check=True, capture_output=True, text=True).stdout
            return "                 U ___" + ("asan_init" if profile == "address" else "ubsan_handle_add_overflow") + "\n" if symbols else "                 U _malloc\n"
        self.assertTrue(hasattr(sleigh_sanitizer_profile, "inspect_sanitizer_build"),
                        "producer must inspect effective per-TU flags and archive evidence")
        with patch.object(sleigh_sanitizer_profile, "_native_metadata", side_effect=metadata):
            return sleigh_sanitizer_profile.inspect_sanitizer_build(
                self.package, path, self.compiler, self.sdk, profile)

    def test_producer_inspects_both_archives_and_effective_commands(self) -> None:
        for profile in ("address", "undefined"):
            evidence = self.inspect(self.commands(profile), profile)
            self.assertEqual(evidence["profile"], profile)
            self.assertEqual(evidence["translationUnitCounts"],
                             {"sleigh_decomp": 1, "sleigh_sla": 1})
            self.assertEqual(evidence["archiveSha256"], self.instrumentation()["archiveSha256"])

    def test_producer_rejects_missing_negated_or_mixed_instrumentation(self) -> None:
        mutations = [
            lambda c: c.pop(),
            lambda c: c[0]["arguments"].remove("-fsanitize=address"),
            lambda c: c[0]["arguments"].append("-fno-sanitize=address"),
            lambda c: c[0]["arguments"].append("-fsanitize=undefined"),
            lambda c: c[0]["arguments"].append("-D_LIBCPP_HAS_NO_ASAN"),
            lambda c: c[0]["arguments"].append("-O3"),
            lambda c: c[0]["arguments"].extend(["-isysroot", "/different-sdk"]),
            lambda c: c[0]["arguments"].__setitem__(0, "/different-compiler"),
            lambda c: c[0]["arguments"].append("@uninspected.rsp"),
            lambda c: c[0]["arguments"].append("-g0"),
            lambda c: c[0]["arguments"].append("-fomit-frame-pointer"),
            lambda c: c[0]["arguments"].append("-mmacosx-version-min=26.0"),
        ]
        for mutate in mutations:
            commands = self.commands()
            mutate(commands)
            with self.assertRaises(sleigh_package.PackageContractError):
                self.inspect(commands)

    def test_producer_rejects_borrowed_uninstrumented_archives(self) -> None:
        with self.assertRaises(sleigh_package.PackageContractError):
            self.inspect(self.commands(), symbols=False)

    def test_producer_rejects_missing_extra_or_substituted_archive_members(self) -> None:
        for members in ({"__.SYMDEF": b"index"},
                        {"unit.cc.o": b"instrumented object sleigh_decomp", "extra.cc.o": b"extra"},
                        {"other.cc.o": b"other"}):
            (self.package / "lib/libdecomp.a").write_bytes(self.archive_bytes(members))
            with self.assertRaises(sleigh_package.PackageContractError):
                self.inspect(self.commands())

    def test_producer_rejects_same_named_hybrid_archive_member(self) -> None:
        commands = self.commands()
        second = copy.deepcopy(commands[0])
        second["arguments"][second["arguments"].index("-o") + 1] = "src/CMakeFiles/sleigh_decomp.dir/second.cc.o"
        (self.root / "src/CMakeFiles/sleigh_decomp.dir/second.cc.o").write_bytes(b"instrumented second")
        commands.append(second)
        (self.package / "lib/libdecomp.a").write_bytes(self.archive_bytes({
            "unit.cc.o": b"instrumented object sleigh_decomp",
            "second.cc.o": b"ordinary uninstrumented substitute",
        }))
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "member bytes"):
            self.inspect(commands)

    def test_producer_resolves_absolute_recorded_objects_after_relocation(self) -> None:
        commands = self.commands()
        for command in commands:
            command["directory"] = "/old/transient/build"
            index = command["arguments"].index("-o") + 1
            command["arguments"][index] = command["directory"] + "/" + command["arguments"][index]
        self.inspect(commands)

    def test_producer_rejects_symlinked_object_parent_directory(self) -> None:
        target = self.root / "src/CMakeFiles/sleigh_decomp.dir"
        with tempfile.TemporaryDirectory() as external:
            moved = Path(external) / "sleigh_decomp.dir"
            shutil.move(str(target), moved)
            target.symlink_to(moved, target_is_directory=True)
            with self.assertRaisesRegex(sleigh_package.PackageContractError, "symlink|escapes"):
                self.inspect(self.commands())

    def test_archive_reader_rejects_truncated_duplicate_and_unsafe_members(self) -> None:
        archive = self.root / "bad.a"
        for payload in (b"!<arch>\ntruncated", self.archive_bytes({"../escape.o": b"bad"}),
                        self.archive_bytes({"unit.o": b"one"}) + self.archive_bytes({"unit.o": b"two"})[8:],
                        self.archive_bytes({"unit.o": b"data"})[:-2]):
            archive.write_bytes(payload)
            with self.assertRaises(sleigh_package.PackageContractError):
                sleigh_sanitizer_profile._native_archive_member_digests(archive)

    def test_archive_reader_supports_short_and_extended_member_names(self) -> None:
        archive = self.root / "valid.a"
        results = []
        for extended in (False, True):
            archive.write_bytes(self.archive_bytes({"unit.o": b"data"}, extended=extended))
            results.append(sleigh_sanitizer_profile._native_archive_member_digests(archive))
        self.assertEqual(results[0], results[1])

    def test_producer_rejects_undefined_recovery_override(self) -> None:
        commands = self.commands("undefined")
        commands[0]["arguments"].append("-fsanitize-recover=all")
        with self.assertRaises(sleigh_package.PackageContractError):
            self.inspect(commands, "undefined")

    def test_changed_archive_cannot_reuse_the_original_profile_receipt(self) -> None:
        self.save(self.manifest())
        (self.package / "lib/libdecomp.a").write_bytes(b"borrowed production archive")
        with self.assertRaises(sleigh_package.PackageContractError):
            sleigh_package.verify_materialization(self.materialization, expected_sanitizer="address")


if __name__ == "__main__":
    unittest.main()
