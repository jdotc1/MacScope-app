# CP7 supplemental scalar FP observations

10,804 additional QEMU-executed vectors; these are separate from the original 9,368-vector oracle and its PASS ratchet.

- Recorded using QEMU 11.1.2 (Debian 1:11.1.2+ds-3), SHA-256 `24edeb3f7bc7b06f5470cc44e27759596d2d1728fc2f0861ba18add40db6564e`.
- FPCR=0, FPSR initially zero. Ordinary scalar mode; full destination storage is compared.
- The tests require `UNSUPPORTED` with the exact reason `FPSR output is not modeled; numeric data checks matched`. A different unsupported reason fails the test. Every numeric result must match before that reason is returned.
- The expected outputs were observed from QEMU, not computed by the builder or evaluator.
- Generation inputs, raw observations, executable probe provenance, scripts and command receipts are in the companion CP7 handback `fp-evidence/` and `receipts/` directories. `make_fixtures.py` only packages recorded results.
- Raw observation SHA-256: `f9295b3c57f2927b4fdf85bef56318215477a294e68dd620c8c7c289ce78f7bf`.
- Fixture SHA-256: `1f0a4aa9dd3cf603b3ae69fed7aa8a76db854fe9c30c8ec079dfb901b0b27a77`.

Fused coverage additionally has an independent integer/Fraction exact reference, checked against all 16,024 observations. Cached Arm 2025-03 FPMulAdd/shared-pseudocode provenance is recorded in `arm-source-provenance.json`; copyrighted XML is not redistributed. Sign-variant instruction XML was unavailable, so those mappings are supported by the recorded QEMU edge grid and finite-algebra corroboration, not claimed as independently read variant XML.

Finite grids cannot establish all-input completeness. Non-default FPCR, FPSR effects, half precision and vector lanes are not claimed.
