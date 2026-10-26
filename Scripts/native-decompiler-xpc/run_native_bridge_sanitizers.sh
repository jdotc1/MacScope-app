#!/bin/bash

set -euo pipefail

usage() {
    printf '%s\n' \
        'usage: run_native_bridge_sanitizers.sh --source-root PATH --build-root PATH' \
        '       --sanitizer <address|undefined> [--materialization-root PATH]' \
        '       [--qualification-report-dir ABSOLUTE_PATH]'
}

source_root=
build_root=
sanitizer=
materialization_root=${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}
qualification_report_dir=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root) source_root=${2:-}; shift 2 ;;
        --build-root) build_root=${2:-}; shift 2 ;;
        --sanitizer) sanitizer=${2:-}; shift 2 ;;
        --materialization-root) materialization_root=${2:-}; shift 2 ;;
        --qualification-report-dir)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            qualification_report_dir=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$source_root" || -z "$build_root" || -z "$materialization_root" ||
      ! "$sanitizer" =~ ^(address|undefined)$ ]]; then
    printf 'ERROR: source, build, materialization, and sanitizer inputs are required\n' >&2
    usage >&2
    exit 2
fi
if [[ $(uname -m) != arm64 ]]; then
    printf 'ERROR: native sanitizer qualification requires arm64\n' >&2
    exit 1
fi

source_root=$(cd "$source_root" && pwd -P)
materialization_root=$(cd "$materialization_root" && pwd -P)
/bin/mkdir -p "$build_root"
build_root=$(cd "$build_root" && pwd -P)/$sanitizer
/bin/mkdir -p "$build_root"

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repository_root=$(cd "$script_dir/../.." && pwd -P)
expected_source_root=$(cd "$repository_root/Tools/NativeDecompilerBridge" && pwd -P)
if [[ "$source_root" != "$expected_source_root" ]]; then
    printf 'ERROR: source root does not match the repository native bridge\n' >&2
    exit 1
fi

tool_path=${MACSCOPE_TOOL_SEARCH_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin}
resolve_tool() {
    local name=$1
    local value
    value=$(PATH="$tool_path" command -v "$name" 2>/dev/null || true)
    [[ -n "$value" ]] || { printf 'ERROR: missing tool: %s\n' "$name" >&2; exit 1; }
    printf '%s' "$value"
}
cmake_bin=$(resolve_tool cmake)
ctest_bin=$(resolve_tool ctest)
ninja_bin=$(resolve_tool ninja)
clangxx=$(xcrun --find clang++)
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
wrapper_revision=$(python3 -B "$script_dir/native_decompiler_source_identity.py" \
    --repository-root "$repository_root" --profile wrapper)
report_cmake_options=()
if [[ -n "$qualification_report_dir" ]]; then
    if [[ -n ${DEVELOPER_DIR:-} ]]; then
        developer_dir=$DEVELOPER_DIR
    else
        developer_dir=$(xcode-select -p)
    fi
    developer_dir=$(cd "$developer_dir" && pwd -P)
    export DEVELOPER_DIR="$developer_dir"
    report_cmake_options=(-DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=OFF)
fi

if [[ "$sanitizer" == address ]]; then
    export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1:abort_on_error=1}
    expected_sanitizer_flags=(-fsanitize=address -fno-omit-frame-pointer)
else
    export UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}
    expected_sanitizer_flags=(-fsanitize=undefined -fno-sanitize-recover=all)
fi
if [[ -n "$qualification_report_dir" ]]; then
    if [[ "$sanitizer" == address ]]; then
        export ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=1
    else
        export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
    fi
fi

# Keep the ordinary qualification input verified, but do not link its
# uninstrumented C++ archives into sanitizer tests. Inlined libc++ templates
# across that mixed boundary can produce false container-overflow reports.
# Build the same pinned source closure with matching instrumentation instead.
package_verifier="$repository_root/Scripts/native-decompiler-direct/verify_sleigh_package.py"
python3 -B "$package_verifier" verify \
    --materialization-root "$materialization_root" >/dev/null
native_source_work_root="$build_root/native-source"
"$repository_root/Scripts/dependencies/build_vendored_sleigh_native_source.sh" \
    --work-root "$native_source_work_root" \
    --sanitizer "$sanitizer" >/dev/null
materialization_root="$native_source_work_root/SleighNativeSource-$sanitizer/materialization"
python3 -B "$package_verifier" verify \
    --materialization-root "$materialization_root" \
    --expected-sanitizer "$sanitizer" >/dev/null

"$cmake_bin" \
    -S "$source_root" \
    -B "$build_root" \
    -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja_bin" \
    -DBUILD_TESTING=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
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
    "-DMACSCOPE_NATIVE_DECOMPILER_SANITIZER=$sanitizer" \
    ${report_cmake_options[@]+"${report_cmake_options[@]}"}

for flag in "${expected_sanitizer_flags[@]}"; do
    if ! /usr/bin/grep -F -- "$flag" "$build_root/build.ninja" >/dev/null; then
        printf 'ERROR: configured build did not materialize sanitizer flag: %s\n' "$flag" >&2
        exit 1
    fi
done

parallel_jobs=${CMAKE_BUILD_PARALLEL_LEVEL:-$(/usr/bin/getconf _NPROCESSORS_ONLN)}
"$cmake_bin" --build "$build_root" --parallel "$parallel_jobs"
performance_core_count=$(/usr/sbin/sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || true)
if [[ ! "$performance_core_count" =~ ^[1-9][0-9]*$ ]]; then
    performance_core_count=$(/usr/bin/getconf _NPROCESSORS_ONLN)
fi
native_ctest_jobs=${MACSCOPE_NATIVE_CTEST_JOBS:-${CTEST_PARALLEL_LEVEL:-$performance_core_count}}
if [[ ! "$native_ctest_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: native sanitizer CTest parallelism must be a positive integer\n' >&2
    exit 1
fi
if [[ -n "$qualification_report_dir" ]]; then
    python3 -B "$script_dir/native_qualification_report.py" run-ctest \
        --repository-root "$repository_root" --build-root "$build_root" \
        --report-dir "$qualification_report_dir" --materialization-root "$materialization_root" \
        --profile "$sanitizer" --developer-dir "$developer_dir" --ctest "$ctest_bin" --jobs "$native_ctest_jobs"
    final_wrapper_revision=$(python3 -B "$script_dir/native_decompiler_source_identity.py" \
        --repository-root "$repository_root" --profile wrapper)
    if [[ "$final_wrapper_revision" != "$wrapper_revision" ]]; then
        printf 'ERROR: declared native source bytes changed during sanitizer qualification\n' >&2
        exit 1
    fi
    python3 -B "$script_dir/native_qualification_report.py" finalize \
        --repository-root "$repository_root" --build-root "$build_root" \
        --report-dir "$qualification_report_dir" --materialization-root "$materialization_root" \
        --profile "$sanitizer" --developer-dir "$developer_dir"
else
    "$ctest_bin" --test-dir "$build_root" --parallel "$native_ctest_jobs" --output-on-failure --no-tests=error
fi
