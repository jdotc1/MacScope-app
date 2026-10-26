"""Bounded public errors for the DCP-03B3 pilot."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PilotError(RuntimeError):
    code: str
    message: str
    exit_code: int = 2

    def __str__(self) -> str:
        return self.message


class CarrierBuildError(PilotError):
    def __init__(self, message: str) -> None:
        super().__init__("carrier.invalid_request", message, 2)


class MaterializationError(PilotError):
    def __init__(self, message: str) -> None:
        super().__init__("dependency.invalid_materialization", message, 3)


class ProviderError(PilotError):
    def __init__(self, message: str = "native decompiler operation failed") -> None:
        super().__init__("backend.failed", message, 4)


class NormalizationError(PilotError):
    def __init__(self, message: str) -> None:
        super().__init__("backend.invalid_structured_output", message, 5)


class CancelledError(PilotError):
    def __init__(self) -> None:
        super().__init__("analysis.cancelled", "analysis cancelled", 6)
