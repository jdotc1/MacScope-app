"""Closed error vocabulary for the DCP-03 proof boundary."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ProofError(RuntimeError):
    """Expected, user-facing proof failure.

    ``code`` is stable machine-readable API. ``message`` is bounded diagnostic
    text and must not contain binary contents or host-specific absolute paths.
    """

    code: str
    message: str
    exit_code: int = 2

    def __str__(self) -> str:
        return self.message


class RequestValidationError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("request.invalid", message, 2)


class DependencyUnavailableError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("dependency.unavailable", message, 3)


class DependencyMismatchError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("dependency.mismatch", message, 3)


class DecodeError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("analysis.decode_failed", message, 4)


class LiftError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("analysis.lift_failed", message, 4)


class BudgetExceededError(ProofError):
    def __init__(self, resource: str) -> None:
        super().__init__("resource.exhausted", f"resource budget exceeded: {resource}", 5)


class CancelledError(ProofError):
    def __init__(self) -> None:
        super().__init__("analysis.cancelled", "analysis cancelled", 6)


class OutputWriteError(ProofError):
    def __init__(self, message: str) -> None:
        super().__init__("output.write_failed", message, 7)
