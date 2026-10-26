#!/bin/bash

set -euo pipefail

usage() {
    printf '%s\n' \
        'usage: build_native_bridge.sh --source-root PATH --build-root PATH' \
        '       --materialization-root PATH --wrapper-revision HEX --configuration Release' \
        '       [--qualification-report-dir ABSOLUTE_PATH]'
}

source_root=
build_root=
materialization_root=
wrapper_revision=
configuration=
qualification_report_dir=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            source_root=$2
            shift 2
            ;;
        --build-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            build_root=$2
            shift 2
            ;;
        --materialization-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            materialization_root=$2
            shift 2
            ;;
        --wrapper-revision)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            wrapper_revision=$2
            shift 2
            ;;
        --configuration)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            configuration=$2
            shift 2
            ;;
        --qualification-report-dir)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            qualification_report_dir=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown argument\n' >&2
            usage >&2
            exit 2
            ;;
    esac
done

for value in "$source_root" "$build_root" "$materialization_root" \
    "$wrapper_revision" "$configuration"; do
    if [[ -z "$value" ]]; then
        printf 'ERROR: every build input must be explicit\n' >&2
        usage >&2
        exit 2
    fi
done

if [[ ! "$wrapper_revision" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    printf 'ERROR: wrapper revision must be lowercase 40- or 64-digit hex\n' >&2
    exit 2
fi
if [[ "$configuration" != Release ]]; then
    printf 'ERROR: relocatable XPC archives require the Release configuration\n' >&2
    exit 2
fi
if [[ $(uname -m) != arm64 ]]; then
    printf 'ERROR: native bridge builds require an arm64 host\n' >&2
    exit 1
fi

source_root=$(cd "$source_root" && pwd -P)
materialization_root=$(cd "$materialization_root" && pwd -P)
development_build_only=${MACSCOPE_NATIVE_DEV_BUILD_ONLY:-0}
case "$development_build_only" in
    0) ;;
    1)
        if [[ ${CONFIGURATION:-} != Debug ||
              ${MACSCOPE_DEBUG_SOURCE_IDENTITY:-} != runtime-only ||
              ${MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE:-} != shared-view ||
              -n "$qualification_report_dir" ]]; then
            printf 'ERROR: native build-only requires receipt-backed runtime-only Debug\n' >&2
            exit 1
        fi
        ;;
    *) printf 'ERROR: unsupported native development build mode\n' >&2; exit 1 ;;
esac
mkdir -p "$build_root"
build_root=$(cd "$build_root" && pwd -P)

if [[ ! -f "$source_root/CMakeLists.txt" || \
      ! -f "$source_root/src/GhidraBuildIdentity.hpp.in" ]]; then
    printf 'ERROR: source root is not the native bridge source root\n' >&2
    exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_dir/../.." && pwd -P)
expected_source_root=$(cd "$repository_root/Tools/NativeDecompilerBridge" && pwd -P)
if [[ "$source_root" != "$expected_source_root" ]]; then
    printf 'ERROR: source root does not match the repository native bridge\n' >&2
    exit 1
fi
identity_helper="$script_dir/native_decompiler_source_identity.py"
if [[ ! -f "$identity_helper" || -L "$identity_helper" ]]; then
    printf 'ERROR: native source identity helper is unavailable\n' >&2
    exit 1
fi
expected_wrapper_revision=$(/usr/bin/python3 -B "$identity_helper" \
    --repository-root "$repository_root" --profile wrapper)
if [[ "$wrapper_revision" != "$expected_wrapper_revision" ]]; then
    printf 'ERROR: wrapper revision does not match the declared native source bytes\n' >&2
    exit 1
fi
verifier="$repository_root/Scripts/native-decompiler-direct/verify_sleigh_package.py"
if [[ ! -f "$verifier" ]]; then
    printf 'ERROR: native package verifier is unavailable\n' >&2
    exit 1
fi
if [[ "$build_root" == "$source_root" || "$build_root" == "$materialization_root" ]]; then
    printf 'ERROR: build root must be separate from source and materialization roots\n' >&2
    exit 1
fi

if [[ -n ${DEVELOPER_DIR:-} ]]; then
    developer_dir=$DEVELOPER_DIR
elif ! developer_dir=$(xcode-select -p 2>/dev/null); then
    printf 'ERROR: the active Xcode developer directory is unavailable\n' >&2
    exit 1
fi
developer_dir=$(cd "$developer_dir" && pwd -P)
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    printf 'ERROR: Xcode 27 developer directory is unavailable\n' >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"
xcode_version_output=$($developer_dir/usr/bin/xcodebuild -version)
xcode_version=${xcode_version_output%%$'\n'*}
if [[ ! "$xcode_version" =~ ^Xcode[[:space:]]27([.[:space:]]|$) ]]; then
    printf 'ERROR: native bridge builds require the Xcode 27 major line\n' >&2
    exit 1
fi

# Xcode's script-phase PATH ends at /usr/local/bin and never contains Homebrew's
# Apple Silicon prefix, so a bare `command -v` lookup finds cmake/ninja/ctest in a
# login shell but not under Xcode, the Xcode MCP server, or any Xcode-driven CI.
# Resolve each tool explicitly, honouring a per-tool override exactly as
# MACSCOPE_LIPO and MACSCOPE_OTOOL already are, and name the tool that is missing.
MACSCOPE_TOOL_SEARCH_PATH="${MACSCOPE_TOOL_SEARCH_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin}"

resolve_required_tool() {
    local name="$1"
    local override="$2"
    local resolved=""
    if [[ -n "$override" ]]; then
        if [[ ! -x "$override" ]]; then
            printf 'ERROR: %s override is not executable: %s\n' "$name" "$override" >&2
            exit 1
        fi
        printf '%s' "$override"
        return 0
    fi
    resolved=$(command -v "$name" 2>/dev/null || true)
    if [[ -z "$resolved" ]]; then
        resolved=$(PATH="$MACSCOPE_TOOL_SEARCH_PATH" command -v "$name" 2>/dev/null || true)
    fi
    if [[ -z "$resolved" ]]; then
        printf 'ERROR: required offline build tool is unavailable: %s\n' "$name" >&2
        printf '       searched PATH and %s\n' "$MACSCOPE_TOOL_SEARCH_PATH" >&2
        printf '       set MACSCOPE_%s to an absolute path to override\n' \
            "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')" >&2
        exit 1
    fi
    printf '%s' "$resolved"
}

cmake_bin=$(resolve_required_tool cmake "${MACSCOPE_CMAKE:-}")
ctest_bin=$(resolve_required_tool ctest "${MACSCOPE_CTEST:-}")
ninja_bin=$(resolve_required_tool ninja "${MACSCOPE_NINJA:-}")
file_bin=$(resolve_required_tool file "${MACSCOPE_FILE:-}")
strings_bin=$(resolve_required_tool strings "${MACSCOPE_STRINGS:-}")
python=$(resolve_required_tool python3 "${MACSCOPE_PYTHON3:-}")
case "${MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE:-}" in
    shared-view)
        "$python" -B "$repository_root/Scripts/qualification/dev_dependency_cache.py" \
            reuse-sleigh --repository-root "$repository_root" \
            --materialization-root "$materialization_root"
        ;;
    '') "$python" -B "$verifier" verify --materialization-root "$materialization_root" >/dev/null ;;
    *) printf 'ERROR: unsupported native verification receipt mode\n' >&2; exit 1 ;;
esac
report_cmake_options=()
if [[ -n "$qualification_report_dir" ]]; then
    report_cmake_options=(-DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=OFF)
fi

clangxx=$(xcrun --find clang++)
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
zlib_input="$sdk_root/usr/lib/libz.tbd"
if [[ ! -f "$zlib_input" ]]; then
    printf 'ERROR: Xcode SDK zlib link input is unavailable\n' >&2
    exit 1
fi

"$cmake_bin" \
    -S "$source_root" \
    -B "$build_root" \
    -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja_bin" \
    -DBUILD_TESTING=ON \
    "-DCMAKE_BUILD_TYPE=$configuration" \
    "-DCMAKE_CXX_COMPILER=$clangxx" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    "-DCMAKE_OSX_SYSROOT=$sdk_root" \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DMACSCOPE_ENABLE_GHIDRA_PROVIDER=ON \
    -DMACSCOPE_GHIDRA_PROVIDER_RELOCATABLE_MATERIALIZATION=ON \
    "-DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT=$materialization_root" \
    "-DMACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION=$wrapper_revision" \
    ${report_cmake_options[@]+"${report_cmake_options[@]}"}

parallel_jobs="${CMAKE_BUILD_PARALLEL_LEVEL:-$(/usr/bin/getconf _NPROCESSORS_ONLN)}"
if [[ ! "$parallel_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: native bridge parallelism must be a positive integer\n' >&2
    exit 1
fi
if [[ "$development_build_only" == 1 ]]; then
    # The caller owns focused validation of changed behavior. Compile the real
    # contract target in its retained tree; do not replay CTest, package scans
    # or link-probe qualification during an incremental Debug iteration.
    "$cmake_bin" --build "$build_root" --target macscope_native_decompiler_contract --parallel "$parallel_jobs"
    archive="$build_root/libmacscope_native_decompiler_contract.a"
    link_inputs="$build_root/macscope-native-decompiler-link-inputs.xcfilelist"
    printf '%s\n' "$archive" \
        "$materialization_root/package/lib/libdecomp.a" \
        "$materialization_root/package/lib/libsla.a" "$zlib_input" > "$link_inputs"
    printf 'native_validation=not-run (focused Debug owner)\narchive=%s\nlink_inputs=%s\n' "$archive" "$link_inputs"
    exit 0
fi
"$cmake_bin" --build "$build_root" --parallel "$parallel_jobs"
# The provider-location case is registered with CTest below; it runs once there.
representative_binary="$build_root/macscope_native_decompiler_relocatable_link_probe"
if [[ ! -x "$representative_binary" ]]; then
    printf 'ERROR: representative relocatable executable is unavailable\n' >&2
    exit 1
fi
"$representative_binary" "$materialization_root"
performance_core_count=$(/usr/sbin/sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || true)
if [[ ! "$performance_core_count" =~ ^[1-9][0-9]*$ ]]; then
    performance_core_count=$(/usr/bin/getconf _NPROCESSORS_ONLN)
fi
native_ctest_jobs="${MACSCOPE_NATIVE_CTEST_JOBS:-${CTEST_PARALLEL_LEVEL:-$performance_core_count}}"
if [[ ! "$native_ctest_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: native bridge CTest parallelism must be a positive integer\n' >&2
    exit 1
fi
if [[ -n "$qualification_report_dir" ]]; then
    "$python" -B "$script_dir/native_qualification_report.py" run-ctest \
        --repository-root "$repository_root" --build-root "$build_root" \
        --report-dir "$qualification_report_dir" --materialization-root "$materialization_root" \
        --profile none --developer-dir "$developer_dir" --ctest "$ctest_bin" --jobs "$native_ctest_jobs"
else
    "$ctest_bin" --test-dir "$build_root" --parallel "$native_ctest_jobs" --output-on-failure --no-tests=error
fi

archive="$build_root/libmacscope_native_decompiler_contract.a"
decompiler_input="$materialization_root/package/lib/libdecomp.a"
sleigh_input="$materialization_root/package/lib/libsla.a"
for input in "$archive" "$decompiler_input" "$sleigh_input" "$zlib_input"; do
    if [[ ! -f "$input" ]]; then
        printf 'ERROR: required final-link input is unavailable\n' >&2
        exit 1
    fi
done
if [[ $(xcrun lipo -archs "$archive") != arm64 ]]; then
    printf 'ERROR: contract archive is not arm64-only\n' >&2
    exit 1
fi
representative_file=$("$file_bin" -b "$representative_binary")
if [[ "$representative_file" != "Mach-O 64-bit executable arm64" ]]; then
    printf 'ERROR: representative binary is not an arm64 Mach-O executable\n' >&2
    exit 1
fi
if [[ $(xcrun lipo -archs "$representative_binary") != arm64 ]]; then
    printf 'ERROR: representative binary is not arm64-only\n' >&2
    exit 1
fi

load_commands="$build_root/macscope-native-decompiler-link-probe.otool-l.txt"
dependencies="$build_root/macscope-native-decompiler-link-probe.otool-L.txt"
xcrun otool -l "$representative_binary" > "$load_commands"
xcrun otool -L "$representative_binary" > "$dependencies"
if /usr/bin/grep -E 'cmd LC_RPATH|cmd LC_ID_DYLIB' "$load_commands" >/dev/null; then
    printf 'ERROR: representative binary has a forbidden rpath or dylib install name\n' >&2
    exit 1
fi

dependency_count=0
saw_zlib=0
saw_libcxx=0
saw_libsystem=0
while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    dependency_count=$((dependency_count + 1))
    case "$dependency" in
        /usr/lib/libz.1.dylib) saw_zlib=1 ;;
        /usr/lib/libc++.1.dylib) saw_libcxx=1 ;;
        /usr/lib/libSystem.B.dylib) saw_libsystem=1 ;;
        *)
            printf 'ERROR: representative binary has an unexpected dynamic dependency\n' >&2
            exit 1
            ;;
    esac
done < <(/usr/bin/tail -n +2 "$dependencies" | /usr/bin/awk '{print $1}')
if [[ $dependency_count -ne 3 || $saw_zlib -ne 1 || \
      $saw_libcxx -ne 1 || $saw_libsystem -ne 1 ]]; then
    printf 'ERROR: representative binary dependency closure is incomplete\n' >&2
    exit 1
fi

scan_artifact() {
    local artifact=$1
    local label=$2
    shift 2
    local strings_file="$build_root/.macscope-native-decompiler-$label-strings-$$"
    "$strings_bin" -a "$artifact" > "$strings_file"
    local forbidden
    for forbidden in "$@"; do
        [[ -n "$forbidden" ]] || continue
        if /usr/bin/grep -F -- "$forbidden" "$strings_file" >/dev/null; then
            rm -f "$strings_file"
            printf 'ERROR: inspected native artifact contains a forbidden local path\n' >&2
            exit 1
        fi
    done
    rm -f "$strings_file"
}

strict_forbidden_paths=(
    "$repository_root"
    "$source_root"
    "$build_root"
    "$materialization_root"
    "${HOME:-}"
    /private/tmp
    /Users/
    /home/
    DerivedData
)
scan_artifact "$archive" contract "${strict_forbidden_paths[@]}"
scan_artifact "$representative_binary" executable "${strict_forbidden_paths[@]}"

# Upstream archives can contain their public build-host provenance in unused
# members. Scan every final-link input for this checkout's private/local paths,
# then prove that every generic upstream home-path candidate is absent from the
# fully linked representative executable.
upstream_inputs=("$decompiler_input" "$sleigh_input" "$zlib_input")
local_forbidden_paths=(
    "$repository_root"
    "$source_root"
    "$build_root"
    "$materialization_root"
    "${HOME:-}"
    /private/tmp
    DerivedData
)
for input in "${upstream_inputs[@]}"; do
    scan_artifact "$input" upstream "${local_forbidden_paths[@]}"
done
upstream_home_paths="$build_root/macscope-native-decompiler-upstream-home-paths.txt"
for input in "${upstream_inputs[@]}"; do
    "$strings_bin" -a "$input"
done | /usr/bin/grep -Eo '/(Users|home)/[^[:space:][:cntrl:]]+' | \
    /usr/bin/sort -u > "$upstream_home_paths" || true
representative_strings="$build_root/.macscope-native-decompiler-representative-strings-$$"
"$strings_bin" -a "$representative_binary" > "$representative_strings"
while IFS= read -r upstream_home_path; do
    [[ -n "$upstream_home_path" ]] || continue
    if /usr/bin/grep -F -- "$upstream_home_path" "$representative_strings" >/dev/null; then
        rm -f "$representative_strings"
        printf 'ERROR: upstream build-host path leaked into representative binary\n' >&2
        exit 1
    fi
done < "$upstream_home_paths"
rm -f "$representative_strings"

inspection="$build_root/macscope-native-decompiler-link-probe-inspection.txt"
{
    printf 'file=%s\n' "$representative_file"
    printf 'architectures=%s\n' "$(xcrun lipo -archs "$representative_binary")"
    printf 'dynamic_dependencies=%s\n' "$dependency_count"
    printf 'rpaths=0\n'
    printf 'dylib_install_names=0\n'
    printf 'upstream_home_path_candidates=%s\n' \
        "$(/usr/bin/wc -l < "$upstream_home_paths" | tr -d ' ')"
} > "$inspection"

link_inputs="$build_root/macscope-native-decompiler-link-inputs.xcfilelist"
printf '%s\n' \
    "$archive" \
    "$decompiler_input" \
    "$sleigh_input" \
    "$zlib_input" > "$link_inputs"

final_wrapper_revision=$(/usr/bin/python3 -B "$identity_helper" \
    --repository-root "$repository_root" --profile wrapper)
if [[ "$final_wrapper_revision" != "$wrapper_revision" ]]; then
    printf 'ERROR: declared native source bytes changed during the build\n' >&2
    exit 1
fi

if [[ -n "$qualification_report_dir" ]]; then
    "$python" -B "$script_dir/native_qualification_report.py" finalize \
        --repository-root "$repository_root" --build-root "$build_root" \
        --report-dir "$qualification_report_dir" --materialization-root "$materialization_root" \
        --profile none --developer-dir "$developer_dir"
fi

printf 'archive=%s\n' "$archive"
printf 'link_inputs=%s\n' "$link_inputs"
printf 'representative_binary=%s\n' "$representative_binary"
printf 'inspection=%s\n' "$inspection"
