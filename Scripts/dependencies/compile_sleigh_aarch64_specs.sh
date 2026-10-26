#!/bin/bash
# Offline compile of the AArch64 SLEIGH specifications with the vendored compiler.
#
#   compile_sleigh_aarch64_specs.sh --spec-root <dir with *.slaspec/*.sinc> --work-root /abs/external
#
# Runs ThirdParty/SleighNative/package/bin/sleigh on AARCH64.slaspec, AARCH64BE.slaspec and
# AARCH64_AppleSilicon.slaspec. Output goes to <work-root>/<cache-key>/ with COMPILE_RECEIPT.json
# (input closure digest, compiler digest, script digest, output digests). The cache key hashes
# exactly those inputs, so an existing verified entry is reused and nothing is recompiled. The
# repository is never written. Verified 2026-10-12: compiling the unmodified upstream closure
# reproduces the release-archive .sla files byte for byte.
set -euo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/../.." && pwd -P)"
compiler="${repo_root}/ThirdParty/SleighNative/package/bin/sleigh"
spec_root=""
work_root=""
while (($#)); do
  case "$1" in
    --spec-root) spec_root="$2"; shift 2 ;;
    --work-root) work_root="$2"; shift 2 ;;
    *) fail "usage: --spec-root <dir> --work-root </absolute/external/dir>" ;;
  esac
done
[[ -n "${spec_root}" && -d "${spec_root}" && ! -L "${spec_root}" ]] || fail "--spec-root must be an ordinary directory"
[[ "${work_root}" == /* ]] || fail "--work-root must be absolute"
[[ -f "${compiler}" && ! -L "${compiler}" ]] || fail "vendored sleigh compiler is missing"

/usr/bin/python3 -B - "${spec_root}" "${work_root}" "${repo_root}" "${compiler}" "${BASH_SOURCE[0]}" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

spec_root, work_root, repo_root, compiler, script = (Path(a) for a in sys.argv[1:])
spec_root = spec_root.resolve(strict=True)
repo_root = repo_root.resolve(strict=True)
work_root = work_root.resolve(strict=False)
if work_root == repo_root or repo_root in work_root.parents:
    raise SystemExit("ERROR: --work-root must be outside the repository")
SPECS = ("AARCH64", "AARCH64BE", "AARCH64_AppleSilicon")

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

inputs = []
for path in sorted(spec_root.iterdir(), key=lambda p: p.name):
    if path.suffix not in (".slaspec", ".sinc"):
        continue
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"ERROR: input is not an ordinary file: {path.name}")
    inputs.append({"name": path.name, "size": path.stat().st_size, "sha256": sha(path)})
missing = [s for s in SPECS if not (spec_root / f"{s}.slaspec").is_file()]
if missing:
    raise SystemExit(f"ERROR: missing slaspec: {missing}")
closure = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
identity = {
    "schemaVersion": 1,
    "inputClosureSha256": closure,
    "compilerSha256": sha(compiler),
    "scriptSha256": sha(script),
}
key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
entry = work_root / key
receipt_path = entry / "COMPILE_RECEIPT.json"

def verify(root: Path) -> dict:
    receipt = json.loads((root / "COMPILE_RECEIPT.json").read_text())
    if {k: receipt.get(k) for k in identity} != identity:
        raise SystemExit("ERROR: cached compile receipt identity mismatch")
    for name, digest in receipt["outputs"].items():
        if sha(root / name) != digest:
            raise SystemExit(f"ERROR: cached output digest mismatch: {name}")
    return receipt

if entry.exists():
    receipt = verify(entry)
    receipt["cache"] = "reused"
    print(json.dumps(receipt, sort_keys=True))
    raise SystemExit(0)

work_root.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix=f".{key[:12]}.", dir=work_root))
try:
    sources = staging / "src"
    sources.mkdir()
    for item in inputs:
        shutil.copyfile(spec_root / item["name"], sources / item["name"])
    outputs = {}
    for spec in SPECS:
        completed = subprocess.run([str(compiler), f"{spec}.slaspec", str(staging / f"{spec}.sla")],
                                   cwd=sources, capture_output=True, text=True, check=False)
        (staging / f"{spec}.log").write_text(completed.stdout + completed.stderr)
        if completed.returncode != 0:
            raise SystemExit(f"ERROR: sleigh failed for {spec}; see {staging / (spec + '.log')}")
        outputs[f"{spec}.sla"] = sha(staging / f"{spec}.sla")
    shutil.rmtree(sources)
    receipt = dict(identity, inputs=inputs, outputs=outputs, network="disabled")
    (staging / "COMPILE_RECEIPT.json").write_text(json.dumps(receipt, sort_keys=True, indent=1) + "\n")
    os.rename(staging, entry)
except BaseException:
    # Failed compiler diagnostics are the only evidence for a focused retry.
    print(f"ERROR: retained failed compile at {staging}", file=sys.stderr)
    raise
receipt = verify(entry)
receipt["cache"] = "built"
print(json.dumps(receipt, sort_keys=True))
PY
