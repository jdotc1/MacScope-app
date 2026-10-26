#!/bin/bash

set -euo pipefail

readonly TEST_SELECTOR='CoreTests/ReconstructionAuthorityRaceStressTests/testCompiledAuthorityRaceScenario'

usage() {
    printf '%s\n' \
        'usage: run_authority_stress_tests.sh --candidate-identity ABSOLUTE_PATH' \
        '       --preparation-receipt ABSOLUTE_PATH' \
        '       --qualification-run-id STABLE_ID --qualification-run-nonce SHA256' \
        '       --predecessor-observations ABSOLUTE_PATH' \
        '       --xctestrun ABSOLUTE_PATH --candidate-app ABSOLUTE_PATH' \
        '       --result-bundle-path ABSOLUTE_PATH --artifact-root ABSOLUTE_PATH' \
        '       [--repetitions POSITIVE_INTEGER]'
}

fail_usage() {
    printf 'ERROR: %s\n' "$1" >&2
    usage >&2
    exit 2
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

candidate_identity=
preparation_receipt=
xctestrun=
candidate_app=
result_bundle=
artifact_root=
qualification_run_id=
qualification_run_nonce=
predecessor_observations=
repetitions=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidate-identity)
            [[ $# -ge 2 ]] || fail_usage '--candidate-identity requires a value'
            candidate_identity=$2
            shift 2
            ;;
        --xctestrun)
            [[ $# -ge 2 ]] || fail_usage '--xctestrun requires a value'
            xctestrun=$2
            shift 2
            ;;
        --preparation-receipt)
            [[ $# -ge 2 ]] || fail_usage '--preparation-receipt requires a value'
            preparation_receipt=$2
            shift 2
            ;;
        --candidate-app)
            [[ $# -ge 2 ]] || fail_usage '--candidate-app requires a value'
            candidate_app=$2
            shift 2
            ;;
        --result-bundle-path)
            [[ $# -ge 2 ]] || fail_usage '--result-bundle-path requires a value'
            result_bundle=$2
            shift 2
            ;;
        --artifact-root)
            [[ $# -ge 2 ]] || fail_usage '--artifact-root requires a value'
            artifact_root=$2
            shift 2
            ;;
        --qualification-run-id)
            [[ $# -ge 2 ]] || fail_usage '--qualification-run-id requires a value'
            qualification_run_id=$2
            shift 2
            ;;
        --qualification-run-nonce)
            [[ $# -ge 2 ]] || fail_usage '--qualification-run-nonce requires a value'
            qualification_run_nonce=$2
            shift 2
            ;;
        --predecessor-observations)
            [[ $# -ge 2 ]] || fail_usage '--predecessor-observations requires a value'
            predecessor_observations=$2
            shift 2
            ;;
        --repetitions)
            [[ $# -ge 2 ]] || fail_usage '--repetitions requires a value'
            repetitions=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail_usage "unknown argument: $1"
            ;;
    esac
done

for value in candidate_identity preparation_receipt predecessor_observations xctestrun candidate_app result_bundle artifact_root; do
    [[ -n "${!value}" ]] || fail_usage "--${value//_/-} is required"
    [[ "${!value}" == /* ]] || fail_usage "--${value//_/-} must be absolute"
done
[[ -n "$qualification_run_id" ]] || fail_usage '--qualification-run-id is required'
[[ -n "$qualification_run_nonce" ]] || fail_usage '--qualification-run-nonce is required'
[[ "$repetitions" =~ ^[1-9][0-9]*$ ]] || \
    fail_usage '--repetitions must be a positive integer'
[[ -f "$candidate_identity" && ! -L "$candidate_identity" ]] || \
    fail 'candidate identity must be a non-symlink regular file'
[[ -f "$preparation_receipt" && ! -L "$preparation_receipt" ]] || \
    fail 'preparation receipt must be a non-symlink regular file'
[[ -f "$predecessor_observations" && ! -L "$predecessor_observations" ]] || \
    fail 'predecessor observations must be a non-symlink regular file'
[[ -f "$xctestrun" && ! -L "$xctestrun" ]] || \
    fail 'xctestrun must be a non-symlink regular file'
[[ -d "$candidate_app" && ! -L "$candidate_app" && "$candidate_app" == *.app ]] || \
    fail 'candidate app must be a non-symlink .app directory'
[[ ! -e "$result_bundle" && ! -L "$result_bundle" ]] || \
    fail 'refusing to overwrite the result bundle path'
[[ -d "$(dirname "$result_bundle")" ]] || \
    fail 'result bundle parent directory does not exist'
[[ ! -e "$artifact_root" && ! -L "$artifact_root" ]] || \
    fail 'refusing to overwrite the artifact root'
[[ -d "$(dirname "$artifact_root")" ]] || \
    fail 'artifact-root parent directory does not exist'

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_dir/../.." && pwd -P)
qualification_validator="$repository_root/Scripts/reconstruction/validate_qualification_product_identity.py"
preparation_validator="$repository_root/Scripts/reconstruction/native_live_preparation_receipt.py"
[[ -f "$qualification_validator" ]] || \
    fail 'qualification product identity validator is unavailable'
[[ -f "$preparation_validator" ]] || \
    fail 'native live preparation receipt validator is unavailable'
source "$repository_root/Scripts/xcode27_env.sh"

candidate_identity=$(cd "$(dirname "$candidate_identity")" && pwd -P)/$(basename "$candidate_identity")
preparation_receipt=$(cd "$(dirname "$preparation_receipt")" && pwd -P)/$(basename "$preparation_receipt")
predecessor_observations=$(cd "$(dirname "$predecessor_observations")" && pwd -P)/$(basename "$predecessor_observations")
xctestrun=$(cd "$(dirname "$xctestrun")" && pwd -P)/$(basename "$xctestrun")
candidate_app=$(cd "$(dirname "$candidate_app")" && pwd -P)/$(basename "$candidate_app")
products_root=$(cd "$(dirname "$xctestrun")" && pwd -P)
candidate_products_root=$(cd "$(dirname "$candidate_app")/.." && pwd -P)
[[ "$products_root" == "$candidate_products_root" ]] || \
    fail 'candidate app and xctestrun must share the exact Build/Products root'
[[ "$(basename "$(dirname "$candidate_app")")" == Debug ]] || \
    fail 'authority stress must use the Debug test product'

/usr/bin/python3 -B "$qualification_validator" \
    --candidate-identity "$candidate_identity" \
    --app-bundle "$candidate_app" \
    --product app

# The full native-live preparation receipt is the sole authority that binds
# this candidate to the exact xctestrun, app, embedded native service, and
# CoreTests bundle. This must complete before any output root is created.
/usr/bin/python3 -B "$preparation_validator" validate \
    --receipt "$preparation_receipt" \
    --xctestrun "$xctestrun" \
    --candidate-app "$candidate_app" \
    --candidate-identity "$candidate_identity"

# Bind the executor to the coordinator-issued qualification run and the exact
# same-run predecessor observation before any output root or test process exists.
# These values are runtime authority and never enter the deterministic plan.
predecessor_observations_sha256=$(/usr/bin/python3 -B - \
    "$repository_root" "$predecessor_observations" \
    "$qualification_run_id" "$qualification_run_nonce" <<'PY'
from pathlib import Path
import sys

repository_root = Path(sys.argv[1])
sys.path.insert(0, str(repository_root))
from Scripts.reconstruction.run_authority_stress import (  # noqa: E402
    load_predecessor_observations,
    parse_qualification_run_authority,
)
from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256  # noqa: E402

qualification_run = parse_qualification_run_authority(sys.argv[3], sys.argv[4])
observations = load_predecessor_observations(
    Path(sys.argv[2]),
    qualification_run=qualification_run,
)
print(canonical_sha256(list(observations)))
PY
)

/usr/bin/python3 -B - "$xctestrun" <<'PY'
import plistlib
from pathlib import Path
import sys

xctestrun_path = Path(sys.argv[1])
try:
    with xctestrun_path.open("rb") as stream:
        document = plistlib.load(stream)
except (OSError, plistlib.InvalidFileException) as error:
    raise SystemExit(f"ERROR: xctestrun cannot be decoded safely: {error}")
metadata = document.get("__xctestrun_metadata__", {})
suite = document.get("CoreTests")
if metadata.get("ContainerInfo", {}).get("SchemeName") != "MacScopeApp":
    raise SystemExit("ERROR: xctestrun is not the MacScopeApp scheme product")
if not isinstance(suite, dict) or suite.get("BlueprintName") != "CoreTests":
    raise SystemExit("ERROR: xctestrun does not carry the CoreTests bundle")
PY

# Do not expose a receipt root until candidate identity and the sealed Xcode
# product have both passed their independent binding checks.
/bin/mkdir "$artifact_root"
artifact_root=$(cd "$artifact_root" && pwd -P)

plan_path="$artifact_root/AuthorityStress.plan.json"
ledger_path="$artifact_root/AuthorityStress.attempt-ledger.json"
results_path="$artifact_root/AuthorityStress.test-results.json"
report_path="$artifact_root/AuthorityStress.execution-report.json"
execution_xctestrun_evidence="$artifact_root/AuthorityStress.xctestrun"
preparation_receipt_evidence="$artifact_root/AuthorityStress.preparation-receipt.json"
prepared_xctestrun_evidence="$artifact_root/AuthorityStress.prepared.xctestrun"

# Preserve immutable, ordinary copies of the precise preparation authority and
# its source xctestrun before deriving the execution-only environment overlay.
# The Gate F receipt validator proves the derived file differs only in the two
# governed stress environment values; it never relies on a live path string.
/bin/cp -p "$preparation_receipt" "$preparation_receipt_evidence"
/bin/cp -p "$xctestrun" "$prepared_xctestrun_evidence"
for evidence in "$preparation_receipt_evidence" "$prepared_xctestrun_evidence"; do
    [[ -f "$evidence" && ! -L "$evidence" ]] || \
        fail 'preparation provenance evidence was not published safely'
done

# Validate the copies that will become Gate F evidence, not merely the live
# source paths that were preflighted above. The descriptor-bound read below
# then derives the execution xctestrun from exactly the receipt-bound bytes.
/usr/bin/python3 -B "$preparation_validator" validate \
    --receipt "$preparation_receipt_evidence" \
    --xctestrun "$prepared_xctestrun_evidence" \
    --candidate-app "$candidate_app" \
    --candidate-identity "$candidate_identity"

/usr/bin/python3 -B "$repository_root/Scripts/reconstruction/run_authority_stress.py" \
    --candidate-identity "$candidate_identity" \
    --repetitions "$repetitions" \
    --execute-python \
    --qualification-run-id "$qualification_run_id" \
    --qualification-run-nonce "$qualification_run_nonce" \
    --output "$plan_path"
[[ -f "$plan_path" && ! -L "$plan_path" ]] || fail 'stress plan was not emitted safely'
plan_sha256_before=$(/usr/bin/shasum -a 256 "$plan_path" | /usr/bin/awk '{print $1}')
execution_xctestrun=$(/usr/bin/mktemp "$products_root/MacScopeAuthorityStress.XXXXXX.xctestrun")
[[ -f "$execution_xctestrun" && ! -L "$execution_xctestrun" ]] || \
    fail 'failed to reserve an exact stress xctestrun path'
cleanup_execution_xctestrun() {
    if [[ -n "${execution_xctestrun:-}" && -f "$execution_xctestrun" \
        && ! -L "$execution_xctestrun" \
        && "$(cd "$(dirname "$execution_xctestrun")" && pwd -P)" == "$products_root" \
        && "$(basename "$execution_xctestrun")" == MacScopeAuthorityStress.*.xctestrun ]]; then
        /bin/rm -f "$execution_xctestrun"
    fi
}
trap cleanup_execution_xctestrun EXIT
/usr/bin/python3 -B - \
    "$prepared_xctestrun_evidence" "$execution_xctestrun" "$plan_path" "$ledger_path" <<'PY'
import os
import hashlib
import json
import plistlib
from pathlib import Path
import stat
import sys

source, output, plan, ledger = map(Path, sys.argv[1:])

def read_ordinary_snapshot(path: Path, label: str) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise SystemExit(f"ERROR: {label} is not a regular file")
        chunks = []
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
    ):
        raise SystemExit(f"ERROR: {label} changed while being read")
    return b"".join(chunks)

preparation = json.loads(read_ordinary_snapshot(
    source.with_name("AuthorityStress.preparation-receipt.json"),
    "prepared stress receipt snapshot",
))
try:
    expected_xctestrun_sha256 = preparation["artifacts"]["xctestrun"]["sha256"]
except (KeyError, TypeError):
    raise SystemExit("ERROR: prepared stress receipt lacks its xctestrun identity")
if not isinstance(expected_xctestrun_sha256, str):
    raise SystemExit("ERROR: prepared stress receipt xctestrun identity is malformed")
source_bytes = read_ordinary_snapshot(source, "prepared xctestrun snapshot")
if hashlib.sha256(source_bytes).hexdigest() != expected_xctestrun_sha256:
    raise SystemExit("ERROR: prepared xctestrun snapshot differs from its preparation receipt")
document = plistlib.loads(source_bytes)
suite = document.get("CoreTests") if isinstance(document, dict) else None
if not isinstance(suite, dict):
    raise SystemExit("ERROR: xctestrun does not carry the CoreTests bundle")
injected = {
    "MACSCOPE_RECONSTRUCTION_STRESS_LEDGER": str(ledger),
    "MACSCOPE_RECONSTRUCTION_STRESS_PLAN": str(plan),
}
for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    environment = suite.get(field)
    if not isinstance(environment, dict):
        raise SystemExit(f"ERROR: CoreTests {field} is not an environment dictionary")
    conflicts = sorted(set(environment).intersection(injected))
    if conflicts:
        raise SystemExit(
            f"ERROR: CoreTests {field} already defines governed stress variables: {conflicts}"
        )
    environment.update(injected)
with output.open("wb") as stream:
    plistlib.dump(document, stream, sort_keys=True)
PY
/bin/cp -p "$execution_xctestrun" "$execution_xctestrun_evidence"
[[ -f "$execution_xctestrun_evidence" && ! -L "$execution_xctestrun_evidence" ]] || \
    fail 'stress xctestrun evidence was not published safely'
started_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')

set +e
/usr/bin/xcrun xcodebuild test-without-building \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 1800 \
    -maximum-test-execution-time-allowance 1800 \
    -xctestrun "$execution_xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$TEST_SELECTOR" \
    -parallel-testing-enabled NO
xcode_exit=$?
set -e
/bin/rm -f "$execution_xctestrun"
execution_xctestrun=
trap - EXIT
ended_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')

# Revalidate the exact source product after execution.  The copied receipt and
# xctestrun snapshot below establish its immutable identity for later receipt
# compilation, while this postflight closes the live product interval.
/usr/bin/python3 -B "$preparation_validator" validate \
    --receipt "$preparation_receipt" \
    --xctestrun "$xctestrun" \
    --candidate-app "$candidate_app" \
    --candidate-identity "$candidate_identity"

plan_sha256_after=$(/usr/bin/shasum -a 256 "$plan_path" | /usr/bin/awk '{print $1}')
[[ "$plan_sha256_before" == "$plan_sha256_after" ]] || \
    fail 'stress plan changed while the test was executing'

if [[ -d "$result_bundle" && ! -L "$result_bundle" ]]; then
    /usr/bin/xcrun xcresulttool get test-results tests \
        --path "$result_bundle" \
        --compact >"$results_path"
else
    printf '{"testNodes":[]}\n' >"$results_path"
fi

/usr/bin/python3 -B - \
    "$repository_root" "$plan_path" "$ledger_path" "$results_path" "$report_path" "$TEST_SELECTOR" \
    "$started_at_unix_ms" "$ended_at_unix_ms" "$xcode_exit" \
    "$qualification_run_id" "$qualification_run_nonce" \
    "$predecessor_observations_sha256" <<'PY'
import json
from pathlib import Path
import sys

repository_root = Path(sys.argv[1])
sys.path.insert(0, str(repository_root))
from Scripts.reconstruction.run_authority_stress import (  # noqa: E402
    StressHarnessError,
    validate_python_results,
    validate_swift_attempt_ledger,
)

plan_path, ledger_path, results_path, report_path = map(Path, sys.argv[2:6])
selector = sys.argv[6]
started, ended, exit_code = map(int, sys.argv[7:10])
qualification_run_id, qualification_run_nonce = sys.argv[10:12]
predecessor_observations_sha256 = sys.argv[12]
plan = json.loads(plan_path.read_text(encoding="utf-8"))
invocations = plan["invocations"]
python_results = plan.get("python_results", [])
try:
    python_attempts = validate_python_results(plan, python_results)
except (ValueError, StressHarnessError) as error:
    raise SystemExit(f"ERROR: invalid Python stress results: {error}")
passed = exit_code == 0
swift_attempts = []

if passed:
    if not ledger_path.is_file() or ledger_path.is_symlink():
        raise SystemExit("ERROR: exact Swift stress attempt ledger is missing")
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        swift_attempts = validate_swift_attempt_ledger(plan, ledger)
    except (OSError, ValueError, StressHarnessError) as error:
        raise SystemExit(f"ERROR: invalid Swift stress attempt ledger: {error}")
    document = json.loads(results_path.read_text(encoding="utf-8"))
    target, suite, method = selector.split("/", 2)
    matches = []
    def visit(node, ancestors):
        if not isinstance(node, dict):
            raise SystemExit("ERROR: malformed xcresult test node")
        name = node.get("name")
        node_type = node.get("nodeType")
        if not isinstance(name, str) or not isinstance(node_type, str):
            raise SystemExit("ERROR: unidentifiable xcresult test node")
        lineage = ancestors + [name, str(node.get("nodeIdentifier", ""))]
        joined = "/".join(lineage)
        if node_type == "Test Case" and suite in joined and target in joined and (
            name in {method, f"{method}()", f"{suite}.{method}", f"{suite}/{method}"}
            or selector in joined
        ):
            matches.append(node)
        children = node.get("children", [])
        if not isinstance(children, list):
            raise SystemExit("ERROR: malformed xcresult children")
        for child in children:
            visit(child, lineage)
    for root in document.get("testNodes", []):
        visit(root, [])
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected one exact stress test case, found {len(matches)}")
    statuses = []
    skips = []
    def collect(node):
        if node.get("nodeType") in {"Test Case", "Test Case Run"} and isinstance(node.get("result"), str):
            statuses.append(node["result"])
        if node.get("nodeType") == "Skip Message":
            skips.append(node.get("name", "skip"))
        for child in node.get("children", []):
            collect(child)
    collect(matches[0])
    passed = bool(statuses) and not skips and all(item == "Passed" for item in statuses)

observed = len(swift_attempts) + len(python_attempts) if passed else len(python_attempts)
report = {
    "ended_at_unix_ms": ended,
    "exit_code": 0 if passed else (exit_code or 1),
    "result": "passed" if passed else "failed",
    "schema_version": 2,
    "qualification_run": {
        "run_id": qualification_run_id,
        "nonce": qualification_run_nonce,
    },
    "predecessor_observations_sha256": predecessor_observations_sha256,
    "started_at_unix_ms": started,
    "stress": {
        "attempt_seeds": [item["seed"] for item in invocations],
        "expected_attempt_count": len(invocations),
        "failed_count": 0 if passed else 1,
        "observed_attempt_count": observed,
    },
}
report_path.write_text(json.dumps(report, sort_keys=True, separators=(",", ":")), encoding="utf-8")
if not passed:
    raise SystemExit("ERROR: authority stress execution did not pass exactly")
PY

printf '%s\n' \
    "MACSCOPE_AUTHORITY_STRESS_PLAN=$plan_path" \
    "MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER=$ledger_path" \
    "MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS=$results_path" \
    "MACSCOPE_AUTHORITY_STRESS_REPORT=$report_path" \
    "MACSCOPE_AUTHORITY_STRESS_XCTESTRUN=$execution_xctestrun_evidence" \
    "MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT=$preparation_receipt_evidence" \
    "MACSCOPE_AUTHORITY_STRESS_PREPARED_XCTESTRUN=$prepared_xctestrun_evidence" \
    '==> Reconstruction authority stress catalog passed.'
