#!/usr/bin/env bash
# Shared MacScope build policy for the Xcode 27 toolchain.
#
# Source this file before invoking Xcode, Swift, or XcodeGen-backed validation.
# The policy intentionally accepts every Xcode 27 beta, RC, and release build;
# transient build numbers are not pinned.

macscope_xcode27_fail() {
  echo "ERROR: MacScope requires the Xcode 27 toolchain: $*" >&2
  return 1
}

macscope_xcode27_guard() {
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  DEVELOPER_DIR="${DEVELOPER_DIR%/}"
  export DEVELOPER_DIR

  [[ "$(/usr/bin/uname -m)" == "arm64" ]] ||
    macscope_xcode27_fail "build host architecture is $(/usr/bin/uname -m), expected arm64" || return 1
  [[ -d "${DEVELOPER_DIR}" ]] ||
    macscope_xcode27_fail "DEVELOPER_DIR does not exist: ${DEVELOPER_DIR}" || return 1

  local macos_version macos_major
  macos_version="$(/usr/bin/sw_vers -productVersion 2>&1)" || {
    macscope_xcode27_fail "the build host macOS version could not be determined"
    return 1
  }
  macos_major="${macos_version%%.*}"
  [[ "${macos_major}" =~ ^[0-9]+$ ]] && (( macos_major >= 27 )) || {
    macscope_xcode27_fail "found macOS ${macos_version}, expected macOS 27.0 or newer"
    return 1
  }

  local xcode_version_output xcode_version_line xcode_version xcode_major
  xcode_version_output="$(/usr/bin/xcrun xcodebuild -version 2>&1)" || {
    macscope_xcode27_fail "xcodebuild is unavailable through DEVELOPER_DIR=${DEVELOPER_DIR}"
    return 1
  }
  xcode_version_line="${xcode_version_output%%$'\n'*}"
  xcode_version="${xcode_version_line#Xcode }"
  xcode_major="${xcode_version%%.*}"
  xcode_major="${xcode_major%% *}"
  [[ "${xcode_version_line}" == Xcode\ * && "${xcode_major}" == "27" ]] || {
    macscope_xcode27_fail "found '${xcode_version_line}', expected Xcode major version 27"
    return 1
  }

  local sdk_version sdk_major
  sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>&1)" || {
    macscope_xcode27_fail "the macOS SDK is unavailable through DEVELOPER_DIR=${DEVELOPER_DIR}"
    return 1
  }
  sdk_major="${sdk_version%%.*}"
  [[ "${sdk_major}" == "27" ]] || {
    macscope_xcode27_fail "found macOS SDK ${sdk_version}, expected SDK major version 27"
    return 1
  }

  local swift_path swift_version_output swift_version_line
  swift_path="$(/usr/bin/xcrun --find swift 2>&1)" || {
    macscope_xcode27_fail "Swift is unavailable through DEVELOPER_DIR=${DEVELOPER_DIR}"
    return 1
  }
  case "${swift_path}" in
    "${DEVELOPER_DIR}"/*) ;;
    *)
      macscope_xcode27_fail "xcrun resolved Swift outside the selected Xcode: ${swift_path}"
      return 1
      ;;
  esac

  swift_version_output="$(/usr/bin/xcrun swift --version 2>&1)" || {
    macscope_xcode27_fail "the selected Swift compiler version could not be determined"
    return 1
  }
  swift_version_line="${swift_version_output%%$'\n'*}"

  echo "==> Xcode 27 policy: macOS ${macos_version}; ${xcode_version_line}; macOS SDK ${sdk_version}; ${swift_version_line}; arm64"
}

macscope_xcode27_guard || { return 1 2>/dev/null || exit 1; }
