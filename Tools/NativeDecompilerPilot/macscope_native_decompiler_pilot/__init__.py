"""MacScope-owned DCP-03B3 native decompiler pilot contracts."""

from .carrier import CarrierArtifact, build_macho_carrier
from .errors import CarrierBuildError
from .normalize import build_result
from .provider import (
    NativeCapability,
    NativeDecompilation,
    NativeEngineStatus,
    NativeFunction,
    NativeInstruction,
    NativeOpenProgram,
    NativeProviderOutput,
)
from .result_validation import ResultValidationError, validate_result

__all__ = [
    "CarrierArtifact",
    "CarrierBuildError",
    "NativeCapability",
    "NativeDecompilation",
    "NativeEngineStatus",
    "NativeFunction",
    "NativeInstruction",
    "NativeOpenProgram",
    "NativeProviderOutput",
    "ResultValidationError",
    "build_macho_carrier",
    "build_result",
    "validate_result",
]
