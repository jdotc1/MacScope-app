"""Capture-bound native outcomes, with physical, non-executing replay.

Reusable producer reports have no candidate/run authority. This adapter obtains
that authority only from the independently compiled command and outer capture.
"""
from __future__ import annotations

from dataclasses import replace
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re

from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes
from .command_catalog import CampaignProfile, campaign_profile_for_inputs, command_templates
from .executor_request_adapter import ExecutorReceiptAdmission
from .qualification_artifact_validator import validate_source_export
from .qualification_receipt_adapter import captured_path
from .schema import ArtifactKind, ReceiptType

COMMANDS = frozenset({"native.normal", "native.asan", "native.ubsan", "native.golden"})
PROFILES = {"native.normal": "none", "native.asan": "address", "native.ubsan": "undefined"}
REPORT_MARKER = "MACSCOPE_NATIVE_QUALIFICATION_REPORT"
GOLDEN_MARKERS = ("MACSCOPE_NATIVE_GOLDEN_RESULT", "MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP",
                  "MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION")
MATERIALIZATION_OUTPUT = "artifact:stdout-path:" + GOLDEN_MARKERS[2]
SCRIPT_ROOT = Path(__file__).resolve().parents[1] / "native-decompiler-xpc"


def _load(name):
    spec = importlib.util.spec_from_file_location("gatef_native_" + name, SCRIPT_ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_REPORT = _load("native_qualification_report")
_GOLDEN = _load("run_gatef_native_golden")


def native_semantic_kind(command_id, source):
    """Assign a layer kind only after command-specific physical validation."""
    if source.command_output == "artifact:stdout-path:" + REPORT_MARKER:
        return ArtifactKind.SANITIZER_REPORT if command_id in {"native.asan", "native.ubsan"} else ArtifactKind.TEST_RESULTS
    if command_id == "native.golden" and source.command_output == "artifact:stdout-path:" + GOLDEN_MARKERS[0]:
        return ArtifactKind.TEST_RESULTS
    return source.kind


def _bytes(path: Path, maximum=16 * 1024 * 1024):
    return _REPORT._bytes(path, maximum)


def _identities(paths):
    return {p: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            for p in paths for s in (p.lstat(),)}


def _capture_fence(admission):
    payload = _bytes(admission.capture.capture_path)
    if hashlib.sha256(payload).hexdigest() != admission.capture.capture_sha256:
        raise ValueError("native outer capture changed during physical admission")


def _fresh_files(paths, capture):
    started, ended = capture["intent"]["started_at_unix_ms"], capture["terminal"]["ended_at_unix_ms"]
    if any(not started <= p.lstat().st_mtime_ns // 1_000_000 <= ended for p in paths):
        raise ValueError("native owner output predates or escapes the captured command interval")


def _directory(path):
    return _REPORT._path(Path(path), directory=True)


def _context(command_id, admission):
    if command_id not in COMMANDS or not isinstance(admission, ExecutorReceiptAdmission):
        raise ValueError("native qualification requires independently retained capture admission")
    from .executor_request_adapter import _capture
    admitted, capture, streams, _, _, _ = _capture(admission)
    context = admission.capture.admission
    inputs = context.integrated_plan_input.inputs
    if campaign_profile_for_inputs(inputs) is not CampaignProfile.BOOTSTRAP_VERIFIER:
        raise ValueError("native outcomes require the promoted bootstrap campaign profile")
    record = admitted.resolved_command.record
    if record.command_id != command_id:
        raise ValueError("native owner differs from captured command")
    expected_role = ReceiptType.NATIVE_SANITIZER if command_id in {"native.asan", "native.ubsan"} else ReceiptType.TEST_RESULT
    if admission.receipt_type is not expected_role:
        raise ValueError("native command has the wrong semantic receipt role")
    template = next(t for t in command_templates(profile=CampaignProfile.BOOTSTRAP_VERIFIER) if t.command_id == command_id)
    def substitute(value):
        return inputs[value[1:-1]] if value.startswith("@") and value.endswith("@") else value
    if (record.argv != tuple(substitute(v) for v in template.argv)
            or record.environment != tuple(sorted((k, substitute(v)) for k, v in template.environment))
            or record.generated_artifacts != tuple(sorted(substitute(v) for v in template.generated_artifacts))
            or record.generated_logs != tuple(sorted(substitute(v) for v in template.generated_logs))):
        raise ValueError("native command differs from frozen vector/environment/output closure")
    root = _directory(admission.artifact_root)
    normal = Path(inputs["native_build_root"])
    parent = normal.parent
    if (normal != root / "native-work/normal" or parent.name != "native-work"
            or Path(inputs["native_sanitizer_build_root"]) != parent / "sanitizers"
            or Path(inputs["native_golden_work_root"]) != parent / "golden"):
        raise ValueError("native command roots differ from fixed campaign layout")
    repository = _directory(inputs["repository_root"])
    source = _directory(inputs["source_export_root"])
    if Path(inputs["native_source_root"]) != repository / "Tools/NativeDecompilerBridge":
        raise ValueError("native source root differs from executing producer repository")
    validate_source_export(context.candidate, source, inputs["integration_ref"])
    expected_outputs = {*('artifact:' + v for v in record.generated_artifacts),
                        *('log:' + v for v in record.generated_logs)}
    sources = admission.owner_artifacts
    if (len(sources) != len(expected_outputs) or {s.command_output for s in sources} != expected_outputs
            or len({s.artifact_id for s in sources}) != len(sources)
            or len({s.relative_path for s in sources}) != len(sources)):
        raise ValueError("native owner requires exact unique physical output set")
    log = next(s for s in sources if s.command_output.startswith("log:"))
    if log.kind is not ArtifactKind.LAUNCH_LOG or _bytes(root / log.relative_path) != streams["stdout"] + streams["stderr"]:
        raise ValueError("native output log differs from retained capture")
    return admitted, capture, streams, inputs, repository, source


def _source_fence(repository, export, paths):
    # Export manifests are independently checked before and after all outcomes.
    for relative in sorted(set(paths)):
        if _bytes(repository / relative) != _bytes(export / relative):
            raise ValueError("native producer source differs from candidate sealed source: " + relative)


def _tool_fence(value, candidate, inputs):
    tools = {t.tool_id: t for t in candidate.tools}
    observed = value["toolchain"]
    if (observed["developer_dir"] != inputs["developer_dir"] or observed["sdk_root"] != inputs["sdk_root"]
            or observed["compiler"]["sha256"] != tools["clang"].identity_sha256
            or observed["compiler_version"] != tools["clang"].version
            or observed["cmake"]["sha256"] != tools["cmake"].identity_sha256
            or observed["cmake_version"] != tools["cmake"].version
            or observed["sdk_settings"]["sha256"] != tools["sdk"].identity_sha256):
        raise ValueError("native selected compiler/SDK/toolchain differs from admitted candidate")


def _semantic(command_id, admission, record):
    selectors = {"native.normal": ("native.governed-package-verification", "native.normal"),
                 "native.asan": ("native.asan",), "native.ubsan": ("native.ubsan",),
                 "native.golden": ("native.golden",)}[command_id]
    if record.scenario_ids != selectors:
        raise ValueError("native semantic constituents differ from frozen scenario catalog")
    count = len(selectors)
    if command_id in {"native.asan", "native.ubsan"}:
        authority = {"sanitizer": PROFILES[command_id], "test_count": 1, "failed_count": 0}
    else:
        authority = dict(selector_catalog_sha256=admission.capture.admission.candidate.selector_catalog_sha256,
            expected_selector_count=count, executed_selector_count=count, passed_selector_count=count,
            failed_selector_count=0, skipped_selector_count=0)
    constituents = [dict(selector_id=s, status="passed", evidence_layer=record.evidence_layer.value,
        candidate_identity_sha256=record.candidate_identity_sha256,
        artifact_ids=sorted([*(s.artifact_id for s in admission.owner_artifacts), admission.execution_report_artifact_id]))
        for s in selectors]
    if (admission.authority is not None and canonical_bytes(admission.authority) != canonical_bytes(authority)) or (
            admission.constituents and canonical_bytes(admission.constituents) != canonical_bytes(constituents)):
        raise ValueError("caller-supplied native semantics differ from physical outcomes")
    return {"authority": authority, "constituents": constituents}


def validate_native_qualification(*, command_id: str, report_path: Path,
    admission: ExecutorReceiptAdmission) -> dict[str, object]:
    if command_id not in PROFILES:
        raise ValueError("command is not an ordinary native qualification owner")
    admitted, capture, streams, inputs, repository, export = _context(command_id, admission)
    profile = PROFILES[command_id]
    build = Path(inputs["native_build_root"]) if profile == "none" else Path(inputs["native_sanitizer_build_root"]) / profile
    report_key = {"none": "native_normal_report_dir", "address": "native_asan_report_dir", "undefined": "native_ubsan_report_dir"}[profile]
    expected = build / "qualification/native-qualification.json"
    if report_path != expected or Path(inputs[report_key]) != expected.parent or captured_path(streams, REPORT_MARKER) != expected:
        raise ValueError("native report differs from admitted fixed report path")
    owner = next(s for s in admission.owner_artifacts if s.command_output == "artifact:stdout-path:" + REPORT_MARKER)
    if (owner.kind is not ArtifactKind.JSON or owner.media_type != "application/json"
            or admission.artifact_root / owner.relative_path != expected):
        raise ValueError("native report must retain its ordinary JSON owner identity")
    producer_outputs = [expected, *(expected.parent / name for name in
        ("ctest.execution.json", "native-inputs.json", "ctest.inventory.json", "ctest.junit.xml"))]
    # Executor-captured logs are published after the retained process capture;
    # bind their bytes/identity, but apply process freshness only to producers.
    watched = [*producer_outputs, *(admission.artifact_root / s.relative_path
        for s in admission.owner_artifacts if s.command_output.startswith("log:"))]
    before = {p: _bytes(p) for p in watched}
    _fresh_files(producer_outputs, capture)
    material = Path(inputs["sleigh_materialization_root"]) if profile == "none" else build / "native-source" / ("SleighNativeSource-" + profile) / "materialization"
    value = _REPORT.validate_native_report(report_path=expected, repository_root=repository, build_root=build,
        materialization_root=material, expected_profile=profile, developer_dir=Path(inputs["developer_dir"]))
    physical_paths = set(watched)
    physical_paths.update(Path(ref["absolute_path"]) for key in ("products", "dependency_evidence", "producer_files") for ref in value[key])
    physical_paths.update(Path(value["toolchain"][key]["absolute_path"]) for key in ("compiler", "cmake", "ctest", "sdk_settings"))
    initial_identities = _identities(physical_paths)
    _tool_fence(value, admission.capture.admission.candidate, inputs)
    if value["wrapper_source_sha256"] != inputs["native_wrapper_revision"]:
        raise ValueError("native wrapper digest differs from admitted source")
    paths = (*_REPORT.producer_paths(profile), *_REPORT.source_identity.profile_paths(repository, "wrapper"))
    _source_fence(repository, export, paths)
    execution = decode_canonical_bytes(before[expected.parent / "ctest.execution.json"])
    if not (capture["intent"]["started_at_unix_ms"] <= execution["started_at_unix_ms"]
            <= execution["ended_at_unix_ms"] <= capture["terminal"]["ended_at_unix_ms"]):
        raise ValueError("native test interval is outside independently captured execution")
    if (expected.parent / "native-inputs.json").lstat().st_mtime_ns // 1_000_000 > execution["started_at_unix_ms"]:
        raise ValueError("native input snapshot was not published before its CTest execution")
    semantics = _semantic(command_id, admission, admitted.record)
    # Final fences run after outcome/schema/semantic validation. None publish or
    # execute; a late replacement or removed raw outcome rejects on replay.
    validate_source_export(admission.capture.admission.candidate, export, inputs["integration_ref"])
    _source_fence(repository, export, paths)
    _REPORT.validate_native_report(report_path=expected, repository_root=repository, build_root=build,
        materialization_root=material, expected_profile=profile, developer_dir=Path(inputs["developer_dir"]))
    if before != {p: _bytes(p) for p in watched} or initial_identities != _identities(physical_paths):
        raise ValueError("native report bytes changed during final admission")
    _capture_fence(admission)
    return semantics


def golden_projection_relative_path(admission):
    return (Path("native-work/golden/metadata") / ("gatef-materialization-" +
        canonical_sha256([admission.receipt_id, MATERIALIZATION_OUTPUT]) + ".json")).as_posix()


def _golden_state(inputs):
    work = Path(inputs["native_golden_work_root"])
    destination = work / "products" / _GOLDEN.RESOURCE_SUBPATH / _GOLDEN._STAGE.DESTINATION_NAME
    metadata = work / "metadata/stage"
    stamp = metadata / _GOLDEN._STAGE.STAMP_NAME
    input_list = metadata / _GOLDEN._STAGE.INPUT_LIST_NAME
    output_list = metadata / _GOLDEN._STAGE.OUTPUT_LIST_NAME
    state = _GOLDEN._STAGE._existing_owned_state(destination, input_list, output_list, stamp)
    source = None
    try:
        if state is None or state[3] is None:
            raise ValueError("golden staging is not a complete physically attested publication")
        source = _GOLDEN._STAGE._STAGER._open_verified_materialization(Path(inputs["sleigh_materialization_root"]), "admitted source")
        if state[0]["materialization"] != source[4]:
            raise ValueError("golden materialization differs from independently admitted package")
        if (state[2][input_list][3], state[2][output_list][3]) != _GOLDEN._STAGE._expected_file_list_payloads(source, destination):
            raise ValueError("golden stage lists differ from fixed source/destination")
        projection = canonical_bytes(dict(schema_version=1, record_kind="macscope-native-golden-materialization",
            directory_path=str(destination), materialization=state[0]["materialization"]))
        _GOLDEN._STAGE._revalidate_owned_state(state, destination, input_list, output_list, stamp, label="Gate F golden")
        _GOLDEN._STAGE._STAGER._revalidate_anchored_materialization(*source[:4], "admitted source")
        return destination, stamp, state[0], projection
    finally:
        _GOLDEN._STAGE._close_owned_state(state)
        if source is not None: os.close(source[1])


def golden_materialization_projection(admission):
    _, _, streams, inputs, _, _ = _context("native.golden", admission)
    destination, _, _, payload = _golden_state(inputs)
    if captured_path(streams, GOLDEN_MARKERS[2]) != destination:
        raise ValueError("golden materialization marker differs from fixed staged directory")
    return payload


def native_projection_sources(admission):
    return tuple(replace(s, relative_path=golden_projection_relative_path(admission))
        if s.command_output == MATERIALIZATION_OUTPUT else s for s in admission.owner_artifacts)


def publish_native_projection(admission):
    payload = golden_materialization_projection(admission)
    sources = native_projection_sources(admission)
    path = admission.artifact_root / golden_projection_relative_path(admission)
    directory = _directory(path.parent)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        output = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(output, "wb") as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.fsync(fd)
    finally: os.close(fd)
    if _bytes(path) != payload:
        raise ValueError("golden projection changed during publication")
    return replace(admission, owner_artifacts=sources)


def validate_native_golden(*, result_path: Path, stage_stamp_path: Path,
    materialization_root: Path, admission: ExecutorReceiptAdmission) -> dict[str, object]:
    admitted, capture, streams, inputs, repository, export = _context("native.golden", admission)
    work = Path(inputs["native_golden_work_root"])
    expected_result = work / "products/NativeDecompilerBridgeGolden.json"
    destination, stamp, state, projection = _golden_state(inputs)
    if (result_path, stage_stamp_path, materialization_root) != (expected_result, stamp, destination):
        raise ValueError("golden artifacts differ from independently admitted fixed layout")
    _fresh_files((result_path, stamp), capture)
    for marker, path in zip(GOLDEN_MARKERS, (result_path, stamp, destination)):
        if captured_path(streams, marker) != path:
            raise ValueError("golden owner marker differs from fixed output")
        owner = next(s for s in admission.owner_artifacts if s.command_output == "artifact:stdout-path:" + marker)
        actual = admission.artifact_root / owner.relative_path
        expected = admission.artifact_root / golden_projection_relative_path(admission) if marker == GOLDEN_MARKERS[2] else path
        if owner.kind is not ArtifactKind.JSON or owner.media_type != "application/json" or actual != expected:
            raise ValueError("golden owner has wrong JSON kind/path")
    projected = admission.artifact_root / golden_projection_relative_path(admission)
    if _bytes(projected) != projection:
        raise ValueError("golden materialization projection differs from actual physical publication")
    tools = {t.tool_id: t for t in admission.capture.admission.candidate.tools}
    developer, sdk = Path(inputs["developer_dir"]), Path(inputs["sdk_root"])
    xcode = re.fullmatch(r"Xcode (27(?:\.\d+){1,2}) \| Build version ([A-Za-z0-9.]+)", tools["xcode"].version)
    swift = re.search(r"Apple Swift version (6(?:\.\d+){1,2})\b", tools["swift"].version)
    target = re.search(r"Target: (arm64-apple-macosx27(?:\.\d+){1,2})", tools["swift"].version)
    if not xcode or not swift or not target:
        raise ValueError("golden toolchain lacks independent Xcode 27/Swift 6 identity")
    swift_path = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    swift_identity = _GOLDEN._tool_file(swift_path, "swift-frontend")
    # Ordinary identity is (metadata, digest); the permitted alias is
    # (alias metadata, target name, (resolved executable metadata, digest)).
    swift_executable = swift_identity[2] if len(swift_identity) == 3 else swift_identity
    if (_REPORT._external(developer / "usr/bin/xcodebuild")["sha256"] != tools["xcode"].identity_sha256
            or swift_executable[1] != tools["swift"].identity_sha256
            or _REPORT._external(sdk / "SDKSettings.json")["sha256"] != tools["sdk"].identity_sha256):
        raise ValueError("golden physical toolchain differs from candidate tools")
    tool_paths = (developer / "usr/bin/xcodebuild", sdk / "SDKSettings.json",
                  sdk / "usr/lib/libz.tbd", sdk / "usr/lib/libc++.tbd",
                  developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo")
    tool_bytes = {p: _bytes(p, 1024 * 1024 * 1024) for p in tool_paths}
    settings = json.loads(_bytes(sdk / "SDKSettings.json"))
    sdk_system_version = sdk / "System/Library/CoreServices/SystemVersion.plist"
    system_bytes = _bytes(sdk_system_version)
    sdk_build = plistlib.loads(system_bytes).get("ProductBuildVersion")
    if not isinstance(sdk_build, str) or not re.fullmatch(r"[A-Za-z0-9.]+", sdk_build):
        raise ValueError("golden selected SDK lacks its physical product build identity")
    if settings.get("Version") != tools["sdk"].version or inputs["sdk_name"] != "macosx" + tools["sdk"].version:
        raise ValueError("golden SDK version differs from admitted SDK")
    normal = Path(inputs["native_build_root"])
    native = _REPORT.validate_native_report(report_path=normal / "qualification/native-qualification.json",
        repository_root=repository, build_root=normal, materialization_root=Path(inputs["sleigh_materialization_root"]),
        expected_profile="none", developer_dir=developer)
    _tool_fence(native, admission.capture.admission.candidate, inputs)
    paths = (*_REPORT.source_identity.profile_paths(repository, "golden"),
        "Scripts/native-decompiler-xpc/run_gatef_native_golden.py", "Scripts/native-decompiler-xpc/native_golden_evidence.py",
        "Scripts/native-decompiler-xpc/stage_xcode_resources.py")
    _source_fence(repository, export, paths)
    expected = {**_GOLDEN._EVIDENCE.PINNED_IDENTITY, "xcodeVersion": xcode[1], "xcodeBuild": xcode[2],
        "swiftCompilerVersion": swift[1], "swiftTargetTriple": target[1], "sdkName": inputs["sdk_name"],
        "sdkVersion": tools["sdk"].version, "sdkBuild": sdk_build,
        "wrapperGitRevision": _REPORT.source_identity.profile_digest(repository, "wrapper"),
        "goldenSourceSHA256": _REPORT.source_identity.profile_digest(repository, "golden"),
        "contractArchiveSHA256": _REPORT._external(normal / "libmacscope_native_decompiler_contract.a")["sha256"],
        "contractBuildIdentitySHA256": _REPORT._external(normal / "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp")["sha256"],
        "stageStampSHA256": hashlib.sha256(_bytes(stamp)).hexdigest(),
        "materializationManifestSHA256": _REPORT._external(destination / "MATERIALIZATION.json")["sha256"],
        "materializationTreeSHA256": state["materialization"]["package"]["treeSha256"],
        "decompilerArchiveSHA256": _REPORT._external(destination / "package/lib/libdecomp.a")["sha256"],
        "sleighArchiveSHA256": _REPORT._external(destination / "package/lib/libsla.a")["sha256"]}
    before = _bytes(result_path, 64 * 1024)
    logs = {admission.artifact_root / s.relative_path: _bytes(admission.artifact_root / s.relative_path)
            for s in admission.owner_artifacts if s.command_output.startswith("log:")}
    physical_paths = {result_path, stamp, projected, sdk_system_version, *tool_paths, *logs}
    physical_paths.update(Path(ref["absolute_path"]) for key in ("products", "dependency_evidence", "producer_files") for ref in native[key])
    initial_identities = _identities(physical_paths)
    _GOLDEN._EVIDENCE.validate_golden_payload(before, expected_identity=expected)
    semantics = _semantic("native.golden", admission, admitted.record)
    validate_source_export(admission.capture.admission.candidate, export, inputs["integration_ref"])
    _source_fence(repository, export, paths)
    if (_golden_state(inputs)[3] != projection or _bytes(projected) != projection
            or _bytes(result_path, 64 * 1024) != before or _bytes(sdk_system_version) != system_bytes
            or tool_bytes != {p: _bytes(p, 1024 * 1024 * 1024) for p in tool_paths}
            or logs != {p: _bytes(p) for p in logs}
            or _GOLDEN._tool_file(swift_path, "swift-frontend") != swift_identity):
        raise ValueError("golden physical outcomes changed during final admission")
    _REPORT.validate_native_report(report_path=normal / "qualification/native-qualification.json",
        repository_root=repository, build_root=normal, materialization_root=Path(inputs["sleigh_materialization_root"]),
        expected_profile="none", developer_dir=developer)
    if initial_identities != _identities(physical_paths):
        raise ValueError("golden physical file identity changed during final admission")
    _capture_fence(admission)
    return semantics


def validate_native_outputs(admission):
    inputs = admission.capture.admission.integrated_plan_input.inputs
    command = admission.capture.command_id
    if command == "native.golden":
        work = Path(inputs["native_golden_work_root"])
        return validate_native_golden(result_path=work / "products/NativeDecompilerBridgeGolden.json",
            stage_stamp_path=work / "metadata/stage" / _GOLDEN._STAGE.STAMP_NAME,
            materialization_root=work / "products" / _GOLDEN.RESOURCE_SUBPATH / _GOLDEN._STAGE.DESTINATION_NAME,
            admission=admission)
    profile = PROFILES[command]
    build = Path(inputs["native_build_root"]) if profile == "none" else Path(inputs["native_sanitizer_build_root"]) / profile
    return validate_native_qualification(command_id=command, report_path=build / "qualification/native-qualification.json", admission=admission)
