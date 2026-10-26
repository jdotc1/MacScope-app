#!/usr/bin/env python3
"""Create and validate the sealed native live-XPC test preparation receipt."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from xml.parsers.expat import ExpatError
from pathlib import Path
from typing import Any, NamedTuple


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction.validate_qualification_product_identity import (  # noqa: E402
    ProductIdentityError,
    validate_products,
)
from Scripts.check_local_signing_policy import (  # noqa: E402
    validate_release_provenance,
)
from Scripts.reconstruction import (  # noqa: E402
    install_release_to_applications as release_installer,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    canonical_sha256,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (  # noqa: E402
    BundleSnapshot,
    CandidateMaterializationError,
    FileSnapshot,
    capture_bundle_snapshot,
    bundle_snapshots_match,
    capture_file_snapshot,
    require_unchanged_bundle_snapshot,
    require_unchanged_file_snapshot,
)
from Scripts.reconstruction_gate_f.schema import parse_candidate_identity  # noqa: E402
from Scripts.qualification import generated_project_evidence  # noqa: E402


SCHEMA_VERSION = 2
RECEIPT_KIND = "native-live-xpc-preparation"
LIVE_TEST_CONDITION = "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
INSTALLED_UI_TEST_CONDITION = "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"
SCHEME = "MacScopeApp"
INSTALLED_UI_SCHEME = "MacScopeInstalledAppUITests"
CONFIGURATION = "Debug"
DESTINATION = "platform=macOS,arch=arm64"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")

TOP_LEVEL_FIELDS = {
    "schema_version",
    "receipt_kind",
    "source",
    "toolchain",
    "build",
    "artifacts",
}
SOURCE_FIELDS = {
    "repository",
    "branch_label",
    "commit",
    "tree",
    "dirty",
    "project_yml_sha256",
    "generated_project_sha256",
}
TOOLCHAIN_FIELDS = {
    "developer_dir",
    "xcodebuild_sha256",
    "xcode_version",
    "xcode_build",
    "swiftc_sha256",
    "swift_version",
    "sdk_path",
    "sdk_settings_sha256",
    "sdk_version",
    "sdk_build",
}
BUILD_FIELDS = {
    "scheme",
    "configuration",
    "destination",
    "live_test_condition",
    "preparation_mode",
}
ARTIFACT_FIELDS = {"xctestrun", "app", "native_decompiler", "core_tests"}
INSTALLED_UI_ARTIFACT_FIELDS = {"xctestrun", "app", "ui_test_bundle", "ui_runner"}
FILE_ARTIFACT_FIELDS = {"path", "sha256"}
BUNDLE_ARTIFACT_FIELDS = {
    "path",
    "closed_tree_sha256",
    "executable_sha256",
}
NATIVE_LIVE_PREPARATION_MODE = "native-live-coretests"
INSTALLED_UI_PREPARATION_MODE = "installed-ui-matrix"
INSTALLED_UI_DUPLICATE_PRODUCTS = {
    Path("Debug/AIAgentWorkerXPCService.xpc"): (
        "bundle",
        Path("Contents/XPCServices/AIAgentWorkerXPCService.xpc"),
    ),
    Path("Debug/AnalysisWorkerXPCService.xpc"): (
        "bundle",
        Path("Contents/XPCServices/AnalysisWorkerXPCService.xpc"),
    ),
    Path("Debug/NativeDecompilerXPCService.xpc"): (
        "bundle",
        Path("Contents/XPCServices/NativeDecompilerXPCService.xpc"),
    ),
    Path("Debug/ShellBrokerXPCService.xpc"): (
        "bundle",
        Path("Contents/XPCServices/ShellBrokerXPCService.xpc"),
    ),
    Path("Debug/SourceExecutionRunner"): (
        "file",
        Path("Contents/MacOS/SourceExecutionRunner"),
    ),
    Path("Debug/ShellBrokerLaunchAgent"): (
        "file",
        Path("Contents/MacOS/ShellBrokerLaunchAgent"),
    ),
}


class PreparationReceiptError(ValueError):
    pass


class SourceSnapshot(NamedTuple):
    """The exact clean Git source state that produced one prepared product."""

    branch_label: str
    commit: str
    status: str
    tree: str


class PreparationPublicationFence(NamedTuple):
    """Source and physical products that must remain exact through publication."""

    repository_root: Path
    source_snapshot: SourceSnapshot
    file_snapshots: tuple[FileSnapshot, ...]
    bundle_snapshots: tuple[BundleSnapshot, ...]


class InstalledReleaseAuthority(NamedTuple):
    """Frozen candidate/receipt authority for one ordinary installed Release app."""

    receipt_path: Path
    receipt_snapshot: FileSnapshot
    receipt_sha256: str
    source_authority: release_installer.SourceAuthority
    application_executable: Path
    native_executable: Path
    native_executable_sha256: str


def _run(argv: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise PreparationReceiptError(
            f"command failed ({result.returncode}): {' '.join(argv)}: {result.stderr.strip()}"
        )
    return result


def _ordinary(path: Path, *, directory: bool) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PreparationReceiptError(f"required path is unavailable: {path}: {error}") from error
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "regular file"
        raise PreparationReceiptError(f"required path is not a non-symlink {kind}: {path}")


def _canonical_existing(path: Path, *, directory: bool) -> Path:
    _ordinary(path, directory=directory)
    resolved = path.resolve(strict=True)
    _ordinary(resolved, directory=directory)
    return resolved


def _canonical_tool(path: Path) -> Path:
    """Resolve an Xcode tool shim while keeping product inputs symlink-free."""

    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise PreparationReceiptError(
            f"required tool path is unavailable: {path}: {error}"
        ) from error
    _ordinary(resolved, directory=False)
    if not os.access(resolved, os.X_OK):
        raise PreparationReceiptError(f"required tool is not executable: {resolved}")
    return resolved


def _canonical_toolchain_directory(path: Path, *, developer_dir: Path) -> Path:
    """Resolve an Xcode-owned directory shim without relaxing product inputs."""

    try:
        canonical_developer_dir = developer_dir.resolve(strict=True)
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise PreparationReceiptError(
            f"required toolchain directory is unavailable: {path}: {error}"
        ) from error
    _ordinary(canonical_developer_dir, directory=True)
    _ordinary(resolved, directory=True)
    try:
        resolved.relative_to(canonical_developer_dir)
    except ValueError as error:
        raise PreparationReceiptError(
            f"required toolchain directory is outside the audited Xcode developer directory: {path}"
        ) from error
    return resolved


def file_sha256(path: Path) -> str:
    try:
        return capture_file_snapshot(path).sha256
    except CandidateMaterializationError as error:
        raise PreparationReceiptError(f"cannot hash {path} safely: {error}") from error


def _capture_prepared_file_snapshot(path: Path) -> FileSnapshot:
    try:
        return capture_file_snapshot(path)
    except CandidateMaterializationError as error:
        raise PreparationReceiptError(
            f"prepared product file is not a stable physical identity: {path}: {error}"
        ) from error


def _capture_prepared_bundle_snapshot(path: Path) -> BundleSnapshot:
    try:
        return capture_bundle_snapshot(path, app_root=path.suffix == ".app")
    except CandidateMaterializationError as error:
        raise PreparationReceiptError(
            f"prepared product bundle is not a stable physical identity: {path}: {error}"
        ) from error


def _require_unchanged_prepared_file_snapshot(snapshot: FileSnapshot, *, phase: str) -> None:
    try:
        require_unchanged_file_snapshot(snapshot, phase=phase)
    except CandidateMaterializationError as error:
        raise PreparationReceiptError(str(error)) from error


def _require_unchanged_prepared_bundle_snapshot(
    snapshot: BundleSnapshot,
    *,
    phase: str,
) -> None:
    try:
        require_unchanged_bundle_snapshot(snapshot, phase=phase)
    except CandidateMaterializationError as error:
        raise PreparationReceiptError(str(error)) from error


def closed_tree_sha256(root: Path) -> str:
    """Return a descriptor-fenced, double-read physical tree identity."""

    return _capture_prepared_bundle_snapshot(root).digests.closed_tree_sha256


def _xctestrun_contract(path: Path) -> None:
    _ordinary(path, directory=False)
    try:
        with path.open("rb") as stream:
            document = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise PreparationReceiptError(f"xctestrun cannot be decoded safely: {error}") from error
    if not isinstance(document, dict):
        raise PreparationReceiptError("xctestrun root is not an object")
    metadata = document.get("__xctestrun_metadata__", {})
    suite = document.get("CoreTests")
    if not isinstance(metadata, dict) or not isinstance(suite, dict):
        raise PreparationReceiptError("xctestrun lacks the MacScope CoreTests contract")
    if metadata.get("ContainerInfo", {}).get("SchemeName") != SCHEME:
        raise PreparationReceiptError("xctestrun is not the MacScopeApp scheme product")
    if suite.get("BlueprintName") != "CoreTests":
        raise PreparationReceiptError("xctestrun does not carry the CoreTests bundle")
    if suite.get("IsAppHostedTestBundle") is not True:
        raise PreparationReceiptError("CoreTests is not an app-hosted test bundle")
    if suite.get("TestHostBundleIdentifier") != "org.macscope.app":
        raise PreparationReceiptError("CoreTests does not name the MacScope host bundle")
    if suite.get("TestHostPath") != "__TESTROOT__/Debug/MacScope.app":
        raise PreparationReceiptError("CoreTests is not bound to the expected MacScope host")
    if suite.get("TestBundlePath") != "__TESTHOST__/Contents/PlugIns/CoreTests.xctest":
        raise PreparationReceiptError("xctestrun does not name the expected CoreTests bundle")
    dependent_products = suite.get("DependentProductPaths")
    required_products = {
        "__TESTROOT__/Debug/MacScope.app",
        "__TESTROOT__/Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest",
    }
    if not isinstance(dependent_products, list) or not required_products.issubset(
        set(dependent_products)
    ):
        raise PreparationReceiptError(
            "xctestrun does not bind CoreTests and its MacScope host as dependent products"
        )


def _bundle_content_tree_identity(path: Path) -> tuple[str, tuple[tuple[object, ...], ...]]:
    """Bind a build duplicate to a sealed bundle while ignoring directory modes only.

    Xcode normalizes directory and non-executable resource permission bits
    while preserving closed content. These products are build-graph
    duplicates, not executed products. Paths, file sizes, bytes, and the
    executable/non-executable boundary remain exact.
    """

    path = _canonical_existing(path, directory=True)
    before = _capture_prepared_bundle_snapshot(path)
    records: list[tuple[object, ...]] = []
    for current_root, directories, files in os.walk(path, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        current = Path(current_root)
        for name in tuple(directories) + tuple(files):
            entry = current / name
            relative = entry.relative_to(path).as_posix()
            metadata = entry.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise PreparationReceiptError(
                    f"installed UI duplicate product contains a symlink: {entry}"
                )
            if stat.S_ISDIR(metadata.st_mode):
                records.append((relative, "directory"))
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1:
                    raise PreparationReceiptError(
                        f"installed UI duplicate product contains a hardlink: {entry}"
                    )
                records.append(
                    (
                        relative,
                        "file",
                        bool(stat.S_IMODE(metadata.st_mode) & 0o111),
                        metadata.st_size,
                    )
                )
            else:
                raise PreparationReceiptError(
                    f"installed UI duplicate product contains a special entry: {entry}"
                )
    after = _capture_prepared_bundle_snapshot(path)
    if not bundle_snapshots_match(after, before):
        raise PreparationReceiptError(
            f"installed UI duplicate product changed during validation: {path}"
        )
    return before.digests.content_sha256, tuple(records)


def _require_duplicate_product_identity(
    duplicate: Path,
    sealed: Path,
    *,
    kind: str,
) -> None:
    if kind == "bundle":
        duplicate_identity = _bundle_content_tree_identity(duplicate)
        sealed_identity = _bundle_content_tree_identity(sealed)
        if duplicate_identity != sealed_identity:
            raise PreparationReceiptError(
                "installed UI duplicate bundle differs from its sealed candidate product"
            )
        return
    if kind != "file":
        raise PreparationReceiptError("installed UI duplicate product kind is unsupported")
    duplicate = _canonical_existing(duplicate, directory=False)
    sealed = _canonical_existing(sealed, directory=False)
    duplicate_metadata = duplicate.lstat()
    sealed_metadata = sealed.lstat()
    if duplicate_metadata.st_nlink != 1 or sealed_metadata.st_nlink != 1:
        raise PreparationReceiptError("installed UI duplicate product contains a hardlink")
    if (
        stat.S_IMODE(duplicate_metadata.st_mode) != stat.S_IMODE(sealed_metadata.st_mode)
        or duplicate_metadata.st_size != sealed_metadata.st_size
        or file_sha256(duplicate) != file_sha256(sealed)
    ):
        raise PreparationReceiptError(
            "installed UI duplicate file differs from its sealed candidate product"
        )


def _installed_ui_xctestrun_contract(
    path: Path,
    *,
    test_bundle: Path,
    ui_runner: Path,
    candidate_app: Path,
) -> None:
    """Bind an installed UI xctestrun to exactly the prepared products.

    This intentionally duplicates only the small, closed plist boundary.  The
    installed receipt imports this helper, so importing that module here would
    create a circular authority path.
    """
    _ordinary(path, directory=False)
    try:
        with path.open("rb") as stream:
            document = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise PreparationReceiptError(f"installed UI xctestrun cannot be decoded safely: {error}") from error
    if not isinstance(document, dict):
        raise PreparationReceiptError("installed UI xctestrun root is not an object")
    metadata = document.get("__xctestrun_metadata__")
    if not isinstance(metadata, dict) or metadata.get("ContainerInfo", {}).get("SchemeName") != INSTALLED_UI_SCHEME:
        raise PreparationReceiptError("installed UI xctestrun is not the MacScopeInstalledAppUITests scheme")
    suites = [
        value for key, value in document.items()
        if key != "__xctestrun_metadata__" and isinstance(value, dict)
        and value.get("BlueprintName") == "MacScopeInstalledAppUITests"
    ]
    if len(suites) != 1:
        raise PreparationReceiptError("installed UI xctestrun must contain exactly one UI test target")
    suite = suites[0]
    test_root = path.parent

    def resolve(value: Any, field: str, *, roots: dict[str, Path]) -> Path:
        if not isinstance(value, str) or "\x00" in value:
            raise PreparationReceiptError(f"installed UI xctestrun {field} must be text")
        macro, separator, remainder = value.partition("/")
        if not separator or macro not in roots:
            raise PreparationReceiptError(f"installed UI xctestrun {field} has an unsupported root")
        relative = Path(remainder)
        if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
            raise PreparationReceiptError(f"installed UI xctestrun {field} has traversal")
        return roots[macro] / relative

    test_host = resolve(
        suite.get("TestHostPath"),
        "TestHostPath",
        roots={"__TESTROOT__": test_root},
    )
    if test_host != ui_runner:
        raise PreparationReceiptError("installed UI xctestrun does not bind the sealed UI runner")
    product_roots = {"__TESTROOT__": test_root, "__TESTHOST__": test_host}
    if resolve(
        suite.get("TestBundlePath"),
        "TestBundlePath",
        roots=product_roots,
    ) != test_bundle:
        raise PreparationReceiptError("installed UI xctestrun does not bind the sealed UI test bundle")
    target = resolve(
        suite.get("UITargetAppPath"),
        "UITargetAppPath",
        roots=product_roots,
    )
    prepared_debug_app = test_root / "Debug/MacScope.app"
    if candidate_app.parent.name == "Release":
        _ordinary(prepared_debug_app, directory=True)
    else:
        prepared_debug_app = candidate_app
    if target not in {ui_runner, prepared_debug_app}:
        raise PreparationReceiptError("installed UI xctestrun does not bind a sealed target product")
    dependencies = suite.get("DependentProductPaths")
    if not isinstance(dependencies, list) or not all(isinstance(value, str) for value in dependencies):
        raise PreparationReceiptError("installed UI xctestrun has no closed dependent product list")
    resolved_dependencies = {
        resolve(value, "DependentProductPaths", roots=product_roots)
        for value in dependencies
    }
    sealed_products = {test_bundle, ui_runner, prepared_debug_app}
    for dependency in resolved_dependencies - sealed_products:
        try:
            relative = dependency.relative_to(test_root)
        except ValueError as error:
            raise PreparationReceiptError(
                "installed UI xctestrun depends on an unsealed product"
            ) from error
        duplicate_contract = INSTALLED_UI_DUPLICATE_PRODUCTS.get(relative)
        if duplicate_contract is None:
            raise PreparationReceiptError(
                "installed UI xctestrun depends on an unsealed product"
            )
        kind, embedded_relative = duplicate_contract
        _require_duplicate_product_identity(
            dependency,
            prepared_debug_app / embedded_relative,
            kind=kind,
        )


def _artifact_paths(
    candidate_app: Path,
    test_bundle: Path | None = None,
) -> tuple[Path, Path, Path]:
    native = (
        candidate_app
        / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService"
    )
    app_executable = candidate_app / "Contents/MacOS/MacScope"
    core_tests = (
        test_bundle
        if test_bundle is not None
        else candidate_app / "Contents/PlugIns/CoreTests.xctest"
    )
    core_tests_executable = core_tests / "Contents/MacOS/CoreTests"
    for path in (native, app_executable, core_tests_executable):
        _ordinary(path, directory=False)
        if not os.access(path, os.X_OK):
            raise PreparationReceiptError(f"prepared executable is not executable: {path}")
    _ordinary(core_tests, directory=True)
    return native, app_executable, core_tests


def _installed_ui_artifact_paths(
    candidate_app: Path,
    test_bundle: Path,
    ui_runner: Path,
) -> tuple[Path, Path, Path]:
    app_executable = candidate_app / "Contents/MacOS/MacScope"
    test_executable = test_bundle / "Contents/MacOS/MacScopeInstalledAppUITests"
    runner_executable = ui_runner / "Contents/MacOS/MacScopeInstalledAppUITests-Runner"
    for path in (app_executable, test_executable, runner_executable):
        _ordinary(path, directory=False)
        if not os.access(path, os.X_OK):
            raise PreparationReceiptError(f"prepared executable is not executable: {path}")
    _ordinary(test_bundle, directory=True)
    _ordinary(ui_runner, directory=True)
    return app_executable, test_executable, runner_executable


def _toolchain_identity() -> dict[str, str]:
    developer_dir_value = os.environ.get("DEVELOPER_DIR")
    if not developer_dir_value:
        raise PreparationReceiptError("DEVELOPER_DIR must name the audited Xcode 27 toolchain")
    developer_dir = _canonical_existing(Path(developer_dir_value), directory=True)
    xcodebuild = _canonical_tool(developer_dir / "usr/bin/xcodebuild")
    swiftc = _canonical_tool(
        developer_dir / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    )
    xcode_lines = _run([str(xcodebuild), "-version"]).stdout.splitlines()
    if len(xcode_lines) != 2 or not xcode_lines[0].startswith("Xcode 27"):
        raise PreparationReceiptError("the preparation toolchain is not the Xcode 27 major line")
    xcode_version = xcode_lines[0].removeprefix("Xcode ").strip()
    xcode_build = xcode_lines[1].removeprefix("Build version ").strip()
    swift_version = _run([str(swiftc), "--version"]).stdout.strip()
    sdk_path = _canonical_toolchain_directory(
        Path(
            _run(
                ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]
            ).stdout.strip()
        ),
        developer_dir=developer_dir,
    )
    sdk_version = _run(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]
    ).stdout.strip()
    sdk_build = _run(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
    ).stdout.strip()
    return {
        "developer_dir": str(developer_dir),
        "xcodebuild_sha256": file_sha256(xcodebuild),
        "xcode_version": xcode_version,
        "xcode_build": xcode_build,
        "swiftc_sha256": file_sha256(swiftc),
        "swift_version": swift_version,
        "sdk_path": str(sdk_path),
        "sdk_settings_sha256": file_sha256(sdk_path / "SDKSettings.json"),
        "sdk_version": sdk_version,
        "sdk_build": sdk_build,
    }


def _git(root: Path, *arguments: str) -> str:
    return _run(["/usr/bin/git", *arguments], cwd=root).stdout.strip()


def _capture_source_snapshot(root: Path) -> SourceSnapshot:
    """Capture the whole Git source identity, including every untracked path."""

    status = _git(root, "status", "--porcelain=v1", "--untracked-files=all")
    commit = _git(root, "rev-parse", "HEAD")
    tree = _git(root, "rev-parse", "HEAD^{tree}")
    if GIT_OBJECT_RE.fullmatch(commit) is None or GIT_OBJECT_RE.fullmatch(tree) is None:
        raise PreparationReceiptError("source commit or tree is not a full Git object identity")
    return SourceSnapshot(
        branch_label=_git(root, "branch", "--show-current"),
        commit=commit,
        status=status,
        tree=tree,
    )


def _require_clean_source_snapshot(root: Path) -> SourceSnapshot:
    snapshot = _capture_source_snapshot(root)
    if snapshot.status:
        raise PreparationReceiptError(
            "preparation requires an exactly clean source repository, including all untracked files"
        )
    if not snapshot.branch_label:
        raise PreparationReceiptError("repository label and branch must be nonempty")
    return snapshot


def _require_unchanged_source_snapshot(
    root: Path,
    expected: SourceSnapshot,
    *,
    phase: str,
) -> None:
    observed = _capture_source_snapshot(root)
    if observed != expected:
        raise PreparationReceiptError(
            f"source identity drifted before {phase}; "
            "HEAD, tree, branch, and clean status must remain exact"
        )


def _project_evidence_snapshots(
    products_root: Path, commit: str, tree: str, project_yml_sha256: str
) -> tuple[FileSnapshot, tuple[FileSnapshot, ...]]:
    run = products_root.parent.parent.parent
    if products_root != run / "DerivedData/Build/Products":
        raise PreparationReceiptError("prepared products have no governed qualification run")
    try:
        arguments = dict(commit=commit, tree=tree, project_yml_sha256=project_yml_sha256)
        project = generated_project_evidence.validate(run, **arguments)
        snapshots = tuple(_capture_prepared_file_snapshot(path) for path in generated_project_evidence.evidence_files(run))
        generated_project_evidence.validate(run, **arguments)
        for snapshot in snapshots:
            _require_unchanged_prepared_file_snapshot(snapshot, phase="generated project evidence admission")
        return next(snapshot for snapshot in snapshots if snapshot.path == project), snapshots
    except generated_project_evidence.GeneratedProjectEvidenceError as error:
        raise PreparationReceiptError(str(error)) from error


def create_document(
    repository_root: Path,
    repository_label: str,
    xctestrun: Path,
    candidate_app: Path,
    *,
    toolchain: dict[str, str] | None = None,
    preparation_mode: str = NATIVE_LIVE_PREPARATION_MODE,
    test_bundle: Path | None = None,
    ui_runner: Path | None = None,
    source_snapshot: SourceSnapshot | None = None,
    publication_fences: list[PreparationPublicationFence] | None = None,
) -> dict[str, object]:
    root = _canonical_existing(repository_root, directory=True)
    project_yml = _canonical_existing(root / "MacScope/project.yml", directory=False)
    project_yml_snapshot = _capture_prepared_file_snapshot(project_yml)
    observed_snapshot = _require_clean_source_snapshot(root)
    if source_snapshot is not None and source_snapshot != observed_snapshot:
        raise PreparationReceiptError(
            "source identity drifted before preparation receipt materialization"
        )
    source_snapshot = source_snapshot or observed_snapshot
    commit = source_snapshot.commit
    tree = source_snapshot.tree
    branch = source_snapshot.branch_label
    if not repository_label:
        raise PreparationReceiptError("repository label and branch must be nonempty")

    xctestrun = _canonical_existing(xctestrun, directory=False)
    candidate_app = _canonical_existing(candidate_app, directory=True)
    if preparation_mode not in {NATIVE_LIVE_PREPARATION_MODE, INSTALLED_UI_PREPARATION_MODE}:
        raise PreparationReceiptError("preparation mode is unsupported")
    products_root = xctestrun.parent
    generated_project_snapshot, project_evidence_snapshots = _project_evidence_snapshots(
        products_root, commit, tree, project_yml_snapshot.sha256
    )
    if (
        candidate_app.parent.parent != products_root
        or candidate_app.parent.name not in {CONFIGURATION, "Release"}
    ):
        raise PreparationReceiptError(
            "xctestrun and candidate app do not share the expected Build/Products root"
        )
    # Freeze every product before parsing contracts or reading executable bytes.
    # The final fence below prevents a receipt from combining an earlier tree
    # hash with later executable or signing-adjacent observations.
    xctestrun_snapshot = _capture_prepared_file_snapshot(xctestrun)
    candidate_app_snapshot = _capture_prepared_bundle_snapshot(candidate_app)
    file_snapshots: list[FileSnapshot] = [
        project_yml_snapshot,
        generated_project_snapshot,
        *project_evidence_snapshots,
        xctestrun_snapshot,
    ]
    bundle_snapshots: list[BundleSnapshot] = [candidate_app_snapshot]
    if preparation_mode == NATIVE_LIVE_PREPARATION_MODE:
        if ui_runner is not None:
            raise PreparationReceiptError(
                "native live preparation does not accept a UI runner"
            )
        if test_bundle is not None:
            test_bundle = _canonical_existing(test_bundle, directory=True)
            expected_test_bundle = (
                products_root
                / "Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest"
            )
            if test_bundle != expected_test_bundle:
                raise PreparationReceiptError(
                    "native live preparation test bundle is not the exact Debug CoreTests product"
                )
        _xctestrun_contract(xctestrun)
        native, app_executable, core_tests = _artifact_paths(candidate_app, test_bundle)
        core_tests_executable = core_tests / "Contents/MacOS/CoreTests"
        native_snapshot = _capture_prepared_file_snapshot(native)
        app_executable_snapshot = _capture_prepared_file_snapshot(app_executable)
        core_tests_snapshot = _capture_prepared_bundle_snapshot(core_tests)
        core_tests_executable_snapshot = _capture_prepared_file_snapshot(core_tests_executable)
        file_snapshots.extend(
            [native_snapshot, app_executable_snapshot, core_tests_executable_snapshot]
        )
        bundle_snapshots.append(core_tests_snapshot)
        artifacts: dict[str, object] = {
            "xctestrun": {"path": str(xctestrun), "sha256": xctestrun_snapshot.sha256},
            "app": {
                "path": str(candidate_app),
                "closed_tree_sha256": candidate_app_snapshot.digests.closed_tree_sha256,
                "executable_sha256": app_executable_snapshot.sha256,
            },
            "native_decompiler": {"path": str(native), "sha256": native_snapshot.sha256},
            "core_tests": {
                "path": str(core_tests),
                "closed_tree_sha256": core_tests_snapshot.digests.closed_tree_sha256,
                "executable_sha256": core_tests_executable_snapshot.sha256,
            },
        }
        scheme = SCHEME
        live_condition = LIVE_TEST_CONDITION
    else:
        if test_bundle is None or ui_runner is None:
            raise PreparationReceiptError("installed UI preparation requires test bundle and UI runner")
        test_bundle = _canonical_existing(test_bundle, directory=True)
        ui_runner = _canonical_existing(ui_runner, directory=True)
        _installed_ui_xctestrun_contract(
            xctestrun,
            test_bundle=test_bundle,
            ui_runner=ui_runner,
            candidate_app=candidate_app,
        )
        app_executable, test_executable, runner_executable = _installed_ui_artifact_paths(
            candidate_app, test_bundle, ui_runner
        )
        test_bundle_snapshot = _capture_prepared_bundle_snapshot(test_bundle)
        ui_runner_snapshot = _capture_prepared_bundle_snapshot(ui_runner)
        app_executable_snapshot = _capture_prepared_file_snapshot(app_executable)
        test_executable_snapshot = _capture_prepared_file_snapshot(test_executable)
        runner_executable_snapshot = _capture_prepared_file_snapshot(runner_executable)
        bundle_snapshots.extend([test_bundle_snapshot, ui_runner_snapshot])
        file_snapshots.extend(
            [app_executable_snapshot, test_executable_snapshot, runner_executable_snapshot]
        )
        artifacts = {
            "xctestrun": {"path": str(xctestrun), "sha256": xctestrun_snapshot.sha256},
            "app": {
                "path": str(candidate_app),
                "closed_tree_sha256": candidate_app_snapshot.digests.closed_tree_sha256,
                "executable_sha256": app_executable_snapshot.sha256,
            },
            "ui_test_bundle": {
                "path": str(test_bundle),
                "closed_tree_sha256": test_bundle_snapshot.digests.closed_tree_sha256,
                "executable_sha256": test_executable_snapshot.sha256,
            },
            "ui_runner": {
                "path": str(ui_runner),
                "closed_tree_sha256": ui_runner_snapshot.digests.closed_tree_sha256,
                "executable_sha256": runner_executable_snapshot.sha256,
            },
        }
        scheme = INSTALLED_UI_SCHEME
        live_condition = INSTALLED_UI_TEST_CONDITION
    document: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "receipt_kind": RECEIPT_KIND,
        "source": {
            "repository": repository_label,
            "branch_label": branch,
            "commit": commit,
            "tree": tree,
            "dirty": False,
            "project_yml_sha256": project_yml_snapshot.sha256,
            "generated_project_sha256": generated_project_snapshot.sha256,
        },
        "toolchain": toolchain if toolchain is not None else _toolchain_identity(),
        "build": {
            "scheme": scheme,
            "configuration": CONFIGURATION,
            "destination": DESTINATION,
            "live_test_condition": live_condition,
            "preparation_mode": preparation_mode,
        },
        "artifacts": artifacts,
    }
    for snapshot in file_snapshots:
        _require_unchanged_prepared_file_snapshot(
            snapshot,
            phase="preparation receipt publication after product reads",
        )
    for snapshot in bundle_snapshots:
        _require_unchanged_prepared_bundle_snapshot(
            snapshot,
            phase="preparation receipt publication after executable reads",
        )
    _require_unchanged_source_snapshot(
        root,
        source_snapshot,
        phase="preparation receipt publication",
    )
    if publication_fences is not None:
        publication_fences.append(
            PreparationPublicationFence(
                repository_root=root,
                source_snapshot=source_snapshot,
                file_snapshots=tuple(file_snapshots),
                bundle_snapshots=tuple(bundle_snapshots),
            )
        )
    return document


def _closed(record: Any, fields: set[str], path: str) -> dict[str, Any]:
    if not isinstance(record, dict) or set(record) != fields:
        raise PreparationReceiptError(f"{path} does not satisfy its closed field set")
    return record


def _text(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PreparationReceiptError(f"{path} must be nonempty bounded text")
    return value


def _digest(value: Any, path: str) -> str:
    value = _text(value, path)
    if SHA256_RE.fullmatch(value) is None:
        raise PreparationReceiptError(f"{path} must be lowercase SHA-256")
    return value


def parse_document(value: Any) -> dict[str, Any]:
    record = _closed(value, TOP_LEVEL_FIELDS, "$")
    if record["schema_version"] not in {1, SCHEMA_VERSION} or record["receipt_kind"] != RECEIPT_KIND:
        raise PreparationReceiptError("receipt schema version or kind is unsupported")
    source = _closed(record["source"], SOURCE_FIELDS, "$.source")
    toolchain = _closed(record["toolchain"], TOOLCHAIN_FIELDS, "$.toolchain")
    legacy_native = record["schema_version"] == 1
    build = _closed(
        record["build"],
        BUILD_FIELDS - {"preparation_mode"} if legacy_native else BUILD_FIELDS,
        "$.build",
    )
    if source["dirty"] is not False:
        raise PreparationReceiptError("receipt source must be clean")
    for field in ("repository", "branch_label"):
        _text(source[field], f"$.source.{field}")
    for field in ("commit", "tree"):
        if GIT_OBJECT_RE.fullmatch(_text(source[field], f"$.source.{field}")) is None:
            raise PreparationReceiptError(f"$.source.{field} must be a full Git object")
    for field in ("project_yml_sha256", "generated_project_sha256"):
        _digest(source[field], f"$.source.{field}")
    for field in TOOLCHAIN_FIELDS:
        _text(toolchain[field], f"$.toolchain.{field}")
    for field in ("xcodebuild_sha256", "swiftc_sha256"):
        _digest(toolchain[field], f"$.toolchain.{field}")
    mode = NATIVE_LIVE_PREPARATION_MODE if legacy_native else _text(
        build["preparation_mode"], "$.build.preparation_mode"
    )
    expected_builds = {
        NATIVE_LIVE_PREPARATION_MODE: {
            "scheme": SCHEME, "configuration": CONFIGURATION, "destination": DESTINATION,
            "live_test_condition": LIVE_TEST_CONDITION, "preparation_mode": NATIVE_LIVE_PREPARATION_MODE,
        },
        INSTALLED_UI_PREPARATION_MODE: {
            "scheme": INSTALLED_UI_SCHEME, "configuration": CONFIGURATION, "destination": DESTINATION,
            "live_test_condition": INSTALLED_UI_TEST_CONDITION, "preparation_mode": INSTALLED_UI_PREPARATION_MODE,
        },
    }
    expected_build = expected_builds.get(mode)
    if expected_build is None:
        raise PreparationReceiptError("receipt preparation mode is unsupported")
    if legacy_native:
        expected_build = dict(expected_build)
        expected_build.pop("preparation_mode")
    if build != expected_build:
        raise PreparationReceiptError("receipt build contract is not exact for its preparation mode")
    artifact_fields = ARTIFACT_FIELDS if mode == NATIVE_LIVE_PREPARATION_MODE else INSTALLED_UI_ARTIFACT_FIELDS
    artifacts = _closed(record["artifacts"], artifact_fields, "$.artifacts")
    artifact_shapes = (
        (("xctestrun", FILE_ARTIFACT_FIELDS), ("native_decompiler", FILE_ARTIFACT_FIELDS),
         ("app", BUNDLE_ARTIFACT_FIELDS), ("core_tests", BUNDLE_ARTIFACT_FIELDS))
        if mode == NATIVE_LIVE_PREPARATION_MODE else
        (("xctestrun", FILE_ARTIFACT_FIELDS), ("app", BUNDLE_ARTIFACT_FIELDS),
         ("ui_test_bundle", BUNDLE_ARTIFACT_FIELDS), ("ui_runner", BUNDLE_ARTIFACT_FIELDS))
    )
    for artifact_id, fields in artifact_shapes:
        artifact = _closed(artifacts[artifact_id], fields, f"$.artifacts.{artifact_id}")
        path = Path(_text(artifact["path"], f"$.artifacts.{artifact_id}.path"))
        if not path.is_absolute():
            raise PreparationReceiptError(f"$.artifacts.{artifact_id}.path must be absolute")
        for field in fields - {"path"}:
            _digest(artifact[field], f"$.artifacts.{artifact_id}.{field}")
    return record


def load_receipt(path: Path) -> dict[str, Any]:
    _ordinary(path, directory=False)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PreparationReceiptError(f"cannot decode preparation receipt: {error}") from error
    record = parse_document(value)
    if path.read_bytes() != canonical_bytes(record):
        raise PreparationReceiptError("preparation receipt is not canonical JSON")
    return record


def validate_prepared_artifacts(
    receipt: dict[str, Any],
    xctestrun: Path,
    candidate_app: Path,
    *,
    test_bundle: Path | None = None,
    ui_runner: Path | None = None,
) -> str:
    xctestrun = _canonical_existing(xctestrun, directory=False)
    candidate_app = _canonical_existing(candidate_app, directory=True)
    mode = receipt["build"].get("preparation_mode", NATIVE_LIVE_PREPARATION_MODE)
    artifacts = receipt["artifacts"]
    if Path(artifacts["xctestrun"]["path"]) != xctestrun:
        raise PreparationReceiptError("xctestrun path differs from the preparation receipt")
    if Path(artifacts["app"]["path"]) != candidate_app:
        raise PreparationReceiptError("candidate app path differs from the preparation receipt")
    xctestrun_snapshot = _capture_prepared_file_snapshot(xctestrun)
    candidate_app_snapshot = _capture_prepared_bundle_snapshot(candidate_app)
    project_snapshot, project_evidence_snapshots = _project_evidence_snapshots(
        xctestrun.parent, receipt["source"]["commit"], receipt["source"]["tree"],
        receipt["source"]["project_yml_sha256"],
    )
    if project_snapshot.sha256 != receipt["source"]["generated_project_sha256"]:
        raise PreparationReceiptError("preparation generated project differs from actual build evidence")
    file_snapshots: list[FileSnapshot] = [xctestrun_snapshot, *project_evidence_snapshots]
    bundle_snapshots: list[BundleSnapshot] = [candidate_app_snapshot]
    if mode == NATIVE_LIVE_PREPARATION_MODE:
        if ui_runner is not None:
            raise PreparationReceiptError(
                "native live preparation validation does not accept a UI runner"
            )
        if test_bundle is None:
            recorded_test_bundle = artifacts.get("core_tests", {}).get("path")
            if not isinstance(recorded_test_bundle, str):
                raise PreparationReceiptError(
                    "native live preparation receipt lacks its CoreTests path"
                )
            test_bundle = Path(recorded_test_bundle)
        test_bundle = _canonical_existing(test_bundle, directory=True)
        expected_test_bundle = (
            xctestrun.parent
            / "Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest"
        )
        if test_bundle != expected_test_bundle:
            raise PreparationReceiptError(
                "native live preparation test bundle is not the exact Debug CoreTests product"
            )
        _xctestrun_contract(xctestrun)
        native, app_executable, core_tests = _artifact_paths(candidate_app, test_bundle)
        native_snapshot = _capture_prepared_file_snapshot(native)
        app_executable_snapshot = _capture_prepared_file_snapshot(app_executable)
        core_tests_snapshot = _capture_prepared_bundle_snapshot(core_tests)
        core_executable_snapshot = _capture_prepared_file_snapshot(
            core_tests / "Contents/MacOS/CoreTests"
        )
        file_snapshots.extend([native_snapshot, app_executable_snapshot, core_executable_snapshot])
        bundle_snapshots.append(core_tests_snapshot)
        observed = {
            "xctestrun": {"path": str(xctestrun), "sha256": xctestrun_snapshot.sha256},
            "app": {"path": str(candidate_app), "closed_tree_sha256": candidate_app_snapshot.digests.closed_tree_sha256, "executable_sha256": app_executable_snapshot.sha256},
            "native_decompiler": {"path": str(native), "sha256": native_snapshot.sha256},
            "core_tests": {"path": str(core_tests), "closed_tree_sha256": core_tests_snapshot.digests.closed_tree_sha256, "executable_sha256": core_executable_snapshot.sha256},
        }
    else:
        if test_bundle is None or ui_runner is None:
            raise PreparationReceiptError("installed UI preparation validation requires test bundle and UI runner")
        test_bundle = _canonical_existing(test_bundle, directory=True)
        ui_runner = _canonical_existing(ui_runner, directory=True)
        _installed_ui_xctestrun_contract(xctestrun, test_bundle=test_bundle, ui_runner=ui_runner, candidate_app=candidate_app)
        app_executable, test_executable, runner_executable = _installed_ui_artifact_paths(candidate_app, test_bundle, ui_runner)
        test_bundle_snapshot = _capture_prepared_bundle_snapshot(test_bundle)
        ui_runner_snapshot = _capture_prepared_bundle_snapshot(ui_runner)
        app_executable_snapshot = _capture_prepared_file_snapshot(app_executable)
        test_executable_snapshot = _capture_prepared_file_snapshot(test_executable)
        runner_executable_snapshot = _capture_prepared_file_snapshot(runner_executable)
        bundle_snapshots.extend([test_bundle_snapshot, ui_runner_snapshot])
        file_snapshots.extend(
            [app_executable_snapshot, test_executable_snapshot, runner_executable_snapshot]
        )
        observed = {
            "xctestrun": {"path": str(xctestrun), "sha256": xctestrun_snapshot.sha256},
            "app": {"path": str(candidate_app), "closed_tree_sha256": candidate_app_snapshot.digests.closed_tree_sha256, "executable_sha256": app_executable_snapshot.sha256},
            "ui_test_bundle": {"path": str(test_bundle), "closed_tree_sha256": test_bundle_snapshot.digests.closed_tree_sha256, "executable_sha256": test_executable_snapshot.sha256},
            "ui_runner": {"path": str(ui_runner), "closed_tree_sha256": ui_runner_snapshot.digests.closed_tree_sha256, "executable_sha256": runner_executable_snapshot.sha256},
        }
    for snapshot in file_snapshots:
        _require_unchanged_prepared_file_snapshot(
            snapshot,
            phase="prepared product validation after executable reads",
        )
    for snapshot in bundle_snapshots:
        _require_unchanged_prepared_bundle_snapshot(
            snapshot,
            phase="prepared product validation after executable reads",
        )
    if artifacts != observed:
        raise PreparationReceiptError("prepared product identity differs from its receipt")
    return canonical_sha256(receipt)


def validate_prepared(
    receipt: dict[str, Any],
    xctestrun: Path,
    candidate_app: Path,
    candidate_identity_path: Path,
    *,
    test_bundle: Path | None = None,
    ui_runner: Path | None = None,
) -> str:
    candidate_identity_path = _canonical_existing(candidate_identity_path, directory=False)
    mode = receipt["build"].get(
        "preparation_mode", NATIVE_LIVE_PREPARATION_MODE
    )
    if test_bundle is None and mode == NATIVE_LIVE_PREPARATION_MODE:
        recorded_test_bundle = receipt["artifacts"].get("core_tests", {}).get("path")
        if not isinstance(recorded_test_bundle, str):
            raise PreparationReceiptError(
                "native live preparation receipt lacks its CoreTests path"
            )
        test_bundle = Path(recorded_test_bundle)
    outer_file_snapshots = [
        _capture_prepared_file_snapshot(_canonical_existing(xctestrun, directory=False)),
        _capture_prepared_file_snapshot(candidate_identity_path),
    ]
    outer_bundle_snapshots = [
        _capture_prepared_bundle_snapshot(_canonical_existing(candidate_app, directory=True))
    ]
    if test_bundle is not None:
        outer_bundle_snapshots.append(
            _capture_prepared_bundle_snapshot(
                _canonical_existing(test_bundle, directory=True)
            )
        )
    if ui_runner is not None:
        outer_bundle_snapshots.append(
            _capture_prepared_bundle_snapshot(
                _canonical_existing(ui_runner, directory=True)
            )
        )
    digest = validate_prepared_artifacts(receipt, xctestrun, candidate_app, test_bundle=test_bundle, ui_runner=ui_runner)
    try:
        candidate_value = json.loads(candidate_identity_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PreparationReceiptError(f"cannot decode candidate identity: {error}") from error
    candidate, issues = parse_candidate_identity(candidate_value)
    if candidate is None or issues:
        diagnostics = "; ".join(
            f"{issue.code} at {issue.path}: {issue.message}" for issue in issues
        )
        raise PreparationReceiptError(f"candidate identity is invalid: {diagnostics}")
    source = receipt["source"]
    expected_source = {
        "repository": candidate.source.repository,
        "branch_label": candidate.source.branch_label,
        "commit": candidate.source.commit,
        "tree": candidate.source.tree,
        "dirty": False,
        "project_yml_sha256": candidate.source.project_yml_sha256,
        "generated_project_sha256": candidate.source.generated_project_sha256,
    }
    if source != expected_source:
        raise PreparationReceiptError("preparation source does not match the exact candidate")
    try:
        product_ids = (
            ("native-live-app", "native-decompiler")
            if mode == NATIVE_LIVE_PREPARATION_MODE
            else ("native-live-app",)
        )
        validate_products(candidate, candidate_app, product_ids)
    except ProductIdentityError as error:
        raise PreparationReceiptError(str(error)) from error
    for snapshot in outer_file_snapshots:
        _require_unchanged_prepared_file_snapshot(
            snapshot,
            phase="complete prepared candidate validation",
        )
    for snapshot in outer_bundle_snapshots:
        _require_unchanged_prepared_bundle_snapshot(
            snapshot,
            phase="complete prepared candidate validation",
        )
    return digest


def _installed_candidate_tool(
    authority: release_installer.SourceAuthority,
    tool_id: str,
):
    matches = [tool for tool in authority.candidate.tools if tool.tool_id == tool_id]
    if len(matches) != 1:
        raise PreparationReceiptError(
            f"candidate must contain exactly one {tool_id!r} tool identity"
        )
    return matches[0]


def _swift_toolchain_values(swift_version: str) -> tuple[str, str]:
    compiler = re.search(r"Apple Swift version ([0-9]+(?:\.[0-9]+){1,2})\b", swift_version)
    target = re.search(r"(?m)^Target: ([A-Za-z0-9._+\-]+)$", swift_version)
    if compiler is None or target is None:
        raise PreparationReceiptError(
            "preparation receipt Swift identity lacks its compiler version or target"
        )
    return compiler.group(1), target.group(1)


def _validate_installed_release_provenance(
    receipt: dict[str, Any],
    authority: release_installer.SourceAuthority,
) -> None:
    source = receipt["source"]
    provenance, errors = validate_release_provenance(
        authority.source_snapshot.root,
        expected_source_commit=source["commit"],
        expected_source_tree=source["tree"],
    )
    if errors or provenance is None:
        detail = "; ".join(errors) or "no canonical Release provenance"
        raise PreparationReceiptError(
            f"installed Release provenance is invalid: {detail}"
        )

    toolchain = receipt["toolchain"]
    swift_compiler, swift_target = _swift_toolchain_values(
        toolchain["swift_version"]
    )
    expected = {
        "configuration": "Release",
        "qualification_eligible": True,
        "git_head_commit": source["commit"],
        "git_head_tree": source["tree"],
        "project_yml_sha256": source["project_yml_sha256"],
        "xcode_version": toolchain["xcode_version"],
        "xcode_build": toolchain["xcode_build"],
        "swift_compiler_version": swift_compiler,
        "swift_target_triple": swift_target,
        "sdk_version": toolchain["sdk_version"],
        "sdk_build": toolchain["sdk_build"],
        "native_decompiler_embedded_service_bundle_identifier": (
            "org.macscope.app.NativeDecompiler"
        ),
    }
    for field, value in expected.items():
        if provenance.get(field) != value:
            raise PreparationReceiptError(
                f"installed Release provenance {field} differs from preparation authority"
            )

    expected_embedded = dict(authority.embedded_executables)
    native_digest = expected_embedded.get("native-decompiler")
    if provenance.get(
        "native_decompiler_embedded_service_executable_sha256"
    ) != native_digest:
        raise PreparationReceiptError(
            "installed Release provenance does not bind the candidate native service"
        )

    golden = provenance.get("native_decompiler_golden_result")
    if not isinstance(golden, dict):
        raise PreparationReceiptError(
            "installed Release provenance lacks native decompiler toolchain evidence"
        )
    golden_expected = {
        "xcodeVersion": toolchain["xcode_version"],
        "xcodeBuild": toolchain["xcode_build"],
        "swiftCompilerVersion": swift_compiler,
        "swiftTargetTriple": swift_target,
        "sdkVersion": toolchain["sdk_version"],
        "sdkBuild": toolchain["sdk_build"],
    }
    for field, value in golden_expected.items():
        if golden.get(field) != value:
            raise PreparationReceiptError(
                f"installed native decompiler provenance {field} differs from preparation authority"
            )


def validate_installed_release(
    receipt_path: Path,
    candidate_identity_path: Path,
    installed_app: Path,
) -> InstalledReleaseAuthority:
    """Cross-bind a prepared source receipt to ordinary installed Release bytes.

    The Debug receipt's artifact identities are deliberately not accepted as
    Release product identities.  Its source/toolchain fields are the only seam
    shared with the candidate, whose ``application`` record remains the sole
    byte authority for the installed app and embedded native service.
    """

    raw_receipt_path = receipt_path
    raw_candidate_path = candidate_identity_path
    raw_installed_app = installed_app
    receipt_path = _canonical_existing(receipt_path, directory=False)
    candidate_identity_path = _canonical_existing(
        candidate_identity_path,
        directory=False,
    )
    installed_app = _canonical_existing(installed_app, directory=True)
    for raw, canonical, label in (
        (raw_receipt_path, receipt_path, "preparation receipt"),
        (raw_candidate_path, candidate_identity_path, "candidate identity"),
        (raw_installed_app, installed_app, "installed app"),
    ):
        if not raw.is_absolute() or raw != canonical:
            raise PreparationReceiptError(
                f"{label} must be an absolute canonical path"
            )
    receipt_snapshot = _capture_prepared_file_snapshot(receipt_path)
    receipt = load_receipt(receipt_path)
    if receipt["schema_version"] != SCHEMA_VERSION:
        raise PreparationReceiptError(
            "installed Release validation requires the current preparation receipt schema"
        )
    if receipt["build"].get("preparation_mode") != NATIVE_LIVE_PREPARATION_MODE:
        raise PreparationReceiptError(
            "installed Release validation requires the native live preparation receipt"
        )
    prepared_app = Path(receipt["artifacts"]["app"]["path"])
    if prepared_app.resolve(strict=False) == installed_app:
        raise PreparationReceiptError(
            "installed Release validation cannot target the prepared Debug app"
        )

    try:
        source_authority = release_installer._load_source_authority(
            candidate_identity_path,
            installed_app,
        )
    except release_installer.InstallationError as error:
        raise PreparationReceiptError(
            f"installed Release bytes differ from candidate authority: {error}"
        ) from error

    candidate = source_authority.candidate
    expected_source = {
        "repository": candidate.source.repository,
        "branch_label": candidate.source.branch_label,
        "commit": candidate.source.commit,
        "tree": candidate.source.tree,
        "dirty": False,
        "project_yml_sha256": candidate.source.project_yml_sha256,
        "generated_project_sha256": candidate.source.generated_project_sha256,
    }
    if receipt["source"] != expected_source:
        raise PreparationReceiptError(
            "preparation source does not match the exact installed Release candidate"
        )

    toolchain = receipt["toolchain"]
    candidate_xcode = _installed_candidate_tool(source_authority, "xcode")
    candidate_swift = _installed_candidate_tool(source_authority, "swift")
    candidate_sdk = _installed_candidate_tool(source_authority, "sdk")
    expected_tools = {
        "xcode": (
            toolchain["xcodebuild_sha256"],
            f"Xcode {toolchain['xcode_version']} | Build version {toolchain['xcode_build']}",
            candidate_xcode,
        ),
        "swift": (
            toolchain["swiftc_sha256"],
            toolchain["swift_version"].replace("\n", " | "),
            candidate_swift,
        ),
        "sdk": (
            toolchain["sdk_settings_sha256"],
            toolchain["sdk_version"],
            candidate_sdk,
        ),
    }
    for tool_id, (identity, version, candidate_tool) in expected_tools.items():
        if (
            candidate_tool.identity_sha256 != identity
            or candidate_tool.version != version
        ):
            raise PreparationReceiptError(
                f"preparation {tool_id} identity differs from the installed Release candidate"
            )

    _validate_installed_release_provenance(receipt, source_authority)

    application_executable = _canonical_existing(
        installed_app / "Contents/MacOS/MacScope",
        directory=False,
    )
    native_executable = _canonical_existing(
        installed_app
        / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/"
        "NativeDecompilerXPCService",
        directory=False,
    )
    native_digest = file_sha256(native_executable)
    expected_native_digest = dict(source_authority.embedded_executables).get(
        "native-decompiler"
    )
    if native_digest != expected_native_digest:
        raise PreparationReceiptError(
            "installed native service differs from candidate embedded executable authority"
        )
    if (
        Path(receipt["artifacts"]["native_decompiler"]["path"]).resolve(strict=False)
        == native_executable
    ):
        raise PreparationReceiptError(
            "installed Release validation cannot execute the prepared Debug native service"
        )

    _require_unchanged_prepared_file_snapshot(
        receipt_snapshot,
        phase="installed Release receipt validation",
    )
    try:
        release_installer._require_source_unchanged(
            source_authority,
            phase="installed Release receipt validation",
        )
    except release_installer.InstallationError as error:
        raise PreparationReceiptError(str(error)) from error
    return InstalledReleaseAuthority(
        receipt_path=receipt_path,
        receipt_snapshot=receipt_snapshot,
        receipt_sha256=canonical_sha256(receipt),
        source_authority=source_authority,
        application_executable=application_executable,
        native_executable=native_executable,
        native_executable_sha256=native_digest,
    )


def require_unchanged_installed_release(
    authority: InstalledReleaseAuthority,
    *,
    phase: str,
) -> None:
    _require_unchanged_prepared_file_snapshot(authority.receipt_snapshot, phase=phase)
    try:
        release_installer._require_source_unchanged(
            authority.source_authority,
            phase=phase,
        )
    except release_installer.InstallationError as error:
        raise PreparationReceiptError(str(error)) from error
    observed = validate_installed_release(
        authority.receipt_path,
        authority.source_authority.candidate_file.path,
        authority.source_authority.source_snapshot.root,
    )
    if (
        observed.receipt_sha256 != authority.receipt_sha256
        or observed.source_authority.candidate_identity_sha256
        != authority.source_authority.candidate_identity_sha256
        or observed.native_executable != authority.native_executable
        or observed.native_executable_sha256 != authority.native_executable_sha256
    ):
        raise PreparationReceiptError(f"installed Release authority changed before {phase}")


def _write_create_only(
    path: Path,
    value: dict[str, Any],
    *,
    repository_root: Path | None = None,
    source_snapshot: SourceSnapshot | None = None,
    publication_fence: PreparationPublicationFence | None = None,
) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise PreparationReceiptError("receipt output must be an absent absolute path")
    if (repository_root is None) != (source_snapshot is None):
        raise PreparationReceiptError(
            "preparation receipt source fence requires both root and snapshot"
        )
    if publication_fence is not None:
        if repository_root is not None or source_snapshot is not None:
            raise PreparationReceiptError(
                "preparation publication accepts either the complete publication fence or the legacy source fence"
            )
        for snapshot in publication_fence.file_snapshots:
            _require_unchanged_prepared_file_snapshot(
                snapshot,
                phase="preparation receipt create-only publication",
            )
        for snapshot in publication_fence.bundle_snapshots:
            _require_unchanged_prepared_bundle_snapshot(
                snapshot,
                phase="preparation receipt create-only publication",
            )
        _require_unchanged_source_snapshot(
            publication_fence.repository_root,
            publication_fence.source_snapshot,
            phase="preparation receipt create-only publication",
        )
    elif repository_root is not None and source_snapshot is not None:
        _require_unchanged_source_snapshot(
            repository_root,
            source_snapshot,
            phase="preparation receipt publication",
        )
    parent = _canonical_existing(path.parent, directory=True)
    destination = parent / path.name
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(canonical_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--repository-root", type=Path, required=True)
    create.add_argument("--repository-label", default="gitfox-local:MacScope")
    create.add_argument("--xctestrun", type=Path, required=True)
    create.add_argument("--candidate-app", type=Path, required=True)
    create.add_argument("--preparation-mode", choices=(NATIVE_LIVE_PREPARATION_MODE, INSTALLED_UI_PREPARATION_MODE), default=NATIVE_LIVE_PREPARATION_MODE)
    create.add_argument("--test-bundle", type=Path)
    create.add_argument("--ui-runner", type=Path)
    create.add_argument("--output", type=Path, required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--receipt", type=Path, required=True)
    validate.add_argument("--xctestrun", type=Path, required=True)
    validate.add_argument("--candidate-app", type=Path, required=True)
    validate.add_argument("--candidate-identity", type=Path, required=True)
    validate.add_argument("--test-bundle", type=Path)
    validate.add_argument("--ui-runner", type=Path)
    validate_artifacts = subparsers.add_parser("validate-artifacts")
    validate_artifacts.add_argument("--receipt", type=Path, required=True)
    validate_artifacts.add_argument("--xctestrun", type=Path, required=True)
    validate_artifacts.add_argument("--candidate-app", type=Path, required=True)
    validate_artifacts.add_argument("--test-bundle", type=Path)
    validate_artifacts.add_argument("--ui-runner", type=Path)
    validate_installed = subparsers.add_parser("validate-installed-release")
    validate_installed.add_argument("--receipt", type=Path, required=True)
    validate_installed.add_argument("--candidate-identity", type=Path, required=True)
    validate_installed.add_argument("--installed-app", type=Path, required=True)
    validate_xctestrun = subparsers.add_parser("validate-xctestrun")
    validate_xctestrun.add_argument("--xctestrun", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "create":
            root = _canonical_existing(arguments.repository_root, directory=True)
            source_snapshot = _require_clean_source_snapshot(root)
            publication_fences: list[PreparationPublicationFence] = []
            document = create_document(
                root,
                arguments.repository_label,
                arguments.xctestrun,
                arguments.candidate_app,
                preparation_mode=arguments.preparation_mode,
                test_bundle=arguments.test_bundle,
                ui_runner=arguments.ui_runner,
                source_snapshot=source_snapshot,
                publication_fences=publication_fences,
            )
            if len(publication_fences) != 1:
                raise PreparationReceiptError(
                    "preparation materialization did not produce one complete publication fence"
                )
            _write_create_only(
                arguments.output,
                document,
                publication_fence=publication_fences[0],
            )
            receipt_path = arguments.output
            digest = canonical_sha256(document)
        elif arguments.command == "validate":
            receipt_path = arguments.receipt
            document = load_receipt(receipt_path)
            digest = validate_prepared(
                document,
                arguments.xctestrun,
                arguments.candidate_app,
                arguments.candidate_identity,
                test_bundle=arguments.test_bundle,
                ui_runner=arguments.ui_runner,
            )
        elif arguments.command == "validate-artifacts":
            receipt_path = arguments.receipt
            document = load_receipt(receipt_path)
            digest = validate_prepared_artifacts(
                document,
                arguments.xctestrun,
                arguments.candidate_app,
                test_bundle=arguments.test_bundle,
                ui_runner=arguments.ui_runner,
            )
        elif arguments.command == "validate-installed-release":
            authority = validate_installed_release(
                arguments.receipt,
                arguments.candidate_identity,
                arguments.installed_app,
            )
            receipt_path = authority.receipt_path
            digest = authority.receipt_sha256
            print(f"MACSCOPE_INSTALLED_NATIVE_EXECUTABLE={authority.native_executable}")
        else:
            _xctestrun_contract(arguments.xctestrun)
            print(f"MACSCOPE_XCTESTRUN_CONTRACT={arguments.xctestrun}")
            return 0
    except (OSError, UnicodeError, ValueError, PreparationReceiptError) as error:
        print(f"ERROR: native live-XPC preparation receipt failed: {error}", file=sys.stderr)
        return 1
    print(f"MACSCOPE_NATIVE_LIVE_PREPARATION_RECEIPT={receipt_path}")
    print(f"MACSCOPE_NATIVE_LIVE_PREPARATION_RECEIPT_SHA256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
