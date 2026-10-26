#!/bin/bash

set -euo pipefail

readonly DEFAULT_TEST_SELECTOR='CoreTests/NativeDecompilerLiveXPCTests/testSignedServiceHonorsSupervisionAndRelaunchContract'
readonly LIVE_TEST_CONDITION='MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING'

usage() {
    printf '%s\n' \
        'usage: run_live_xpc_tests.sh --prepare-derived-data ABSENT_ABSOLUTE_PATH \' \
        '       --preparation-receipt ABSENT_ABSOLUTE_PATH \' \
        '       --materialization-root ABSOLUTE_PATH' \
        '       run_live_xpc_tests.sh --execute-prepared \' \
        '       --preparation-receipt ABSOLUTE_PATH --xctestrun ABSOLUTE_PATH \' \
        '       --candidate-app ABSOLUTE_PATH --candidate-identity ABSOLUTE_PATH \' \
        '       --result-bundle-path ABSENT_ABSOLUTE_PATH \' \
        '       --artifact-root ABSENT_ABSOLUTE_PATH \' \
        '       --qualification-run-id STABLE_ID \' \
        '       --qualification-run-nonce SHA256 \' \
        '       --predecessor-observations-sha256 SHA256 \' \
        '       [--only-testing TARGET/SUITE/METHOD]' \
        '       run_live_xpc_tests.sh --verify-test-results-json ABSOLUTE_PATH \' \
        '       [--only-testing TARGET/SUITE/METHOD]' \
        '       run_live_xpc_tests.sh --self-test-owned-cleanup'
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

canonical_path() {
    local path=$1
    local kind=$2
    local maximum_bytes=${3:-0}
    /usr/bin/python3 -B - "$path" "$kind" "$maximum_bytes" <<'PY'
import os
import stat
import sys


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


raw = sys.argv[1]
kind = sys.argv[2]
maximum_bytes = int(sys.argv[3])
if not raw.startswith("/") or not os.path.basename(raw) or any(
    character in raw for character in ("\x00", "\n", "\r")
):
    fail("path must be an absolute canonical leaf without control characters")
parent_raw = os.path.dirname(raw)
try:
    parent = os.path.realpath(parent_raw)
    parent_metadata = os.lstat(parent)
except OSError as error:
    fail(f"path parent is unavailable: {error}")
canonical = os.path.join(parent, os.path.basename(raw))
allowed_alias = False
if sys.platform == "darwin":
    for alias in ("/etc", "/tmp", "/var"):
        if raw == alias or raw.startswith(f"{alias}/"):
            allowed_alias = canonical == f"/private{raw}"
            break
if raw != canonical and not allowed_alias:
    fail("path must be canonical and traverse no symbolic links")
if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
    fail("path parent must be an ordinary non-symlink directory")
parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
parent_descriptor = os.open(parent, parent_flags)
try:
    opened_parent = os.fstat(parent_descriptor)
    if (opened_parent.st_dev, opened_parent.st_ino) != (
        parent_metadata.st_dev,
        parent_metadata.st_ino,
    ):
        fail("path parent changed before validation")
    name = os.path.basename(raw)
    try:
        metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        if kind != "absent":
            fail("required path is unavailable")
    else:
        if kind == "absent":
            fail("output path must be absent")
        if kind == "file":
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_nlink != 1
                or metadata.st_size < 0
                or metadata.st_size > maximum_bytes
            ):
                fail("input must be a bounded, singly linked ordinary file")
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        elif kind == "directory":
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                fail("input must be an ordinary non-symlink directory")
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        else:
            fail("unsupported path validation kind")
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        try:
            observed = os.fstat(descriptor)
            if (observed.st_dev, observed.st_ino) != (metadata.st_dev, metadata.st_ino):
                fail("path changed before descriptor validation")
        finally:
            os.close(descriptor)
finally:
    os.close(parent_descriptor)
print(canonical)
PY
}

require_disjoint_execution_paths() {
    /usr/bin/python3 -B - "$@" <<'PY'
from pathlib import Path
import sys

paths = [Path(value) for value in sys.argv[1:]]
for index, path in enumerate(paths):
    for other in paths[index + 1:]:
        if path == other or path in other.parents or other in path.parents:
            raise SystemExit(
                f"ERROR: execution authority and output paths overlap: {path} and {other}"
            )
PY
}

publish_regular_copy() {
    local source=$1
    local destination=$2
    /usr/bin/python3 -B - "$source" "$destination" <<'PY'
import hashlib
import os
import stat
import sys


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


source = sys.argv[1]
destination = sys.argv[2]
destination_parent = os.path.dirname(destination)
if destination != os.path.join(os.path.realpath(destination_parent), os.path.basename(destination)):
    fail("copy destination is not canonical")
source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
source_descriptor = os.open(source, source_flags)
parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
parent_descriptor = os.open(destination_parent, parent_flags)
temporary_name = f".{os.path.basename(destination)}.tmp.{os.getpid()}.{os.urandom(16).hex()}"
temporary_descriptor = -1
linked = False
succeeded = False
published_identity = None
try:
    before = os.fstat(source_descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        fail("copy source is not a singly linked ordinary file")
    try:
        os.stat(os.path.basename(destination), dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        fail("copy destination appeared before publication")
    temporary_descriptor = os.open(
        temporary_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        stat.S_IMODE(before.st_mode),
        dir_fd=parent_descriptor,
    )
    source_digest = hashlib.sha256()
    byte_count = 0
    while True:
        block = os.read(source_descriptor, 1024 * 1024)
        if not block:
            break
        source_digest.update(block)
        byte_count += len(block)
        offset = 0
        while offset < len(block):
            written = os.write(temporary_descriptor, block[offset:])
            if written <= 0:
                fail("copy write made no progress")
            offset += written
    os.fsync(temporary_descriptor)
    after = os.fstat(source_descriptor)
    temporary = os.fstat(temporary_descriptor)
    stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable):
        fail("copy source changed while read")
    if temporary.st_size != byte_count or byte_count != before.st_size:
        fail("copy byte count differs from its source")
    os.link(
        temporary_name,
        os.path.basename(destination),
        src_dir_fd=parent_descriptor,
        dst_dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    linked = True
    published_identity = (temporary.st_dev, temporary.st_ino)
    os.unlink(temporary_name, dir_fd=parent_descriptor)
    temporary_name = ""
    final = os.stat(os.path.basename(destination), dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        not stat.S_ISREG(final.st_mode)
        or final.st_nlink != 1
        or final.st_size != before.st_size
    ):
        fail("copy publication identity is invalid")
    os.fsync(parent_descriptor)
    succeeded = True
finally:
    if temporary_descriptor >= 0:
        os.close(temporary_descriptor)
    os.close(source_descriptor)
    if temporary_name:
        try:
            os.unlink(temporary_name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass
    if linked and not succeeded and published_identity is not None:
        try:
            published = os.stat(
                os.path.basename(destination),
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            if (published.st_dev, published.st_ino) == published_identity:
                os.unlink(os.path.basename(destination), dir_fd=parent_descriptor)
    os.close(parent_descriptor)
PY
}

materialization_root=
test_results_json=
candidate_identity=
prepare_derived_data=
execute_prepared=false
preparation_receipt=
xctestrun=
candidate_app=
result_bundle=
artifact_root=
qualification_run_id=
qualification_run_nonce=
predecessor_observations_sha256=
self_test_owned_cleanup=false
only_testing_supplied=false
test_selector=$DEFAULT_TEST_SELECTOR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --materialization-root)
            [[ $# -ge 2 ]] || fail_usage '--materialization-root requires a value'
            materialization_root=$2
            shift 2
            ;;
        --ghostty-source-dir)
            # Retired: Xcode builds Ghostty VT from the repository-owned source
            # into the prepared DerivedData, and Scripts/build_ghostty_vt.sh
            # rejects external source authority outside its test-only gate.
            fail_usage '--ghostty-source-dir is retired; preparation verifies the Xcode-owned Ghostty VT build root'
            ;;
        --prepare-derived-data)
            [[ $# -ge 2 ]] || fail_usage '--prepare-derived-data requires a value'
            prepare_derived_data=$2
            shift 2
            ;;
        --execute-prepared)
            execute_prepared=true
            shift
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
        --candidate-identity)
            [[ $# -ge 2 ]] || fail_usage '--candidate-identity requires a value'
            candidate_identity=$2
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
        --predecessor-observations-sha256)
            [[ $# -ge 2 ]] || fail_usage '--predecessor-observations-sha256 requires a value'
            predecessor_observations_sha256=$2
            shift 2
            ;;
        --only-testing)
            [[ $# -ge 2 ]] || fail_usage '--only-testing requires a value'
            test_selector=$2
            only_testing_supplied=true
            shift 2
            ;;
        --verify-test-results-json)
            [[ $# -ge 2 ]] || fail_usage '--verify-test-results-json requires a value'
            test_results_json=$2
            shift 2
            ;;
        --self-test-owned-cleanup)
            self_test_owned_cleanup=true
            shift
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
    CoreTests/NativeDecompilerLiveXPCTests/testSignedServiceHonorsSupervisionAndRelaunchContract|\
    CoreTests/NativeDecompilerLiveXPCTests/testSignedProviderPreservesAuthoredSnapshotCalleeAndReadonlyDataContext|\
    CoreTests/NativeDecompilerLiveXPCTests/testSignedProviderTokenAndSourceScalarsProjectForCompleteAndTruncatedDocuments|\
    CoreTests/NativeDecompilerLiveXPCTests/testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation)
        ;;
    *)
        fail_usage '--only-testing must name one governed exact native live-XPC vector'
        ;;
esac

verify_test_results_json() {
    local results_path=$1
    /usr/bin/python3 -B - "$results_path" "$test_selector" <<'PY'
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
parts = selector.split("/")
if len(parts) != 3 or any(not part for part in parts):
    fail("selected test must have TARGET/SUITE/METHOD form")
target, suite, method = parts
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
    fail("the exact selected test recorded a skip message")
if not results:
    fail("the exact selected test has no executed result")
if any(result != "Passed" for result in results):
    fail(f"the exact selected test was not exclusively passed: {results}")
print(f"verified exact executed test: {selector} (results={','.join(results)})")
PY
}

read_owned_directory_identity() {
    local directory=$1
    /usr/bin/python3 -B - "$directory" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit("owned path is not an ordinary directory")
    print(metadata.st_dev, metadata.st_ino)
finally:
    os.close(descriptor)
PY
}

cleanup_owned_directory() {
    local directory=$1
    local expected_device=$2
    local expected_inode=$3
    /usr/bin/python3 -B - "$directory" "$expected_device" "$expected_inode" <<'PY'
import os
import stat
import sys

path = os.path.abspath(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
parent_path, name = os.path.split(path)
if not parent_path or not name or name in (".", ".."):
    raise SystemExit("refusing unsafe owned-directory path")
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
parent_fd = os.open(parent_path, flags)
root_fd = -1
try:
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise RuntimeError("owned path is no longer an ordinary directory")
    if (before.st_dev, before.st_ino) != expected:
        raise RuntimeError("owned path was substituted")
    root_fd = os.open(name, flags, dir_fd=parent_fd)
    after = os.fstat(root_fd)
    if (after.st_dev, after.st_ino) != expected:
        raise RuntimeError("owned path changed before cleanup")
    raise RuntimeError("safe atomic cleanup is unavailable; owned residue preserved")
finally:
    if root_fd >= 0:
        os.close(root_fd)
    os.close(parent_fd)
PY
}

if [[ -n "$test_results_json" ]]; then
    [[ -z "$materialization_root" \
        && -z "$candidate_identity" && -z "$prepare_derived_data" \
        && "$execute_prepared" == false && -z "$preparation_receipt" \
        && -z "$xctestrun" && -z "$candidate_app" && -z "$result_bundle" \
        && -z "$artifact_root" && -z "$qualification_run_id" \
        && -z "$qualification_run_nonce" && -z "$predecessor_observations_sha256" \
        && "$self_test_owned_cleanup" == false ]] || \
        fail_usage '--verify-test-results-json cannot be combined with runner modes'
    [[ "$test_results_json" == /* ]] || \
        fail_usage '--verify-test-results-json must be absolute'
    test_results_json=$(canonical_path "$test_results_json" file $((4 * 1024 * 1024))) || \
        fail 'test-results JSON is unavailable, oversized, linked, or unsafe'
    verify_test_results_json "$test_results_json"
    exit 0
fi

if [[ "$self_test_owned_cleanup" == true ]]; then
    [[ -z "$materialization_root" \
        && -z "$candidate_identity" && -z "$prepare_derived_data" \
        && "$execute_prepared" == false && -z "$preparation_receipt" \
        && -z "$xctestrun" && -z "$candidate_app" && -z "$result_bundle" \
        && -z "$artifact_root" && -z "$qualification_run_id" \
        && -z "$qualification_run_nonce" && -z "$predecessor_observations_sha256" \
        && "$only_testing_supplied" == false ]] || \
        fail_usage '--self-test-owned-cleanup cannot be combined with runner modes'
    self_test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macscope-owned-cleanup-test.XXXXXX")
    /usr/bin/printf '%s\n' 'owned' >"$self_test_root/original-sentinel"
    read -r original_device original_inode < <(read_owned_directory_identity "$self_test_root")
    original_path="${self_test_root}.original"
    /bin/mv -- "$self_test_root" "$original_path"
    /bin/mkdir -- "$self_test_root"
    /usr/bin/printf '%s\n' 'foreign' >"$self_test_root/replacement-sentinel"
    if cleanup_owned_directory "$self_test_root" "$original_device" "$original_inode" \
        >/dev/null 2>&1; then
        fail 'owned cleanup accepted a substituted directory'
    fi
    read -r replacement_device replacement_inode < <(read_owned_directory_identity "$self_test_root")
    if cleanup_owned_directory "$self_test_root" "$replacement_device" "$replacement_inode" \
        >/dev/null 2>&1; then
        fail 'owned cleanup claimed it could delete the replacement directory'
    fi
    if cleanup_owned_directory "$original_path" "$original_device" "$original_inode" \
        >/dev/null 2>&1; then
        fail 'owned cleanup claimed it could delete the original directory'
    fi
    [[ -f "$self_test_root/replacement-sentinel" \
        && -f "$original_path/original-sentinel" ]] || \
        fail 'owned cleanup removed preserved residue'
    printf '%s\n' \
        'verified owned cleanup preserves owned and substituted residue' \
        "residue=$self_test_root" \
        "residue=$original_path"
    exit 0
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_dir/../.." && pwd -P)
macscope_dir="$repository_root/MacScope"
project="$macscope_dir/MacScope.xcodeproj"
verifier="$repository_root/Scripts/native-decompiler-direct/verify_sleigh_package.py"
signing_guard="$repository_root/Scripts/check_local_signing_policy.py"
preparation_helper="$repository_root/Scripts/reconstruction/native_live_preparation_receipt.py"
execution_reporter="$repository_root/Scripts/reconstruction/write_execution_report.py"
ghostty_verifier="$repository_root/Scripts/build_ghostty_vt.sh"

if [[ -n "$prepare_derived_data" ]]; then
    [[ "$execute_prepared" == false ]] || \
        fail_usage '--prepare-derived-data and --execute-prepared are mutually exclusive'
    [[ -n "$preparation_receipt" ]] || fail_usage '--preparation-receipt is required'
    [[ -n "$materialization_root" ]] || fail_usage '--materialization-root is required'
    [[ -z "$candidate_identity" && -z "$xctestrun" && -z "$candidate_app" \
        && -z "$result_bundle" && -z "$artifact_root" \
        && -z "$qualification_run_id" && -z "$qualification_run_nonce" \
        && -z "$predecessor_observations_sha256" \
        && "$only_testing_supplied" == false ]] || \
        fail_usage 'preparation cannot accept execution or selector arguments'
    for path in "$prepare_derived_data" "$preparation_receipt" \
        "$materialization_root"; do
        [[ "$path" == /* ]] || fail_usage 'all preparation paths must be absolute'
    done
    [[ ! -e "$prepare_derived_data" && ! -L "$prepare_derived_data" ]] || \
        fail 'refusing to reuse a DerivedData preparation root'
    [[ ! -e "$preparation_receipt" && ! -L "$preparation_receipt" ]] || \
        fail 'refusing to overwrite a preparation receipt'
    [[ -d "$(dirname "$prepare_derived_data")" \
        && -d "$(dirname "$preparation_receipt")" ]] || \
        fail 'preparation output parents must exist'
    [[ -d "$materialization_root" && ! -L "$materialization_root" ]] || \
        fail 'materialization root is unavailable or unsafe'
    [[ -z "$(/usr/bin/git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]] || \
        fail 'preparation requires an exactly clean source repository'
    materialization_root=$(cd "$materialization_root" && pwd -P)
    prepare_derived_data="$(cd "$(dirname "$prepare_derived_data")" && pwd -P)/$(basename "$prepare_derived_data")"
    preparation_receipt="$(cd "$(dirname "$preparation_receipt")" && pwd -P)/$(basename "$preparation_receipt")"
    # shellcheck disable=SC1091
    source "$repository_root/Scripts/xcode27_env.sh"
    command -v xcodegen >/dev/null 2>&1 || fail 'required tool is unavailable: xcodegen'
    [[ -f "$verifier" && -f "$signing_guard" && -f "$preparation_helper" \
        && -x "$ghostty_verifier" ]] || \
        fail 'a preparation verifier is unavailable'
    case "${MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE:-}" in
        shared-view)
            /usr/bin/python3 -B "$repository_root/Scripts/qualification/dev_dependency_cache.py" \
                reuse-sleigh --repository-root "$repository_root" \
                --materialization-root "$materialization_root"
            ;;
        '') /usr/bin/python3 -B "$verifier" verify \
            --materialization-root "$materialization_root" >/dev/null ;;
        *) fail 'unsupported native verification receipt mode' ;;
    esac
    lipo=$(/usr/bin/xcrun --find lipo)
    for archive in \
        "$materialization_root/package/lib/libdecomp.a" \
        "$materialization_root/package/lib/libsla.a"; do
        [[ -f "$archive" && ! -L "$archive" ]] || \
            fail 'verified native package archive is unavailable'
        [[ $($lipo -archs "$archive") == arm64 ]] || \
            fail 'native package archives must be arm64-only'
    done
    /usr/bin/python3 -B "$signing_guard" --active-toolchain
    /usr/bin/python3 -B "$repository_root/Scripts/generate_xcode_json_project.py" --source "$macscope_dir"
    /usr/bin/python3 -B "$signing_guard" --xcodeproj "$project"
    printf '%s\n' \
        '==> Preparing the certificate-signed native live-XPC test product' \
        "    DerivedData: $prepare_derived_data" \
        "    live condition: $LIVE_TEST_CONDITION"
    /usr/bin/xcrun xcodebuild build-for-testing \
        -project "$project" \
        -scheme MacScopeApp \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$prepare_derived_data" \
        -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        MACSCOPE_SLEIGH_MATERIALIZATION_ROOT="$materialization_root" \
        MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION="$LIVE_TEST_CONDITION"
    xctestrun=$(/usr/bin/python3 -B - "$prepare_derived_data/Build/Products" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
matches = sorted(path for path in root.glob("*.xctestrun") if path.is_file() and not path.is_symlink())
if len(matches) != 1:
    raise SystemExit(f"ERROR: expected exactly one prepared xctestrun, found {len(matches)}")
print(matches[0])
PY
    )
    candidate_app="$prepare_derived_data/Build/Products/Debug/MacScope.app"
    [[ -d "$candidate_app" && ! -L "$candidate_app" ]] || \
        fail 'build-for-testing did not produce the expected signed app'
    # Xcode's "Build repository-owned Ghostty VT" phase is the only Ghostty
    # producer: it builds the vendored source into
    # $(CONFIGURATION_TEMP_DIR)/MacScopeGhosttyVT inside this DerivedData and
    # links/embeds that artifact. Discover exactly one Debug build root the same
    # way validate_qualification_product_identity.py does, then verify it with
    # the qualification script's canonical form
    # (build_ghostty_vt.sh --work-root <root> --verify-only).
    ghostty_vt_work_root=$(/usr/bin/python3 -B - "$prepare_derived_data" Debug <<'PY'
from pathlib import Path
import sys

derived_data = Path(sys.argv[1])
configuration = sys.argv[2]
intermediates = derived_data / "Build/Intermediates.noindex"
candidates = []
for manifest in intermediates.glob(
    "**/MacScopeGhosttyVT/artifacts/lib/.macscope-ghostty-vt-manifest"
):
    root = manifest.parents[2]
    relative = root.relative_to(intermediates)
    if any(
        part == configuration or part.startswith(configuration + "-")
        for part in relative.parts
    ):
        candidates.append(root)
if len(candidates) != 1:
    raise SystemExit(
        f"ERROR: DerivedData must contain exactly one {configuration} "
        f"Xcode-owned Ghostty VT build, found {len(candidates)}"
    )
root = candidates[0]
if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
    raise SystemExit("ERROR: Xcode-owned Ghostty VT build root is linked or noncanonical")
print(root)
PY
    ) || fail 'Xcode-owned Ghostty VT build root is unavailable or ambiguous'
    # The governed Zig output intentionally publishes the stable dylib name as
    # a symlink to its versioned ordinary file. Verify the complete Ghostty
    # source/artifact contract before following that standard link, and keep
    # the verifier's diagnostics so a rejection is actionable.
    if ! ghostty_verification=$("$ghostty_verifier" \
        --work-root "$ghostty_vt_work_root" --verify-only 2>&1); then
        printf '%s\n' "$ghostty_verification" >&2
        fail 'Xcode-owned Ghostty VT build failed verification'
    fi
    ghostty_library="$ghostty_vt_work_root/artifacts/lib/libghostty-vt.dylib"
    [[ -f "$ghostty_library" ]] || \
        fail 'verified Ghostty VT build output is unavailable'
    [[ $($lipo -archs "$ghostty_library") == arm64 ]] || \
        fail 'Ghostty VT build output must be arm64-only'
    /usr/bin/python3 -B "$preparation_helper" create \
        --repository-root "$repository_root" \
        --xctestrun "$xctestrun" \
        --candidate-app "$candidate_app" \
        --output "$preparation_receipt"
    printf '%s\n' \
        "MACSCOPE_NATIVE_LIVE_PREPARED_XCTESTRUN=$xctestrun" \
        "MACSCOPE_NATIVE_LIVE_PREPARED_APP=$candidate_app" \
        '==> Native live-XPC test preparation passed.'
    exit 0
fi

if [[ "$execute_prepared" == true ]]; then
    [[ -z "$materialization_root" && -z "$prepare_derived_data" ]] || \
        fail_usage 'execution cannot accept build, dependency, or preparation-root arguments'
    for value in preparation_receipt xctestrun candidate_app candidate_identity \
        result_bundle artifact_root qualification_run_id qualification_run_nonce \
        predecessor_observations_sha256; do
        [[ -n "${!value}" ]] || fail_usage "--${value//_/-} is required"
    done
    [[ "$qualification_run_id" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || \
        fail_usage '--qualification-run-id must be a canonical stable ID'
    [[ "$qualification_run_nonce" =~ ^[0-9a-f]{64}$ ]] || \
        fail_usage '--qualification-run-nonce must be a lowercase SHA-256'
    [[ "$predecessor_observations_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail_usage '--predecessor-observations-sha256 must be a lowercase SHA-256'
    for value in preparation_receipt xctestrun candidate_app candidate_identity \
        result_bundle artifact_root; do
        [[ "${!value}" == /* ]] || fail_usage 'all execution paths must be absolute'
    done
    preparation_receipt=$(canonical_path "$preparation_receipt" file $((2 * 1024 * 1024))) || \
        fail 'preparation receipt is unavailable, oversized, linked, or noncanonical'
    xctestrun=$(canonical_path "$xctestrun" file $((16 * 1024 * 1024))) || \
        fail 'xctestrun is unavailable, oversized, linked, or noncanonical'
    candidate_identity=$(canonical_path "$candidate_identity" file $((16 * 1024 * 1024))) || \
        fail 'candidate identity is unavailable, oversized, linked, or noncanonical'
    candidate_app=$(canonical_path "$candidate_app" directory) || \
        fail 'candidate app is unavailable, linked, or noncanonical'
    result_bundle=$(canonical_path "$result_bundle" absent) || \
        fail 'result bundle output is unavailable, linked, reused, or noncanonical'
    artifact_root=$(canonical_path "$artifact_root" absent) || \
        fail 'artifact root output is unavailable, linked, reused, or noncanonical'
    [[ "$candidate_app" == *.app ]] || \
        fail 'candidate app must be an exact .app directory'
    [[ "$result_bundle" == *.xcresult ]] || \
        fail 'result bundle must use the exact .xcresult suffix'
    require_disjoint_execution_paths \
        "$preparation_receipt" "$xctestrun" "$candidate_app" \
        "$candidate_identity" "$result_bundle" "$artifact_root" || \
        fail 'execution inputs and outputs must be pairwise disjoint'
    [[ -f "$preparation_helper" && -f "$signing_guard" \
        && -f "$execution_reporter" ]] || fail 'an execution verifier is unavailable'
    # shellcheck disable=SC1091
    source "$repository_root/Scripts/xcode27_env.sh" >&2
    /usr/bin/python3 -B "$preparation_helper" validate \
        --receipt "$preparation_receipt" \
        --xctestrun "$xctestrun" \
        --candidate-app "$candidate_app" \
        --candidate-identity "$candidate_identity" >&2
    /usr/bin/python3 -B "$signing_guard" \
        --app-bundle "$candidate_app" \
        --configuration Debug \
        --xcode-test-host-entitlements >&2
    /bin/mkdir -m 700 "$artifact_root"
    artifact_root=$(canonical_path "$artifact_root" directory) || \
        fail 'created artifact root lost its exact directory identity'
    test_results_path="$artifact_root/NativeDecompilerLiveXPC.test-results.json"
    test_results_temporary="$artifact_root/.NativeDecompilerLiveXPC.test-results.partial.json"
    native_artifact_path="$artifact_root/NativeDecompilerXPCService"
    execution_report_path="$artifact_root/NativeDecompilerLiveXPC.execution-report.json"
    native_executable="$candidate_app/Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService"
    printf '%s\n' \
        '==> Executing the sealed native live-XPC product without rebuilding' \
        "    selector: $test_selector" \
        "    xctestrun: $xctestrun" \
        "    candidate: $candidate_app" \
        "    result bundle: $result_bundle" >&2
    started_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')
    set +e
    /usr/bin/xcrun xcodebuild test-without-building \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 120 \
        -maximum-test-execution-time-allowance 120 \
        -xctestrun "$xctestrun" \
        -destination 'platform=macOS,arch=arm64' \
        -resultBundlePath "$result_bundle" \
        -only-testing:"$test_selector" \
        -parallel-testing-enabled NO >&2
    xcode_exit=$?
    verification_exit=1
    result_bundle_identity_exit=1
    if canonical_result_bundle=$(canonical_path "$result_bundle" directory); then
        result_bundle=$canonical_result_bundle
        read -r result_bundle_device result_bundle_inode \
            < <(read_owned_directory_identity "$result_bundle")
        result_bundle_identity_exit=$?
    fi
    if [[ "$result_bundle_identity_exit" -eq 0 ]]; then
        /usr/bin/xcrun xcresulttool get test-results tests \
            --path "$result_bundle" \
            --compact >"$test_results_temporary"
        extraction_exit=$?
        if [[ "$extraction_exit" -eq 0 ]]; then
            verify_test_results_json "$test_results_temporary"
            verification_exit=$?
            if [[ "$verification_exit" -eq 0 ]]; then
                publish_regular_copy "$test_results_temporary" "$test_results_path"
                verification_exit=$?
                if [[ "$verification_exit" -eq 0 ]]; then
                    /bin/rm -f -- "$test_results_temporary"
                fi
            fi
        else
            verification_exit=$extraction_exit
        fi
    else
        extraction_exit=1
    fi
    if [[ "$result_bundle_identity_exit" -eq 0 ]]; then
        read -r final_result_bundle_device final_result_bundle_inode \
            < <(read_owned_directory_identity "$result_bundle")
        final_result_bundle_identity_exit=$?
        if [[ "$final_result_bundle_identity_exit" -ne 0 \
            || "$final_result_bundle_device" != "$result_bundle_device" \
            || "$final_result_bundle_inode" != "$result_bundle_inode" ]]; then
            verification_exit=1
        fi
    fi
    /usr/bin/python3 -B "$preparation_helper" validate \
        --receipt "$preparation_receipt" \
        --xctestrun "$xctestrun" \
        --candidate-app "$candidate_app" \
        --candidate-identity "$candidate_identity" >&2
    post_validation_exit=$?
    native_publication_exit=1
    if [[ "$post_validation_exit" -eq 0 ]]; then
        if native_executable=$(canonical_path "$native_executable" file $((1024 * 1024 * 1024))); then
            publish_regular_copy "$native_executable" "$native_artifact_path"
            native_publication_exit=$?
        fi
    fi
    ended_at_unix_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1_000_000)')
    execution_exit=$xcode_exit
    if [[ "$execution_exit" -eq 0 && "$verification_exit" -ne 0 ]]; then
        execution_exit=$verification_exit
    fi
    if [[ "$execution_exit" -eq 0 && "$post_validation_exit" -ne 0 ]]; then
        execution_exit=$post_validation_exit
    fi
    if [[ "$execution_exit" -eq 0 && "$native_publication_exit" -ne 0 ]]; then
        execution_exit=$native_publication_exit
    fi
    if [[ "$execution_exit" -eq 0 ]]; then
        execution_result=passed
    else
        execution_result=failed
    fi
    reporter_arguments=(
        --output "$execution_report_path" \
        --qualification-run-id "$qualification_run_id" \
        --qualification-run-nonce "$qualification_run_nonce" \
        --predecessor-observations-sha256 "$predecessor_observations_sha256" \
        --started-at-unix-ms "$started_at_unix_ms" \
        --ended-at-unix-ms "$ended_at_unix_ms" \
        --result "$execution_result" \
        --exit-code "$execution_exit"
    )
    if [[ "$execution_exit" -eq 0 ]]; then
        reporter_arguments+=(
            --native-preparation-receipt "$preparation_receipt"
            --native-xctestrun "$xctestrun"
            --native-candidate-app "$candidate_app"
            --native-candidate-identity "$candidate_identity"
            --native-result-bundle "$result_bundle"
            --native-test-results "$test_results_path"
            --native-service-artifact "$native_artifact_path"
            --native-test-selector "$test_selector"
        )
    fi
    /usr/bin/python3 -B "$execution_reporter" "${reporter_arguments[@]}" >&2
    reporter_exit=$?
    set -e
    [[ "$reporter_exit" -eq 0 ]] || fail 'native live-XPC execution report was not published'
    if [[ -f "$test_results_path" && ! -L "$test_results_path" ]]; then
        printf '%s\n' "MACSCOPE_SIGNED_NATIVE_TEST_RESULTS=$test_results_path"
    fi
    if [[ -f "$native_artifact_path" && ! -L "$native_artifact_path" ]]; then
        printf '%s\n' "MACSCOPE_SIGNED_NATIVE_EXECUTABLE=$native_artifact_path"
    fi
    printf '%s\n' "MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT=$execution_report_path"
    [[ "$execution_exit" -eq 0 ]] || fail 'signed native live-XPC execution failed'
    printf '%s\n' '==> Native-decompiler signed live-XPC gate passed.' >&2
    exit 0
fi

fail_usage 'choose exactly one runner mode'
