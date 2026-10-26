"""Capture-bound directory projections and physical qualification receipt proofs.

Directory artifacts retain their original catalogue output identity. Their
ordinary JSON descriptors are not substitutes for the directories: every
admission regenerates the descriptor from the original governed directory.
"""
from __future__ import annotations

import os
import re
from dataclasses import replace
from pathlib import Path

from .canonical_json import canonical_bytes, canonical_sha256
from .schema import ArtifactKind, ReceiptType
from .qualification_artifact_validator import (
    validate_qualification_products, validate_selected_xcresult, validate_full_coretests_xcresult,
)


def captured_path(streams, marker: str) -> Path:
    prefix = marker + "="
    values = [line[len(prefix):] for line in streams["stdout"].decode("utf-8", errors="strict").splitlines()
              if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError("capture must contain one exact " + marker + " path")
    path = Path(values[0])
    if not path.is_absolute() or path.resolve(strict=True) != path or path.is_symlink():
        raise ValueError("captured qualification path is not canonical")
    return path


def qualification_receipt_path(admission, streams) -> Path:
    path = captured_path(streams, "MACSCOPE_QUALIFICATION_RECEIPT")
    sources = [item for item in admission.owner_artifacts
               if item.command_output == "artifact:stdout-path:MACSCOPE_QUALIFICATION_RECEIPT"]
    if len(sources) != 1 or admission.artifact_root / sources[0].relative_path != path:
        raise ValueError("qualification receipt differs from original owner artifact")
    return path


def directory_path(admission, source, streams) -> Path:
    receipt = qualification_receipt_path(admission, streams)
    if source.kind is ArtifactKind.APP_BUNDLE:
        expected = "artifact:receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app"
        if admission.capture.command_id != "release.build" or source.command_output != expected:
            raise ValueError("app directory is not the frozen Release output")
        path = receipt.parent / "DerivedData/Build/Products/Release/MacScope.app"
    elif source.kind is ArtifactKind.XCRESULT:
        if source.command_output != "artifact:stdout-path:MACSCOPE_TEST_RESULTS":
            raise ValueError("xcresult is not the frozen test-result output")
        path = captured_path(streams, "MACSCOPE_TEST_RESULTS")
        pattern = (r"FocusedTestResults\.xcresult" if admission.capture.command_id.startswith("xcode.focused.")
                   else r"TestResults(?:\.resume-[0-9]+)?\.xcresult")
        if path.parent != receipt.parent or not re.fullmatch(pattern, path.name):
            raise ValueError("xcresult is outside the admitted qualifier run")
    else:
        raise ValueError("unsupported directory artifact kind")
    if not path.is_absolute() or path.resolve(strict=True) != path or path.is_symlink() or not path.is_dir():
        raise ValueError("qualification directory must be canonical and ordinary")
    return path


def projection_relative_path(admission, source) -> str:
    digest = canonical_sha256([admission.receipt_id, source.command_output])
    return ".gatef-directory-" + digest + ".json"


def directory_projection(admission, source, streams) -> bytes:
    path = directory_path(admission, source, streams)
    if source.kind is ArtifactKind.APP_BUNDLE:
        from Scripts.reconstruction.installed_matrix_receipt import _bundle_identity
        identity = _bundle_identity(path, path / "Contents/MacOS/MacScope")
    else:
        from Scripts.ws24_emit_installed_qualification_report import result_bundle_sha256
        identity = {"content_sha256": result_bundle_sha256(path)}
    projection = {"schema_version": 1, "artifact_kind": source.kind.value,
                  "directory_path": str(path), "identity": identity}
    if source.kind is ArtifactKind.XCRESULT and admission.receipt_type is ReceiptType.TEST_RESULT:
        record = next(item for item in admission.capture.admission.integrated_plan_input.plan.commands
                      if item.command_id == admission.capture.command_id)
        scope = (_option(record.argv, "--only-testing")
                 if _option(record.argv, "--mode") == "focused-test" else "CoreTests")
        if scope == "CoreTests" and _option(record.argv, "--mode") == "full-test":
            projection["test_observations"] = validate_full_coretests_xcresult(path,
                candidate=admission.capture.admission.candidate,
                source_root=qualification_receipt_path(admission, streams).parent / "source",
                integration_ref=_option(record.argv, "--integration-ref"), scratch_root=admission.artifact_root)
        else:
            projection["test_observations"] = validate_selected_xcresult(path,
                selected_scope=scope, allowed_skips={}, scratch_root=admission.artifact_root)
    return canonical_bytes(projection)


def qualification_artifact_projection_sources(admission):
    """Deterministic metadata projection only; no evidence or execution claim."""
    return tuple(replace(source, relative_path=projection_relative_path(admission, source),
                         media_type="application/json")
                 if source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT} else source
                 for source in admission.owner_artifacts)


def publish_qualification_artifact_projections(admission):
    from .executor_request_adapter import _capture
    _, _, streams, _, _, _ = _capture(admission)
    sources = qualification_artifact_projection_sources(admission)
    root_fd = os.open(admission.artifact_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for source in admission.owner_artifacts:
            if source.kind not in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}:
                continue
            payload = directory_projection(admission, source, streams)
            relative = projection_relative_path(admission, source)
            descriptor = os.open(relative, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=root_fd)
            with os.fdopen(descriptor, "wb") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
        os.fsync(root_fd)
    finally:
        os.close(root_fd)
    return replace(admission, owner_artifacts=sources)


def _option(argv, name):
    positions = [index for index, value in enumerate(argv) if value == name]
    if len(positions) != 1 or positions[0] + 1 >= len(argv):
        raise ValueError("compiled qualification option missing or ambiguous: " + name)
    return argv[positions[0] + 1]


def semantic_qualification(admission, admitted, streams, directory_proofs):
    record = admitted.resolved_command.record
    argv = record.argv
    def option(name):
        return _option(argv, name)
    mode = option("--mode")
    receipt = qualification_receipt_path(admission, streams)
    products = validate_qualification_products(admission.capture.admission.candidate, receipt,
        integration_ref=option("--integration-ref"), dependency_cache_root=Path(option("--dependency-cache-root")), mode=mode)
    if admission.receipt_type is ReceiptType.COMMAND_EXECUTION and record.command_id == "xcode.smoke" and mode == "smoke":
        # build-for-testing proves preparation of products, not execution of tests.
        return products, None
    if admission.receipt_type is ReceiptType.RELEASE_BUILD:
        if mode != "release":
            raise ValueError("Release receipt requires the admitted Release command")
        app = next(item for item in admission.owner_artifacts if item.kind is ArtifactKind.APP_BUNDLE)
        # Independently reobserved in addition to the earlier projection check.
        directory_projection(admission, app, streams)
        candidate = admission.capture.admission.candidate
        return ({"bundle_sha256": products["bundle_sha256"],
                 "closed_tree_sha256": products["closed_tree_sha256"],
                 "executable_sha256": candidate.application.executable_sha256}, None)
    if admission.receipt_type is not ReceiptType.TEST_RESULT or mode not in {"focused-test", "full-test"}:
        raise ValueError("test receipt requires the admitted focused or full test command")
    scope = option("--only-testing") if mode == "focused-test" else "CoreTests"
    source = next(item for item in admission.owner_artifacts if item.kind is ArtifactKind.XCRESULT)
    # The caller just regenerated this complete projection from the original
    # directory. Reuse that observation within this admission, not another run.
    observed = directory_proofs[source.command_output]["test_observations"]
    return observed, scope
