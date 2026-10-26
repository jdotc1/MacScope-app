"""Patch contract for the MacScope-patched AArch64 SLEIGH resources (WP0, decision D3).

Mirrors the Ghostty Surface patch contract: the upstream release-archive identity stays in
``package/`` and ``MATERIALIZATION.json``; the patched identity is recorded separately in
``PATCHED_RESOURCES.json`` and is reproduced offline from the archive baseline, the
digest-pinned patch series and the vendored ``sleigh`` compiler.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPONENT = ROOT / "ThirdParty/SleighNative"
PATCHES = COMPONENT / "patches/aarch64"
RESOURCES = COMPONENT / "AARCH64"
BASELINE = COMPONENT / "package/share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages"
RECORD = json.loads((COMPONENT / "PATCHED_RESOURCES.json").read_text(encoding="utf-8"))
COMPILE = ROOT / "Scripts/dependencies/compile_sleigh_aarch64_specs.sh"

EXPECTED_PATCHES = {
    '0001-AARCH64-fix-MOPS-WT-option-field-SET-mnemonic-and-si.patch':
        '871ef743a9c93a166b49b56e47cfd0317d68eef6dffc6aa93b02a43d62d7607a',
    '0002-AARCH64-exclude-odd-hint-immediates-from-BTI-and-dec.patch':
        '0e810a05543b6c27ddbea744d17773d9a192f76b12f507ac2b9d7eef287f48df',
    '0003-AARCH64-reject-MOPS-encodings-with-aliased-or-invali.patch':
        '7c18e7381e82a8fc5ca15c8c2957fe14565efe7c94bc5c1a2260c2a0ecd94645',
    '0004-dot-element-export-and-accumulator.patch':
        'a8ee6e1c6605be18c660ab3c0fb3e4510ee6586044abdc0f6b8557d9a8e0835c',
    '0005-rmif-rotate-and-preserve-flags.patch':
        '79cc5f04d77059b00c077b4aa2d985f4cf55c5307b316b59c49d41798dbe43e8',
    '0006-cssc-clear-upper-x.patch':
        'e266a214ba29c203860dfd70471b2aa1806210a3314c5ffe3300f13e367f8fd0',
    '0007-vector-lane-operands.patch':
        '221ac3c3063af3b349218189f7f8cd50d608aacf2084c28ae2bd9ab9e7e15c39',
    '0008-fjcvtzs-js-modulo-and-nzcv.patch':
        '7ed15e12a792b1d69227d3732014e0704328bbb83b1ff09d7de409ff28792399',
    '0009-fhm-widen-before-fp-accumulation.patch':
        '419d2e112fe2cd75fc08ae8f277de318d5a72e7ce8df3c9003f8aaefd30250ff',
    '0010-bf16-narrowing-and-preserved-halves.patch':
        '683179d8b377e2d0386c61353f5dc02ff87aae4700ecc8c52dbecfd239de72c2',
    '0011-dot-and-fcmla-accumulator-dataflow.patch':
        'faf2b748423826edd3c43bc7b4ff0091bf93bf40c4162caf9ba9b00aa1e45e79',
    '0012-base-modification-notice.patch':
        '582775adeea463398cda6e388e5981f340e4a2af33ac08f57787eff310c10059',
    '0013-frint-scalar-rounding-range.patch':
        'f2049514c8ddda6d403a8a64b49ae7af07dea7eb325c6da0a33ba289086710a4',
    '0014-sme-sme2-bounded-decode.patch':
        '422b35f225a487c867aba584fa12f72f0f64c58b7dee358f39e43f011b8f836d',
    '0015-cp1-sme-normal-path-and-decode-identities.patch':
        '2b35979c47380480efbbc6a66ce254e9337632aa39a51e1289cc9e500a7dcbd6',
    '0017-cp1b-vertical-mova-fixed-subpieces.patch':
        '171c7659b2e65afcf9ab94fb3bd83939037d2dcdeef132cfb578d6bc31f8737e',
    '0018-cp1b-decimal-register-display.patch':
        '200a70bf8fb6835f7eb0f019894ec299d8769957915d16f20a3112ed24862928',
    '0019-cp1b-packed-mova-destinations.patch':
        '02374e08a90ea064c8372cd5dae2ba6aabc0aafe19f0f67f59341aba11224a4d',
}
LANGUAGES = "Ghidra/Processors/AARCH64/data/languages/"
EXPECTED_CHANGED_PATHS = {
    LANGUAGES + "AARCH64_PAuthLR_MOPS_THE.sinc",
    LANGUAGES + "AARCH64base.sinc",
    LANGUAGES + "AARCH64instructions.sinc",
    LANGUAGES + "AARCH64neon.sinc",
    LANGUAGES + "AARCH64sme.sinc",
    LANGUAGES + "AARCH64sve.sinc",
    LANGUAGES + "AARCH64sme_core.sinc",
    LANGUAGES + "AARCH64sme_cp1.sinc",
}
ARCHIVE_PACKAGE_TREE = "9cc94c918e6af5659a211330561a7fed7099a00fa3ea05c54698051827498460"
PATCHED_CLOSURE_TREE = 'c7e6f7fc0c4d5228f1073d4e3f0a3b510ab80252784e95869f8c5c26d015aa8d'
PATCHED_PACKAGE_TREE = 'f58ca156d1fbe25f0941c37295b01e3b012be9937259aebb4e19db337f9b3eb6'


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SleighAArch64PatchContractTests(unittest.TestCase):
    def test_package_overlay_pin_is_materialized(self) -> None:
        # CP1 cannot infer a new full-package SHA from the old SHA in an archive
        # that deliberately omits package/. Fail closed until the Mac re-derives it.
        self.assertIsInstance(PATCHED_PACKAGE_TREE, str,
                              "CP1 requires Mac package-overlay repinning before acceptance")
        self.assertRegex(PATCHED_PACKAGE_TREE, r"^[0-9a-f]{64}$")

    def test_patch_set_is_closed_and_digest_pinned(self) -> None:
        observed = {path.name for path in PATCHES.iterdir() if path.is_file()}
        self.assertEqual(observed, set(EXPECTED_PATCHES))
        for name, digest in EXPECTED_PATCHES.items():
            self.assertEqual(sha256(PATCHES / name), digest)
        self.assertEqual(
            RECORD["patchSeries"],
            [{"path": f"patches/aarch64/{name}", "sha256": digest}
             for name, digest in sorted(EXPECTED_PATCHES.items())],
        )

    def test_patch_set_changes_only_reviewed_upstream_paths(self) -> None:
        observed: set[str] = set()
        for name in EXPECTED_PATCHES:
            text = (PATCHES / name).read_text(encoding="utf-8")
            observed.update(re.findall(r"^diff --git a/(\S+) b/\S+$", text, re.MULTILINE))
        self.assertEqual(observed, EXPECTED_CHANGED_PATHS)

    def test_archive_identity_is_kept_and_patched_identity_is_separate(self) -> None:
        manifest = json.loads((COMPONENT / "MATERIALIZATION.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["package"]["treeSha256"], ARCHIVE_PACKAGE_TREE)
        self.assertEqual(RECORD["baseline"]["packageTreeSha256"], ARCHIVE_PACKAGE_TREE)
        self.assertEqual(RECORD["patched"]["resourceClosureTreeSha256"], PATCHED_CLOSURE_TREE)
        self.assertEqual(RECORD["patched"]["packageTreeSha256WithResourceOverlay"], PATCHED_PACKAGE_TREE)
        internalize = load("internalize", "Scripts/dependencies/internalize_sleigh_aarch64_resources.py")
        analysis = internalize.inspect(RESOURCES)
        self.assertEqual(analysis["treeSha256"], PATCHED_CLOSURE_TREE)
        for name, entry in RECORD["patched"]["changedFiles"].items():
            self.assertEqual(sha256(RESOURCES / name), entry["patchedSha256"])
            baseline = BASELINE / name
            if entry["baselineSha256"] is None:
                self.assertFalse(baseline.exists())
            else:
                self.assertEqual(sha256(baseline), entry["baselineSha256"])
        unchanged = {path.name for path in RESOURCES.iterdir()} - set(RECORD["patched"]["changedFiles"])
        for name in unchanged:
            self.assertEqual(sha256(RESOURCES / name), sha256(BASELINE / name), name)

    def test_series_replays_from_archive_baseline_and_compiles_to_committed_sla(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            replay = pathlib.Path(directory) / "replay"
            replay.mkdir()
            for path in BASELINE.iterdir():
                if path.suffix in (".sinc", ".slaspec"):
                    shutil.copyfile(path, replay / path.name)
            for name in sorted(EXPECTED_PATCHES):
                subprocess.run(
                    ["/usr/bin/patch", "--batch", "--fuzz=0", "-s", "-p6", "-d", str(replay),
                     "-i", str(PATCHES / name)],
                    check=True,
                )
            # BSD /usr/bin/patch defaults to --backup-if-mismatch and leaves *.orig after an
            # offset hunk (0009 on AARCH64neon.sinc). Offsets are allowed; fuzz and failures
            # are not (--fuzz=0, check=True), so drop the backups before comparing.
            for backup in replay.glob("*.orig"):
                backup.unlink()
            for path in replay.iterdir():
                self.assertEqual(sha256(path), sha256(RESOURCES / path.name), path.name)
            completed = subprocess.run(
                [str(COMPILE), "--spec-root", str(replay), "--work-root", f"{directory}/compile"],
                check=True, capture_output=True, text=True,
            )
            receipt = json.loads(completed.stdout)
            for name, digest in receipt["outputs"].items():
                self.assertEqual(digest, sha256(RESOURCES / name), name)
                self.assertEqual(digest, RECORD["patched"]["changedFiles"][name]["patchedSha256"])

    def test_unmodified_upstream_spec_recompiles_byte_for_byte(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [str(COMPILE), "--spec-root", str(BASELINE), "--work-root", f"{directory}/compile"],
                check=True, capture_output=True, text=True,
            )
            receipt = json.loads(completed.stdout)
            for name, digest in receipt["outputs"].items():
                self.assertEqual(digest, sha256(BASELINE / name), name)

    def test_overlay_package_identity_matches_record(self) -> None:
        verifier = load("vendored", "Scripts/dependencies/verify_vendored_sleigh_native.py")
        package = COMPONENT / "package"
        prefix = BASELINE.relative_to(package).as_posix() + "/"
        entries: dict[str, tuple[int, str]] = {}
        for path in package.rglob("*"):
            if path.is_file():
                entries[path.relative_to(package).as_posix()] = (path.stat().st_size, sha256(path))
        for path in RESOURCES.iterdir():
            entries[prefix + path.name] = (path.stat().st_size, sha256(path))
        digest = hashlib.sha256()
        for relative in sorted(entries, key=lambda value: value.encode()):
            size, member = entries[relative]
            digest.update(relative.encode() + b"\0" + str(size).encode() + b"\0" + member.encode() + b"\0")
        self.assertEqual(digest.hexdigest(), PATCHED_PACKAGE_TREE)
        self.assertEqual(len(entries), RECORD["patched"]["packageFileCountWithResourceOverlay"])
        self.assertTrue(callable(verifier.tree_digest))


if __name__ == "__main__":
    unittest.main()
