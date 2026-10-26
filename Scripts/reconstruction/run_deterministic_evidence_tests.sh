#!/bin/bash

set -euo pipefail

readonly TEST_SELECTOR='CoreTests/ReconstructionDeterministicEvidenceEmitterTests/testEmitsCanonicalDeterministicEvidenceArtifacts'

usage() {
    printf '%s\n' \
        'usage: run_deterministic_evidence_tests.sh --candidate-identity ABSOLUTE_PATH' \
        '       --preparation-receipt ABSOLUTE_PATH --xctestrun ABSOLUTE_PATH' \
        '       --candidate-app ABSOLUTE_PATH' \
        '       --result-bundle-root ABSOLUTE_PATH --artifact-root ABSOLUTE_PATH' \
        '       --qualification-run-id STABLE_ID --qualification-run-nonce SHA256' \
        '       --predecessor-observations-sha256 SHA256'
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
result_bundle_root=
artifact_root=
qualification_run_id=
qualification_run_nonce=
predecessor_observations_sha256=

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --result-bundle-root)
            [[ $# -ge 2 ]] || fail_usage '--result-bundle-root requires a value'
            result_bundle_root=$2
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

for value in candidate_identity preparation_receipt xctestrun candidate_app result_bundle_root \
    artifact_root qualification_run_id qualification_run_nonce \
    predecessor_observations_sha256; do
    [[ -n "${!value}" ]] || fail_usage "--${value//_/-} is required"
done
[[ "$qualification_run_id" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || \
    fail_usage '--qualification-run-id must be a canonical stable ID'
[[ "$qualification_run_nonce" =~ ^[0-9a-f]{64}$ ]] || \
    fail_usage '--qualification-run-nonce must be a lowercase SHA-256'
[[ "$predecessor_observations_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    fail_usage '--predecessor-observations-sha256 must be a lowercase SHA-256'
for value in candidate_identity preparation_receipt xctestrun candidate_app result_bundle_root artifact_root; do
    [[ "${!value}" == /* ]] || fail_usage "--${value//_/-} must be absolute"
done
[[ -f "$candidate_identity" && ! -L "$candidate_identity" ]] || \
    fail 'candidate identity must be a non-symlink regular file'
[[ -f "$preparation_receipt" && ! -L "$preparation_receipt" ]] || \
    fail 'preparation receipt must be a non-symlink regular file'
[[ -f "$xctestrun" && ! -L "$xctestrun" ]] || \
    fail 'xctestrun must be a non-symlink regular file'
[[ -d "$candidate_app" && ! -L "$candidate_app" && "$candidate_app" == *.app ]] || \
    fail 'candidate app must be a non-symlink .app directory'
for path in "$result_bundle_root" "$artifact_root"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "refusing to overwrite output root: $path"
    [[ -d "$(dirname "$path")" ]] || fail "output parent directory does not exist: $path"
done
[[ "$result_bundle_root" != "$artifact_root" ]] || fail 'output roots must be distinct'

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_dir/../.." && pwd -P)
qualification_validator="$repository_root/Scripts/reconstruction/validate_qualification_product_identity.py"
preparation_validator="$repository_root/Scripts/reconstruction/native_live_preparation_receipt.py"
artifact_comparator="$repository_root/Scripts/reconstruction/deterministic_evidence_artifacts.py"
execution_reporter="$repository_root/Scripts/reconstruction/write_execution_report.py"
for helper in "$qualification_validator" "$preparation_validator" "$artifact_comparator" "$execution_reporter"; do
    [[ -f "$helper" && ! -L "$helper" ]] || fail "qualification helper is unavailable: $helper"
done
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
    fail 'deterministic evidence qualification must use the Debug test product'

/usr/bin/python3 -B "$preparation_validator" validate \
    --receipt "$preparation_receipt" \
    --xctestrun "$xctestrun" \
    --candidate-app "$candidate_app" \
    --candidate-identity "$candidate_identity"

/usr/bin/python3 -B "$qualification_validator" \
    --candidate-identity "$candidate_identity" \
    --app-bundle "$candidate_app" \
    --product native-live-app

/bin/mkdir "$result_bundle_root" "$artifact_root"
result_bundle_root=$(cd "$result_bundle_root" && pwd -P)
artifact_root=$(cd "$artifact_root" && pwd -P)
first_root="$artifact_root/fresh-process-1"
second_root="$artifact_root/fresh-process-2"
/bin/mkdir "$first_root" "$second_root"
first_bundle="$result_bundle_root/fresh-process-1.xcresult"
second_bundle="$result_bundle_root/fresh-process-2.xcresult"
first_results="$artifact_root/fresh-process-1.test-results.json"
second_results="$artifact_root/fresh-process-2.test-results.json"
first_xctestrun="$artifact_root/fresh-process-1.xctestrun"
second_xctestrun="$artifact_root/fresh-process-2.xctestrun"
comparison="$artifact_root/DeterministicEvidence.comparison.json"
execution_report="$artifact_root/DeterministicEvidence.execution-report.json"

/usr/bin/python3 -B "$artifact_comparator" prepare-xctestrun --source "$xctestrun" --output "$first_xctestrun" --artifact-root "$first_root"
/usr/bin/python3 -B "$artifact_comparator" prepare-xctestrun --source "$xctestrun" --output "$second_xctestrun" --artifact-root "$second_root"

started_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')
set +e
/usr/bin/xcrun xcodebuild test-without-building \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    -maximum-test-execution-time-allowance 300 \
    -xctestrun "$first_xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$first_bundle" \
    -only-testing:"$TEST_SELECTOR" \
    -parallel-testing-enabled NO
first_exit=$?
/usr/bin/xcrun xcodebuild test-without-building \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    -maximum-test-execution-time-allowance 300 \
    -xctestrun "$second_xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$second_bundle" \
    -only-testing:"$TEST_SELECTOR" \
    -parallel-testing-enabled NO
second_exit=$?
set -e

extract_results() {
    local bundle=$1
    local output=$2
    if [[ -d "$bundle" && ! -L "$bundle" ]]; then
        /usr/bin/xcrun xcresulttool get test-results tests \
            --path "$bundle" --compact >"$output"
    else
        printf '{"testNodes":[]}\n' >"$output"
        return 1
    fi
}

validate_results() {
    /usr/bin/python3 -B - "$1" "$TEST_SELECTOR" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
selector = sys.argv[2]
try:
    document = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, ValueError) as error:
    raise SystemExit(f"ERROR: test results cannot be decoded: {error}")
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
    raise SystemExit(f"ERROR: expected one exact deterministic evidence test, found {len(matches)}")
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
if not statuses or skips or any(status != "Passed" for status in statuses):
    raise SystemExit("ERROR: deterministic evidence test did not pass exactly without skips")
PY
}

verification_exit=0
set +e
extract_results "$first_bundle" "$first_results"
first_extract=$?
extract_results "$second_bundle" "$second_results"
second_extract=$?
if [[ "$first_extract" -eq 0 ]]; then
    validate_results "$first_results"
    first_verify=$?
else
    first_verify=$first_extract
fi
if [[ "$second_extract" -eq 0 ]]; then
    validate_results "$second_results"
    second_verify=$?
else
    second_verify=$second_extract
fi
if [[ "$first_exit" -ne 0 || "$second_exit" -ne 0 \
      || "$first_verify" -ne 0 || "$second_verify" -ne 0 ]]; then
    verification_exit=1
else
    /usr/bin/python3 -B "$artifact_comparator" compare \
        --candidate-identity "$candidate_identity" \
        --first-root "$first_root" \
        --second-root "$second_root" \
        --output "$comparison"
    verification_exit=$?
fi
set -e
ended_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')

if [[ "$verification_exit" -eq 0 ]]; then
    execution_result=passed
    execution_exit=0
else
    execution_result=failed
    execution_exit=1
fi
/usr/bin/python3 -B "$execution_reporter" \
    --output "$execution_report" \
    --qualification-run-id "$qualification_run_id" \
    --qualification-run-nonce "$qualification_run_nonce" \
    --predecessor-observations-sha256 "$predecessor_observations_sha256" \
    --started-at-unix-ms "$started_at_unix_ms" \
    --ended-at-unix-ms "$ended_at_unix_ms" \
    --result "$execution_result" \
    --exit-code "$execution_exit"

if [[ "$execution_exit" -eq 0 ]]; then
    printf '%s\n' \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT=$first_root/checkpoint.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT_TWO=$second_root/checkpoint.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_COMPARISON=$comparison" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS=$first_root/corpus-manifest.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS_TWO=$second_root/corpus-manifest.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_EXECUTION_REPORT=$execution_report" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER=$first_root/evidence-frontier.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER_TWO=$second_root/evidence-frontier.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT=$first_root/tool-receipt.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT_TWO=$second_root/tool-receipt.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET=$first_root/retrieval-packet.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET_TWO=$second_root/retrieval-packet.json" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_ONE=$first_results" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_TWO=$second_results"
else
    printf '%s\n' \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_ONE=$first_results" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_TWO=$second_results" \
        "MACSCOPE_DETERMINISTIC_EVIDENCE_EXECUTION_REPORT=$execution_report"
fi
[[ "$execution_exit" -eq 0 ]] || fail 'deterministic evidence execution failed'
printf '%s\n' '==> Deterministic Reconstruction artifacts were byte-identical across two fresh processes.'
