"""MacScope DCP-03 native SLEIGH data-flow proof.

This package is a developer-only, non-shipping proof boundary. It imports
``pypcode`` lazily, so request/schema/data-flow verification tests do not
require a materialized native dependency.
"""

from .engine import analyze_request
from .errors import ProofError
from .request import AnalysisRequest, parse_request_bytes
from .result_validation import ResultValidationError, validate_result

__all__ = [
    "AnalysisRequest",
    "ProofError",
    "ResultValidationError",
    "analyze_request",
    "parse_request_bytes",
    "validate_result",
]
