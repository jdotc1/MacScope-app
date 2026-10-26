#!/bin/bash

set -euo pipefail

readonly DEFAULT_TEST_SELECTOR='CoreTests/Phase2LiveAIAgentXPCProductionGateTests/testSignedWorkerCompletesReconstructionRoundThenFinalSynthesisExactlyOnce'
readonly R2_TEST_SELECTOR='CoreTests/Phase2LiveAIAgentXPCProductionGateTests/testSignedR2WorkerDispatchesReadableObjectiveAndEvidenceThenAcceptsExactSemantics'

usage() {
    printf '%s\n' \
        'usage: run_signed_reconstruction_worker_tests.sh \' \
        '       --candidate-identity ABSOLUTE_PATH \' \
        '       --preparation-receipt ABSOLUTE_PATH \' \
        '       --xctestrun ABSOLUTE_PATH --candidate-app ABSOLUTE_PATH \' \
        '       --result-bundle-path ABSOLUTE_PATH --artifact-root ABSOLUTE_PATH \' \
        '       --qualification-run-id STABLE_ID \' \
        '       --qualification-run-nonce SHA256 \' \
        '       --predecessor-observations-sha256 SHA256 \' \
        '       [--test-selector ALLOWLISTED_SELECTOR]' \
        '       run_signed_reconstruction_worker_tests.sh \' \
        '       --verify-test-results-json ABSOLUTE_PATH \' \
        '       [--test-selector ALLOWLISTED_SELECTOR]' \
        "       R1 (default): $DEFAULT_TEST_SELECTOR" \
        "       R2: $R2_TEST_SELECTOR"
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
test_results_json=
qualification_run_id=
qualification_run_nonce=
predecessor_observations_sha256=
test_selector=$DEFAULT_TEST_SELECTOR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-selector)
            [[ $# -ge 2 ]] || fail_usage '--test-selector requires a value'
            test_selector=$2
            shift 2
            ;;
        --candidate-identity)
            [[ $# -ge 2 ]] || fail_usage '--candidate-identity requires a value'
            candidate_identity=$2
            shift 2
            ;;
        --preparation-receipt)
            [[ $# -ge 2 ]] || fail_usage '--preparation-receipt requires a value'
            preparation_receipt=$2
            shift 2
            ;;
        --xctestrun)
            [[ $# -ge 2 ]] || fail_usage '--xctestrun requires a value'
            xctestrun=$2
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
        --verify-test-results-json)
            [[ $# -ge 2 ]] || fail_usage '--verify-test-results-json requires a value'
            test_results_json=$2
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
        --predecessor-observations-sha256)
            [[ $# -ge 2 ]] || fail_usage '--predecessor-observations-sha256 requires a value'
            predecessor_observations_sha256=$2
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

case "$test_selector" in
    "$DEFAULT_TEST_SELECTOR"|"$R2_TEST_SELECTOR") ;;
    *) fail_usage '--test-selector must name an allowlisted exact signed reconstruction test' ;;
esac
readonly TEST_SELECTOR=$test_selector

verify_test_results_json() {
    local results_path=$1
    /usr/bin/python3 -B - "$results_path" "$TEST_SELECTOR" <<'PY'
import json
from pathlib import Path
import sys


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


path = Path(sys.argv[1])
selector = sys.argv[2]
try:
    document = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read xcresult test-results JSON: {error}")

target, suite, method = selector.split("/", 2)
matches = []


def visit(node, ancestors):
    if not isinstance(node, dict):
        fail("xcresult test-results JSON contains a non-object test node")
    node_type = node.get("nodeType")
    name = node.get("name")
    identifier = node.get("nodeIdentifier")
    if not isinstance(node_type, str) or not isinstance(name, str):
        fail("xcresult test-results JSON contains an unidentifiable test node")
    texts = [name]
    if isinstance(identifier, str):
        texts.append(identifier)
    lineage = ancestors + texts
    joined = "/".join(lineage)
    method_names = {method, f"{method}()", f"{suite}.{method}", f"{suite}/{method}"}
    if (
        node_type == "Test Case"
        and (name in method_names or selector in joined)
        and suite in joined
        and target in joined
    ):
        matches.append(node)
    children = node.get("children", [])
    if not isinstance(children, list):
        fail("xcresult test-results JSON contains a malformed children field")
    for child in children:
        visit(child, lineage)


roots = document.get("testNodes") if isinstance(document, dict) else None
if not isinstance(roots, list):
    fail("xcresult test-results JSON lacks a testNodes array")
for root in roots:
    visit(root, [])
if len(matches) != 1:
    fail(f"expected exactly one recorded exact selected test case, found {len(matches)}")

results = []
skip_messages = []


def collect(node):
    node_type = node.get("nodeType")
    result = node.get("result")
    if node_type in ("Test Case", "Test Case Run") and isinstance(result, str):
        results.append(result)
    if node_type == "Skip Message":
        skip_messages.append(node.get("name", "skip"))
    for child in node.get("children", []):
        collect(child)


collect(matches[0])
if skip_messages:
    fail("the exact selected reconstruction test recorded a skip message")
if not results:
    fail("the exact selected reconstruction test has no executed result")
if any(result != "Passed" for result in results):
    fail(f"the exact selected reconstruction test was not exclusively passed: {results}")
print(f"verified exact executed test: {selector} (results={','.join(results)})")
PY
}

if [[ -n "$test_results_json" ]]; then
    [[ -z "$candidate_identity" && -z "$preparation_receipt" \
        && -z "$xctestrun" && -z "$candidate_app" \
        && -z "$result_bundle" && -z "$artifact_root" \
        && -z "$qualification_run_id" && -z "$qualification_run_nonce" \
        && -z "$predecessor_observations_sha256" ]] || \
        fail_usage '--verify-test-results-json cannot be combined with live-run arguments'
    [[ "$test_results_json" == /* ]] || \
        fail_usage '--verify-test-results-json must be absolute'
    [[ -f "$test_results_json" && ! -L "$test_results_json" ]] || \
        fail 'test-results JSON is unavailable or unsafe'
    verify_test_results_json "$test_results_json"
    exit 0
fi

[[ -n "$candidate_identity" ]] || fail_usage '--candidate-identity is required'
[[ -n "$preparation_receipt" ]] || fail_usage '--preparation-receipt is required'
[[ -n "$xctestrun" ]] || fail_usage '--xctestrun is required'
[[ -n "$candidate_app" ]] || fail_usage '--candidate-app is required'
[[ -n "$result_bundle" ]] || fail_usage '--result-bundle-path is required'
[[ -n "$artifact_root" ]] || fail_usage '--artifact-root is required'
[[ -n "$qualification_run_id" ]] || fail_usage '--qualification-run-id is required'
[[ -n "$qualification_run_nonce" ]] || fail_usage '--qualification-run-nonce is required'
[[ -n "$predecessor_observations_sha256" ]] || \
    fail_usage '--predecessor-observations-sha256 is required'
[[ "$qualification_run_id" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || \
    fail_usage '--qualification-run-id must be a canonical stable ID'
[[ "$qualification_run_nonce" =~ ^[0-9a-f]{64}$ ]] || \
    fail_usage '--qualification-run-nonce must be a lowercase SHA-256'
[[ "$predecessor_observations_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    fail_usage '--predecessor-observations-sha256 must be a lowercase SHA-256'
for path in "$candidate_identity" "$preparation_receipt" "$xctestrun" "$candidate_app" "$result_bundle" "$artifact_root"; do
    [[ "$path" == /* ]] || fail_usage 'all live-run paths must be absolute'
done
[[ -f "$candidate_identity" && ! -L "$candidate_identity" ]] || \
    fail 'candidate identity must be a non-symlink regular file'
[[ -f "$preparation_receipt" && ! -L "$preparation_receipt" ]] || \
    fail 'preparation receipt must be a non-symlink regular file'
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
signing_guard="$repository_root/Scripts/check_local_signing_policy.py"
qualification_validator="$repository_root/Scripts/reconstruction/validate_qualification_product_identity.py"
execution_reporter="$repository_root/Scripts/reconstruction/write_execution_report.py"
preparation_validator="$repository_root/Scripts/reconstruction/native_live_preparation_receipt.py"

# This test-without-building gate deliberately consumes a previously sealed test product. It
# must not regenerate the project or invoke the native/SLEIGH build phases merely to exercise
# the independently embedded, signed reconstruction AI worker.
source "$repository_root/Scripts/xcode27_env.sh"

candidate_identity=$(cd "$(dirname "$candidate_identity")" && pwd -P)/$(basename "$candidate_identity")
preparation_receipt=$(cd "$(dirname "$preparation_receipt")" && pwd -P)/$(basename "$preparation_receipt")
xctestrun=$(cd "$(dirname "$xctestrun")" && pwd -P)/$(basename "$xctestrun")
candidate_app=$(cd "$(dirname "$candidate_app")" && pwd -P)/$(basename "$candidate_app")
products_root=$(cd "$(dirname "$xctestrun")" && pwd -P)
candidate_products_root=$(cd "$(dirname "$candidate_app")/.." && pwd -P)
[[ "$products_root" == "$candidate_products_root" ]] || \
    fail 'candidate app and xctestrun must share the exact Build/Products root'
[[ "$(basename "$(dirname "$candidate_app")")" == Debug ]] || \
    fail 'the signed reconstruction selector must use the Debug test product'

candidate_executable="$candidate_app/Contents/MacOS/MacScope"
worker_executable="$candidate_app/Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
for executable in "$candidate_executable" "$worker_executable"; do
    [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || \
        fail "required signed executable is unavailable or unsafe: $executable"
done

[[ -f "$signing_guard" ]] || fail 'local signing-policy guard is unavailable'
[[ -f "$qualification_validator" ]] || \
    fail 'qualification product identity validator is unavailable'
[[ -f "$execution_reporter" ]] || fail 'execution report emitter is unavailable'
[[ -f "$preparation_validator" ]] || fail 'preparation receipt validator is unavailable'
/usr/bin/python3 -B "$preparation_validator" validate \
    --receipt "$preparation_receipt" \
    --xctestrun "$xctestrun" \
    --candidate-app "$candidate_app" \
    --candidate-identity "$candidate_identity"
/usr/bin/python3 -B "$qualification_validator" \
    --candidate-identity "$candidate_identity" \
    --app-bundle "$candidate_app" \
    --product app \
    --product ai-agent-worker
/usr/bin/python3 -B "$signing_guard" \
    --app-bundle "$candidate_app" \
    --configuration Debug \
    --xcode-test-host-entitlements

# Publish nothing until the sealed test product and its signing policy have been
# accepted.  A rejected candidate must not leave behind an apparently valid
# evidence root.
/bin/mkdir "$artifact_root"
artifact_root=$(cd "$artifact_root" && pwd -P)

test_results_path="$artifact_root/SignedReconstructionWorker.test-results.json"
worker_artifact_path="$artifact_root/AIAgentWorkerXPCService"
execution_report_path="$artifact_root/SignedReconstructionWorker.execution-report.json"

printf '%s\n' \
    '==> Running the signed reconstruction AI-worker parity selector without rebuilding' \
    "    selector: $TEST_SELECTOR" \
    "    xctestrun: $xctestrun" \
    "    candidate: $candidate_app" \
    "    result bundle: $result_bundle"

started_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')
set +e
/usr/bin/xcrun xcodebuild test-without-building \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 120 \
    -xctestrun "$xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$TEST_SELECTOR" \
    -parallel-testing-enabled NO
xcode_exit=$?
set -e

verification_exit=1
if [[ -d "$result_bundle" && ! -L "$result_bundle" ]]; then
    set +e
    /usr/bin/xcrun xcresulttool get test-results tests \
        --path "$result_bundle" \
        --compact >"$test_results_path"
    extraction_exit=$?
    if [[ "$extraction_exit" -eq 0 ]]; then
        verify_test_results_json "$test_results_path"
        verification_exit=$?
    else
        verification_exit=$extraction_exit
    fi
    set -e
else
    printf '{"testNodes":[]}\n' >"$test_results_path"
fi
ended_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')
/bin/cp -p "$worker_executable" "$worker_artifact_path"
[[ -f "$worker_artifact_path" && ! -L "$worker_artifact_path" ]] || \
    fail 'signed worker evidence artifact was not published safely'

execution_exit=$xcode_exit
if [[ "$execution_exit" -eq 0 && "$verification_exit" -ne 0 ]]; then
    execution_exit=$verification_exit
fi
if [[ "$execution_exit" -eq 0 ]]; then
    execution_result=passed
else
    execution_result=failed
fi
/usr/bin/python3 -B "$execution_reporter" \
    --output "$execution_report_path" \
    --qualification-run-id "$qualification_run_id" \
    --qualification-run-nonce "$qualification_run_nonce" \
    --predecessor-observations-sha256 "$predecessor_observations_sha256" \
    --started-at-unix-ms "$started_at_unix_ms" \
    --ended-at-unix-ms "$ended_at_unix_ms" \
    --result "$execution_result" \
    --exit-code "$execution_exit"

printf '%s\n' \
    "MACSCOPE_SIGNED_RECONSTRUCTION_TEST_RESULTS=$test_results_path" \
    "MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTABLE=$worker_artifact_path" \
    "MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTION_REPORT=$execution_report_path"
[[ "$execution_exit" -eq 0 ]] || fail 'signed reconstruction AI-worker execution failed'
printf '%s\n' '==> Signed reconstruction AI-worker parity selector passed.'
