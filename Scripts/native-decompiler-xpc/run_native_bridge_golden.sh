#!/bin/bash

set -euo pipefail

usage() {
    printf '%s\n' \
        'usage: run_native_bridge_golden.sh --build-root ABSOLUTE_PATH' \
        '       --materialization-root ABSOLUTE_PATH' \
        '       --native-archive-root ABSOLUTE_PATH' \
        '       --stage-stamp ABSOLUTE_PATH' \
        '       --developer-dir ABSOLUTE_PATH' \
        '       --sdk-root ABSOLUTE_PATH' \
        '       --sdk-name VALUE' \
        '       --target-build-dir ABSOLUTE_PATH' \
        '       --project-temp-dir ABSOLUTE_PATH' \
        '       --result ABSOLUTE_PATH'
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

build_root=
materialization_root=
native_archive_root=
stage_stamp=
developer_dir=
sdk_root=
sdk_name=
target_build_dir=
project_temp_dir=
result=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-root)
            [[ $# -ge 2 ]] || fail_usage '--build-root requires a value'
            build_root=$2
            shift 2
            ;;
        --materialization-root)
            [[ $# -ge 2 ]] || fail_usage '--materialization-root requires a value'
            materialization_root=$2
            shift 2
            ;;
        --native-archive-root)
            [[ $# -ge 2 ]] || fail_usage '--native-archive-root requires a value'
            native_archive_root=$2
            shift 2
            ;;
        --result)
            [[ $# -ge 2 ]] || fail_usage '--result requires a value'
            result=$2
            shift 2
            ;;
        --stage-stamp)
            [[ $# -ge 2 ]] || fail_usage '--stage-stamp requires a value'
            stage_stamp=$2
            shift 2
            ;;
        --developer-dir)
            [[ $# -ge 2 ]] || fail_usage '--developer-dir requires a value'
            developer_dir=$2
            shift 2
            ;;
        --sdk-root)
            [[ $# -ge 2 ]] || fail_usage '--sdk-root requires a value'
            sdk_root=$2
            shift 2
            ;;
        --sdk-name)
            [[ $# -ge 2 ]] || fail_usage '--sdk-name requires a value'
            sdk_name=$2
            shift 2
            ;;
        --target-build-dir)
            [[ $# -ge 2 ]] || fail_usage '--target-build-dir requires a value'
            target_build_dir=$2
            shift 2
            ;;
        --project-temp-dir)
            [[ $# -ge 2 ]] || fail_usage '--project-temp-dir requires a value'
            project_temp_dir=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail_usage 'unknown argument'
            ;;
    esac
done

for value in \
    "$build_root" \
    "$materialization_root" \
    "$native_archive_root" \
    "$stage_stamp" \
    "$developer_dir" \
    "$sdk_root" \
    "$target_build_dir" \
    "$project_temp_dir" \
    "$result"; do
    [[ -n "$value" ]] || fail_usage 'all roots, the stage stamp, and the result path must be explicit'
    [[ "$value" == /* ]] || fail_usage 'all paths must be absolute'
done
[[ -n "$sdk_name" ]] || fail_usage 'SDK name must be explicit'
[[ "$sdk_name" =~ ^macosx[0-9]+([.][0-9]+)*$ ]] || fail_usage 'SDK name must be explicit and canonical'

[[ $(uname -m) == arm64 ]] || fail 'native bridge golden tests require an arm64 host'

# The exact signed Debug continuation consumes prior proof before any legacy
# verifier, archive digest or golden fixture execution. Release never enters it.
if [[ -n "${MACSCOPE_NATIVE_DEBUG_CONTINUATION_RECEIPT:-}" ]]; then
    /usr/bin/python3 -B "$(dirname "$0")/debug_native_receipt.py" \
        --repository-root "$(cd "$(dirname "$0")/../.." && pwd -P)" \
        --golden-result "$result"
    exit 0
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
filesystem_helper="$script_dir/golden_filesystem.py"
[[ -f "$filesystem_helper" && ! -L "$filesystem_helper" ]] || \
    fail 'golden filesystem helper is unavailable'

ordinary_directory() {
    local path=$1
    local label=$2
    [[ -d "$path" && ! -L "$path" ]] || fail "$label must be an ordinary directory"
    (cd "$path" && pwd -P)
}

require_contained() {
    local child=$1
    local parent=$2
    local label=$3
    case "$child/" in
        "$parent/"*) ;;
        *) fail "$label escaped its Xcode-owned root" ;;
    esac
}

developer_dir=$(ordinary_directory "$developer_dir" 'developer directory')
target_build_dir=$(ordinary_directory "$target_build_dir" 'target build directory')
project_temp_dir=$(ordinary_directory "$project_temp_dir" 'project temporary directory')
materialization_root=$(ordinary_directory "$materialization_root" 'staged materialization root')
native_archive_root=$(ordinary_directory "$native_archive_root" 'native archive root')
sdk_root=$(cd "$sdk_root" && pwd -P)
require_contained "$sdk_root" "$developer_dir" 'SDK root'
require_contained "$materialization_root" "$target_build_dir" 'staged materialization root'
require_contained "$native_archive_root" "$project_temp_dir" 'native archive root'

build_root_parent=$(ordinary_directory "$(dirname "$build_root")" 'golden build root parent')
require_contained "$build_root_parent" "$project_temp_dir" 'golden build root parent'
build_root="$build_root_parent/$(basename "$build_root")"
mkdir -p "$build_root"
build_root=$(ordinary_directory "$build_root" 'golden build root')
require_contained "$build_root" "$project_temp_dir" 'golden build root'
build_root_identity=$(/usr/bin/python3 -B \
    "$filesystem_helper" snapshot-directory "$build_root")

[[ -f "$stage_stamp" && ! -L "$stage_stamp" ]] || fail 'stage stamp must be an ordinary file'
stage_stamp_parent=$(ordinary_directory "$(dirname "$stage_stamp")" 'stage stamp parent')
require_contained "$stage_stamp_parent" "$project_temp_dir" 'stage stamp'
stage_stamp="$stage_stamp_parent/$(basename "$stage_stamp")"

result_parent=$(ordinary_directory "$(dirname "$result")" 'result parent')
require_contained "$result_parent" "$target_build_dir" 'result path'
result_name=$(basename "$result")
result="$result_parent/$result_name"
result_parent_identity=$(/usr/bin/python3 -B \
    "$filesystem_helper" snapshot-directory "$result_parent")
result_initial_identity=$(/usr/bin/python3 -B \
    "$filesystem_helper" snapshot-regular \
    "$result_parent" "$result_parent_identity" "$result_name" --allow-absent)

if [[ "$build_root" == "$materialization_root" || \
      "$build_root" == "$native_archive_root" || \
      "$materialization_root" == "$native_archive_root" ]]; then
    fail 'build, materialization, and native archive roots must be distinct'
fi
case "$build_root/" in
    "$materialization_root/"*|"$native_archive_root/"*)
        fail 'build root must not be nested inside an immutable input root'
        ;;
esac

repository_root=$(cd "$script_dir/../.." && pwd -P)
verifier="$repository_root/Scripts/native-decompiler-direct/verify_sleigh_package.py"
identity_helper="$script_dir/native_decompiler_source_identity.py"
golden_receipt_helper="$script_dir/native_golden_receipts.py"
[[ -f "$verifier" ]] || fail 'native package verifier is unavailable'
[[ -f "$identity_helper" && ! -L "$identity_helper" ]] || \
    fail 'native source identity helper is unavailable'

[[ -x "$developer_dir/usr/bin/xcodebuild" ]] || fail 'selected Xcode developer directory is unavailable'
export DEVELOPER_DIR="$developer_dir"
xcode_version_output=$($developer_dir/usr/bin/xcodebuild -version)
xcode_version=$(printf '%s\n' "$xcode_version_output" | /usr/bin/sed -n '1s/^Xcode //p')
xcode_build=$(printf '%s\n' "$xcode_version_output" | /usr/bin/sed -n '2s/^Build version //p')
[[ "$xcode_version" =~ ^27([.[:space:]]|$) ]] || \
    fail 'native bridge golden tests require the selected Xcode 27 major line'

python=/usr/bin/python3
[[ -x "$python" && -x /usr/bin/cmp ]] || fail 'required offline validation tools are unavailable'
verify_golden_package() {
    if [[ "${MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE:-}" == shared-view ]]; then
        "$python" -B "$golden_receipt_helper" verify-package --materialization-root "$1"
    else
        "$python" -B "$verifier" verify --materialization-root "$1" >/dev/null
    fi
}
verify_golden_package "$materialization_root"

clangxx="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
swiftc="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
lipo="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"
for tool in "$clangxx" "$swiftc" "$lipo"; do
    [[ -x "$tool" ]] || fail 'a required build-selected Xcode tool is unavailable'
done
plutil=/usr/bin/plutil
[[ -x "$plutil" ]] || fail 'Property-list normalization tool is unavailable'
sdk_version=$($developer_dir/usr/bin/xcodebuild -version -sdk "$sdk_root" SDKVersion)
sdk_build=$($developer_dir/usr/bin/xcodebuild -version -sdk "$sdk_root" ProductBuildVersion)
swift_version_output=$($swiftc --version)
swift_compiler_version=$(printf '%s\n' "$swift_version_output" | \
    /usr/bin/sed -n '1s/.*Apple Swift version \([^ ]*\).*/\1/p')
swift_target_triple=$(printf '%s\n' "$swift_version_output" | \
    /usr/bin/sed -n 's/^Target: //p')
[[ "$swift_compiler_version" =~ ^6\. ]] || fail 'build-selected Swift compiler is not version 6'
[[ "$swift_target_triple" =~ ^arm64-apple-macosx27\.[0-9]+(\.[0-9]+)?$ ]] || \
    fail 'build-selected Swift compiler target is not arm64 macOS 27'
[[ -n "$xcode_build" && -n "$sdk_version" && -n "$sdk_build" ]] || \
    fail 'build-selected Xcode or SDK identity is incomplete'

stable_sha256() {
    "$python" -B "$golden_receipt_helper" digest --path "$1" \
        --materialization-root "$materialization_root"
}

wrapper_source_sha256=$("$python" -B "$identity_helper" \
    --repository-root "$repository_root" --profile wrapper)
golden_source_sha256=$("$python" -B "$identity_helper" \
    --repository-root "$repository_root" --profile golden)
[[ "$wrapper_source_sha256" =~ ^[0-9a-f]{64}$ && \
   "$golden_source_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    fail 'native source identities are invalid'

native_archive="$native_archive_root/libmacscope_native_decompiler_contract.a"
native_cache="$native_archive_root/CMakeCache.txt"
build_identity="$native_archive_root/generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"
decompiler_archive="$materialization_root/package/lib/libdecomp.a"
sleigh_archive="$materialization_root/package/lib/libsla.a"
zlib_input="$sdk_root/usr/lib/libz.tbd"
libcxx_input="$sdk_root/usr/lib/libc++.tbd"

for input in \
    "$native_archive" \
    "$native_cache" \
    "$build_identity" \
    "$decompiler_archive" \
    "$sleigh_archive" \
    "$zlib_input" \
    "$libcxx_input"; do
    [[ -f "$input" ]] || fail 'a required verified native or SDK link input is unavailable'
done

/usr/bin/grep -Eq '^CMAKE_OSX_ARCHITECTURES:[^=]+=arm64$' "$native_cache" || \
    fail 'native archive was not configured for arm64 only'
/usr/bin/grep -Eq '^CMAKE_OSX_DEPLOYMENT_TARGET:[^=]+=27\.0$' "$native_cache" || \
    fail 'native archive was not configured for macOS 27.0'
/usr/bin/grep -Eq '^MACSCOPE_ENABLE_GHIDRA_PROVIDER:[^=]+=ON$' "$native_cache" || \
    fail 'native archive does not contain the verified provider'
/usr/bin/grep -Eq '^MACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION:[^=]+=ON$' "$native_cache" || \
    fail 'native archive was not built in relocatable materialization mode'

manifest_sha256=$(stable_sha256 "$materialization_root/MATERIALIZATION.json")
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'verified staged materialization digest is invalid'
/usr/bin/grep -Fqx "    \"$manifest_sha256\";" "$build_identity" || \
    fail 'native archive build identity does not match the staged materialization digest'
wrapper_revision=$(/usr/bin/sed -n \
    's/^MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION:[^=]*=//p' \
    "$native_cache")
[[ "$wrapper_revision" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || \
    fail 'native archive wrapper revision is invalid'
[[ "$wrapper_revision" == "$wrapper_source_sha256" ]] || \
    fail 'native archive wrapper revision does not match the declared source bytes'
/usr/bin/grep -Fqx "    \"$wrapper_revision\";" "$build_identity" || \
    fail 'native archive generated build identity does not match its wrapper revision'

decompiler_archive_sha256=$(stable_sha256 "$decompiler_archive")
sleigh_archive_sha256=$(stable_sha256 "$sleigh_archive")
native_archive_sha256=$(stable_sha256 "$native_archive")
build_identity_sha256=$(stable_sha256 "$build_identity")
stage_stamp_sha256=$(stable_sha256 "$stage_stamp")
materialization_tree_sha256=$("$python" -B - \
    "$stage_stamp" \
    "$materialization_root/MATERIALIZATION.json" \
    "$decompiler_archive_sha256" \
    "$sleigh_archive_sha256" <<'PY'
import json
import os
import pathlib
import sys

stamp_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
decompiler_sha256 = sys.argv[3]
sleigh_sha256 = sys.argv[4]
stamp_bytes = stamp_path.read_bytes()
manifest_bytes = manifest_path.read_bytes()
stamp = json.loads(stamp_bytes)
manifest = json.loads(manifest_bytes)
if stamp_bytes != (json.dumps(stamp, sort_keys=True, separators=(",", ":")) + "\n").encode():
    raise SystemExit("stage stamp is not canonical JSON")
if set(stamp) != {
    "schemaVersion", "destinationName", "materialization",
    "inputFileListSHA256", "outputFileListSHA256", "linkInputs",
} or stamp["schemaVersion"] != 2 or stamp["destinationName"] != "NativeDecompilerPackage":
    raise SystemExit("stage stamp has an unsupported identity")
if stamp["materialization"] != manifest:
    raise SystemExit("stage stamp materialization identity differs from staged manifest")
expected_links = [
    {"relativePath": "package/lib/libdecomp.a", "sha256": decompiler_sha256},
    {"relativePath": "package/lib/libsla.a", "sha256": sleigh_sha256},
]
if stamp["linkInputs"] != expected_links:
    raise SystemExit("stage stamp link input digests differ from stable staged archive hashes")
tree_sha256 = manifest.get("package", {}).get("treeSha256")
if not isinstance(tree_sha256, str) or len(tree_sha256) != 64:
    raise SystemExit("materialization tree identity is unavailable")
print(tree_sha256)
PY
)

for archive in "$native_archive" "$decompiler_archive" "$sleigh_archive"; do
    [[ $("$lipo" -archs "$archive") == arm64 ]] || fail 'a native archive is not arm64-only'
done

run_root=
run_root_identity=
result_temporary=
result_temporary_name=
result_temporary_identity=
cleanup() {
    if [[ -n "$result_temporary_name" && -n "$result_temporary_identity" ]]; then
        if ! "$python" -B "$filesystem_helper" cleanup-regular \
            "$build_root" "$build_root_identity" \
            "$result_temporary_name" "$result_temporary_identity"
        then
            printf '%s\n' \
                "WARNING: refused unsafe golden-result temporary cleanup under $build_root" >&2
        fi
        result_temporary_name=
        result_temporary_identity=
    fi
    if [[ -n "$run_root" && -n "$run_root_identity" ]]; then
        if ! "$python" -B "$filesystem_helper" \
            cleanup-directory "$run_root" "$run_root_identity"
        then
            printf '%s\n' \
                "WARNING: refused unsafe golden run-root cleanup at $run_root" >&2
        fi
        run_root=
        run_root_identity=
    fi
}
# Clean up once. A signal (xcodebuild cancels running phases with TERM when
# another task fails) cleans up and exits; it must not resume the script and then
# clean the same run root again on EXIT.
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
run_root=$(/usr/bin/mktemp -d "$build_root/native-bridge-golden.XXXXXX")
run_root_identity=$("$python" -B \
    "$filesystem_helper" snapshot-directory "$run_root")
objc_test="$run_root/native-decompiler-objc-bridge-tests"
package_objc_test="$run_root/native-decompiler-package-bridge-tests"
swift_harness="$run_root/native-decompiler-swift-wire-harness"

bridge_dir="$repository_root/MacScope/NativeDecompilerXPCService/Bridge"
test_dir="$repository_root/MacScope/Tests/CoreTests"
contract_include="$repository_root/Tools/NativeDecompilerBridge/include"
contract_source="$repository_root/Tools/NativeDecompilerBridge/src"

compile_objc_bridge_test() {
    local output=$1
    shift
    "$clangxx" \
    -std=c++20 \
    -fobjc-arc \
    -fmodules \
    -arch arm64 \
    -mmacosx-version-min=27.0 \
    -isysroot "$sdk_root" \
    -Wall -Wextra -Wpedantic -Werror \
    "$@" \
    -DMACSCOPE_NATIVE_BRIDGE_STANDALONE_TEST \
    "$test_dir/NativeDecompilerObjCBridgeTests.mm" \
    "$bridge_dir/NativeDecompilerWireCodec.mm" \
    "$bridge_dir/NativeDecompilerObjCBridge.mm" \
    -I "$bridge_dir" \
    -I "$contract_include" \
    -I "$contract_source" \
    "$native_archive" \
    "$decompiler_archive" \
    "$sleigh_archive" \
    "$zlib_input" \
    "$libcxx_input" \
    -framework Foundation \
    -o "$output"
}

# The wire/codec fixture is standalone and never ships. Keep its ObjC++ paths
# instrumented, while the package-backed executable remains ABI-consistent with
# the deliberately unsanitized production archive it exercises.
compile_objc_bridge_test "$objc_test" \
    "$contract_source/CanonicalRequest.cpp" \
    -fsanitize=address -fno-omit-frame-pointer
compile_objc_bridge_test "$package_objc_test"

ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=1 "$objc_test"
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=1 "$objc_test" --emit-cp4-fixtures "$run_root"

test_app="$run_root/NativeDecompilerBridgeGolden.app"
test_app_contents="$test_app/Contents"
test_app_executable="$test_app_contents/MacOS/native-decompiler-objc-bridge-tests"
staged_materialization="$test_app_contents/Resources/NativeDecompilerPackage"
/bin/mkdir -p "$test_app_contents/MacOS" "$test_app_contents/Resources"
/bin/cp "$package_objc_test" "$test_app_executable"
"$python" -B "$repository_root/Scripts/native-decompiler-xpc/stage_verified_package.py" \
    --source-materialization-root "$materialization_root" \
    --destination-materialization-root "$staged_materialization" \
    --input-file-list "$run_root/test-app-package.inputs.xcfilelist" \
    --output-file-list "$run_root/test-app-package.outputs.xcfilelist"
/usr/bin/cmp -s "$materialization_root/MATERIALIZATION.json" \
    "$staged_materialization/MATERIALIZATION.json" || \
    fail 'staged native package manifest bytes differ from the explicit verified input'
verify_golden_package "$staged_materialization"

test_app_info="$test_app_contents/Info.plist"
"$plutil" -create xml1 "$test_app_info"
"$plutil" -insert CFBundleIdentifier -string com.macscope.NativeDecompilerBridgeGolden "$test_app_info"
"$plutil" -insert CFBundleName -string NativeDecompilerBridgeGolden "$test_app_info"
"$plutil" -insert CFBundleExecutable -string native-decompiler-objc-bridge-tests "$test_app_info"
"$plutil" -insert CFBundlePackageType -string APPL "$test_app_info"

package_request_one="$run_root/package-request-1.bplist"
package_reply_one="$run_root/package-reply-1.bplist"
package_request_two="$run_root/package-request-2.bplist"
package_reply_two="$run_root/package-reply-2.bplist"
"$test_app_executable" --package-backed-decompile "$package_request_one" "$package_reply_one"
"$test_app_executable" --package-backed-decompile "$package_request_two" "$package_reply_two"
/usr/bin/cmp -s "$package_request_one" "$package_request_two" || \
    fail 'package-backed request bytes are not deterministic across fresh processes'
/usr/bin/cmp -s "$package_reply_one" "$package_reply_two" || \
    fail 'package-backed reply bytes are not deterministic across fresh processes'

objc_request_one="$run_root/objc-request-1.bplist"
objc_reply_one="$run_root/objc-reply-1.bplist"
objc_mapping_one="$run_root/objc-mapping-1.bplist"
objc_request_two="$run_root/objc-request-2.bplist"
objc_reply_two="$run_root/objc-reply-2.bplist"
objc_mapping_two="$run_root/objc-mapping-2.bplist"

"$objc_test" --emit-cross-language-fixture \
    "$objc_request_one" "$objc_reply_one" "$objc_mapping_one"
"$objc_test" --emit-cross-language-fixture \
    "$objc_request_two" "$objc_reply_two" "$objc_mapping_two"
/usr/bin/cmp -s "$objc_request_one" "$objc_request_two" || fail 'Objective-C request bytes are not deterministic'
/usr/bin/cmp -s "$objc_reply_one" "$objc_reply_two" || fail 'Objective-C reply bytes are not deterministic'
/usr/bin/cmp -s "$objc_mapping_one" "$objc_mapping_two" || fail 'Objective-C mapping fixture bytes are not deterministic'

wire_model_dir="$repository_root/MacScope/Models/NativeDecompilerWire"
"$swiftc" \
    -parse-as-library \
    -warnings-as-errors \
    -target arm64-apple-macosx27.0 \
    -sdk "$sdk_root" \
    -DMACSCOPE_NATIVE_BRIDGE_CROSS_LANGUAGE_STANDALONE \
    "$wire_model_dir/NativeDecompilerWirePrimitives.swift" \
    "$wire_model_dir/NativeDecompilerWireTargetProfile.swift" \
    "$wire_model_dir/NativeDecompilerWireAuthoredModels.swift" \
    "$wire_model_dir/NativeDecompilerWireCanonicalRequest.swift" \
    "$wire_model_dir/NativeDecompilerWireResultModels.swift" \
    "$wire_model_dir/NativeDecompilerWireBinaryPropertyListValidator.swift" \
    "$wire_model_dir/NativeDecompilerWireSemanticValidator.swift" \
    "$wire_model_dir/NativeDecompilerWireCodec.swift" \
    "$test_dir/NativeDecompilerObjCBridgeCrossLanguageTests.swift" \
    -o "$swift_harness"

"$swift_harness" --validate-cp4-fixtures "$run_root"

swift_reply_one="$run_root/swift-reply-1.bplist"
swift_reply_two="$run_root/swift-reply-2.bplist"
swift_request_one="$run_root/swift-request-1.bplist"
swift_request_two="$run_root/swift-request-2.bplist"
"$swift_harness" --canonicalize-request "$objc_request_one" "$swift_request_one"
"$swift_harness" --canonicalize-request "$objc_request_two" "$swift_request_two"
/usr/bin/cmp -s "$swift_request_one" "$swift_request_two" || \
    fail 'Swift canonical request bytes are not deterministic'
"$swift_harness" \
    "$swift_request_one" "$objc_reply_one" "$objc_mapping_one" "$swift_reply_one"
"$swift_harness" \
    "$swift_request_one" "$objc_reply_one" "$objc_mapping_one" "$swift_reply_two"
/usr/bin/cmp -s "$swift_reply_one" "$swift_reply_two" || fail 'Swift canonical reply bytes are not deterministic'

package_swift_reply_one="$run_root/package-swift-reply-1.bplist"
package_swift_reply_two="$run_root/package-swift-reply-2.bplist"
package_swift_request_one="$run_root/package-swift-request-1.bplist"
package_swift_request_two="$run_root/package-swift-request-2.bplist"
"$swift_harness" --canonicalize-request "$package_request_one" "$package_swift_request_one"
"$swift_harness" --canonicalize-request "$package_request_two" "$package_swift_request_two"
/usr/bin/cmp -s "$package_swift_request_one" "$package_swift_request_two" || \
    fail 'package-backed Swift canonical request bytes are not deterministic'
"$swift_harness" --validate-package-backed \
    "$package_swift_request_one" "$package_reply_one" "$package_swift_reply_one"
"$swift_harness" --validate-package-backed \
    "$package_swift_request_two" "$package_reply_two" "$package_swift_reply_two"
/usr/bin/cmp -s "$package_swift_reply_one" "$package_swift_reply_two" || \
    fail 'package-backed Swift reply bytes are not deterministic across fresh processes'

package_objc_reply_xml="$run_root/package-objc-reply.xml"
package_swift_reply_xml="$run_root/package-swift-reply.xml"
"$plutil" -convert xml1 -o "$package_objc_reply_xml" "$package_reply_one"
"$plutil" -convert xml1 -o "$package_swift_reply_xml" "$package_swift_reply_one"
/usr/bin/cmp -s "$package_objc_reply_xml" "$package_swift_reply_xml" || \
    fail 'normalized package-backed Objective-C and Swift replies differ'

objc_reply_xml="$run_root/objc-reply.xml"
swift_reply_xml="$run_root/swift-reply.xml"
"$plutil" -convert xml1 -o "$objc_reply_xml" "$objc_reply_one"
"$plutil" -convert xml1 -o "$swift_reply_xml" "$swift_reply_one"
/usr/bin/cmp -s "$objc_reply_xml" "$swift_reply_xml" || \
    fail 'normalized Objective-C and Swift canonical replies differ'

[[ $("$python" -B "$identity_helper" \
    --repository-root "$repository_root" --profile wrapper) == "$wrapper_source_sha256" ]] || \
    fail 'declared wrapper source bytes changed during the golden gate'
[[ $("$python" -B "$identity_helper" \
    --repository-root "$repository_root" --profile golden) == "$golden_source_sha256" ]] || \
    fail 'declared golden source bytes changed during the golden gate'
[[ $(stable_sha256 "$materialization_root/MATERIALIZATION.json") == "$manifest_sha256" ]] || \
    fail 'staged materialization manifest changed during the golden gate'
[[ $(stable_sha256 "$stage_stamp") == "$stage_stamp_sha256" ]] || \
    fail 'stage stamp changed during the golden gate'
[[ $(stable_sha256 "$decompiler_archive") == "$decompiler_archive_sha256" ]] || \
    fail 'staged decompiler archive changed during the golden gate'
[[ $(stable_sha256 "$sleigh_archive") == "$sleigh_archive_sha256" ]] || \
    fail 'staged SLEIGH archive changed during the golden gate'
[[ $(stable_sha256 "$native_archive") == "$native_archive_sha256" ]] || \
    fail 'native contract archive changed during the golden gate'
[[ $(stable_sha256 "$build_identity") == "$build_identity_sha256" ]] || \
    fail 'native contract build identity changed during the golden gate'
objc_request_sha256=$(stable_sha256 "$objc_request_one")
objc_reply_sha256=$(stable_sha256 "$objc_reply_one")
objc_mapping_sha256=$(stable_sha256 "$objc_mapping_one")
swift_reply_sha256=$(stable_sha256 "$swift_reply_one")
package_request_sha256=$(stable_sha256 "$package_request_one")
package_reply_sha256=$(stable_sha256 "$package_reply_one")
package_swift_reply_sha256=$(stable_sha256 "$package_swift_reply_one")

result_temporary=$(/usr/bin/mktemp "$build_root/.native-bridge-golden-result.XXXXXX")
result_temporary_name=$(basename "$result_temporary")
result_temporary_identity=$("$python" -B \
    "$filesystem_helper" snapshot-regular \
    "$build_root" "$build_root_identity" "$result_temporary_name")
"$python" -B - \
    "$result_temporary" \
    "$package_reply_one" \
    "$manifest_sha256" \
    "$native_archive_sha256" \
    "$build_identity_sha256" \
    "$stage_stamp_sha256" \
    "$materialization_tree_sha256" \
    "$decompiler_archive_sha256" \
    "$sleigh_archive_sha256" \
    "$wrapper_revision" \
    "$golden_source_sha256" \
    "$xcode_version" \
    "$xcode_build" \
    "$swift_compiler_version" \
    "$swift_target_triple" \
    "$sdk_name" \
    "$sdk_version" \
    "$sdk_build" \
    "$objc_request_sha256" \
    "$objc_reply_sha256" \
    "$objc_mapping_sha256" \
    "$swift_reply_sha256" \
    "$package_request_sha256" \
    "$package_reply_sha256" \
    "$package_swift_reply_sha256" <<'PY'
import json
import os
import pathlib
import plistlib
import sys

(
    output,
    package_reply_path,
    manifest_sha256,
    native_archive_sha256,
    build_identity_sha256,
    stage_stamp_sha256,
    materialization_tree_sha256,
    decompiler_archive_sha256,
    sleigh_archive_sha256,
    wrapper_revision,
    golden_source_sha256,
    xcode_version,
    xcode_build,
    swift_compiler_version,
    swift_target_triple,
    sdk_name,
    sdk_version,
    sdk_build,
    objc_request_sha256,
    objc_reply_sha256,
    objc_mapping_sha256,
    swift_reply_sha256,
    package_request_sha256,
    package_reply_sha256,
    package_swift_reply_sha256,
) = sys.argv[1:]
with pathlib.Path(package_reply_path).open("rb") as stream:
    package_reply = plistlib.load(stream)
try:
    identity = package_reply["success"]["availability"]["runtimeIdentity"]
except (KeyError, TypeError) as error:
    raise SystemExit("package-backed reply lacks native backend identity") from error
expected_identity = {
    "backendID": "ghidra-native-decompiler",
    "engineVersion": "12.1.2",
    "engineRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
    "wrapperVersion": "dcp05c-v1",
    "wrapperRevision": wrapper_revision,
    "packageManifestSHA256": manifest_sha256,
    "packageTreeSHA256": materialization_tree_sha256,
    "languageID": "AARCH64:LE:64:AppleSilicon",
    "compilerSpecID": "default",
    "targetProfileID": "apple-aarch64-pac-visible-clobber-v1",
    "contextProfileSHA256": "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
}
if identity != expected_identity:
    raise SystemExit("package-backed reply does not carry the exact compiled backend identity")
payload = {
    "architecture": "arm64",
    "backendID": identity["backendID"],
    "contractArchiveSHA256": native_archive_sha256,
    "contractBuildIdentitySHA256": build_identity_sha256,
    "decompilerArchiveSHA256": decompiler_archive_sha256,
    "deploymentTarget": "27.0",
    "engineGitRevision": identity["engineRevision"],
    "engineVersion": identity["engineVersion"],
    "goldenSourceSHA256": golden_source_sha256,
    "materializationManifestSHA256": manifest_sha256,
    "materializationTreeSHA256": materialization_tree_sha256,
    "objcMappingSHA256": objc_mapping_sha256,
    "objcReplySHA256": objc_reply_sha256,
    "objcRequestSHA256": objc_request_sha256,
    "packageBackedReplySHA256": package_reply_sha256,
    "packageBackedRequestSHA256": package_request_sha256,
    "packageBackedSwiftReplySHA256": package_swift_reply_sha256,
    "passed": True,
    "schemaVersion": 1,
    "sdkBuild": sdk_build,
    "sdkName": sdk_name,
    "sdkVersion": sdk_version,
    "sleighArchiveSHA256": sleigh_archive_sha256,
    "stageStampSHA256": stage_stamp_sha256,
    "swiftCompilerVersion": swift_compiler_version,
    "swiftReplySHA256": swift_reply_sha256,
    "swiftTargetTriple": swift_target_triple,
    "wrapperGitRevision": identity["wrapperRevision"],
    "wrapperVersion": identity["wrapperVersion"],
    "xcodeBuild": xcode_build,
    "xcodeVersion": xcode_version,
}
encoded = json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True) + "\n"
with pathlib.Path(output).open("w", encoding="utf-8") as stream:
    stream.write(encoded)
    stream.flush()
    os.fsync(stream.fileno())
PY
/bin/chmod 0644 "$result_temporary"
result_temporary_identity=$("$python" -B \
    "$filesystem_helper" snapshot-regular \
    "$build_root" "$build_root_identity" "$result_temporary_name")
"$python" -B "$filesystem_helper" publish \
    "$build_root" "$build_root_identity" \
    "$result_temporary_name" "$result_temporary_identity" \
    "$result_parent" "$result_parent_identity" \
    "$result_name" "$result_initial_identity"
result_temporary=
result_temporary_name=
result_temporary_identity=

printf 'PASS: native bridge golden runner\n'
printf 'result=%s\n' "$result"
