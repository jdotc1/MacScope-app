"""Pinned libghidra adapter with MacScope-owned, bounded DTOs.

No libghidra Python model, nanobind object, protobuf object, or native pointer
crosses this module. The adapter loads only the exact materialized v0.0.2 native
extension, invokes its address-driven local API, and converts returned mappings
into closed dataclasses. The local v0.0.2 backend does not supply token/local or
CFG records; this adapter never calls those enumeration methods and never parses
rendered pseudocode to synthesize semantics.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, Protocol

from macscope_decompiler_proof.canonical import canonical_json_bytes
from macscope_decompiler_proof.request import AnalysisRequest

from .carrier import CarrierArtifact
from .contract import (
    APPROVED_WHEELS,
    ENGINE_COMPILER_SPEC_ID,
    ENGINE_COMPONENT_ID,
    ENGINE_FORMAT,
    ENGINE_GIT_REVISION,
    ENGINE_HOST_MODE,
    ENGINE_LANGUAGE_ID,
    ENGINE_SERVICE_NAME,
    ENGINE_SERVICE_VERSION,
    ENGINE_VERSION,
    MAX_CAPABILITY_COUNT,
    MAX_INSTRUCTION_COUNT,
    MAX_MATERIALIZATION_BYTES,
    MAX_PSEUDOCODE_BYTES,
    MAX_SHORT_TEXT,
    MAX_TEXT,
    REQUIRED_NATIVE_CAPABILITIES,
)
from .errors import CancelledError, MaterializationError, ProviderError


@dataclass(frozen=True)
class NativeCapability:
    capability_id: str
    status: str


@dataclass(frozen=True)
class NativeEngineStatus:
    service_name: str
    service_version: str
    host_mode: str
    program_revision: int
    capabilities: tuple[NativeCapability, ...]
    wheel_filename: str
    wheel_sha256: str
    wheel_platform: str
    extension_sha256: str
    materialization_sha256: str


@dataclass(frozen=True)
class NativeOpenProgram:
    program_name: str
    language_id: str
    compiler_spec: str
    reported_image_base: int


@dataclass(frozen=True)
class NativeDecompilation:
    function_entry: int
    pseudocode: str
    completed: bool
    fallback: bool


@dataclass(frozen=True)
class NativeFunction:
    entry_address: int
    name: str
    start_address: int
    end_address: int
    size: int
    namespace_name: str
    prototype: str
    is_thunk: bool
    parameter_count: int


@dataclass(frozen=True)
class NativeInstruction:
    address: int
    mnemonic: str
    operand_text: str
    disassembly: str
    length: int


@dataclass(frozen=True)
class NativeProviderOutput:
    engine: NativeEngineStatus
    opened_program: NativeOpenProgram
    decompilation: NativeDecompilation
    function: NativeFunction
    instructions: tuple[NativeInstruction, ...]


class NativeDecompilerProvider(Protocol):
    def decompile(
        self,
        *,
        request: AnalysisRequest,
        carrier: CarrierArtifact,
        carrier_path: Path,
        state_directory: Path,
        cancellation_path: Path | None,
    ) -> NativeProviderOutput: ...


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _ordinary_file(path: Path, label: str) -> Path:
    try:
        before = path.lstat()
    except OSError as error:
        raise MaterializationError(f"{label} is missing or inaccessible") from error
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise MaterializationError(f"{label} must be an ordinary regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MaterializationError(f"{label} could not be opened safely") from error
    try:
        after = os.fstat(descriptor)
        if not stat.S_ISREG(after.st_mode) or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise MaterializationError(f"{label} changed while opening")
    finally:
        os.close(descriptor)
    return path.resolve(strict=True)


def _ordinary_directory(path: Path, label: str) -> Path:
    try:
        before = path.lstat()
        resolved = path.resolve(strict=True)
        after = resolved.lstat()
    except OSError as error:
        raise MaterializationError(f"{label} is missing or inaccessible") from error
    if (
        not stat.S_ISDIR(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or not stat.S_ISDIR(after.st_mode)
    ):
        raise MaterializationError(f"{label} must be an ordinary directory")
    return resolved


def _duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _load_manifest(path: Path) -> tuple[dict[str, Any], str, Path]:
    resolved = _ordinary_file(path, "materialization manifest")
    try:
        raw = resolved.read_bytes()
        if len(raw) > MAX_MATERIALIZATION_BYTES:
            raise MaterializationError("materialization manifest exceeds its fixed bound")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_duplicate_object)
    except MaterializationError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise MaterializationError("materialization manifest is not canonical JSON") from error
    if canonical_json_bytes(value) != raw:
        raise MaterializationError("materialization manifest is not canonical JSON")

    expected_keys = {
        "schemaVersion",
        "componentId",
        "version",
        "gitRevision",
        "wheel",
        "wheelSha256",
        "wheelPlatform",
        "wheelURL",
        "extensionRelativePath",
        "extensionSha256",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise MaterializationError("materialization manifest has an unsupported shape")
    if value["schemaVersion"] != 1 or value["componentId"] != ENGINE_COMPONENT_ID:
        raise MaterializationError("materialization manifest identifies a different component")
    if value["version"] != ENGINE_VERSION or value["gitRevision"] != ENGINE_GIT_REVISION:
        raise MaterializationError("materialization manifest identifies a different revision")

    for key in (
        "wheel",
        "wheelSha256",
        "wheelPlatform",
        "wheelURL",
        "extensionRelativePath",
        "extensionSha256",
    ):
        item = value[key]
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > MAX_TEXT:
            raise MaterializationError(f"materialization manifest field {key} is invalid")

    approved = APPROVED_WHEELS.get(value["wheel"])
    if approved is None or (
        value["wheelSha256"] != approved.sha256
        or value["wheelPlatform"] != approved.platform
        or value["wheelURL"] != approved.url
    ):
        raise MaterializationError("materialization manifest uses an unapproved wheel identity")

    checksum = value["extensionSha256"]
    if len(checksum) != 64 or any(character not in "0123456789abcdef" for character in checksum):
        raise MaterializationError("materialization extension checksum is malformed")
    relative = Path(value["extensionRelativePath"])
    if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise MaterializationError("materialization extension path escapes its root")
    if relative.suffix not in {".so", ".dylib", ".pyd"}:
        raise MaterializationError("materialization extension path has an unsupported suffix")
    return value, hashlib.sha256(raw).hexdigest(), resolved.parent.resolve(strict=True)


def _load_native_extension(extension_path: Path) -> ModuleType:
    try:
        spec = importlib.util.spec_from_file_location("_libghidra", extension_path)
        if spec is None or spec.loader is None:
            raise ImportError("extension spec is unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as error:
        raise MaterializationError("pinned libghidra native extension could not be loaded") from error
    if not hasattr(module, "create_local_client"):
        raise MaterializationError("pinned libghidra native extension lacks create_local_client")
    return module


def _bounded_text(value: Any, label: str, *, maximum: int = MAX_SHORT_TEXT, allow_empty: bool = True) -> str:
    if not isinstance(value, str) or (not allow_empty and not value) or len(value.encode("utf-8")) > maximum:
        raise ProviderError(f"native decompiler returned invalid {label}")
    if any(ord(character) < 0x20 and character not in "\n\r\t" for character in value):
        raise ProviderError(f"native decompiler returned invalid {label}")
    if any(0xD800 <= ord(character) <= 0xDFFF or character == "\x00" for character in value):
        raise ProviderError(f"native decompiler returned invalid {label}")
    return value


def _integer(value: Any, label: str, *, minimum: int = 0, maximum: int = (1 << 64) - 1) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ProviderError(f"native decompiler returned invalid {label}")
    return value


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise ProviderError(f"native decompiler returned invalid {label}")
    return value


def _mapping(value: Any, label: str, *, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ProviderError(f"native decompiler returned invalid {label}")
    return value


def _sequence(value: Any, label: str, maximum: int) -> list[Any]:
    if not isinstance(value, list) or len(value) > maximum:
        raise ProviderError(f"native decompiler returned invalid {label}")
    return value


def _cancelled(path: Path | None) -> bool:
    if path is None:
        return False
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def _validate_status(raw: Any) -> tuple[str, str, str, int]:
    value = _mapping(
        raw,
        "status",
        keys={
            "ok",
            "service_name",
            "service_version",
            "host_mode",
            "program_revision",
            "warnings",
        },
    )
    if not _boolean(value["ok"], "status ok"):
        raise ProviderError("native decompiler reported an unhealthy local service")
    service_name = _bounded_text(value["service_name"], "service name", allow_empty=False)
    service_version = _bounded_text(value["service_version"], "service version", allow_empty=False)
    host_mode = _bounded_text(value["host_mode"], "host mode", allow_empty=False)
    revision = _integer(value["program_revision"], "program revision")
    warning_values = _sequence(value["warnings"], "status warnings", MAX_CAPABILITY_COUNT)
    for index, item in enumerate(warning_values):
        _bounded_text(item, f"status warnings[{index}]", maximum=MAX_TEXT)
    if warning_values:
        # Native warning text is not independently verifiable and may contain
        # host paths or other diagnostics. Fail closed rather than export it.
        raise ProviderError("native decompiler reported warnings")
    if (
        service_name != ENGINE_SERVICE_NAME
        or service_version != ENGINE_SERVICE_VERSION
        or host_mode != ENGINE_HOST_MODE
    ):
        raise ProviderError("native decompiler reported an unexpected service identity")
    return service_name, service_version, host_mode, revision


def _validate_capabilities(raw: Any) -> tuple[NativeCapability, ...]:
    values = _sequence(raw, "capabilities", MAX_CAPABILITY_COUNT)
    result: list[NativeCapability] = []
    for index, item in enumerate(values):
        value = _mapping(item, f"capabilities[{index}]", keys={"id", "status", "note"})
        capability_id = _bounded_text(value["id"], "capability id", allow_empty=False)
        status = _bounded_text(value["status"], "capability status", allow_empty=False)
        _bounded_text(value["note"], "capability note", maximum=MAX_TEXT)
        result.append(NativeCapability(capability_id=capability_id, status=status))
    ordered = tuple(sorted(result, key=lambda item: (item.capability_id, item.status)))
    if len({item.capability_id for item in ordered}) != len(ordered):
        raise ProviderError("native decompiler returned duplicate capability identifiers")
    observed = {item.capability_id: item.status for item in ordered}
    for capability_id, expected_status in REQUIRED_NATIVE_CAPABILITIES.items():
        if observed.get(capability_id) != expected_status:
            raise ProviderError(f"required native decompiler capability is unavailable: {capability_id}")
    return ordered


def _convert_decompilation(raw: Any) -> NativeDecompilation:
    value = _mapping(
        raw,
        "decompilation",
        keys={
            "function_entry_address",
            "function_name",
            "prototype",
            "pseudocode",
            "completed",
            "is_fallback",
            "error_message",
            "locals",
            "tokens",
        },
    )
    # v0.0.2's local GetDecompilation only fills entry, pseudocode, completed,
    # and error_message. Reject non-empty optional semantic records instead of
    # silently upgrading the capability contract.
    if _bounded_text(value["function_name"], "decompilation function name"):
        raise ProviderError("pinned libghidra returned an unexpected decompilation name record")
    if _bounded_text(value["prototype"], "decompilation prototype", maximum=MAX_TEXT):
        raise ProviderError("pinned libghidra returned an unexpected decompilation prototype record")
    if _sequence(value["locals"], "decompilation locals", 0):
        raise ProviderError("pinned libghidra returned unsupported local records")
    if _sequence(value["tokens"], "decompilation tokens", 0):
        raise ProviderError("pinned libghidra returned unsupported token records")
    error_message = _bounded_text(value["error_message"], "decompilation error", maximum=MAX_TEXT)
    completed = _boolean(value["completed"], "completion flag")
    fallback = _boolean(value["is_fallback"], "fallback flag")
    pseudocode = _bounded_text(value["pseudocode"], "pseudocode", maximum=MAX_PSEUDOCODE_BYTES)
    if error_message and completed:
        raise ProviderError("native decompiler returned both success and an error message")
    return NativeDecompilation(
        function_entry=_integer(value["function_entry_address"], "decompilation entry"),
        pseudocode=pseudocode,
        completed=completed,
        fallback=fallback,
    )


def _convert_function(raw: Any) -> NativeFunction:
    value = _mapping(
        raw,
        "function",
        keys={
            "entry_address",
            "name",
            "start_address",
            "end_address",
            "size",
            "namespace_name",
            "prototype",
            "is_thunk",
            "parameter_count",
        },
    )
    return NativeFunction(
        entry_address=_integer(value["entry_address"], "function entry"),
        name=_bounded_text(value["name"], "function name"),
        start_address=_integer(value["start_address"], "function start"),
        end_address=_integer(value["end_address"], "function end"),
        size=_integer(value["size"], "function size"),
        namespace_name=_bounded_text(value["namespace_name"], "function namespace"),
        prototype=_bounded_text(value["prototype"], "function prototype", maximum=MAX_TEXT),
        is_thunk=_boolean(value["is_thunk"], "function thunk flag"),
        parameter_count=_integer(value["parameter_count"], "function parameter count", maximum=100_000),
    )


def _convert_instruction(raw: Any) -> NativeInstruction:
    value = _mapping(
        raw,
        "instruction",
        keys={"address", "mnemonic", "operand_text", "disassembly", "length"},
    )
    return NativeInstruction(
        address=_integer(value["address"], "instruction address"),
        mnemonic=_bounded_text(value["mnemonic"], "instruction mnemonic", allow_empty=False),
        operand_text=_bounded_text(value["operand_text"], "instruction operands", maximum=MAX_TEXT),
        disassembly=_bounded_text(value["disassembly"], "instruction disassembly", maximum=MAX_TEXT, allow_empty=False),
        length=_integer(value["length"], "instruction length", minimum=1, maximum=16),
    )


class LibGhidraExtensionProvider:
    """Address-driven provider for one explicitly materialized native wheel."""

    def __init__(self, materialization_manifest: Path) -> None:
        self.materialization_manifest = materialization_manifest

    def decompile(
        self,
        *,
        request: AnalysisRequest,
        carrier: CarrierArtifact,
        carrier_path: Path,
        state_directory: Path,
        cancellation_path: Path | None,
    ) -> NativeProviderOutput:
        if _cancelled(cancellation_path):
            raise CancelledError()
        manifest, materialization_sha, root = _load_manifest(self.materialization_manifest)
        extension = _ordinary_file(root / manifest["extensionRelativePath"], "libghidra extension")
        try:
            extension.relative_to(root)
        except ValueError as error:
            raise MaterializationError("materialization extension path escapes its root") from error
        if _sha256(extension) != manifest["extensionSha256"]:
            raise MaterializationError("libghidra extension checksum does not match its manifest")

        carrier_file = _ordinary_file(carrier_path, "carrier")
        if carrier_file.stat().st_size != len(carrier.data) or _sha256(carrier_file) != carrier.sha256:
            raise ProviderError("carrier file does not match the deterministic caller-owned artifact")
        state_root = _ordinary_directory(state_directory, "pilot state directory")
        state_path = state_root / "libghidra-state.xml"
        if os.path.lexists(state_path):
            raise ProviderError("pilot state path must not already exist")

        native = _load_native_extension(extension)
        try:
            client = native.create_local_client(
                ghidra_root="",
                state_path=str(state_path),
                default_arch=ENGINE_LANGUAGE_ID,
                pool_size=1,
            )
        except Exception as error:
            raise ProviderError() from error

        opened = False
        try:
            service_name, service_version, host_mode, revision = _validate_status(
                client.get_status()
            )
            capabilities = _validate_capabilities(client.get_capabilities())
            if _cancelled(cancellation_path):
                raise CancelledError()

            opened_value = _mapping(
                client.open_program(
                    program_path=str(carrier_file),
                    analyze=False,
                    read_only=True,
                    project_path="",
                    project_name="",
                    language_id=ENGINE_LANGUAGE_ID,
                    compiler_spec_id=ENGINE_COMPILER_SPEC_ID,
                    format=ENGINE_FORMAT,
                    base_address=request.preferred_load_address,
                ),
                "open-program response",
                keys={"program_name", "language_id", "compiler_spec", "image_base"},
            )
            opened = True
            opened_program_name = _bounded_text(
                opened_value["program_name"],
                "opened program name",
                maximum=MAX_TEXT,
                allow_empty=False,
            )
            if "/" in opened_program_name or "\\" in opened_program_name:
                raise ProviderError("native decompiler returned an unsafe opened program name")
            opened_language_id = _bounded_text(
                opened_value["language_id"],
                "opened language",
                maximum=MAX_TEXT,
                allow_empty=False,
            )
            opened_compiler_spec = _bounded_text(
                opened_value["compiler_spec"],
                "opened compiler specification",
                maximum=MAX_TEXT,
                allow_empty=False,
            )
            if opened_language_id != ENGINE_LANGUAGE_ID:
                raise ProviderError("native decompiler opened the carrier with an unexpected language")
            if opened_compiler_spec != ENGINE_COMPILER_SPEC_ID:
                raise ProviderError("native decompiler opened the carrier with an unexpected compiler specification")
            reported_image_base = _integer(opened_value["image_base"], "opened image base")
            if reported_image_base not in {0, request.preferred_load_address}:
                raise ProviderError("native decompiler opened the carrier at an unexpected image base")
            if _cancelled(cancellation_path):
                raise CancelledError()

            decomp_raw = client.get_decompilation(request.function_entry, request.budgets.max_wall_time_ms)
            if decomp_raw is None:
                raise ProviderError("native decompiler returned no decompilation record")
            decompilation = _convert_decompilation(decomp_raw)
            if (
                decompilation.function_entry != request.function_entry
                or not decompilation.completed
                or decompilation.fallback
                or not decompilation.pseudocode
            ):
                raise ProviderError("native decompiler did not complete a non-fallback decompilation")

            function_raw = client.get_function(request.function_entry)
            if function_raw is None:
                raise ProviderError("native decompiler returned no function record")
            function = _convert_function(function_raw)

            # libghidra models the range end as inclusive. The MacScope request
            # contract is half-open, so do not allow the first instruction of a
            # neighboring function to enter the pilot result.
            instruction_items = _sequence(
                client.list_instructions(
                    request.function_entry,
                    request.function_end - 1,
                    min(MAX_INSTRUCTION_COUNT, request.budgets.max_instructions),
                    0,
                ),
                "instructions",
                min(MAX_INSTRUCTION_COUNT, request.budgets.max_instructions),
            )
            instructions = tuple(_convert_instruction(item) for item in instruction_items)
            if not instructions:
                raise ProviderError("native decompiler returned no instruction records")
            if _cancelled(cancellation_path):
                raise CancelledError()

            return NativeProviderOutput(
                engine=NativeEngineStatus(
                    service_name=service_name,
                    service_version=service_version,
                    host_mode=host_mode,
                    program_revision=revision,
                    capabilities=capabilities,
                    wheel_filename=manifest["wheel"],
                    wheel_sha256=manifest["wheelSha256"],
                    wheel_platform=manifest["wheelPlatform"],
                    extension_sha256=manifest["extensionSha256"],
                    materialization_sha256=materialization_sha,
                ),
                opened_program=NativeOpenProgram(
                    program_name=opened_program_name,
                    language_id=opened_language_id,
                    compiler_spec=opened_compiler_spec,
                    reported_image_base=reported_image_base,
                ),
                decompilation=decompilation,
                function=function,
                instructions=instructions,
            )
        except CancelledError:
            raise
        except (ProviderError, MaterializationError):
            raise
        except Exception as error:
            # Do not disclose native exception text, filesystem paths, or crash
            # diagnostics across the process boundary.
            raise ProviderError() from error
        finally:
            if opened:
                try:
                    client.close_program(2)  # pinned ShutdownPolicy::kDiscard
                except Exception:
                    pass
