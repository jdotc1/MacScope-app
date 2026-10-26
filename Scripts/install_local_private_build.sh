#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install_local_private_build.sh --app-bundle /absolute/path/MacScope.app [--configuration Release]
    [--signing-receipt /absolute/path/source-signing.receipt.json]

  install_local_private_build.sh --mode installed-acceptance \
    --integration-ref refs/remotes/<remote>/<branch> \
    --qualification-receipt /absolute/path/QUALIFICATION_INPUTS.json \
    --qualification-run-id <stable-id> \
    --qualification-run-nonce <lowercase-sha256> \
    --predecessor-observations-sha256 <lowercase-sha256> \
    --candidate-artifact-root /absolute/external/candidate-root \
    --work-root /absolute/external/empty-work-root \
    --destination /Applications/MacScope.app \
    --signing development \
    --begin-timeout-seconds <0.01..86400> \
    --compiler-timeout-seconds <0.01..86400> \
    --report-timeout-seconds <0.01..86400> \
    --commit-timeout-seconds <0.01..86400> \
    --rollback-timeout-seconds <0.01..86400>

The ordinary mode keeps the existing private local install behavior. Installed
acceptance is never implicit: it delegates the entire begin/eight-gate/
commit-or-rollback sequence to the canonical transaction driver, validates its
committed manifest, and only then invokes the final local-candidate validator.
Successful installed-acceptance stdout is one absolute final-receipt path.
EOF
}

usage_error() {
  echo "ERROR: $*" >&2
  usage >&2
  exit 2
}

ALL_ARGUMENTS=("$@")
MODE_COUNT=0
REQUESTED_MODE=""
for ((ARGUMENT_INDEX = 0; ARGUMENT_INDEX < ${#ALL_ARGUMENTS[@]}; ARGUMENT_INDEX++)); do
  if [[ "${ALL_ARGUMENTS[$ARGUMENT_INDEX]}" == "--mode" ]]; then
    MODE_COUNT=$((MODE_COUNT + 1))
    ((ARGUMENT_INDEX + 1 < ${#ALL_ARGUMENTS[@]})) || usage_error "missing value for --mode"
    REQUESTED_MODE="${ALL_ARGUMENTS[$((ARGUMENT_INDEX + 1))]}"
  fi
done
((MODE_COUNT <= 1)) || usage_error "--mode may be specified only once"
if ((MODE_COUNT == 1)) && [[ "$REQUESTED_MODE" != "installed-acceptance" ]]; then
  usage_error "unsupported mode: $REQUESTED_MODE"
fi

if ((MODE_COUNT == 0)); then
  SOURCE=""
  CONFIGURATION="Release"
  while (($#)); do
    case "$1" in
      --app-bundle) SOURCE="${2:?missing value for --app-bundle}"; shift 2 ;;
      --signing-receipt) SIGNING_RECEIPT="${2:?missing value for --signing-receipt}"; shift 2 ;;
      --configuration) CONFIGURATION="${2:?missing value for --configuration}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "$SOURCE" ]] || { echo "ERROR: --app-bundle is required" >&2; exit 2; }
  [[ "$SOURCE" == /* ]] || { echo "ERROR: --app-bundle must be absolute" >&2; exit 2; }
  [[ "$SOURCE" == */MacScope.app ]] || { echo "ERROR: source must end in MacScope.app" >&2; exit 1; }
  [[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { echo "ERROR: source must be a non-symlink directory: $SOURCE" >&2; exit 1; }

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  RECEIPT_HELPER="$ROOT_DIR/qualification/install_bundle_receipt.py"
  SIGNING_RECEIPT="${SIGNING_RECEIPT:-${SOURCE%/*}/MacScope.install-signing.receipt.json}"
  [[ "$CONFIGURATION" == Release ]] || { echo "ERROR: install accepts only Release" >&2; exit 2; }
  [[ "$SIGNING_RECEIPT" == /* ]] || { echo "ERROR: signing receipt must be absolute" >&2; exit 2; }
  [[ -z "${MACSCOPE_INSTALL_PREFLIGHT:-}" ]] || { echo "ERROR: preflight override is unsupported; signing receipt cannot be bypassed" >&2; exit 2; }
  DITTO="${MACSCOPE_INSTALL_DITTO:-/usr/bin/ditto}"
  DESTINATION="${MACSCOPE_INSTALL_DESTINATION:-/Applications/MacScope.app}"
  [[ "$DESTINATION" == /* && "$DESTINATION" == */MacScope.app ]] || { echo "ERROR: destination must be an absolute MacScope.app path" >&2; exit 2; }
  [[ "$DESTINATION" != "$SOURCE" ]] || { echo "ERROR: source and destination must differ" >&2; exit 1; }
  DEST_PARENT="${DESTINATION%/*}"
  [[ -d "$DEST_PARENT" && ! -L "$DEST_PARENT" ]] || { echo "ERROR: destination parent must be a non-symlink directory: $DEST_PARENT" >&2; exit 1; }
  [[ -f "$RECEIPT_HELPER" ]] || { echo "ERROR: signing receipt helper is missing" >&2; exit 1; }
  [[ -x "$DITTO" ]] || { echo "ERROR: ditto is not executable: $DITTO" >&2; exit 1; }

  fail() { echo "ERROR: $*" >&2; exit 1; }
  STAGE_ROOT=""
  BACKUP="${DEST_PARENT}/.MacScope.previous.$$"
  QUARANTINE="${DEST_PARENT}/.MacScope.failed.$$"
  cleanup() {
    if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
      /bin/rm -rf "$STAGE_ROOT"
    fi
  }
  trap cleanup EXIT

  PREFLIGHT_DEST="${DESTINATION}.preflight.$$"
  [[ ! -e "$PREFLIGHT_DEST" ]] || fail "preflight destination token already exists: $PREFLIGHT_DEST"
  /usr/bin/python3 -B "$RECEIPT_HELPER" admit --source "$SOURCE" --receipt "$SIGNING_RECEIPT" || fail "source signing admission rejected the build"

  if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || fail "prior destination is not a recoverable app directory: $DESTINATION"
    [[ ! -e "$BACKUP" ]] || fail "recovery path already exists; refusing overwrite: $BACKUP"
  fi

  STAGE_ROOT="$(mktemp -d "${DEST_PARENT}/.MacScope.stage.XXXXXX")"
  STAGED_APP="$STAGE_ROOT/MacScope.app"
  "$DITTO" --rsrc --extattr --acl "$SOURCE" "$STAGED_APP" || fail "same-volume staging copy failed"
  [[ -d "$STAGED_APP" && ! -L "$STAGED_APP" ]] || fail "staging did not produce a recoverable MacScope.app"

  if [[ -e "$DESTINATION" ]]; then
    mv "$DESTINATION" "$BACKUP" || fail "could not move prior app to recoverable backup; destination left untouched"
  fi
  if ! mv "$STAGED_APP" "$DESTINATION"; then
    if [[ -e "$BACKUP" && ! -e "$DESTINATION" ]]; then mv "$BACKUP" "$DESTINATION" || true; fi
    fail "could not install staged app; any prior app remains at $BACKUP if rollback was incomplete"
  fi
  if ! /usr/bin/python3 -B "$RECEIPT_HELPER" compare --source "$SOURCE" --destination "$DESTINATION" --receipt "$SIGNING_RECEIPT"; then
    [[ ! -e "$QUARANTINE" ]] || fail "comparison failed and quarantine path already exists; installed app retained at $DESTINATION"
    mv "$DESTINATION" "$QUARANTINE" || fail "comparison failed; could not quarantine new app and prior app was not restored"
    if [[ -e "$BACKUP" ]]; then
      mv "$BACKUP" "$DESTINATION" || fail "comparison failed; prior app retained at $BACKUP and new app retained at $QUARANTINE"
    fi
    fail "post-install closed-bundle comparison failed; new app quarantined at $QUARANTINE"
  fi

  if [[ -e "$BACKUP" ]]; then
    echo "PASS: installed $DESTINATION; prior app preserved at $BACKUP"
  else
    echo "PASS: installed $DESTINATION and post-install closed-bundle comparison passed"
  fi
  exit 0
fi

INTEGRATION_REF=""
QUALIFICATION_RECEIPT=""
QUALIFICATION_RUN_ID=""
QUALIFICATION_RUN_NONCE=""
PREDECESSOR_OBSERVATIONS_SHA256=""
CANDIDATE_ARTIFACT_ROOT=""
WORK_ROOT=""
DESTINATION=""
SIGNING_POLICY=""
BEGIN_TIMEOUT=""
COMPILER_TIMEOUT=""
REPORT_TIMEOUT=""
COMMIT_TIMEOUT=""
ROLLBACK_TIMEOUT=""

SEEN_MODE=0
SEEN_INTEGRATION_REF=0
SEEN_QUALIFICATION_RECEIPT=0
SEEN_QUALIFICATION_RUN_ID=0
SEEN_QUALIFICATION_RUN_NONCE=0
SEEN_PREDECESSOR=0
SEEN_CANDIDATE_ROOT=0
SEEN_WORK_ROOT=0
SEEN_DESTINATION=0
SEEN_SIGNING=0
SEEN_BEGIN_TIMEOUT=0
SEEN_COMPILER_TIMEOUT=0
SEEN_REPORT_TIMEOUT=0
SEEN_COMMIT_TIMEOUT=0
SEEN_ROLLBACK_TIMEOUT=0

require_value() { (($# >= 2)) || usage_error "missing value for $1"; }

while (($#)); do
  case "$1" in
    --mode)
      require_value "$@"; ((SEEN_MODE == 0)) || usage_error "duplicate --mode"
      [[ "$2" == "installed-acceptance" ]] || usage_error "unsupported mode: $2"
      SEEN_MODE=1; shift 2 ;;
    --integration-ref)
      require_value "$@"; ((SEEN_INTEGRATION_REF == 0)) || usage_error "duplicate --integration-ref"
      INTEGRATION_REF="$2"; SEEN_INTEGRATION_REF=1; shift 2 ;;
    --qualification-receipt)
      require_value "$@"; ((SEEN_QUALIFICATION_RECEIPT == 0)) || usage_error "duplicate --qualification-receipt"
      QUALIFICATION_RECEIPT="$2"; SEEN_QUALIFICATION_RECEIPT=1; shift 2 ;;
    --qualification-run-id)
      require_value "$@"; ((SEEN_QUALIFICATION_RUN_ID == 0)) || usage_error "duplicate --qualification-run-id"
      QUALIFICATION_RUN_ID="$2"; SEEN_QUALIFICATION_RUN_ID=1; shift 2 ;;
    --qualification-run-nonce)
      require_value "$@"; ((SEEN_QUALIFICATION_RUN_NONCE == 0)) || usage_error "duplicate --qualification-run-nonce"
      QUALIFICATION_RUN_NONCE="$2"; SEEN_QUALIFICATION_RUN_NONCE=1; shift 2 ;;
    --predecessor-observations-sha256)
      require_value "$@"; ((SEEN_PREDECESSOR == 0)) || usage_error "duplicate --predecessor-observations-sha256"
      PREDECESSOR_OBSERVATIONS_SHA256="$2"; SEEN_PREDECESSOR=1; shift 2 ;;
    --candidate-artifact-root)
      require_value "$@"; ((SEEN_CANDIDATE_ROOT == 0)) || usage_error "duplicate --candidate-artifact-root"
      CANDIDATE_ARTIFACT_ROOT="$2"; SEEN_CANDIDATE_ROOT=1; shift 2 ;;
    --work-root)
      require_value "$@"; ((SEEN_WORK_ROOT == 0)) || usage_error "duplicate --work-root"
      WORK_ROOT="$2"; SEEN_WORK_ROOT=1; shift 2 ;;
    --destination)
      require_value "$@"; ((SEEN_DESTINATION == 0)) || usage_error "duplicate --destination"
      DESTINATION="$2"; SEEN_DESTINATION=1; shift 2 ;;
    --signing)
      require_value "$@"; ((SEEN_SIGNING == 0)) || usage_error "duplicate --signing"
      SIGNING_POLICY="$2"; SEEN_SIGNING=1; shift 2 ;;
    --begin-timeout-seconds)
      require_value "$@"; ((SEEN_BEGIN_TIMEOUT == 0)) || usage_error "duplicate --begin-timeout-seconds"
      BEGIN_TIMEOUT="$2"; SEEN_BEGIN_TIMEOUT=1; shift 2 ;;
    --compiler-timeout-seconds)
      require_value "$@"; ((SEEN_COMPILER_TIMEOUT == 0)) || usage_error "duplicate --compiler-timeout-seconds"
      COMPILER_TIMEOUT="$2"; SEEN_COMPILER_TIMEOUT=1; shift 2 ;;
    --report-timeout-seconds)
      require_value "$@"; ((SEEN_REPORT_TIMEOUT == 0)) || usage_error "duplicate --report-timeout-seconds"
      REPORT_TIMEOUT="$2"; SEEN_REPORT_TIMEOUT=1; shift 2 ;;
    --commit-timeout-seconds)
      require_value "$@"; ((SEEN_COMMIT_TIMEOUT == 0)) || usage_error "duplicate --commit-timeout-seconds"
      COMMIT_TIMEOUT="$2"; SEEN_COMMIT_TIMEOUT=1; shift 2 ;;
    --rollback-timeout-seconds)
      require_value "$@"; ((SEEN_ROLLBACK_TIMEOUT == 0)) || usage_error "duplicate --rollback-timeout-seconds"
      ROLLBACK_TIMEOUT="$2"; SEEN_ROLLBACK_TIMEOUT=1; shift 2 ;;
    --app-bundle|--configuration) usage_error "$1 cannot be mixed with installed-acceptance mode" ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown installed-acceptance argument: $1" ;;
  esac
done

((SEEN_MODE == 1)) || usage_error "--mode installed-acceptance is required"
((SEEN_INTEGRATION_REF == 1)) || usage_error "--integration-ref is required"
((SEEN_QUALIFICATION_RECEIPT == 1)) || usage_error "--qualification-receipt is required"
((SEEN_QUALIFICATION_RUN_ID == 1)) || usage_error "--qualification-run-id is required"
((SEEN_QUALIFICATION_RUN_NONCE == 1)) || usage_error "--qualification-run-nonce is required"
((SEEN_PREDECESSOR == 1)) || usage_error "--predecessor-observations-sha256 is required"
((SEEN_CANDIDATE_ROOT == 1)) || usage_error "--candidate-artifact-root is required"
((SEEN_WORK_ROOT == 1)) || usage_error "--work-root is required"
((SEEN_DESTINATION == 1)) || usage_error "--destination is required"
((SEEN_SIGNING == 1)) || usage_error "--signing development is required"
((SEEN_BEGIN_TIMEOUT == 1)) || usage_error "--begin-timeout-seconds is required"
((SEEN_COMPILER_TIMEOUT == 1)) || usage_error "--compiler-timeout-seconds is required"
((SEEN_REPORT_TIMEOUT == 1)) || usage_error "--report-timeout-seconds is required"
((SEEN_COMMIT_TIMEOUT == 1)) || usage_error "--commit-timeout-seconds is required"
((SEEN_ROLLBACK_TIMEOUT == 1)) || usage_error "--rollback-timeout-seconds is required"
[[ "$SIGNING_POLICY" == "development" ]] || usage_error "installed acceptance requires --signing development"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$ROOT_DIR/.." && pwd -P)"
PLAN_COMPILER="$ROOT_DIR/reconstruction/compile_installed_acceptance_gate_plan.py"
TRANSACTION_DRIVER="$ROOT_DIR/reconstruction/run_installed_acceptance_transaction.py"
FINAL_VALIDATOR="$ROOT_DIR/reconstruction/validate_final_local_candidate.py"
RESULT_OUTPUT="$WORK_ROOT/InstalledAcceptanceTransaction.result.json"
FINAL_OUTPUT="$WORK_ROOT/FinalLocalCandidate.receipt.json"

/usr/bin/python3 -B - "$REPOSITORY_ROOT" "$PLAN_COMPILER" "$TRANSACTION_DRIVER" "$FINAL_VALIDATOR" \
  "$INTEGRATION_REF" "$QUALIFICATION_RECEIPT" "$QUALIFICATION_RUN_ID" "$QUALIFICATION_RUN_NONCE" \
  "$PREDECESSOR_OBSERVATIONS_SHA256" "$CANDIDATE_ARTIFACT_ROOT" "$WORK_ROOT" "$DESTINATION" \
  "$BEGIN_TIMEOUT" "$COMPILER_TIMEOUT" "$REPORT_TIMEOUT" "$COMMIT_TIMEOUT" "$ROLLBACK_TIMEOUT" \
  "$RESULT_OUTPUT" "$FINAL_OUTPUT" <<'PY'
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

(repository_raw, compiler_raw, driver_raw, validator_raw, integration_ref, receipt_raw,
 run_id, run_nonce, predecessor, candidate_raw, work_raw, destination_raw,
 begin_timeout, compiler_timeout, report_timeout, commit_timeout, rollback_timeout,
 result_raw, final_raw) = sys.argv[1:]

def refuse(message):
    print("ERROR: installed acceptance refused: " + message, file=sys.stderr)
    raise SystemExit(2)

def existing_directory(raw, label):
    path = Path(raw)
    if not path.is_absolute(): refuse(label + " must be absolute")
    try:
        metadata, resolved = path.lstat(), path.resolve(strict=True)
    except OSError as error:
        refuse(f"{label} is unavailable: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or resolved != path:
        refuse(label + " must be a canonical non-symlink directory")
    return path

def existing_file(raw, label, executable=False):
    path = Path(raw)
    if not path.is_absolute(): refuse(label + " must be absolute")
    try:
        metadata, resolved = path.lstat(), path.resolve(strict=True)
    except OSError as error:
        refuse(f"{label} is unavailable: {error}")
    if (not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_nlink != 1 or resolved != path):
        refuse(label + " must be a canonical non-symlink single-link regular file")
    if executable and not os.access(path, os.X_OK): refuse(label + " must be executable")
    return path

def related(first, second):
    return first == second or first in second.parents or second in first.parents

def git_value(repository, arguments, label, allow_empty=False):
    environment = {
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    try:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), *arguments],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
    except OSError as error:
        refuse(f"cannot resolve {label} locally: {error}")
    if completed.returncode != 0 or completed.stderr or len(completed.stdout) > 16384:
        refuse(f"cannot resolve {label} locally")
    try:
        value = completed.stdout.decode("utf-8").removesuffix("\n")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}")
    if (not value and not allow_empty) or "\n" in value or "\r" in value or "\x00" in value:
        refuse(f"{label} is malformed")
    return value

repository = existing_directory(repository_raw, "repository root")
helpers = repository / "Scripts" / "reconstruction"
compiler = existing_file(compiler_raw, "gate-plan compiler", executable=True)
driver = existing_file(driver_raw, "installed-acceptance transaction driver")
validator = existing_file(validator_raw, "final local-candidate validator")
if compiler != helpers / "compile_installed_acceptance_gate_plan.py": refuse("gate-plan compiler path is not frozen")
if driver != helpers / "run_installed_acceptance_transaction.py": refuse("transaction driver path is not frozen")
if validator != helpers / "validate_final_local_candidate.py": refuse("final validator path is not frozen")

receipt = existing_file(receipt_raw, "qualification receipt")
if receipt.name != "QUALIFICATION_INPUTS.json": refuse("qualification receipt must be named QUALIFICATION_INPUTS.json")
candidate = existing_directory(candidate_raw, "candidate artifact root")
existing_file(str(candidate / "candidate.json"), "candidate identity")
existing_file(str(candidate / "NativeLivePreparation.receipt.json"), "native live preparation receipt")
work = existing_directory(work_raw, "acceptance work root")
if any(work.iterdir()): refuse("acceptance work root must be empty")
if related(candidate, repository): refuse("candidate artifact root must be outside the repository")
if related(work, repository): refuse("acceptance work root must be outside the repository")
if related(candidate, work): refuse("candidate artifact root and acceptance work root must be disjoint")
if work == receipt or work in receipt.parents: refuse("qualification receipt must not be beneath the acceptance work root")

destination = Path(destination_raw)
if destination != Path("/Applications/MacScope.app"): refuse("destination must be exactly /Applications/MacScope.app")
destination_parent = existing_directory(str(destination.parent), "destination parent")
if destination.exists() or destination.is_symlink(): existing_directory(str(destination), "installed destination")
if related(work, destination) or related(work, destination_parent): refuse("work root must be disjoint from destination")
if related(candidate, destination): refuse("candidate root must be disjoint from destination")

ref_match = re.fullmatch(
    r"refs/remotes/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/(.+)",
    integration_ref,
)
remote_name = ref_match.group(1) if ref_match is not None else ""
suffix = ref_match.group(2) if ref_match is not None else ""
ref_parts = suffix.split("/")
if (len(integration_ref) > 256
        or any(ord(character) < 0x20 or ord(character) == 0x7f for character in integration_ref)
        or ".." in integration_ref or "@{" in integration_ref or "//" in integration_ref
        or ref_match is None
        or remote_name.endswith(".") or remote_name.lower().endswith(".lock")
        or suffix == "HEAD"
        or suffix.endswith("/")
        or any(part in {"", ".", ".."} or part.startswith(".")
               or part.endswith(".") or part.lower().endswith(".lock") for part in ref_parts)):
    refuse("integration ref contains forbidden revision or path syntax")
git_value(
    repository,
    ["check-ref-format", integration_ref],
    "integration ref format",
    allow_empty=True,
)
for revision_suffix, label in (("^{commit}", "integration commit"), ("^{tree}", "integration tree")):
    identity = git_value(
        repository,
        ["rev-parse", "--verify", integration_ref + revision_suffix],
        label,
    )
    if re.fullmatch(r"[0-9a-f]{40}", identity) is None:
        refuse(label + " is not a lowercase 40-hex Git identity")
remote_url = git_value(
    repository,
    ["config", "--local", "--no-includes", "--get-all", f"remote.{remote_name}.url"],
    f"local integration remote {remote_name} URL",
)
existing_file(str(helpers / "integration_remote_authority.py"), "integration remote authority policy")
sys.path.insert(0, str(repository))
from Scripts.reconstruction.integration_remote_authority import validate_integration_remote_url
try:
    validate_integration_remote_url(remote_url)
except ValueError as error:
    refuse(f"remote {remote_name}: {error}")
if re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", run_id) is None: refuse("qualification run ID is not canonical")
for value, label in ((run_nonce, "qualification run nonce"), (predecessor, "predecessor observations digest")):
    if re.fullmatch(r"[0-9a-f]{64}", value) is None: refuse(label + " must be a lowercase SHA-256")
for value, label in ((begin_timeout, "begin"), (compiler_timeout, "compiler"),
                     (report_timeout, "report"), (commit_timeout, "commit"),
                     (rollback_timeout, "rollback")):
    try: parsed = float(value)
    except ValueError: refuse(label + " timeout must be numeric")
    if not math.isfinite(parsed) or not 0.01 <= parsed <= 86400.0:
        refuse(label + " timeout must be finite and between 0.01 and 86400")
for raw, name, label in ((result_raw, "InstalledAcceptanceTransaction.result.json", "transaction result"),
                         (final_raw, "FinalLocalCandidate.receipt.json", "final receipt")):
    path = Path(raw)
    if not path.is_absolute() or path.parent != work or path.name != name:
        refuse(label + " output is not the governed direct-child path")
    if os.path.lexists(path): refuse(label + " output already exists")
PY

classify_helper_stdout() {
  /usr/bin/python3 -B -c '
import sys

expected = (sys.argv[1] + "\n").encode("utf-8")
observed_length = 0
matches = True
while True:
    chunk = sys.stdin.buffer.read(65536)
    if not chunk:
        break
    start = observed_length
    observed_length += len(chunk)
    if matches and chunk != expected[start:observed_length]:
        matches = False
if observed_length == 0:
    raise SystemExit(0)
if matches and observed_length == len(expected):
    raise SystemExit(1)
raise SystemExit(2)
' "$1"
}

DRIVER_ARGUMENTS=(
  /usr/bin/python3 -B "$TRANSACTION_DRIVER"
  --gate-plan-compiler "$PLAN_COMPILER"
  --qualification-receipt "$QUALIFICATION_RECEIPT"
  --qualification-run-id "$QUALIFICATION_RUN_ID"
  --qualification-run-nonce "$QUALIFICATION_RUN_NONCE"
  --predecessor-observations-sha256 "$PREDECESSOR_OBSERVATIONS_SHA256"
  --candidate-artifact-root "$CANDIDATE_ARTIFACT_ROOT"
  --work-root "$WORK_ROOT"
  --installed-app "$DESTINATION"
  --begin-timeout-seconds "$BEGIN_TIMEOUT"
  --compiler-timeout-seconds "$COMPILER_TIMEOUT"
  --report-timeout-seconds "$REPORT_TIMEOUT"
  --commit-timeout-seconds "$COMMIT_TIMEOUT"
  --rollback-timeout-seconds "$ROLLBACK_TIMEOUT"
  --result-output "$RESULT_OUTPUT"
)

set +e
"${DRIVER_ARGUMENTS[@]}" | classify_helper_stdout "$RESULT_OUTPUT"
DRIVER_PIPE_STATUSES=("${PIPESTATUS[@]}")
set -e
TRANSACTION_EXIT_STATUS="${DRIVER_PIPE_STATUSES[0]}"
DRIVER_STDOUT_CLASS="${DRIVER_PIPE_STATUSES[1]}"
if ((TRANSACTION_EXIT_STATUS != 0)); then
  ((DRIVER_STDOUT_CLASS == 0)) || echo "ERROR: transaction driver emitted forbidden stdout while failing" >&2
  exit "$TRANSACTION_EXIT_STATUS"
fi
if ((DRIVER_STDOUT_CLASS != 1)); then
  echo "ERROR: transaction driver stdout was not exactly the governed result path plus one LF" >&2
  exit 1
fi

# The transaction result has one schema authority: the independently maintained
# final-candidate validator below. Do not duplicate its closed schema or topology
# here; duplicate validators previously drifted after the installed Task 10
# result was added and could reject a valid transaction after commit.

VALIDATOR_ARGUMENTS=(
  /usr/bin/python3 -B "$FINAL_VALIDATOR"
  --transaction-result "$RESULT_OUTPUT"
  --integration-ref "$INTEGRATION_REF"
  --qualification-receipt "$QUALIFICATION_RECEIPT"
  --candidate-artifact-root "$CANDIDATE_ARTIFACT_ROOT"
  --output "$FINAL_OUTPUT"
)
set +e
"${VALIDATOR_ARGUMENTS[@]}" | classify_helper_stdout "$FINAL_OUTPUT"
VALIDATOR_PIPE_STATUSES=("${PIPESTATUS[@]}")
set -e
FINAL_VALIDATOR_EXIT_STATUS="${VALIDATOR_PIPE_STATUSES[0]}"
VALIDATOR_STDOUT_CLASS="${VALIDATOR_PIPE_STATUSES[1]}"
if ((FINAL_VALIDATOR_EXIT_STATUS != 0)); then
  ((VALIDATOR_STDOUT_CLASS == 0)) || echo "ERROR: final validator emitted forbidden stdout while failing" >&2
  exit "$FINAL_VALIDATOR_EXIT_STATUS"
fi
if ((VALIDATOR_STDOUT_CLASS != 1)); then
  echo "ERROR: final validator stdout was not exactly the governed receipt path plus one LF" >&2
  exit 1
fi

/usr/bin/python3 -B - "$FINAL_OUTPUT" <<'PY'
import json
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
try: metadata, resolved, payload = path.lstat(), path.resolve(strict=True), path.read_bytes()
except OSError as error:
    print(f"ERROR: final receipt is unavailable: {error}", file=sys.stderr)
    raise SystemExit(1)
if (resolved != path or not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600
        or not 0 < len(payload) <= 4 * 1024 * 1024):
    print("ERROR: final receipt is not one exact private bounded file", file=sys.stderr)
    raise SystemExit(1)
try:
    value = json.loads(payload.decode("utf-8"))
    canonical = json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True,
                           separators=(",", ":")).encode("utf-8")
except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
    print(f"ERROR: final receipt is not canonical JSON: {error}", file=sys.stderr)
    raise SystemExit(1)
if canonical != payload:
    print("ERROR: final receipt is not canonical JSON without a trailing newline", file=sys.stderr)
    raise SystemExit(1)
PY

printf '%s\n' "$FINAL_OUTPUT"
