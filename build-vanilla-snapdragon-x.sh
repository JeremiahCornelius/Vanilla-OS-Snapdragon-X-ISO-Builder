#!/usr/bin/env bash
# build-vanilla-arm64-release-v2.7.12.sh
#
# Constructive Vanilla ARM64 Release Builder
# Version: 2.7.12
#
# Purpose:
#   Deterministically build a VanillaOS ARM64 UEFI installation ISO from
#   Vanilla ARM GitHub sources, local board-specific artifacts, and optional
#   staged Qualcomm firmware, while preserving release provenance.
#
# Primary build host:
#   Debian 13 VM on Apple Silicon / M3 Macintosh
#
# Primary target profile:
#   HP Omnibook 5 / Qualcomm Snapdragon X Plus
#
# Important design rules:
#   - Custom kernel .deb packages and .dtb files are local inputs.
#   - Qualcomm firmware extraction is isolated and must not install to host.
#   - User prompts are numbered and self-explanatory.
#   - Prompt text goes to stderr; function return values go to stdout only.
#   - Release artifacts are stamped, checksummed, and manifested.
#
# Notes:
#   This script intentionally uses conservative staging hooks. VanillaOS ARM
#   source layout may change; generated hooks are placed in conventional
#   live-build/Vib locations and logged for review.

set -Eeuo pipefail

SCRIPT_VERSION="2.7.12"
SCRIPT_NAME="$(basename "$0")"
LAST_DEEP_DIAGNOSTIC_LOG=""
VIB_RUN_USER="${VIB_RUN_USER:-vanillabuilder}"
VIB_ALLOW_ROOT="${VIB_ALLOW_ROOT:-0}"
DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD="${DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD:-auto}"  # auto|1|0
PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE="${PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE:-1}"
RECONSTRUCT_INCLUDES_CONTAINER_ON_RUNTIME_BREAK="${RECONSTRUCT_INCLUDES_CONTAINER_ON_RUNTIME_BREAK:-1}"
PRESERVE_FIRMWARE_IN_INCLUDES_RECONSTRUCTION="${PRESERVE_FIRMWARE_IN_INCLUDES_RECONSTRUCTION:-1}"
NORMALIZE_FIRMWARE_TO_USR_LIB="${NORMALIZE_FIRMWARE_TO_USR_LIB:-1}"
STREAM_LONG_COMMAND_OUTPUT="${STREAM_LONG_COMMAND_OUTPUT:-1}"
PODMAN_BUILD_NETWORK="${PODMAN_BUILD_NETWORK:-host}"  # host|default|none|<podman-network-name>
LIVE_ISO_CONTAINER_PLATFORM="${LIVE_ISO_CONTAINER_PLATFORM:-linux/arm64}"
LIVE_ISO_CONTAINER_IMAGE="${LIVE_ISO_CONTAINER_IMAGE:-ghcr.io/vanilla-os/pico:dev}"
LIVE_ISO_CONTAINER_RUNTIME="${LIVE_ISO_CONTAINER_RUNTIME:-podman}"  # podman|docker
LIVE_ISO_CONTAINER_FALLBACK_IMAGES="${LIVE_ISO_CONTAINER_FALLBACK_IMAGES:-ghcr.io/vanilla-os/pico:dev ghcr.io/vanilla-os/pico:latest debian:trixie}"
VERIFY_CUSTOM_KERNEL_IN_ISO="${VERIFY_CUSTOM_KERNEL_IN_ISO:-1}"
INSTALL_CUSTOM_KERNEL_HEADERS_IN_LIVE="${INSTALL_CUSTOM_KERNEL_HEADERS_IN_LIVE:-0}"
INSTALL_CUSTOM_KERNEL_TOOLS_IN_LIVE="${INSTALL_CUSTOM_KERNEL_TOOLS_IN_LIVE:-0}"
PATCH_LIVE_INSTALLER_HOOK="${PATCH_LIVE_INSTALLER_HOOK:-1}"
ALLOW_MISSING_OPTIONAL_PACKAGES="${ALLOW_MISSING_OPTIONAL_PACKAGES:-1}"
KNOWN_UNAVAILABLE_PACKAGES="${KNOWN_UNAVAILABLE_PACKAGES:-network-manager-fortisslvpn}"
PATCH_KNOWN_DEBIAN_CHANGELOG_DATES="${PATCH_KNOWN_DEBIAN_CHANGELOG_DATES:-1}"
VIB_VERSION_POLICY="${VIB_VERSION_POLICY:-warn}"  # warn|strict|ignore

# ----------------------------- UI helpers -----------------------------

if [[ -t 2 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()    { printf '%sOK%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { fail "$*"; exit 1; }

stage() {
  local n="$1" total="$2" msg="$3"
  CURRENT_STAGE="$n/$total: $msg"
  printf '\n%s[Stage %s of %s]%s %s\n' "$C_BOLD" "$n" "$total" "$C_RESET" "$msg" >&2
}

hr() { printf '%s\n' '==================================================================' >&2; }


# Current high-level stage, used by failure diagnostics.
CURRENT_STAGE="startup"
LAST_COMMAND_LOG=""

print_failure_tail() {
  local log="$1"
  if [[ -n "$log" && -f "$log" ]]; then
    printf '\n%sLast 80 lines from failing command log:%s\n' "$C_BOLD" "$C_RESET" >&2
    printf 'Log file: %s\n' "$log" >&2
    printf '%s\n' '------------------------------------------------------------------' >&2
    tail -n 80 "$log" >&2 || true
    printf '%s\n' '------------------------------------------------------------------' >&2
  fi
}

log_has_only_header() {
  # Return true when a command log contains only the wrapper header and no
  # substantive child-process output. This is especially useful for Vib, which
  # can fail before emitting useful text to stdout/stderr.
  local log="$1"
  [[ -f "$log" ]] || return 1

  # Remove blank lines and wrapper header lines. If nothing remains, the child
  # command produced no useful output.
  local payload
  payload="$(sed '/^[[:space:]]*$/d; /^### /d' "$log" 2>/dev/null || true)"
  [[ -z "$payload" ]]
}


summarize_deep_diagnostic_log() {
  # Extract the most useful high-signal lines from a deep Vib diagnostic log so
  # the operator does not have to manually open a second file after a silent
  # primary `vib build` failure.
  local log="$1"
  [[ -f "$log" ]] || return 0

  printf '\nDeep diagnostic log:\n  %s\n' "$log" >&2
  printf '\nHigh-signal diagnostic summary:\n' >&2

  grep -nE \
    'recipe vibversion:|installed vib version|raw vib --version|VIB_|YAML_|FSGUARD_|Direct exit status|Debug-env exit status|script-wrapped exit status|strace-wrapped exit status|execve\\(|openat\\(.*recipe.yml|ENOENT|EACCES|EPERM|SIGSEGV|SIGILL|panic|error|Error|ERROR|failed|Failed|FAIL' \
    "$log" 2>/dev/null | tail -n 120 >&2 || true

  printf '\nLast 120 lines from deep diagnostic log:\n' >&2
  printf '%s\n' '------------------------------------------------------------------' >&2
  tail -n 120 "$log" >&2 || true
  printf '%s\n' '------------------------------------------------------------------' >&2
}


command_failure_menu() {
  # Print diagnostics for a failed subprocess and return the operator's desired
  # next action on stdout. This function must return status 0 so that callers
  # running under `set -e` do not trigger the global ERR trap while handling an
  # expected command failure.
  local label="$1" workdir="$2" log="$3" status="$4"
  local choice

  fail "Command failed during stage ${CURRENT_STAGE}."
  printf 'Command label: %s
' "$label" >&2
  printf 'Exit status:   %s
' "$status" >&2
  printf 'Working dir:   %s
' "$workdir" >&2
  printf 'Command log:   %s
' "$log" >&2
  print_failure_tail "$log"

  if [[ -n "${LAST_DEEP_DIAGNOSTIC_LOG:-}" && -f "$LAST_DEEP_DIAGNOSTIC_LOG" ]]; then
    if log_has_only_header "$log"; then
      warn "The primary command log contains no child-process output."
      warn "Showing the deep diagnostic log instead."
      summarize_deep_diagnostic_log "$LAST_DEEP_DIAGNOSTIC_LOG"
    fi
  fi

  choice="$(menu "Build Command Failure

The previous command failed. If the command produced no useful output, the builder may already have generated a deep diagnostic log. You can inspect the working directory and logs before deciding whether to abort or retry." "1" \
    "1|Open an interactive shell in the failing working directory [RECOMMENDED]|Inspect recipe files, generated hooks, container state, and logs. Type 'exit' to return." \
    "2|Retry the failed command|Run the same command again after any manual corrections." \
    "3|Run deep Vib diagnostics, then return to this menu|Use this when Vib exits with little or no output. Captures binary, plugin ABI, recipe YAML, runtime, and strace diagnostics." \
    "4|Abort build|Stop immediately and preserve logs/workspace for diagnosis.")"

  case "$choice" in
    1) printf '%s
' "shell" ;;
    2) printf '%s
' "retry" ;;
    3) printf '%s
' "diagnose" ;;
    4|*) printf '%s
' "abort" ;;
  esac
  return 0
}



ensure_user_can_traverse_path() {
  # Ensure the non-root Vib user can traverse every parent directory needed to
  # reach the build workspace. This matters when the builder is executed as root
  # and WORKDIR defaults under /root. Even if WORKDIR itself is chowned to the
  # Vib user, /root is usually mode 0700, so runuser cannot `cd` into
  # /root/src/vanilla-arm64-build-system/...
  #
  # Preferred method:
  #   setfacl -m u:<user>:--x <parent>
  #
  # Fallback:
  #   chmod o+x <parent>
  #
  # The fallback is intentionally limited to execute/search permission on parent
  # directories. It does not grant read permission, and it does not expose files
  # inside /root. It only allows path traversal to the explicitly chowned
  # workspace.
  local user="$1"
  local target="$2"
  local path parent
  local changed_log="$OUTPUT_DIR/logs/${BUILD_DATE}-vib-path-traversal-$(date -u +%H%M%S).log"

  mkdir -p "$OUTPUT_DIR/logs"
  : > "$changed_log"

  target="$(readlink -f "$target")"
  [[ -n "$target" && -d "$target" ]] || die "Cannot resolve Vib workspace path for traversal setup: $target"

  info "Checking parent-directory traversal for Vib user $user."
  printf 'Target path: %s\n' "$target" >>"$changed_log"
  printf 'User: %s\n\n' "$user" >>"$changed_log"

  parent="/"
  IFS='/' read -r -a parts <<< "${target#/}"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    parent="${parent%/}/$part"

    # Stop after the target itself; ownership/permissions for contents are
    # handled separately by chown -R.
    if [[ "$parent" == "$target" ]]; then
      break
    fi

    if runuser -u "$user" -- test -x "$parent" 2>/dev/null; then
      printf 'PASS traverse: %s\n' "$parent" >>"$changed_log"
      continue
    fi

    printf 'NEEDS traverse permission: %s\n' "$parent" >>"$changed_log"

    if command -v setfacl >/dev/null 2>&1; then
      info "Granting execute-only ACL for $user on parent directory: $parent"
      setfacl -m "u:${user}:--x" "$parent" \
        || die "Failed to grant ACL traversal permission on $parent"
      printf 'ACTION setfacl -m u:%s:--x %s\n' "$user" "$parent" >>"$changed_log"
    else
      warn "setfacl is not available; using chmod o+x on parent directory: $parent"
      chmod o+x "$parent" \
        || die "Failed to grant execute/search permission on $parent"
      printf 'ACTION chmod o+x %s\n' "$parent" >>"$changed_log"
    fi
  done

  if ! runuser -u "$user" -- test -x "$target" 2>/dev/null; then
    fail "Vib user still cannot traverse to workspace after permission setup."
    warn "Traversal log: $changed_log"
    return 1
  fi

  ok "Vib user can traverse to workspace."
  printf '\nRESULT: Vib user can traverse target workspace.\n' >>"$changed_log"
  printf 'Traversal log:\n  %s\n' "$changed_log" >&2
}

ensure_vib_run_user() {
  # Vib appears to exit immediately when executed as UID 0. Strace showed:
  #   getuid() = 0
  #   exit_group(1)
  # with no stdout/stderr. Therefore the builder must run Vib as a non-root
  # user while preserving root for privileged container/ISO steps.
  #
  # If the script itself is not running as root, no special handling is needed.
  # If running as root, create/use VIB_RUN_USER and grant ownership over the
  # working tree so the non-root Vib process can read/write recipe outputs.
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  if [[ "$VIB_ALLOW_ROOT" == "1" ]]; then
    warn "VIB_ALLOW_ROOT=1 is set; Vib will be attempted as root despite known silent-exit behavior."
    return 0
  fi

  if ! id "$VIB_RUN_USER" >/dev/null 2>&1; then
    info "Creating non-root Vib build user: $VIB_RUN_USER"
    useradd --system --create-home --shell /bin/bash "$VIB_RUN_USER" \
      || die "Unable to create Vib build user: $VIB_RUN_USER"
  fi

  info "Ensuring Vib user can traverse the build workspace path."
  ensure_user_can_traverse_path "$VIB_RUN_USER" "$WORKDIR"

  # Keep Git source trees owned by the main builder/root until the moment Vib
  # needs to write inside a specific recipe tree. This avoids Git "dubious
  # ownership" failures during source refresh.
  mkdir -p "$OUTPUT_DIR/logs" "$TMP_DIR"
  chown -R "$VIB_RUN_USER:$VIB_RUN_USER" "$OUTPUT_DIR" "$TMP_DIR" 2>/dev/null || true
}


prepare_repo_for_vib_user() {
  # Vib writes build outputs in the recipe repository. Chown only the specific
  # image recipe tree immediately before running Vib, not the entire WORKDIR and
  # not before Git refresh.
  local repo="$1"
  if [[ "$(id -u)" -eq 0 && "$VIB_ALLOW_ROOT" != "1" ]]; then
    info "Granting Vib build user ownership of recipe tree: $repo"
    chown -R "$VIB_RUN_USER:$VIB_RUN_USER" "$repo" \
      || die "Unable to chown recipe tree for Vib user: $repo"
  fi
}

run_as_vib_user() {
  # Run a command as the non-root Vib user when the builder itself is root.
  # Arguments: working-directory command args...
  local workdir="$1"; shift

  if [[ "$(id -u)" -eq 0 && "$VIB_ALLOW_ROOT" != "1" ]]; then
    if command -v runuser >/dev/null 2>&1; then
      local cmd
      cmd="cd $(printf '%q' "$workdir") && PATH=$(printf '%q' "$PATH") exec"
      local arg
      for arg in "$@"; do
        cmd+=" $(printf '%q' "$arg")"
      done
      runuser -u "$VIB_RUN_USER" -- bash -lc "$cmd"
    elif command -v su >/dev/null 2>&1; then
      su -s /bin/bash "$VIB_RUN_USER" -c "cd $(printf '%q' "$workdir") && PATH=$(printf '%q' "$PATH") exec $(printf '%q ' "$@")"
    else
      die "Neither runuser nor su is available to run Vib as non-root."
    fi
  else
    ( cd "$workdir" && "$@" )
  fi
}


run_logged() {
  # Run a command with explicit per-command logging and failure diagnostics.
  # Usage: run_logged "human label" "/working/dir" command arg ...
  #
  # Trap-safety note:
  #   This function intentionally disables both errexit and the global ERR trap
  #   while the child command executes. A failing Vib/container command is an
  #   expected condition that must be captured, logged, and presented to the
  #   operator. If the ERR trap remains active here, Bash can recursively invoke
  #   the global failure handler before the actual command output is preserved.
  local label="$1" workdir="$2"; shift 2
  local safe log status action old_errexit old_errtrace
  safe="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
  mkdir -p "$OUTPUT_DIR/logs"

  while true; do
    log="$OUTPUT_DIR/logs/${BUILD_DATE}-${safe}-$(date -u +%H%M%S).log"
    LAST_COMMAND_LOG="$log"

    info "$label"
    printf 'Working directory: %s\n' "$workdir" >&2
    printf 'Command: ' >&2
    printf '%q ' "$@" >&2
    printf '\nCommand log: %s\n' "$log" >&2

    {
      printf '### %s\n' "$label"
      printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '### PWD: %s\n' "$workdir"
      printf '### COMMAND:'
      printf ' %q' "$@"
      printf '\n\n'
    } > "$log"

    # Save shell option state for the two options we are about to relax.
    case "$-" in *e*) old_errexit=1 ;; *) old_errexit=0 ;; esac
    case "$-" in *E*) old_errtrace=1 ;; *) old_errtrace=0 ;; esac

    # Disable ERR trap and errexit for the expected-failure boundary only.
    trap - ERR
    set +e
    set +E
    if [[ "$label" == *"Vib"* || "$*" == *"vib"* ]]; then
      run_as_vib_user "$workdir" "$@" >> "$log" 2>&1
    else
      (
        cd "$workdir" || exit 97
        "$@"
      ) >> "$log" 2>&1
    fi
    status=$?

    # Restore shell behavior for the rest of the builder.
    if [[ "$old_errtrace" -eq 1 ]]; then set -E; else set +E; fi
    if [[ "$old_errexit" -eq 1 ]]; then set -e; else set +e; fi
    trap 'rc=$?; fail "Unexpected failure at stage ${CURRENT_STAGE}, line ${LINENO}, exit status ${rc}."; [[ -n "${LAST_COMMAND_LOG:-}" ]] && print_failure_tail "$LAST_COMMAND_LOG"; exit "$rc"' ERR

    if [[ "$status" -eq 0 ]]; then
      ok "$label completed successfully."
      return 0
    fi

    if [[ "$label" == *"Vib"* || "$*" == *"vib"* ]]; then
      if log_has_only_header "$log"; then
        warn "The Vib command failed but produced no stdout/stderr beyond the command header."
        warn "Running deep Vib diagnostics automatically before presenting the failure menu."
        vib_deep_diagnostics "$workdir" "$safe"
        warn "Primary Vib log was empty. Deep diagnostic log:"
        warn "  $LAST_DEEP_DIAGNOSTIC_LOG"
      fi
    fi

    if [[ "$label" == *"container image"* || "$*" == *"podman"* ]]; then
      classify_container_build_failure "$log"
    fi

    action="$(command_failure_menu "$label" "$workdir" "$log" "$status")"
    case "$action" in
      shell)
        open_shell "$workdir"
        ;;
      retry)
        continue
        ;;
      diagnose)
        if [[ "$label" == *"Vib"* || "$*" == *"vib"* ]]; then
          vib_deep_diagnostics "$workdir" "$safe"
        else
          warn "Deep diagnostics are currently implemented for Vib commands only."
        fi
        ;;
      logshell)
        open_shell "$OUTPUT_DIR/logs"
        ;;
      abort|*)
        die "Build aborted after command failure. See log: $log"
        ;;
    esac
  done
}

trap 'rc=$?; fail "Unexpected failure at stage ${CURRENT_STAGE}, line ${LINENO}, exit status ${rc}."; [[ -n "${LAST_COMMAND_LOG:-}" ]] && print_failure_tail "$LAST_COMMAND_LOG"; exit "$rc"' ERR

# -------------------------- string/path helpers ------------------------

trim() {
  # Trim leading/trailing ASCII whitespace without disturbing embedded spaces.
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_outer_quotes() {
  local s="$1"
  if [[ ${#s} -ge 2 ]]; then
    if [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
      s="${s:1:${#s}-2}"
    elif [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
      s="${s:1:${#s}-2}"
    fi
  fi
  printf '%s' "$s"
}

normalize_path_input() {
  local raw="$1"
  local s
  s="$(trim "$raw")"
  s="$(strip_outer_quotes "$s")"
  case "$s" in
    "~") s="$HOME" ;;
    "~/"*) s="$HOME/${s#~/}" ;;
  esac
  printf '%s' "$s"
}

shell_escape() { printf '%q' "$1"; }

open_shell() {
  local dir="${1:-$PWD}"
  mkdir -p "$dir"
  printf '\n*** Opening interactive shell. Type %sexit%s to return to the builder. ***\n' "$C_BOLD" "$C_RESET" >&2
  printf 'Directory: %s\n' "$dir" >&2
  (cd "$dir" && "${SHELL:-/bin/bash}")
}

menu() {
  # Args:
  #   $1 title
  #   $2 default number
  #   remaining args are option lines. Each option line is:
  #      "number|label|description"
  #
  # Returns selected number on stdout.
  local title="$1"; shift
  local default="$1"; shift
  local ans opt n label desc

  while true; do
    printf '\n' >&2
    hr
    printf '%s\n\n' "$title" >&2
    printf 'Select an action:\n\n' >&2

    for opt in "$@"; do
      IFS='|' read -r n label desc <<<"$opt"
      if [[ "$n" == "$default" ]]; then
        printf '  %s) %s [DEFAULT]\n' "$n" "$label" >&2
      else
        printf '  %s) %s\n' "$n" "$label" >&2
      fi
      [[ -n "${desc:-}" ]] && printf '     %s\n\n' "$desc" >&2
    done

    printf 'Special commands:\n' >&2
    printf '  ?  Show this menu again\n' >&2
    printf '  !  Open an interactive shell\n' >&2
    hr
    read -rp "Selection [$default]: " ans
    ans="$(trim "${ans:-$default}")"

    case "$ans" in
      "?") continue ;;
      "!") open_shell "$PWD"; continue ;;
    esac

    for opt in "$@"; do
      IFS='|' read -r n label desc <<<"$opt"
      if [[ "$ans" == "$n" ]]; then
        printf '%s' "$ans"
        return 0
      fi
    done

    printf '\nInvalid selection: %s\nPlease enter one of the listed numbers.\n' "$(shell_escape "$ans")" >&2
  done
}

prompt_text() {
  # Prompt text; returns normalized answer on stdout.
  local title="$1"
  local default="$2"
  local ans

  printf '\n%s\n' "$title" >&2
  printf 'Default: %s\n' "$default" >&2
  read -rp "$title [$default]: " ans
  ans="${ans:-$default}"
  ans="$(trim "$ans")"
  printf '%s' "$ans"
}

prompt_path() {
  local title="$1"
  local default="$2"
  local ans
  printf '\n%s\n' "$title" >&2
  printf 'Default: %s\n' "$default" >&2
  read -rp "$title [$default]: " ans
  ans="${ans:-$default}"
  normalize_path_input "$ans"
}

prompt_existing_file_optional() {
  local title="$1"
  local default="$2"
  local path choice
  while true; do
    path="$(prompt_path "$title" "$default")"
    if [[ -z "$path" ]]; then
      printf ''
      return 0
    fi
    if [[ -f "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi

    printf '\nThe selected file does not exist:\n  %s\n' "$(shell_escape "$path")" >&2
    choice="$(menu "File Not Found" "1" \
      "1|Retry the file path|Return to the file prompt." \
      "2|Open an interactive shell|Download, move, or inspect files manually, then type 'exit' to resume." \
      "3|Skip this optional file|Continue without setting this value." \
      "4|Abort the build|Stop immediately.")"

    case "$choice" in
      1) continue ;;
      2) open_shell "$(dirname "$path")"; continue ;;
      3) printf ''; return 0 ;;
      4) die "Build aborted by operator." ;;
    esac
  done
}

# ----------------------------- defaults --------------------------------

WORKDIR="${WORKDIR:-$HOME/src/vanilla-arm64-build-system}"
PROFILE="${PROFILE:-hp-omnibook-5}"
ARCH="${ARCH:-arm64}"
RELEASE_PREFIX="${RELEASE_PREFIX:-Constructive-VanillaOS-Orchid}"
QCOM_DEVICE_PATH_DEFAULT="x1p42100/hp/omnibook-5"

SOURCES_DIR="$WORKDIR/sources"
ARTIFACT_DIR="$WORKDIR/artifacts/$PROFILE"
ROOT_OVERLAY_DIR="$WORKDIR/root-overlay/$PROFILE"
DOWNLOADS_DIR="$WORKDIR/downloads"
OUTPUT_DIR="$WORKDIR/output"
RELEASES_DIR="$OUTPUT_DIR/releases"
TMP_DIR="$WORKDIR/tmp"
STAGED_QCOM_DIR="$WORKDIR/staged-firmware/qcom/$PROFILE"
PRESTAGED_QCOM_DIR="$WORKDIR/prestaged-firmware/$PROFILE"

CORE_REPO_URL="${CORE_REPO_URL:-https://github.com/vanilla-arm/core-image}"
DESKTOP_REPO_URL="${DESKTOP_REPO_URL:-https://github.com/vanilla-arm/desktop-image}"
LIVE_REPO_URL="${LIVE_REPO_URL:-https://github.com/vanilla-arm/live-iso}"
PICO_REPO_URL="${PICO_REPO_URL:-https://github.com/vanilla-arm/pico-image}"

CORE_BRANCH="${CORE_BRANCH:-dev}"
DESKTOP_BRANCH="${DESKTOP_BRANCH:-dev}"
LIVE_BRANCH="${LIVE_BRANCH:-orchid}"
PICO_BRANCH="${PICO_BRANCH:-main}"

# Repository handling policy.
# ask-once: ask for one policy and apply it to all existing repositories.
# prompt:   prompt separately for each existing repository.
# pull:     automatically fetch/checkout/pull existing repositories.
# continue: use existing repositories without network activity.
# reclone:  delete and freshly clone existing repositories.
REPO_POLICY="${REPO_POLICY:-ask-once}"

BUILD_DATE="$(date -u +%Y%m%d)"
BUILD_COUNTER_FILE="$WORKDIR/.build-number"

# ------------------------------ logging --------------------------------

LOG_FILE=""
setup_logging() {
  mkdir -p "$OUTPUT_DIR/logs"
  LOG_FILE="$OUTPUT_DIR/logs/build-${BUILD_DATE}-$(date -u +%H%M%S).log"
  # Duplicate all stdout/stderr to log, while preserving streams.
  exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
  info "Logging to: $LOG_FILE"
}

# ---------------------------- dependencies -----------------------------

have() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    aarch64|arm64) printf 'arm64' ;;
    x86_64|amd64) printf 'amd64' ;;
    *) printf '%s' "$m" ;;
  esac
}

apt_install_deps() {
  info "Installing Debian-managed dependencies with apt."
  apt update
  apt install -y \
    git curl ca-certificates gawk coreutils findutils tar gzip unzip \
    python3 podman docker.io xorriso genisoimage jq file rsync \
    squashfs-tools gnupg zstd
}

find_iso_reader() {
  if have isoinfo; then
    printf 'isoinfo'
  elif have xorriso; then
    printf 'xorriso'
  else
    printf ''
  fi
}

resolve_vib() {
  if have vib; then
    ok "vib already present: $(command -v vib)"
    return 0
  fi

  local host_arch install_dest choice tmp release_json assets asset_name asset_url
  host_arch="$(detect_arch)"
  if [[ "$(id -u)" -eq 0 ]]; then
    install_dest="/usr/local/bin/vib"
  else
    mkdir -p "$HOME/.local/bin"
    install_dest="$HOME/.local/bin/vib"
  fi

  while true; do
    printf '\n' >&2
    hr
    printf 'Vib Dependency Resolver\n\n' >&2
    printf 'Vib is required because Vanilla image recipes are built with:\n' >&2
    printf '  vib build recipe.yml\n\n' >&2
    printf 'Install destination:\n  %s\n\n' "$install_dest" >&2
    printf 'Host architecture detected:\n  %s\n\n' "$host_arch" >&2

    choice="$(menu "Resolve Missing Vib" "1" \
      "1|Download and install latest Vib binary release|Fetch GitHub release metadata, reject plugin bundles, and install the matching vib binary." \
      "2|Open an interactive shell to install Vib manually|Install vib yourself, then exit the shell and choose re-check." \
      "3|Re-check PATH for an already-installed vib|Use this after manual installation." \
      "4|Abort build|Stop immediately.")"

    case "$choice" in
      1)
        tmp="$TMP_DIR/vib-install-$$"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        release_json="$tmp/release.json"

        info "Querying latest Vib release metadata from GitHub."
        curl -fsSL "https://api.github.com/repos/Vanilla-OS/Vib/releases/latest" -o "$release_json" \
          || { fail "Unable to query latest Vib release metadata."; continue; }

        # Corrected asset selection:
        #   - Reject plugin archives: plugins-*.tar.gz
        #   - Prefer exact vib-$arch assets.
        #   - Accept archive assets containing vib only as a fallback.
        # Known current release naming includes vib-amd64/vib-arm64 and
        # plugins-amd64/plugins-arm64. The previous resolver accidentally
        # selected plugins-arm64.tar.gz on aarch64 hosts.
        if have jq; then
          asset_url="$(jq -r --arg arch "$host_arch" '
            .assets[]
            | select(.name | test("^vib-" + $arch + "($|[. _-])"))
            | select(.name | test("plugins"; "i") | not)
            | .browser_download_url
          ' "$release_json" | head -n1)"
          asset_name="$(jq -r --arg url "$asset_url" '.assets[] | select(.browser_download_url==$url) | .name' "$release_json" | head -n1)"
        else
          asset_url="$(python3 - "$release_json" "$host_arch" <<'PY'
import json, sys, re
data=json.load(open(sys.argv[1]))
arch=sys.argv[2]
for a in data.get("assets", []):
    name=a.get("name","")
    if re.search(r"plugins", name, re.I):
        continue
    if re.match(rf"^vib-{re.escape(arch)}($|[. _-])", name):
        print(a.get("browser_download_url",""))
        break
PY
)"
          asset_name="$(basename "$asset_url")"
        fi

        if [[ -z "${asset_url:-}" || "$asset_url" == "null" ]]; then
          fail "Could not identify a Vib binary asset for architecture '$host_arch'."
          warn "Expected an asset resembling: vib-$host_arch"
          warn "Rejected plugin bundles such as: plugins-$host_arch.tar.gz"
          open_shell "$tmp"
          continue
        fi

        info "Downloading Vib binary asset: $asset_name"
        curl -fL "$asset_url" -o "$tmp/$asset_name" || { fail "Vib download failed."; continue; }

        local candidate=""
        if file "$tmp/$asset_name" | grep -qiE 'executable|ELF'; then
          candidate="$tmp/$asset_name"
        else
          mkdir -p "$tmp/extract"
          case "$asset_name" in
            *.tar.gz|*.tgz) tar -xzf "$tmp/$asset_name" -C "$tmp/extract" ;;
            *.zip) unzip -q "$tmp/$asset_name" -d "$tmp/extract" ;;
            *) warn "Unknown Vib asset format; trying direct executable check only." ;;
          esac
          candidate="$(find "$tmp/extract" -type f \( -name 'vib' -o -name 'vib-*' \) ! -iname '*plugin*' -print -quit 2>/dev/null || true)"
        fi

        if [[ -z "$candidate" || ! -f "$candidate" ]]; then
          fail "Downloaded Vib asset did not contain an identifiable vib executable."
          open_shell "$tmp"
          continue
        fi

        chmod +x "$candidate"
        info "Installing Vib to: $install_dest"
        install -m 0755 "$candidate" "$install_dest"
        if have vib || [[ -x "$install_dest" ]]; then
          ok "Vib installed successfully."
          export PATH="$(dirname "$install_dest"):$PATH"
          vib --help >/dev/null 2>&1 || warn "Installed vib exists, but 'vib --help' returned non-zero."
          return 0
        fi
        ;;
      2) open_shell "$WORKDIR" ;;
      3)
        if have vib; then
          ok "vib found: $(command -v vib)"
          return 0
        fi
        fail "vib still not found in PATH."
        ;;
      4) die "Build aborted because vib is required." ;;
    esac
  done
}

resolve_vib_plugin_bundle_into_repo() {
  # Vanilla image recipes commonly require Vib plugins, especially fsguard.
  # The Vib GitHub release publishes separate binary assets:
  #   - vib-arm64 / vib-amd64          => the Vib executable
  #   - plugins-arm64.tar.gz / ...     => plugin bundle
  #
  # Earlier builder revisions installed only the Vib executable. That allowed
  # Stage 8 to reach `vib build recipe.yml`, but core-image/plugins and
  # desktop-image/plugins remained empty, causing opaque Vib failures.
  #
  # This function installs the matching plugins-$arch bundle into the supplied
  # repository's plugins/ directory. It is intentionally idempotent.
  local repo="$1"
  local repo_name
  local plugins_dir
  local host_arch
  local tmp release_json asset_url asset_name extract_dir copied_count

  repo_name="$(basename "$repo")"
  plugins_dir="$repo/plugins"
  host_arch="$(detect_arch)"

  [[ -d "$repo" ]] || return 0

  mkdir -p "$plugins_dir"

  if find "$plugins_dir" -type f | grep -q .; then
    ok "Vib plugins already present for $repo_name: $plugins_dir"
    return 0
  fi

  printf '\n' >&2
  hr
  printf 'Vib Plugin Bundle Required\n\n' >&2
  printf 'Repository:\n  %s\n\n' "$repo_name" >&2
  printf 'Plugin directory:\n  %s\n\n' "$plugins_dir" >&2
  printf 'The directory is empty. Vanilla image recipes may require plugins such as fsguard.\n' >&2
  printf 'The builder will download the matching Vib plugin bundle for this host architecture:\n  %s\n' "$host_arch" >&2
  hr

  tmp="$TMP_DIR/vib-plugins-${repo_name}-$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  release_json="$tmp/release.json"
  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"

  info "Querying latest Vib release metadata for plugin bundle."
  curl -fsSL "https://api.github.com/repos/Vanilla-OS/Vib/releases/latest" -o "$release_json" \
    || die "Unable to query latest Vib release metadata for plugin bundle."

  if have jq; then
    asset_url="$(jq -r --arg arch "$host_arch" '
      .assets[]
      | select(.name | test("^plugins-" + $arch + ".*\\.tar\\.gz$"))
      | .browser_download_url
    ' "$release_json" | head -n1)"
    asset_name="$(jq -r --arg url "$asset_url" '.assets[] | select(.browser_download_url==$url) | .name' "$release_json" | head -n1)"
  else
    asset_url="$(python3 - "$release_json" "$host_arch" <<'PY'
import json, sys, re
data=json.load(open(sys.argv[1]))
arch=sys.argv[2]
pat=re.compile(rf"^plugins-{re.escape(arch)}.*\.tar\.gz$")
for a in data.get("assets", []):
    name=a.get("name","")
    if pat.search(name):
        print(a.get("browser_download_url",""))
        break
PY
)"
    asset_name="$(basename "$asset_url")"
  fi

  if [[ -z "${asset_url:-}" || "$asset_url" == "null" ]]; then
    fail "Could not identify a Vib plugin bundle for architecture '$host_arch'."
    warn "Expected an asset resembling: plugins-$host_arch.tar.gz"
    open_shell "$tmp"
    die "Vib plugin bundle could not be resolved."
  fi

  info "Downloading Vib plugin bundle: $asset_name"
  curl -fL "$asset_url" -o "$tmp/$asset_name" \
    || die "Failed to download Vib plugin bundle: $asset_name"

  info "Extracting Vib plugin bundle."
  tar -xzf "$tmp/$asset_name" -C "$extract_dir" \
    || die "Failed to extract Vib plugin bundle: $asset_name"

  copied_count=0

  while IFS= read -r f; do
    cp -a "$f" "$plugins_dir/$(basename "$f")"
    copied_count=$((copied_count + 1))
  done < <(
    find "$extract_dir" -type f \( \
      -name '*.so' -o \
      -iname '*fsguard*' -o \
      -iname '*plugin*' \
    \) ! -name '*.tar.gz' | sort
  )

  if [[ "$copied_count" -eq 0 ]]; then
    warn "No obvious .so/fsguard/plugin files found in plugin bundle; copying all regular files as fallback."
    while IFS= read -r f; do
      cp -a "$f" "$plugins_dir/$(basename "$f")"
      copied_count=$((copied_count + 1))
    done < <(find "$extract_dir" -type f ! -name '*.tar.gz' | sort)
  fi

  if [[ "$copied_count" -eq 0 ]] || ! find "$plugins_dir" -type f | grep -q .; then
    fail "Plugin bundle was downloaded but no plugin files were installed into $plugins_dir."
    warn "Extraction workspace: $tmp"
    open_shell "$tmp"
    die "Vib plugin installation failed for $repo_name."
  fi

  ok "Installed $copied_count Vib plugin file(s) into $plugins_dir."
  printf 'Installed plugin files:\n' >&2
  find "$plugins_dir" -maxdepth 1 -type f -printf '  %f\n' | sort >&2
}

ensure_vib_plugins_for_image_repos() {
  # Install Vib plugins into every source repository that uses Vib recipes.
  # This runs after Git sources are cloned/refreshed and before Stage 8.
  local repo
  for repo in "$SOURCES_DIR/core-image" "$SOURCES_DIR/desktop-image"; do
    [[ -d "$repo" ]] || continue
    if [[ -f "$repo/recipe.yml" ]]; then
      resolve_vib_plugin_bundle_into_repo "$repo"
    fi
  done
}


recipe_uses_fsguard() {
  local repo="$1"
  [[ -f "$repo/recipe.yml" ]] || return 1
  grep -Eq '^[[:space:]]*type:[[:space:]]*fsguard[[:space:]]*$' "$repo/recipe.yml"
}

find_existing_fsguard_plugin() {
  local dir="$1"
  find "$dir" -maxdepth 3 -type f \( \
      -iname 'fsguard.so' -o \
      -iname '*fsguard*.so' -o \
      -iname 'vib-fsguard*.so' \
    \) 2>/dev/null | head -n1
}

install_fsguard_plugin_into_repo() {
  # Recipes that contain `type: fsguard` require the separate compiled
  # Vanilla-OS/vib-fsguard plugin. The generic plugins-arm64.tar.gz bundle may
  # not include it.
  local repo="$1"
  local repo_name plugins_dir host_arch tmp release_json asset_url asset_name extract_dir found

  repo_name="$(basename "$repo")"
  plugins_dir="$repo/plugins"
  host_arch="$(detect_arch)"

  [[ -d "$repo" ]] || return 0
  recipe_uses_fsguard "$repo" || return 0

  mkdir -p "$plugins_dir"
  found="$(find_existing_fsguard_plugin "$plugins_dir" || true)"
  if [[ -n "$found" ]]; then
    if [[ "$(basename "$found")" != "fsguard.so" ]]; then
      cp -a "$found" "$plugins_dir/fsguard.so"
    fi
    ok "fsguard plugin present for $repo_name: $plugins_dir/fsguard.so"
    return 0
  fi

  printf '\n' >&2
  hr
  printf 'Vib fsguard Plugin Required\n\n' >&2
  printf 'Repository:\n  %s\n\n' "$repo_name" >&2
  printf 'Reason:\n  recipe.yml contains: type: fsguard\n\n' >&2
  printf 'Required destination:\n  %s/fsguard.so\n\n' "$plugins_dir" >&2
  printf 'The builder will try to download the latest Vanilla-OS/vib-fsguard release asset for:\n  %s\n' "$host_arch" >&2
  hr

  tmp="$TMP_DIR/vib-fsguard-${repo_name}-$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  release_json="$tmp/release.json"
  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"

  info "Querying latest vib-fsguard release metadata."
  curl -fsSL "https://api.github.com/repos/Vanilla-OS/vib-fsguard/releases/latest" -o "$release_json" \
    || die "Unable to query latest vib-fsguard release metadata."

  if have jq; then
    asset_url="$(jq -r --arg arch "$host_arch" '
      .assets[]
      | select((.name | ascii_downcase | contains($arch))
               and (.name | ascii_downcase | contains("fsguard"))
               and (.name | test("\\.so$|\\.tar\\.gz$|\\.tgz$|\\.zip$"; "i")))
      | .browser_download_url
    ' "$release_json" | head -n1)"
    asset_name="$(jq -r --arg url "$asset_url" '.assets[] | select(.browser_download_url==$url) | .name' "$release_json" | head -n1)"
  else
    asset_url="$(python3 - "$release_json" "$host_arch" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
arch=sys.argv[2].lower()
for a in data.get("assets", []):
    name=a.get("name","")
    low=name.lower()
    if arch in low and "fsguard" in low and (low.endswith(".so") or low.endswith(".tar.gz") or low.endswith(".tgz") or low.endswith(".zip")):
        print(a.get("browser_download_url",""))
        break
PY
)"
    asset_name="$(basename "$asset_url")"
  fi

  if [[ -z "${asset_url:-}" || "$asset_url" == "null" ]]; then
    fail "Could not identify a vib-fsguard release asset for architecture '$host_arch'."
    warn "Manually place a compiled host-architecture fsguard plugin at:"
    warn "  $plugins_dir/fsguard.so"
    open_shell "$repo"
    found="$(find_existing_fsguard_plugin "$plugins_dir" || true)"
    if [[ -n "$found" ]]; then
      cp -a "$found" "$plugins_dir/fsguard.so"
      chmod 0755 "$plugins_dir/fsguard.so" || true
      ok "Using manually supplied fsguard plugin: $plugins_dir/fsguard.so"
      return 0
    fi
    die "Missing required fsguard plugin for $repo_name."
  fi

  info "Downloading vib-fsguard asset: $asset_name"
  curl -fL "$asset_url" -o "$tmp/$asset_name" \
    || die "Failed to download vib-fsguard asset: $asset_name"

  case "$asset_name" in
    *.so)
      cp -a "$tmp/$asset_name" "$plugins_dir/fsguard.so"
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$tmp/$asset_name" -C "$extract_dir" \
        || die "Failed to extract vib-fsguard archive: $asset_name"
      found="$(find_existing_fsguard_plugin "$extract_dir" || true)"
      [[ -n "$found" ]] || die "vib-fsguard archive did not contain a recognizable fsguard .so"
      cp -a "$found" "$plugins_dir/fsguard.so"
      ;;
    *.zip)
      unzip -q "$tmp/$asset_name" -d "$extract_dir" \
        || die "Failed to extract vib-fsguard zip: $asset_name"
      found="$(find_existing_fsguard_plugin "$extract_dir" || true)"
      [[ -n "$found" ]] || die "vib-fsguard zip did not contain a recognizable fsguard .so"
      cp -a "$found" "$plugins_dir/fsguard.so"
      ;;
    *)
      die "Unsupported vib-fsguard asset type: $asset_name"
      ;;
  esac

  chmod 0755 "$plugins_dir/fsguard.so" || true
  [[ -s "$plugins_dir/fsguard.so" ]] || die "Installed fsguard plugin is missing or empty: $plugins_dir/fsguard.so"
  ok "Installed fsguard plugin for $repo_name: $plugins_dir/fsguard.so"
}

ensure_required_recipe_specific_plugins() {
  local repo
  for repo in "$SOURCES_DIR/core-image" "$SOURCES_DIR/desktop-image"; do
    [[ -d "$repo" ]] || continue
    install_fsguard_plugin_into_repo "$repo"
  done
}



check_dependencies() {
  local missing=()
  local required=(git curl gawk find tar python3 podman docker rsync sha256sum)
  local t
  for t in "${required[@]}"; do
    have "$t" || missing+=("$t")
  done
  [[ -n "$(find_iso_reader)" ]] || missing+=("isoinfo-or-xorriso")
  have vib || missing+=("vib")

  if [[ "${#missing[@]}" -eq 0 ]]; then
    ok "All required dependencies found."
    return 0
  fi

  printf '\n' >&2
  fail "Missing required tools: ${missing[*]}"
  printf '\nSuggested Debian 13 packages for common tools:\n' >&2
  printf '  sudo apt update\n' >&2
  printf '  sudo apt install -y git curl ca-certificates gawk coreutils findutils tar python3 python3-yaml podman docker.io xorriso genisoimage file binutils strace bsdutils util-linux acl file binutils strace jq file rsync squashfs-tools gnupg zstd\n\n' >&2
  printf 'Additional builder requirement:\n' >&2
  printf '  vib must be installed from Vanilla-OS/Vib release assets.\n\n' >&2

  local choice
  choice="$(menu "Dependency Remediation" "1" \
    "1|Install apt-managed dependencies, then resolve Vib|Recommended on a fresh Debian 13 build host." \
    "2|Resolve Vib only|Use this if all apt dependencies are already installed." \
    "3|Open an interactive shell|Install or inspect dependencies manually, then resume." \
    "4|Re-check dependencies|Use this after manual changes." \
    "5|Abort build|Stop immediately.")"

  case "$choice" in
    1) apt_install_deps; resolve_vib ;;
    2) resolve_vib ;;
    3) open_shell "$WORKDIR" ;;
    4) ;;
    5) die "Dependency check failed." ;;
  esac

  # Recurse once after remediation. If still missing, show menu again.
  check_dependencies
}

# --------------------------- source handling ---------------------------

repo_action() {
  local name="$1" path="$2"
  menu "Repository Status

Repository:
  $name

Location:
  $path

This directory is already a Git checkout. Choose how to handle it." "2" \
    "1|Continue using the existing checkout|No network activity. The local checkout is left exactly as-is." \
    "2|Refresh from Git (git pull)|Fetch/prune, checkout the configured branch, and fast-forward only. Recommended for repeatable current builds." \
    "3|Re-clone repository|Delete the local checkout and perform a fresh clone. Use this for corrupted or uncertain checkouts." \
    "4|Open an interactive shell here|Make manual changes, inspect branches, then exit the shell to resume." \
    "5|Skip this repository|Continue with remaining repositories. Build may fail if the repo is required." \
    "6|Quit the builder|Exit immediately."
}

repo_policy_menu() {
  # Ask once for the repository handling policy so an existing sources/ tree does
  # not trigger repetitive per-repository prompts. This is the default path for
  # deterministic repeat builds.
  menu "Repository Refresh Policy

The builder found or may find existing Git repositories under:
  $SOURCES_DIR

Select one policy to apply to existing checkouts during this run." "1" \
    "1|Refresh existing repositories automatically [RECOMMENDED]|For each existing checkout, run fetch/prune, checkout configured branch, and git pull --ff-only. Missing repos are cloned." \
    "2|Use existing repositories without network access|Do not fetch or pull existing checkouts. Missing repos are cloned only if absent." \
    "3|Prompt separately for each repository|Show the full repository action menu for every existing checkout." \
    "4|Re-clone all existing repositories|Delete and freshly clone each configured repository." \
    "5|Open an interactive shell before repository handling|Inspect or repair the sources directory, then return to choose again." \
    "6|Abort build|Stop immediately."
}

normalize_repo_policy() {
  case "${REPO_POLICY,,}" in
    ask-once|ask|once) REPO_POLICY="ask-once" ;;
    prompt|interactive) REPO_POLICY="prompt" ;;
    pull|refresh|update) REPO_POLICY="pull" ;;
    continue|keep|existing|offline) REPO_POLICY="continue" ;;
    reclone|clone|fresh) REPO_POLICY="reclone" ;;
    *) die "Invalid repository policy: $REPO_POLICY. Use ask-once, prompt, pull, continue, or reclone." ;;
  esac
}

choose_repo_policy_once() {
  normalize_repo_policy
  if [[ "$REPO_POLICY" != "ask-once" ]]; then
    info "Repository policy supplied: $REPO_POLICY"
    return 0
  fi

  while true; do
    local choice
    choice="$(repo_policy_menu)"
    case "$choice" in
      1) REPO_POLICY="pull"; break ;;
      2) REPO_POLICY="continue"; break ;;
      3) REPO_POLICY="prompt"; break ;;
      4) REPO_POLICY="reclone"; break ;;
      5) open_shell "$SOURCES_DIR" ;;
      6) die "Build aborted before repository refresh." ;;
    esac
  done
  ok "Repository policy for this run: $REPO_POLICY"
}

repo_current_state() {
  local path="$1" branch="$2"
  if [[ ! -d "$path/.git" ]]; then
    printf 'missing'
    return
  fi
  local current commit dirty remote_url
  current="$(git -C "$path" branch --show-current 2>/dev/null || true)"
  commit="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
  remote_url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]]; then dirty="dirty"; else dirty="clean"; fi
  printf 'branch=%s expected=%s commit=%s state=%s origin=%s' "${current:-detached}" "$branch" "${commit:-unknown}" "$dirty" "${remote_url:-unknown}"
}


mark_git_safe_directory_if_needed() {
  # If an earlier build run changed source ownership to the Vib build user,
  # root-owned Git commands may reject the repository as "dubious ownership".
  # Mark only the explicit repository path safe for this build user/root context.
  local path="$1"
  [[ -d "$path/.git" ]] || return 0
  git config --global --add safe.directory "$path" 2>/dev/null || true
}

repair_source_tree_ownership_for_git() {
  # Previous revisions chowned the entire WORKDIR to the non-root Vib user.
  # That broke subsequent Git operations as root. Before refreshing sources,
  # take ownership of source checkouts back to the current user when running as
  # root, and mark each checkout as safe to avoid Git's dubious ownership guard.
  local repo
  [[ "$(id -u)" -eq 0 ]] || return 0

  for repo in "$SOURCES_DIR"/*; do
    [[ -d "$repo/.git" ]] || continue
    info "Preparing Git checkout for root-owned refresh: $repo"
    chown -R root:root "$repo" 2>/dev/null || true
    mark_git_safe_directory_if_needed "$repo"
  done
}

sync_repo() {
  local name="$1" url="$2" branch="$3" path="$4"
  mkdir -p "$(dirname "$path")"
  mark_git_safe_directory_if_needed "$path"

  if [[ -d "$path" && ! -d "$path/.git" ]]; then
    warn "$name path exists but is not a Git repository: $path"
    local choice
    choice="$(menu "Non-Git Directory Found

Repository:
  $name

Location:
  $path

The path exists but does not contain .git. The builder cannot safely pull it as a repository." "2" \
      "1|Open an interactive shell here|Inspect or move the directory manually, then resume." \
      "2|Move it aside and clone fresh [DEFAULT]|Rename the directory with a .non-git timestamp suffix, then clone." \
      "3|Abort build|Stop immediately.")"
    case "$choice" in
      1) open_shell "$path"; sync_repo "$name" "$url" "$branch" "$path"; return ;;
      2) mv "$path" "${path}.non-git.$(date -u +%Y%m%d%H%M%S)" ;;
      3) die "Non-Git repository path encountered for $name." ;;
    esac
  fi

  if [[ -d "$path/.git" ]]; then
    info "$name existing checkout detected: $(repo_current_state "$path" "$branch")"

    local policy="$REPO_POLICY" choice
    if [[ "$policy" == "prompt" ]]; then
      choice="$(repo_action "$name" "$path")"
      case "$choice" in
        1) policy="continue" ;;
        2) policy="pull" ;;
        3) policy="reclone" ;;
        4) open_shell "$path"; sync_repo "$name" "$url" "$branch" "$path"; return ;;
        5) warn "Skipping $name."; return 0 ;;
        6) exit 0 ;;
      esac
    fi

    case "$policy" in
      continue)
        ok "Using existing checkout for $name."
        ;;
      pull)
        info "Refreshing $name."
        git -C "$path" fetch --all --prune
        git -C "$path" checkout "$branch"
        git -C "$path" pull --ff-only
        ok "$name refreshed: $(repo_current_state "$path" "$branch")"
        ;;
      reclone)
        warn "Re-cloning $name."
        rm -rf "$path"
        git clone -b "$branch" "$url" "$path"
        ok "$name cloned: $(repo_current_state "$path" "$branch")"
        ;;
      *) die "Internal error: unsupported repository policy '$policy'" ;;
    esac
  else
    info "Cloning missing repository $name from $url branch $branch."
    git clone -b "$branch" "$url" "$path"
    ok "$name cloned: $(repo_current_state "$path" "$branch")"
  fi
}

# ---------------------------- artifacts --------------------------------

collect_files() {
  local dir="$1" pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -print 2>/dev/null | sort
}

validate_artifacts() {
  local debs dtbs choice
  mkdir -p "$ARTIFACT_DIR"

  while true; do
    mapfile -t KERNEL_DEBS < <(collect_files "$ARTIFACT_DIR" '*.deb')
    mapfile -t DTB_FILES < <(collect_files "$ARTIFACT_DIR" '*.dtb')

    if [[ "${#KERNEL_DEBS[@]}" -gt 0 && "${#DTB_FILES[@]}" -gt 0 ]]; then
      ok "Found ${#KERNEL_DEBS[@]} .deb artifact(s) and ${#DTB_FILES[@]} DTB file(s)."
      PRIMARY_DTB="${DTB_FILES[0]}"
      if [[ "${#DTB_FILES[@]}" -gt 1 ]]; then
        warn "Multiple DTBs found. Current revision uses the first sorted DTB."
        warn "Future revision should enforce Snapdragon SoC-prefixed DTB taxonomy and prompt for primary DTB."
      fi
      return 0
    fi

    printf '\nArtifact directory is incomplete.\n\n' >&2
    printf 'Current directory:\n  %s\n\n' "$ARTIFACT_DIR" >&2
    printf 'Expected at minimum:\n  • one or more *.deb kernel/module/header packages\n  • one or more *.dtb files\n\n' >&2
    printf 'Found:\n  .deb files: %s\n  .dtb files: %s\n' "${#KERNEL_DEBS[@]}" "${#DTB_FILES[@]}" >&2

    choice="$(menu "Artifact Directory Validation" "1" \
      "1|Retry after correcting this directory|Return to validation after you add files." \
      "2|Choose a different artifact directory|Enter another local path containing .deb and .dtb files." \
      "3|Open an interactive shell in this directory|Copy/download files manually, then exit to resume." \
      "4|Skip custom kernel and DTB injection|Not recommended for HP Omnibook 5 target builds." \
      "5|Abort build|Stop immediately.")"
    case "$choice" in
      1) continue ;;
      2) ARTIFACT_DIR="$(prompt_path "Custom kernel/DTB artifact directory" "$ARTIFACT_DIR")"; mkdir -p "$ARTIFACT_DIR" ;;
      3) open_shell "$ARTIFACT_DIR" ;;
      4) warn "Skipping custom kernel and DTB injection."; PRIMARY_DTB=""; KERNEL_DEBS=(); DTB_FILES=(); return 0 ;;
      5) die "Artifact validation failed." ;;
    esac
  done
}

# ------------------------ Qualcomm firmware staging --------------------

configure_qcom_firmware() {
  QCOM_MODE="skip"
  QCOM_ARCHIVE=""
  QCOM_URL=""
  QCOM_PRESTAGED=""
  QCOM_DEVICE_PATH="$QCOM_DEVICE_PATH_DEFAULT"

  local choice
  choice="$(menu "Qualcomm Firmware Source Selection

Qualcomm firmware handling is intentionally isolated.
The builder will NOT install firmware onto this Debian build host.

Choose how the target firmware should be staged for the image build." "1" \
    "1|Use a local Qualcomm Windows Graphics Driver ZIP/EXE|Recommended for reproducible builds. The file is archived in the release inputs." \
    "2|Use a direct Qualcomm driver URL|Convenient, but less reproducible unless the downloaded file is archived." \
    "3|Use a pre-staged firmware directory|Use when you already have the needed /lib/firmware tree extracted." \
    "4|Open an interactive shell before choosing|Download, inspect, or prepare files manually, then resume this menu." \
    "5|Skip Qualcomm firmware extraction for this build|Continue without Qualcomm firmware staging.")"

  case "$choice" in
    1)
      QCOM_MODE="archive"
      local default_archive="$DOWNLOADS_DIR/qualcomm-windows-graphics-driver.zip"
      QCOM_ARCHIVE="$(prompt_existing_file_optional "Local Qualcomm Windows Graphics Driver ZIP/EXE" "$default_archive")"
      [[ -n "$QCOM_ARCHIVE" ]] || QCOM_MODE="skip"
      ;;
    2)
      QCOM_MODE="url"
      QCOM_URL="$(prompt_text "Direct Qualcomm driver URL" "")"
      [[ -n "$QCOM_URL" ]] || QCOM_MODE="skip"
      ;;
    3)
      QCOM_MODE="prestaged"
      QCOM_PRESTAGED="$(prompt_path "Pre-staged Qualcomm firmware directory" "$PRESTAGED_QCOM_DIR")"
      [[ -d "$QCOM_PRESTAGED" ]] || die "Pre-staged firmware directory does not exist: $QCOM_PRESTAGED"
      ;;
    4)
      open_shell "$WORKDIR"
      configure_qcom_firmware
      ;;
    5) QCOM_MODE="skip" ;;
  esac

  if [[ "$QCOM_MODE" != "skip" ]]; then
    QCOM_DEVICE_PATH="$(prompt_text "qcom-firmware-updater device path" "$QCOM_DEVICE_PATH_DEFAULT")"
  fi
}

qcom_container_network_menu() {
  # Return a podman network argument string on stdout.
  # We default to host networking on Debian/Podman VMs because rootful Podman
  # containers can sometimes pull images successfully but fail DNS resolution
  # inside the running container when using the default bridge/slirp network.
  local choice
  choice="$(menu "Qualcomm Extraction Container Network

The firmware extractor runs inside a disposable Debian container.
It must have DNS/network access only to install temporary extraction tools
inside that container. Nothing is installed onto the build host.

If earlier attempts showed 'Temporary failure resolving deb.debian.org',
choose host networking." "1" \
    "1|Use host networking for the disposable extraction container|Recommended when Podman containers cannot resolve deb.debian.org." \
    "2|Use Podman's default container networking|Use this if default container DNS is known to work." \
    "3|Open an interactive shell before continuing|Inspect Podman/DNS configuration manually, then resume." \
    "4|Skip Qualcomm firmware extraction|Continue the build without staged Qualcomm firmware.")"
  case "$choice" in
    1) printf '%s' '--network=host' ;;
    2) printf '%s' '' ;;
    3) open_shell "$WORKDIR"; qcom_container_network_menu ;;
    4) printf '%s' 'SKIP' ;;
  esac
}

stage_qcom_firmware() {
  rm -rf "$STAGED_QCOM_DIR"
  mkdir -p "$STAGED_QCOM_DIR"

  case "$QCOM_MODE" in
    skip)
      warn "Qualcomm firmware staging skipped."
      return 0
      ;;
    prestaged)
      info "Copying pre-staged Qualcomm firmware tree."
      rsync -a "$QCOM_PRESTAGED"/ "$STAGED_QCOM_DIR"/
      ;;
    archive|url)
      info "Preparing isolated Qualcomm firmware extraction container."
      local updater_dir="$SOURCES_DIR/qcom-firmware-updater"
      if [[ -d "$updater_dir/.git" ]]; then
        git -C "$updater_dir" pull --ff-only || warn "Could not fast-forward qcom-firmware-updater; using existing checkout."
      else
        git clone https://github.com/alejandroqh/qcom-firmware-updater "$updater_dir"
      fi

      local work="$TMP_DIR/qcom-extract-$$"
      rm -rf "$work"
      mkdir -p "$work/out" "$work/input"

      if [[ "$QCOM_MODE" == "archive" ]]; then
        # Preserve the original archive extension. The updater may branch on it.
        cp -a "$QCOM_ARCHIVE" "$work/input/$(basename "$QCOM_ARCHIVE")"
      fi

      local run_script="$work/run-qcom-extract.sh"
      cat >"$run_script" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf 'qcom-container: %s\n' "$*"; }
fail() { printf 'qcom-container: ERROR: %s\n' "$*" >&2; exit 1; }

log "Disposable extraction environment started."
log "This container may write only inside the container and /out, never to the build host."

# Fail early with a clear diagnostic instead of allowing apt-get to continue
# with stale/empty indexes and then produce misleading package errors.
if ! getent hosts deb.debian.org >/dev/null 2>&1; then
  log "DNS preflight failed: deb.debian.org does not resolve inside this container."
  log "Retry with host networking, or use a pre-staged firmware directory."
  exit 70
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
# qcom-firmware-updater currently needs unzip, msiextract from msitools,
# sha256sum/coreutils, and either 7zz/7z. Debian package naming for 7z has
# changed across releases, so try 7zip first and fall back to p7zip-full.
if ! apt-get install -y --no-install-recommends \
  ca-certificates curl unzip msitools 7zip zstd rsync bash coreutils findutils file grep sed gawk; then
  apt-get install -y --no-install-recommends \
    ca-certificates curl unzip msitools p7zip-full zstd rsync bash coreutils findutils file grep sed gawk
fi

# qcom-firmware-updater is designed for a live target system and uses sudo
# only for installation steps. This wrapper avoids its installation path and
# captures the extracted firmware staging directory directly. Keep a harmless
# sudo shim anyway so any incidental sudo calls cannot affect the build host.
printf '#!/usr/bin/env bash\nexec "$@"\n' >/usr/local/bin/sudo
chmod +x /usr/local/bin/sudo

mkdir -p /out/lib/firmware /out/logs /work
cp -a /updater /work/qcom-firmware-updater
cd /work/qcom-firmware-updater

log "Preparing qcom-firmware-updater capture wrapper."
log "Device path: ${QCOM_DEVICE_PATH:-unset}"

# The upstream script's install function may be disabled/commented in current
# revisions. Therefore do not rely on /lib/firmware side effects. Instead,
# load the script's functions but suppress the trailing 'main "$@"', then run
# parse/check/extract/find ourselves and copy fw_staging into /out.
orig="$(cat ./qcom-firmware-updater.sh)"
orig="${orig%$'\n'}"
case "$orig" in
  *'main "$@"') orig="${orig%main \"\$@\"}" ;;
  *) log "Could not strip trailing main invocation using suffix match; falling back to direct execution." ;;
esac
printf '%s\n' "$orig" > /work/qcom-functions.sh
cat >> /work/qcom-functions.sh <<'CAPTURE_EOF'

capture_main() {
  parse_args "$@"
  check_deps

  if [[ -z "$DEVICE_PATH" ]]; then
    detect_device
  else
    info "Using manual device path: $DEVICE_PATH"
  fi

  FIRMWARE_DIR="$FIRMWARE_BASE/$DEVICE_PATH"
  TMPDIR=$(mktemp -d /tmp/qcom-fw-capture.XXXXXX)

  local input_path=""
  if [[ -n "$INPUT_URL" ]]; then
    input_path="$TMPDIR/download.zip"
    download_driver "$input_path"
  else
    [[ -f "$INPUT_FILE" ]] || die "File not found: $INPUT_FILE"
    input_path="$INPUT_FILE"
  fi

  local extract_root
  extract_root=$(extract_exe "$input_path")

  local fw_staging
  fw_staging=$(find_firmware "$extract_root")

  local dest="/out/lib/firmware/qcom/$DEVICE_PATH"
  mkdir -p "$dest"
  cp -a "$fw_staging"/. "$dest"/
  chmod -R a+rX /out/lib/firmware || true

  printf '%s\n' "$fw_staging" > /out/logs/fw_staging_path.txt
  find "$dest" -type f | sort > /out/logs/captured-firmware-files.txt
  info "Captured $(find "$dest" -type f | wc -l) firmware file(s) into $dest"
}

capture_main "$@"
CAPTURE_EOF
chmod +x /work/qcom-functions.sh

if [[ -n "${QCOM_URL:-}" ]]; then
  log "Using Qualcomm driver URL."
  bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" --url "$QCOM_URL" 2>&1 | tee /out/logs/qcom-capture.log
elif compgen -G "/input/*" >/dev/null; then
  local_file="$(find /input -maxdepth 1 -type f | sort | head -n1)"
  log "Using local driver archive: $local_file"
  bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" "$local_file" 2>&1 | tee /out/logs/qcom-capture.log
else
  fail "No local archive or URL was supplied to the container."
fi

# Preserve the updater working tree and extraction logs for operator inspection.
mkdir -p /out/updater-workdir
rsync -a /work/qcom-firmware-updater/ /out/updater-workdir/ || true
rsync -a /work/qcom-functions.sh /out/logs/qcom-functions.capture.sh || true

if find /out/lib/firmware -type f | grep -q .; then
  log "Captured firmware files under /out/lib/firmware."
else
  log "No firmware files captured under /out/lib/firmware."
fi
EOS
      chmod +x "$run_script"

      local net_arg container_rc choice
      net_arg="$(qcom_container_network_menu)"
      if [[ "$net_arg" == "SKIP" ]]; then
        warn "Qualcomm firmware staging skipped by operator."
        return 0
      fi

      # Run the disposable container. Do not use host mounts for /lib/firmware.
      # The only writable output is $work/out, which is later copied into the
      # target-image staging directory.
      set +e
      if [[ -n "$net_arg" ]]; then
        podman run --rm --privileged $net_arg \
          -e QCOM_URL="${QCOM_URL:-}" \
          -e QCOM_DEVICE_PATH="$QCOM_DEVICE_PATH" \
          -v "$updater_dir:/updater:ro" \
          -v "$work/input:/input:ro" \
          -v "$work/out:/out" \
          -v "$run_script:/run-qcom-extract.sh:ro" \
          debian:13 \
          /bin/bash /run-qcom-extract.sh
      else
        podman run --rm --privileged \
          -e QCOM_URL="${QCOM_URL:-}" \
          -e QCOM_DEVICE_PATH="$QCOM_DEVICE_PATH" \
          -v "$updater_dir:/updater:ro" \
          -v "$work/input:/input:ro" \
          -v "$work/out:/out" \
          -v "$run_script:/run-qcom-extract.sh:ro" \
          debian:13 \
          /bin/bash /run-qcom-extract.sh
      fi
      container_rc=$?
      set -e

      if [[ "$container_rc" -eq 70 ]]; then
        warn "Container DNS preflight failed."
        choice="$(menu "Qualcomm Container DNS Failure

The Debian extraction container could not resolve deb.debian.org.
The build host was not modified.

Most likely causes:
  • Podman container DNS/network configuration problem
  • VM DNS problem
  • Temporary upstream DNS/network outage

Recommended next attempt: host networking." "1" \
          "1|Retry extraction with host networking|Run the same disposable container with --network=host." \
          "2|Open shell to inspect extraction workspace|Review scripts, input archive, and Podman/DNS state." \
          "3|Use pre-staged firmware instead|Return to configuration and select an already extracted firmware tree." \
          "4|Continue without staged Qualcomm firmware|Build may boot but target may lack required firmware." \
          "5|Abort build|Stop immediately.")"
        case "$choice" in
          1)
            net_arg='--network=host'
            set +e
            podman run --rm --privileged $net_arg \
              -e QCOM_URL="${QCOM_URL:-}" \
              -e QCOM_DEVICE_PATH="$QCOM_DEVICE_PATH" \
              -v "$updater_dir:/updater:ro" \
              -v "$work/input:/input:ro" \
              -v "$work/out:/out" \
              -v "$run_script:/run-qcom-extract.sh:ro" \
              debian:13 \
              /bin/bash /run-qcom-extract.sh
            container_rc=$?
            set -e
            ;;
          2) open_shell "$work" ;;
          3) QCOM_MODE="prestaged"; QCOM_PRESTAGED="$(prompt_path "Pre-staged Qualcomm firmware directory" "$PRESTAGED_QCOM_DIR")"; [[ -d "$QCOM_PRESTAGED" ]] || die "Pre-staged firmware directory does not exist: $QCOM_PRESTAGED"; rsync -a "$QCOM_PRESTAGED"/ "$STAGED_QCOM_DIR"/; return 0 ;;
          4) warn "Continuing without staged Qualcomm firmware."; return 0 ;;
          5) die "Qualcomm firmware extraction aborted." ;;
        esac
      elif [[ "$container_rc" -ne 0 ]]; then
        warn "Containerized qcom extraction returned non-zero exit code: $container_rc"
      fi

      if [[ -d "$work/out/lib/firmware" ]]; then
        rsync -a "$work/out/lib/firmware"/ "$STAGED_QCOM_DIR"/
      fi

      if ! find "$STAGED_QCOM_DIR" -type f | grep -q .; then
        warn "No Qualcomm firmware files were captured."
        warn "Extraction workspace preserved for inspection: $work"
        local c
        c="$(menu "Qualcomm Firmware Capture Empty

The extractor completed or partially completed, but no files were captured
under the staged target firmware directory:
  $STAGED_QCOM_DIR

This can happen if the updater's CLI changed, the supplied archive is not
the expected Qualcomm package, or additional manual interaction is required." "1" \
          "1|Continue without staged Qualcomm firmware|Build will proceed, but target may lack required firmware." \
          "2|Open shell to inspect extraction workspace|Inspect files, copy staged firmware manually into $STAGED_QCOM_DIR, then resume." \
          "3|Use pre-staged firmware directory instead|Select an already extracted firmware tree and copy it into staging." \
          "4|Abort build|Stop immediately.")"
        case "$c" in
          1) ;;
          2) open_shell "$work" ;;
          3) QCOM_PRESTAGED="$(prompt_path "Pre-staged Qualcomm firmware directory" "$PRESTAGED_QCOM_DIR")"; [[ -d "$QCOM_PRESTAGED" ]] || die "Pre-staged firmware directory does not exist: $QCOM_PRESTAGED"; rsync -a "$QCOM_PRESTAGED"/ "$STAGED_QCOM_DIR"/ ;;
          4) die "Qualcomm firmware staging failed." ;;
        esac
      fi
      ;;
  esac
}


resolve_custom_kernel_release() {
  # Determine the kernel release expected from the supplied linux-image .deb.
  # Prefer the package name because Debian kernel packages conventionally use:
  #   linux-image-<kernel-release>
  local deb pkg release

  for deb in "${KERNEL_DEBS[@]:-}"; do
    [[ -f "$deb" ]] || continue
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    case "$pkg" in
      linux-image-*)
        release="${pkg#linux-image-}"
        printf '%s\n' "$release"
        return 0
        ;;
    esac
  done

  return 1
}

patch_live_iso_grub_for_custom_dtb() {
  # The upstream ARM live-ISO GRUB template may be minified onto one physical
  # line. Patch the complete file as text instead of requiring a line beginning
  # with "linux".
  local live="$1"
  local dtb_name="$2"
  local grub="$live/etc/config/bootloaders/grub-pc/grub.cfg"
  local backup tmp log expected_entries patched_entries rc

  [[ -f "$grub" ]] || die "Live ISO GRUB template not found: $grub"

  backup="$grub.builder-backup-custom-dtb.$(date -u +%Y%m%d%H%M%S)"
  tmp="$grub.builder-patched.$$"
  log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-iso-grub-dtb-patch-$(date -u +%H%M%S).log"
  mkdir -p "$OUTPUT_DIR/logs"
  cp -a "$grub" "$backup"

  expected_entries="$(grep -oE 'initrd(efi)?[[:space:]]+INITRD_LIVE' "$grub" | wc -l | awk '{print $1}')"

  {
    printf 'GRUB template: %s\n' "$grub"
    printf 'DTB: %s\n' "$dtb_name"
    printf 'INITRD_LIVE entries: %s\n\n' "$expected_entries"
    sed -n '1,240p' "$grub"
  } >"$log"

  if [[ "${expected_entries:-0}" -eq 0 ]]; then
    fail "The live ISO GRUB template contains no INITRD_LIVE commands."
    warn "GRUB patch log: $log"
    return 1
  fi

  set +e
  python3 - "$grub" "$tmp" "$dtb_name" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
dtb = sys.argv[3]
marker = "CUSTOM_ARM64_DTB_MANAGED_BY_BUILDER"

data = src.read_text(encoding="utf-8")

# Remove directives from previous builder runs.
data = re.sub(
    r"\s*devicetree\s+/boot/dtbs/[^\s;}\n]+"
    r"(?:\s+#\s*CUSTOM_ARM64_DTB_MANAGED_BY_BUILDER)?\s*",
    " ",
    data,
)

# Insert before every live initrd placeholder, regardless of one-line or
# multi-line formatting.
pattern = re.compile(r"\b(initrd(?:efi)?\s+INITRD_LIVE)\b")
replacement = (
    f"\n    devicetree /boot/dtbs/{dtb} # {marker}\n"
    r"    \1"
)
data, count = pattern.subn(replacement, data)

if count == 0:
    sys.exit(20)

dst.write_text(data, encoding="utf-8")
print(count)
PY
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp"
    fail "Unable to patch live ISO GRUB template with custom DTB."
    warn "GRUB patch log: $log"
    return "$rc"
  fi

  mv "$tmp" "$grub"
  patched_entries="$(grep -c "devicetree /boot/dtbs/$dtb_name" "$grub" || true)"

  {
    printf '\nPatched directive count: %s\n' "$patched_entries"
    printf '\nDiff:\n'
    diff -u "$backup" "$grub" || true
  } >>"$log"

  if [[ "${patched_entries:-0}" -ne "${expected_entries:-0}" ]]; then
    fail "DTB directive count mismatch: expected $expected_entries, patched $patched_entries."
    warn "GRUB patch log: $log"
    return 1
  fi

  ok "Patched $patched_entries live ISO GRUB entries to load DTB: $dtb_name"
  printf 'GRUB patch log:\n  %s\n' "$log" >&2
}

verify_live_iso_source_integration() {
  local live="$1"
  local expected_kver="$2"
  local dtb_name="$3"
  local failed=0

  info "Verifying live ISO custom kernel/DTB source integration."

  [[ -d "$live/etc/config/packages.chroot" ]] || {
    fail "Missing live-build packages.chroot directory."
    failed=1
  }

  if ! find "$live/etc/config/packages.chroot" -maxdepth 1 -type f -name 'linux-image-*.deb' | grep -q .; then
    fail "No custom linux-image .deb staged under config/packages.chroot."
    failed=1
  fi

  if [[ "$INSTALL_CUSTOM_KERNEL_HEADERS_IN_LIVE" != "1" ]] &&      find "$live/etc/config/packages.chroot" -maxdepth 1 -type f -name 'linux-headers-*.deb' | grep -q .; then
    fail "Kernel headers were staged into the live chroot despite headers policy being disabled."
    failed=1
  fi

  if [[ "$INSTALL_CUSTOM_KERNEL_TOOLS_IN_LIVE" != "1" ]] &&      find "$live/etc/config/packages.chroot" -maxdepth 1 -type f \( -name 'linux-tools-*.deb' -o -name 'linux-*-tools-*.deb' \) | grep -q .; then
    fail "Kernel tools were staged into the live chroot despite tools policy being disabled."
    failed=1
  fi

  if grep -RqsE '^[[:space:]]*(linux-image-arm64|linux-headers-arm64)[[:space:]]*$' "$live/etc/config/package-lists" 2>/dev/null; then
    fail "Standard Debian ARM64 kernel metapackage remains in live-build package lists."
    failed=1
  fi

  [[ -x "$live/etc/config/hooks/live/095-custom-arm64-kernel.chroot" ]] || {
    fail "Missing executable custom-kernel live-build hook."
    failed=1
  }

  grep -q "EXPECTED_CUSTOM_KERNEL=$expected_kver" "$live/etc/config/hooks/live/095-custom-arm64-kernel.chroot" || {
    fail "Custom-kernel hook does not contain expected kernel release: $expected_kver"
    failed=1
  }

  grep -q "devicetree /boot/dtbs/$dtb_name" "$live/etc/config/bootloaders/grub-pc/grub.cfg" || {
    fail "GRUB template does not load expected DTB: $dtb_name"
    failed=1
  }

  [[ -f "$live/etc/config/includes.binary/boot/dtbs/$dtb_name" ]] || {
    fail "DTB is missing from ISO binary includes."
    failed=1
  }

  [[ "$failed" -eq 0 ]] || return 1
  ok "Live ISO custom kernel/DTB source integration verified."
}

verify_built_iso_custom_boot_artifacts() {
  # Verify the ISO itself, not only the source tree. This checks:
  #   - DTB present in ISO binary filesystem
  #   - GRUB config contains devicetree directive
  #   - live squashfs contains custom /boot/vmlinuz and /lib/modules release
  local live="$1"
  local expected_kver="$2"
  local dtb_name="$3"
  local iso work listing squashfs grub_extract log

  [[ "$VERIFY_CUSTOM_KERNEL_IN_ISO" == "1" ]] || return 0

  iso="$(find "$live/builds" -type f -name '*.iso' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"
  [[ -n "$iso" && -f "$iso" ]] || die "Unable to locate generated ISO for custom boot verification."

  work="$TMP_DIR/iso-custom-boot-verify-$$"
  listing="$work/iso-listing.txt"
  squashfs="$work/filesystem.squashfs"
  grub_extract="$work/grub.cfg"
  log="$OUTPUT_DIR/logs/${BUILD_DATE}-iso-custom-kernel-dtb-verification-$(date -u +%H%M%S).log"
  mkdir -p "$work" "$OUTPUT_DIR/logs"

  {
    printf 'ISO: %s\n' "$iso"
    printf 'Expected kernel release: %s\n' "$expected_kver"
    printf 'Expected DTB: %s\n\n' "$dtb_name"
  } >"$log"

  xorriso -indev "$iso" -find / -type f -print >"$listing" 2>>"$log" \
    || die "Unable to list generated ISO with xorriso."

  grep -q "/boot/dtbs/$dtb_name" "$listing" || {
    fail "Generated ISO does not contain /boot/dtbs/$dtb_name"
    warn "Verification log: $log"
    return 1
  }

  # Locate/extract GRUB config from common live-build ISO paths.
  local grub_path
  grub_path="$(grep -E '/boot/grub/grub.cfg$|/EFI/BOOT/grub.cfg$' "$listing" | head -n1 || true)"
  if [[ -n "$grub_path" ]]; then
    xorriso -osirrox on -indev "$iso" -extract "$grub_path" "$grub_extract" >>"$log" 2>&1 || true
    if [[ -f "$grub_extract" ]]; then
      grep -q "devicetree /boot/dtbs/$dtb_name" "$grub_extract" || {
        fail "Generated ISO GRUB config does not contain expected devicetree directive."
        warn "Verification log: $log"
        return 1
      }
    fi
  fi

  local squash_path
  squash_path="$(grep -E '/live/filesystem\.squashfs$' "$listing" | head -n1 || true)"
  [[ -n "$squash_path" ]] || {
    fail "Generated ISO does not contain /live/filesystem.squashfs"
    return 1
  }

  xorriso -osirrox on -indev "$iso" -extract "$squash_path" "$squashfs" >>"$log" 2>&1 \
    || die "Unable to extract filesystem.squashfs for verification."

  if ! unsquashfs -ll "$squashfs" 2>>"$log" | grep -Eq "(/boot/vmlinuz-$expected_kver|/lib/modules/$expected_kver)"; then
    fail "Generated ISO live filesystem does not contain custom kernel release $expected_kver."
    warn "Verification log: $log"
    return 1
  fi

  ok "Generated ISO contains the custom kernel and DTB boot integration."
  printf 'ISO verification log:\n  %s\n' "$log" >&2
}


classify_kernel_deb_for_live() {
  # Print one of:
  #   boot      -> install into live chroot
  #   headers   -> optional development package
  #   tools     -> optional tooling package
  #   metadata  -> do not install
  #   other     -> do not install automatically
  local deb="$1"
  local pkg

  pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"

  case "$pkg" in
    linux-image-*|linux-modules-*|linux-modules-extra-*)
      printf '%s\n' "boot"
      ;;
    linux-headers-*|linux-*-headers-*)
      printf '%s\n' "headers"
      ;;
    linux-tools-*|linux-*-tools-*)
      printf '%s\n' "tools"
      ;;
    linux-buildinfo-*|*.buildinfo|*.changes)
      printf '%s\n' "metadata"
      ;;
    *)
      printf '%s\n' "other"
      ;;
  esac
}

stage_live_custom_kernel_packages() {
  # Install only packages needed to boot the live ISO. Headers and tools are not
  # boot dependencies and can introduce unavailable cross-distribution package
  # dependencies such as linux-tools-common.
  local live="$1"
  local packages_dir="$live/etc/config/packages.chroot"
  local archive_dir="$live/etc/config/includes.chroot/root/custom-kernel-packages"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-custom-kernel-package-selection-$(date -u +%H%M%S).log"
  local deb class pkg boot_count=0

  mkdir -p "$packages_dir" "$archive_dir" "$OUTPUT_DIR/logs"

  # Remove packages staged by previous builder revisions.
  find "$packages_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
  rm -rf "$archive_dir"
  mkdir -p "$archive_dir"

  {
    printf '### Live custom-kernel package selection\n'
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Headers in live: %s\n' "$INSTALL_CUSTOM_KERNEL_HEADERS_IN_LIVE"
    printf 'Tools in live: %s\n\n' "$INSTALL_CUSTOM_KERNEL_TOOLS_IN_LIVE"
  } >"$log"

  for deb in "${KERNEL_DEBS[@]:-}"; do
    [[ -f "$deb" ]] || continue
    class="$(classify_kernel_deb_for_live "$deb")"
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || basename "$deb")"

    printf '%s\t%s\t%s\n' "$class" "$pkg" "$deb" >>"$log"

    # Preserve every supplied package as a reference artifact inside /root,
    # but install only packages appropriate for the live boot environment.
    cp -a "$deb" "$archive_dir/"

    case "$class" in
      boot)
        cp -a "$deb" "$packages_dir/"
        boot_count=$((boot_count + 1))
        ;;
      headers)
        if [[ "$INSTALL_CUSTOM_KERNEL_HEADERS_IN_LIVE" == "1" ]]; then
          cp -a "$deb" "$packages_dir/"
        fi
        ;;
      tools)
        if [[ "$INSTALL_CUSTOM_KERNEL_TOOLS_IN_LIVE" == "1" ]]; then
          cp -a "$deb" "$packages_dir/"
        fi
        ;;
      metadata|other)
        ;;
    esac
  done

  if [[ "$boot_count" -eq 0 ]]; then
    fail "No boot-critical custom kernel packages were selected for the live ISO."
    warn "Package selection log: $log"
    return 1
  fi

  ok "Selected $boot_count boot-critical custom kernel package(s) for live ISO."
  printf 'Kernel package selection log:\n  %s\n' "$log" >&2
}

remove_standard_kernel_metapackages_from_live() {
  # The Vanilla live ISO package lists can select Debian's linux-image-arm64 and
  # linux-headers-arm64 metapackages. Those conflict with the custom kernel and
  # pull an unrelated standard kernel into the ISO.
  local live="$1"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-standard-kernel-metapackage-removal-$(date -u +%H%M%S).log"
  local file tmp changed=0

  mkdir -p "$OUTPUT_DIR/logs"
  : >"$log"

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    if grep -Eq '^[[:space:]]*(linux-image-arm64|linux-headers-arm64)[[:space:]]*$' "$file"; then
      tmp="$file.builder-kernel-meta.$$"
      awk '
        !/^[[:space:]]*linux-image-arm64[[:space:]]*$/ &&
        !/^[[:space:]]*linux-headers-arm64[[:space:]]*$/
      ' "$file" >"$tmp"
      cp -a "$file" "$file.builder-backup-kernel-meta.$(date -u +%Y%m%d%H%M%S)"
      mv "$tmp" "$file"
      printf 'PATCHED %s\n' "$file" >>"$log"
      changed=1
    fi
  done < <(find "$live/etc/config" -type f \( -name '*.list.chroot' -o -name '*.list.binary' -o -name '*.list' \) 2>/dev/null | sort)

  if [[ "$changed" -eq 1 ]]; then
    warn "Removed standard ARM64 kernel metapackages from live-build package lists."
    warn "Metapackage removal log: $log"
  else
    ok "No standard ARM64 kernel metapackages found in live-build package lists."
  fi
}

write_live_custom_kernel_dependency_list() {
  # Explicit runtime dependencies for the custom kernel and live environment.
  # Do not include linux-tools-common: it is unavailable in the current Vanilla
  # repository snapshot and is only required by optional tools packages.
  local live="$1"
  local list="$live/etc/config/package-lists/zz-custom-arm64-kernel.list.chroot"

  mkdir -p "$(dirname "$list")"

  cat >"$list" <<'EOF'
linux-base
initramfs-tools
wireless-regdb
rsync
uuid-runtime
wget
ca-certificates
EOF

  ok "Wrote custom kernel dependency package list: $list"
}


patch_live_installer_hook() {
  local live="$1"
  local hook="$live/etc/config/hooks/live/001-install-vanilla-installer.chroot"
  local backup log albius_url installer_url

  [[ "$PATCH_LIVE_INSTALLER_HOOK" == "1" ]] || return 0
  [[ -f "$hook" ]] || { warn "Installer hook not found: $hook"; return 0; }

  backup="$hook.builder-backup.$(date -u +%Y%m%d%H%M%S)"
  log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-installer-hook-patch-$(date -u +%H%M%S).log"
  mkdir -p "$OUTPUT_DIR/logs"
  cp -a "$hook" "$backup"

  albius_url="$(grep -Eo 'https?://[^"'"'"' ]*albius[^"'"'"' ]*\.deb' "$hook" | head -n1 || true)"
  installer_url="$(grep -Eo 'https?://[^"'"'"' ]*vanilla-installer[^"'"'"' ]*\.deb' "$hook" | head -n1 || true)"

  [[ -n "$albius_url" && -n "$installer_url" ]] || {
    fail "Could not extract installer package URLs from $hook"
    return 1
  }

  cat >"$hook" <<EOF
#!/bin/sh
set -eu
ALBIUS_URL='$albius_url'
INSTALLER_URL='$installer_url'

apt-get update
apt-get install -y --no-install-recommends wget ca-certificates

download_deb() {
  url="\$1"
  output="\$2"
  rm -f "\$output"
  wget --https-only --tries=5 --timeout=30 -O "\$output" "\$url"
  test -s "\$output" || { echo "ERROR: empty download: \$output" >&2; exit 91; }
  dpkg-deb --info "\$output" >/dev/null 2>&1 || {
    echo "ERROR: invalid Debian package: \$output" >&2
    exit 92
  }
}

download_deb "\$ALBIUS_URL" /tmp/albius.deb
apt-get install -y /tmp/albius.deb
rm -f /tmp/albius.deb

download_deb "\$INSTALLER_URL" /tmp/vanilla-installer.deb
apt-get install -y /tmp/vanilla-installer.deb
rm -f /tmp/vanilla-installer.deb
EOF

  chmod +x "$hook"
  {
    printf 'Hook: %s\nBackup: %s\n' "$hook" "$backup"
    diff -u "$backup" "$hook" || true
  } >"$log"

  ok "Hardened Vanilla installer live-build hook."
  printf 'Installer hook patch log:\n  %s\n' "$log" >&2
}

patch_remove_blacklisted_packages_hook() {
  local live="$1"
  local hook="$live/etc/config/hooks/live/000-remove-blacklisted-packages.chroot"
  [[ -f "$hook" ]] || return 0

  python3 - "$hook" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
out = []
for line in lines:
    stripped = line.strip()
    if "/etc/rc.local" in line and not stripped.startswith(("if ", "[ ", "test ")):
        indent = line[:len(line)-len(line.lstrip())]
        out.append(f"{indent}if [ -e /etc/rc.local ]; then")
        out.append(f"{indent}  {line.lstrip()}")
        out.append(f"{indent}fi")
    else:
        out.append(line)
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
  chmod +x "$hook"
}

# ------------------------- staging into repos --------------------------

stage_customizations() {
  local core="$SOURCES_DIR/core-image"
  local desktop="$SOURCES_DIR/desktop-image"
  local live="$SOURCES_DIR/live-iso"

  info "Staging local artifacts and overlays into source trees."

  for repo in "$core" "$desktop"; do
    [[ -d "$repo" ]] || continue
    mkdir -p "$repo/includes.container/opt/vendor-kernel" "$repo/includes.container/boot/dtbs" "$repo/includes.container/root"
    for f in "${KERNEL_DEBS[@]:-}"; do cp -a "$f" "$repo/includes.container/opt/vendor-kernel/"; done
    for f in "${DTB_FILES[@]:-}"; do cp -a "$f" "$repo/includes.container/boot/dtbs/"; done
    if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
      rsync -a "$ROOT_OVERLAY_DIR"/ "$repo/includes.container/root"/
    fi
    if [[ -d "$STAGED_QCOM_DIR" ]] && find "$STAGED_QCOM_DIR" -type f | grep -q .; then
      mkdir -p "$repo/includes.container/lib/firmware"
      rsync -a "$STAGED_QCOM_DIR"/ "$repo/includes.container/lib/firmware"/
    fi

    mkdir -p "$repo/modules"
    cat >"$repo/modules/zz-custom-arm64-kernel.yml" <<'EOF'
name: zz-custom-arm64-kernel
type: shell
commands:
  - |
    set -eu
    if ls /opt/vendor-kernel/*.deb >/dev/null 2>&1; then
      dpkg -i /opt/vendor-kernel/*.deb || apt -f install -y
    fi
    mkdir -p /boot/dtbs
    if ls /boot/dtbs/*.dtb >/dev/null 2>&1; then
      echo "Custom DTBs staged under /boot/dtbs"
    fi
    if command -v update-initramfs >/dev/null 2>&1; then
      update-initramfs -c -k all || update-initramfs -u -k all || true
    fi
    if command -v update-grub >/dev/null 2>&1; then
      update-grub || true
    fi
EOF
  done

  if [[ -d "$live" ]]; then
    local expected_kver dtb_name
    expected_kver="$(resolve_custom_kernel_release || true)"
    [[ -n "$expected_kver" ]] || die "Unable to determine custom kernel release from supplied linux-image .deb."
    [[ -n "${PRIMARY_DTB:-}" ]] || die "A primary DTB is required for the ARM64 live ISO."
    dtb_name="$(basename "$PRIMARY_DTB")"

    # live-build native local package input. Packages placed here are installed
    # into the live chroot as packages, rather than copied as inert files.
    mkdir -p "$live/etc/config/packages.chroot" \
             "$live/etc/config/includes.chroot/boot/dtbs" \
             "$live/etc/config/includes.binary/boot/dtbs" \
             "$live/etc/config/includes.chroot/root"

    # Remove stale copies from previous builder revisions to keep reruns
    # deterministic and prevent multiple kernel versions from accumulating.
    find "$live/etc/config/packages.chroot" -maxdepth 1 -type f \
      \( -name 'linux-image-*.deb' -o -name 'linux-modules-*.deb' -o -name 'linux-headers-*.deb' -o -name 'linux-tools-*.deb' -o -name 'linux-buildinfo-*.deb' \) \
      -delete 2>/dev/null || true
    rm -rf "$live/etc/config/includes.chroot/opt/vendor-kernel"
    rm -f "$live/etc/config/hooks/live/010-custom-arm64-kernel.chroot"
    rm -f "$live/etc/config/includes.binary/boot/grub/custom-dtb.cfg"

    stage_live_custom_kernel_packages "$live"       || die "Unable to stage boot-critical custom kernel packages for live ISO."
    remove_standard_kernel_metapackages_from_live "$live"
    write_live_custom_kernel_dependency_list "$live"
    patch_live_installer_hook "$live"       || die "Unable to harden the Vanilla installer live-build hook."
    patch_remove_blacklisted_packages_hook "$live"

    for f in "${DTB_FILES[@]:-}"; do
      cp -a "$f" "$live/etc/config/includes.chroot/boot/dtbs/"
      cp -a "$f" "$live/etc/config/includes.binary/boot/dtbs/"
    done

    if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
      rsync -a "$ROOT_OVERLAY_DIR"/ "$live/etc/config/includes.chroot/root"/
    fi

    if [[ -d "$STAGED_QCOM_DIR" ]] && find "$STAGED_QCOM_DIR" -type f | grep -q .; then
      mkdir -p "$live/etc/config/includes.chroot/usr/lib/firmware"
      rsync -a "$STAGED_QCOM_DIR"/ "$live/etc/config/includes.chroot/usr/lib/firmware"/
    fi

    # Run late enough that Vanilla's core-package hooks have completed, but
    # before final cleanup. Fail hard if the expected custom kernel did not
    # install. Do not silently fall back to the standard kernel.
    mkdir -p "$live/etc/config/hooks/live"
    cat >"$live/etc/config/hooks/live/095-custom-arm64-kernel.chroot" <<EOF
#!/bin/sh
set -eu

EXPECTED_CUSTOM_KERNEL=$expected_kver
EXPECTED_CUSTOM_DTB=$dtb_name

echo "Validating custom ARM64 kernel: \$EXPECTED_CUSTOM_KERNEL"

if [ ! -d "/lib/modules/\$EXPECTED_CUSTOM_KERNEL" ]; then
  echo "ERROR: custom kernel modules missing: /lib/modules/\$EXPECTED_CUSTOM_KERNEL" >&2
  dpkg-query -W 'linux-image-*' 'linux-modules-*' 2>/dev/null || true
  exit 81
fi

if [ ! -e "/boot/vmlinuz-\$EXPECTED_CUSTOM_KERNEL" ]; then
  echo "ERROR: custom kernel image missing: /boot/vmlinuz-\$EXPECTED_CUSTOM_KERNEL" >&2
  exit 82
fi

if [ ! -f "/boot/dtbs/\$EXPECTED_CUSTOM_DTB" ]; then
  echo "ERROR: custom DTB missing: /boot/dtbs/\$EXPECTED_CUSTOM_DTB" >&2
  exit 83
fi

# Generate an initramfs specifically for the custom kernel. A generic '-k all'
# can leave live-build selecting the wrong kernel/initrd pair.
rm -f "/boot/initrd.img-\$EXPECTED_CUSTOM_KERNEL"
update-initramfs -c -k "\$EXPECTED_CUSTOM_KERNEL"

test -s "/boot/initrd.img-\$EXPECTED_CUSTOM_KERNEL" || {
  echo "ERROR: custom initramfs was not generated." >&2
  exit 84
}

# Make the intended kernel explicit for tools that follow the standard links.
ln -sfn "boot/vmlinuz-\$EXPECTED_CUSTOM_KERNEL" /vmlinuz
ln -sfn "boot/initrd.img-\$EXPECTED_CUSTOM_KERNEL" /initrd.img

printf '%s\n' "\$EXPECTED_CUSTOM_KERNEL" > /etc/vanilla-custom-kernel-release
printf '%s\n' "\$EXPECTED_CUSTOM_DTB" > /etc/vanilla-custom-dtb

echo "Custom ARM64 kernel and DTB validated successfully."
EOF
    chmod +x "$live/etc/config/hooks/live/095-custom-arm64-kernel.chroot"

    patch_live_iso_grub_for_custom_dtb "$live" "$dtb_name" \
      || die "Unable to integrate the custom DTB into the live ISO GRUB template."
    verify_live_iso_source_integration "$live" "$expected_kver" "$dtb_name" \
      || die "Live ISO custom kernel/DTB source verification failed."
  fi
}

# ------------------------------- build --------------------------------

repair_known_vib_recipe_yaml() {
  # Some Vanilla ARM source snapshots have contained malformed YAML indentation
  # in recipe.yml. Vib can exit status 1 with no useful stdout/stderr when the
  # recipe cannot be parsed, which makes this failure difficult to diagnose.
  #
  # This repair pass is intentionally narrow and idempotent:
  #   - it creates a timestamped backup before changing recipe.yml
  #   - it only corrects known malformed indentation patterns observed in
  #     Vanilla Core's recipe.yml
  #   - it records a unified diff in output/logs
  #
  # Known corrections observed during HP Omnibook 5 ARM64 builder testing:
  #   "   - mandb -c"        -> "    - mandb -c"
  #   "   - name: runroot"   -> "  - name: runroot"
  #   "- name: cleanup2"     -> "  - name: cleanup2"
  local repo="$1"
  local repo_name recipe backup diff_log tmp
  local bad_re

  repo_name="$(basename "$repo")"
  recipe="$repo/recipe.yml"
  [[ -f "$recipe" ]] || return 0

  mkdir -p "$OUTPUT_DIR/logs"

  # The expression intentionally matches only known-bad lines. It does not try
  # to become a generic YAML formatter.
  bad_re='^[[:space:]]{3}- mandb -c$|^[[:space:]]{3}- name: runroot$|^- name: cleanup2$'

  if grep -Eq "$bad_re" "$recipe"; then
    backup="$repo/recipe.yml.builder-backup.$(date -u +%Y%m%d%H%M%S)"
    diff_log="$OUTPUT_DIR/logs/${BUILD_DATE}-${repo_name}-recipe-yaml-repair-$(date -u +%H%M%S).diff"
    tmp="$repo/recipe.yml.builder-repaired.$$"

    warn "Known malformed YAML indentation detected in $repo_name/recipe.yml."
    warn "Creating backup before repair: $backup"
    cp -a "$recipe" "$backup"

    # Use Python for exact line-oriented repair while preserving all other text.
    python3 - "$recipe" "$tmp" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
changed = False
out = []
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        stripped = line.rstrip("\n")
        if stripped == "   - mandb -c":
            line = "    - mandb -c\n"
            changed = True
        elif stripped == "   - name: runroot":
            line = "  - name: runroot\n"
            changed = True
        elif stripped == "- name: cleanup2":
            line = "  - name: cleanup2\n"
            changed = True
        out.append(line)
with open(dst, "w", encoding="utf-8") as f:
    f.writelines(out)
sys.exit(0 if changed else 2)
PY

    mv "$tmp" "$recipe"
    diff -u "$backup" "$recipe" >"$diff_log" || true
    ok "Repaired known YAML indentation issue in $repo_name/recipe.yml."
    printf 'Recipe repair diff:\n  %s\n' "$diff_log" >&2
  fi

  # Lightweight structural check for the exact bad patterns after repair.
  if grep -Eq "$bad_re" "$recipe"; then
    fail "recipe.yml still contains known malformed YAML indentation after repair attempt: $recipe"
    grep -nE "$bad_re" "$recipe" >&2 || true
    return 1
  fi

  return 0
}

repair_known_vib_recipes() {
  local repo
  for repo in "$SOURCES_DIR/core-image" "$SOURCES_DIR/desktop-image"; do
    [[ -d "$repo" ]] || continue
    repair_known_vib_recipe_yaml "$repo"
  done
}


recipe_declared_vibversion() {
  # Extract the recipe's declared Vib version. The core-image recipe currently
  # declares a `vibversion:` value. That value is useful provenance and a
  # compatibility hint, but it should not be allowed to fail opaquely if the
  # installed Vib binary itself cannot report a version.
  local workdir="$1"
  awk -F: '
    /^[[:space:]]*vibversion[[:space:]]*:/ {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'\'']|["'\'']$/, "", v)
      print v
      exit
    }
  ' "$workdir/recipe.yml" 2>/dev/null || true
}

installed_vib_version_string() {
  # Vib has returned non-zero for --help/--version in some downloaded builds.
  # Never let that behavior trigger set -e or pipefail. Return a semantic
  # version-looking token if one appears, otherwise return empty.
  local out
  set +e
  out="$(vib --version 2>&1)"
  set -e
  printf '%s\n' "$out" | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?/) {
          print $i
          exit
        }
      }
    }
  ' || true
}

validate_vib_version_matches_recipe() {
  # Compatibility policy:
  #   warn   = default. Record mismatch/unknown version, continue build.
  #   strict = fail preflight on mismatch or unknown installed version.
  #   ignore = record values but never warn/fail.
  #
  # Reason: upstream ARM recipes may declare older vibversion values while the
  # latest downloaded Vib binary may not report a clean version string. Treating
  # this as a hard failure blocked Stage 8 without proving it was the real build
  # cause.
  local workdir="$1"
  local log="$2"
  local declared installed policy

  declared="$(recipe_declared_vibversion "$workdir")"
  installed="$(installed_vib_version_string)"
  policy="${VIB_VERSION_POLICY,,}"

  {
    printf '\n## Vib version compatibility\n'
    printf 'policy: %s\n' "$policy"
    printf 'recipe vibversion: %s\n' "${declared:-not-declared}"
    printf 'installed vib version: %s\n' "${installed:-unknown}"
    printf 'raw vib --version output:\n'
    set +e
    vib --version 2>&1
    printf 'raw vib --version exit status: %s\n' "$?"
    set -e
  } >>"$log" 2>&1

  case "$policy" in
    ignore)
      printf 'PASS vib-version-compatibility: ignored by policy\n' >>"$log"
      return 0
      ;;
    warn|"")
      if [[ -n "$declared" && -n "$installed" && "$declared" != "$installed" ]]; then
        printf 'WARN vib-version-compatibility: recipe declares %s but installed vib appears to be %s; continuing by default.\n' "$declared" "$installed" >>"$log"
      elif [[ -n "$declared" && -z "$installed" ]]; then
        printf 'WARN vib-version-compatibility: recipe declares %s but installed vib version could not be parsed; continuing by default.\n' "$declared" >>"$log"
      else
        printf 'PASS vib-version-compatibility-or-warning-policy\n' >>"$log"
      fi
      return 0
      ;;
    strict)
      if [[ -n "$declared" && -z "$installed" ]]; then
        printf 'FAIL vib-version-compatibility: strict mode cannot verify installed Vib version.\n' >>"$log"
        return 1
      fi
      if [[ -n "$declared" && -n "$installed" && "$declared" != "$installed" ]]; then
        printf 'FAIL vib-version-compatibility: recipe declares %s but installed vib appears to be %s.\n' "$declared" "$installed" >>"$log"
        return 1
      fi
      printf 'PASS vib-version-compatibility: strict mode satisfied\n' >>"$log"
      return 0
      ;;
    *)
      printf 'WARN vib-version-compatibility: unknown VIB_VERSION_POLICY=%s; treating as warn.\n' "$policy" >>"$log"
      return 0
      ;;
  esac
}


vib_deep_diagnostics() {
  local workdir="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-vib-deep-diagnostics-$(date -u +%H%M%S).log"
  local old_errexit old_errtrace

  mkdir -p "$OUTPUT_DIR/logs"
  LAST_COMMAND_LOG="$log"
  LAST_DEEP_DIAGNOSTIC_LOG="$log"

  info "Running deep Vib diagnostics for $label"
  printf 'Deep diagnostic log: %s\n' "$log" >&2

  case "$-" in *e*) old_errexit=1 ;; *) old_errexit=0 ;; esac
  case "$-" in *E*) old_errtrace=1 ;; *) old_errtrace=0 ;; esac
  trap - ERR
  set +e
  set +E

  (
    cd "$workdir" || exit 97
    printf '### Deep Vib diagnostics for %s\n' "$label"
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### PWD: %s\n\n' "$workdir"

    printf '## Vib binary\n'
    command -v vib || true
    ls -l "$(command -v vib)" 2>/dev/null || true
    file "$(command -v vib)" 2>/dev/null || true
    ldd "$(command -v vib)" 2>/dev/null || true
    printf '\n'

    printf '## Vib version data\n'
    printf 'recipe vibversion: %s\n' "$(recipe_declared_vibversion "$PWD")"
    printf 'installed vib version token: %s\n' "$(installed_vib_version_string)"
    vib --version 2>&1 || true
    printf '\n'

    printf '## Recipe header\n'
    sed -n '1,200p' recipe.yml 2>/dev/null || true
    printf '\n'

    printf '## Plugin files\n'
    find plugins -maxdepth 2 -type f -printf '%p %s bytes\n' 2>/dev/null | sort || true
    printf '\n'

    if [[ -f plugins/fsguard.so ]]; then
      printf '## fsguard plugin binary diagnostics\n'
      file plugins/fsguard.so 2>/dev/null || true
      ldd plugins/fsguard.so 2>/dev/null || true
      if command -v nm >/dev/null 2>&1; then
        nm -D plugins/fsguard.so 2>/dev/null | grep -E 'PlugInfo|BuildModule' || true
      elif command -v readelf >/dev/null 2>&1; then
        readelf -Ws plugins/fsguard.so 2>/dev/null | grep -E 'PlugInfo|BuildModule' || true
      fi
      printf '\n'
    fi

    printf '## Container runtimes\n'
    command -v podman && podman --version || true
    command -v docker && docker --version || true
    printf '\n'

    printf '## Direct vib execution as configured Vib user, stdout+stderr\n'
    printf 'current diagnostic uid: %s\n' "$(id -u)"
    run_as_vib_user "$PWD" vib build recipe.yml 2>&1
    printf '\nDirect exit status: %s\n\n' "$?"

    printf '## Vib execution with debug-ish environment as configured Vib user, stdout+stderr\n'
    run_as_vib_user "$PWD" env VIB_LOG_LEVEL=debug RUST_BACKTRACE=full RUST_LOG=debug vib build recipe.yml 2>&1
    printf '\nDebug-env exit status: %s\n\n' "$?"

    if command -v script >/dev/null 2>&1; then
      printf '## Vib execution under pseudo-TTY via script(1)\n'
      script -q -e -c "runuser -u $VIB_RUN_USER -- bash -lc 'cd $(pwd) && vib build recipe.yml'" /tmp/vib-build.typescript
      printf 'script-wrapped exit status: %s\n' "$?"
      printf '\n--- typescript output ---\n'
      cat /tmp/vib-build.typescript || true
      printf '\n'
    else
      printf 'script(1) not installed; skipping pseudo-TTY capture.\n'
    fi

    if command -v strace >/dev/null 2>&1; then
      printf '## strace vib build, last 240 lines\n'
      strace -f -s 256 -o /tmp/vib-build.strace runuser -u "$VIB_RUN_USER" -- bash -lc "cd $(pwd) && vib build recipe.yml"
      printf 'strace-wrapped exit status: %s\n\n' "$?"
      tail -n 240 /tmp/vib-build.strace || true
      printf '\n'
    else
      printf 'strace not installed; skipping syscall trace. Install package strace for syscall-level Vib diagnostics.\n'
    fi

    printf '## Files generated/changed in repo root after Vib attempts\n'
    find . -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM %p %s bytes\n' | sort | tail -n 250 || true
  ) >"$log" 2>&1

  if [[ "$old_errtrace" -eq 1 ]]; then set -E; else set +E; fi
  if [[ "$old_errexit" -eq 1 ]]; then set -e; else set +e; fi
  trap 'rc=$?; fail "Unexpected failure at stage ${CURRENT_STAGE}, line ${LINENO}, exit status ${rc}."; [[ -n "${LAST_COMMAND_LOG:-}" ]] && print_failure_tail "$LAST_COMMAND_LOG"; exit "$rc"' ERR

  print_failure_tail "$log"
  warn "Deep Vib diagnostics complete. Review: $log"
}


validate_recipe_yaml_parse() {
  # Parse recipe.yml with PyYAML before invoking Vib. Vib can exit 1 without
  # explaining YAML parser failures, so this preflight reports line/column and
  # nearby source context directly in the command log.
  local workdir="$1"
  local log="$2"
  local recipe="$workdir/recipe.yml"

  {
    printf '\n## YAML parse validation\n'
    printf 'recipe: %s\n' "$recipe"
  } >>"$log"

  python3 - "$recipe" >>"$log" 2>&1 <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])

def print_context(line_no, radius=6):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception as exc:
        print(f"YAML_CONTEXT_ERROR: could not read recipe for context: {exc}")
        return
    if not line_no:
        print("YAML_CONTEXT: line number unavailable")
        return
    start = max(1, line_no - radius)
    end = min(len(lines), line_no + radius)
    print(f"YAML_CONTEXT: showing lines {start}-{end}")
    for idx in range(start, end + 1):
        marker = ">>" if idx == line_no else "  "
        print(f"{marker} {idx:04d}: {lines[idx-1]}")

try:
    import yaml
except Exception as exc:
    print("YAML_VALIDATION_DEPENDENCY_ERROR:")
    print(f"  Python could not import PyYAML module 'yaml': {exc}")
    print("  Install Debian package: python3-yaml")
    print("  Suggested command: apt-get update && apt-get install -y python3-yaml")
    sys.exit(22)

try:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as exc:
    print("YAML_PARSE_ERROR:")
    print(f"  {exc}")
    mark = getattr(exc, "problem_mark", None) or getattr(exc, "context_mark", None)
    if mark is not None:
        line_no = int(mark.line) + 1
        col_no = int(mark.column) + 1
        print(f"YAML_ERROR_LOCATION: line {line_no}, column {col_no}")
        print_context(line_no)
    else:
        print_context(None)
    sys.exit(23)
except Exception as exc:
    print("YAML_PARSE_UNEXPECTED_ERROR:")
    print(f"  {type(exc).__name__}: {exc}")
    sys.exit(24)

if not isinstance(data, dict):
    print("YAML_STRUCTURE_ERROR: top-level recipe document is not a mapping")
    sys.exit(25)

required = ["name", "id", "vibversion", "stages"]
missing = [k for k in required if k not in data]
if missing:
    print("YAML_STRUCTURE_ERROR: missing required top-level keys:", ", ".join(missing))
    sys.exit(26)

if not isinstance(data.get("stages"), list) or not data["stages"]:
    print("YAML_STRUCTURE_ERROR: stages must be a non-empty list")
    sys.exit(27)

print("YAML_PARSE_OK")
PY
  return $?
}

validate_fsguard_plugin_abi() {
  local workdir="$1"
  local log="$2"
  local plugin="$workdir/plugins/fsguard.so"
  local status=0

  if ! grep -Eq '^[[:space:]]*type:[[:space:]]*fsguard[[:space:]]*$' "$workdir/recipe.yml"; then
    return 0
  fi

  {
    printf '\n## fsguard plugin ABI validation\n'
    printf 'plugin: %s\n' "$plugin"

    if [[ ! -s "$plugin" ]]; then
      printf 'FSGUARD_PLUGIN_ERROR: missing or empty fsguard plugin\n'
      exit 31
    fi

    if command -v file >/dev/null 2>&1; then
      file "$plugin" || true
    fi

    if command -v ldd >/dev/null 2>&1; then
      printf '\nldd plugins/fsguard.so:\n'
      ldd "$plugin" || exit 32
    fi

    if command -v nm >/dev/null 2>&1; then
      printf '\nExported Vib plugin symbols:\n'
      nm -D "$plugin" 2>/dev/null | grep -E 'PlugInfo|BuildModule' || exit 33
    elif command -v readelf >/dev/null 2>&1; then
      printf '\nExported Vib plugin symbols:\n'
      readelf -Ws "$plugin" 2>/dev/null | grep -E 'PlugInfo|BuildModule' || exit 33
    else
      printf 'WARN: neither nm nor readelf is available for symbol validation.\n'
    fi

    printf 'FSGUARD_PLUGIN_ABI_OK\n'
  } >>"$log" 2>&1 || status=$?

  return "$status"
}

validate_required_recipe_plugins() {
  local workdir="$1"
  local log="$2"

  {
    printf '\n## Required recipe plugin validation\n'
    printf 'recipe plugin types:\n'
    awk '
      /^[[:space:]]*type:[[:space:]]*/ {
        line=$0
        gsub(/^[[:space:]]*type:[[:space:]]*/, "", line)
        gsub(/[[:space:]]*$/, "", line)
        print line
      }
    ' "$workdir/recipe.yml" | sort -u
  } >>"$log" 2>&1 || true

  validate_fsguard_plugin_abi "$workdir" "$log"
}


vib_preflight() {
  # Emit detailed, command-log-friendly Vib diagnostics before invoking
  # `vib build`. This version prints an explicit PASS/FAIL verdict for every
  # hard validation so the failure reason is visible even when the last 80 log
  # lines only show non-fatal help probes.
  local workdir="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-vib-preflight-$(date -u +%H%M%S).log"
  local failed_check=""

  mkdir -p "$OUTPUT_DIR/logs"
  LAST_COMMAND_LOG="$log"

  info "Running Vib preflight diagnostics for $label"
  printf 'Preflight log: %s\n' "$log" >&2

  {
    printf '### Vib preflight for %s\n' "$label"
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### PWD: %s\n\n' "$workdir"

    printf '## Host\n'
    uname -a || true
    printf '\n'

    printf '## PATH\n%s\n\n' "$PATH"

    printf '## Vib discovery\n'
    if command -v vib >/dev/null 2>&1; then
      printf 'vib path: %s\n' "$(command -v vib)"
      ls -l "$(command -v vib)" || true
      if command -v file >/dev/null 2>&1; then
        file "$(command -v vib)" || true
      fi
      if command -v ldd >/dev/null 2>&1; then
        printf '\nldd output, if dynamically linked:\n'
        ldd "$(command -v vib)" || true
      fi
      printf '\nvib --version:\n'
      set +e
      vib --version
      printf 'vib --version exit status: %s\n' "$?"
      set -e
    else
      printf 'vib was not found in PATH.\n'
    fi

    printf '\n## Repository build files\n'
    cd "$workdir" || exit 0
    pwd
    printf '\nrecipe.yml:\n'
    ls -l recipe.yml || true
    printf '\nrecipe.yml focused excerpt around known fragile sections:\n'
    grep -nE 'mandb|runroot|fsguard|cleanup2|vibversion' recipe.yml 2>/dev/null || true
    printf '\nContainerfile / Dockerfile:\n'
    ls -l Containerfile Dockerfile 2>/dev/null || true
    printf '\nplugins directory:\n'
    find plugins -maxdepth 2 -type f -printf '%p %s bytes\n' 2>/dev/null | sort || true
    printf '\nTop-level files:\n'
    find . -maxdepth 2 -type f | sort | sed -n '1,200p' || true

    printf '\n## Known YAML indentation issue check\n'
    if grep -nE '^[[:space:]]{3}- mandb -c$|^[[:space:]]{3}- name: runroot$|^- name: cleanup2$' recipe.yml 2>/dev/null; then
      printf 'FAIL known malformed recipe.yml indentation remains.\n'
    else
      printf 'PASS no known malformed indentation patterns detected.\n'
    fi

    printf '\n## Vib dry diagnostics, informational only\n'
    printf 'Attempting: vib build --help\n'
    set +e
    set +o pipefail
    vib build --help > /tmp/vib-build-help.$$ 2>&1
    _vib_build_help_status=$?
    sed -n '1,120p' /tmp/vib-build-help.$$ || true
    rm -f /tmp/vib-build-help.$$
    printf '\nvib build --help exit status: %s\n' "$_vib_build_help_status"

    printf '\nAttempting: vib --help\n'
    vib --help > /tmp/vib-help.$$ 2>&1
    _vib_help_status=$?
    sed -n '1,120p' /tmp/vib-help.$$ || true
    rm -f /tmp/vib-help.$$
    printf '\nvib --help exit status: %s\n' "$_vib_help_status"
    set -o pipefail
    set -e
  } >"$log" 2>&1

  # Hard validation checks. Every return path writes a visible verdict into the
  # same log before returning failure.
  {
    printf '\n## Hard preflight validation verdicts\n'
  } >>"$log"

  if ! command -v vib >/dev/null 2>&1; then
    failed_check="vib-path"
    printf 'FAIL %s: vib is not available in PATH.\n' "$failed_check" >>"$log"
    fail "Vib preflight failed: $failed_check"
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS vib-path: %s\n' "$(command -v vib)" >>"$log"

  if [[ ! -x "$(command -v vib)" ]]; then
    failed_check="vib-executable-bit"
    printf 'FAIL %s: vib exists but is not executable: %s\n' "$failed_check" "$(command -v vib)" >>"$log"
    fail "Vib preflight failed: $failed_check"
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS vib-executable-bit\n' >>"$log"

  {
    printf '\n## Vib root-execution guard\n'
    printf 'builder uid: %s\n' "$(id -u)"
    printf 'VIB_RUN_USER: %s\n' "$VIB_RUN_USER"
    printf 'VIB_ALLOW_ROOT: %s\n' "$VIB_ALLOW_ROOT"
    if [[ "$(id -u)" -eq 0 && "$VIB_ALLOW_ROOT" != "1" ]]; then
      printf 'PASS vib-root-guard: Vib will be run via non-root user %s\n' "$VIB_RUN_USER"
    elif [[ "$(id -u)" -eq 0 && "$VIB_ALLOW_ROOT" == "1" ]]; then
      printf 'WARN vib-root-guard: Vib will run as root because VIB_ALLOW_ROOT=1\n'
    else
      printf 'PASS vib-root-guard: builder is already non-root\n'
    fi
  } >>"$log"

  if [[ ! -f "$workdir/recipe.yml" ]]; then
    failed_check="recipe-present"
    printf 'FAIL %s: recipe.yml is missing in %s\n' "$failed_check" "$workdir" >>"$log"
    fail "Vib preflight failed: $failed_check"
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS recipe-present\n' >>"$log"

  if ! validate_vib_version_matches_recipe "$workdir" "$log"; then
    failed_check="vib-version-compatibility"
    printf 'FAIL %s\n' "$failed_check" >>"$log"
    fail "Vib preflight failed: $failed_check"
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS vib-version-compatibility\n' >>"$log"

  if ! validate_recipe_yaml_parse "$workdir" "$log"; then
    failed_check="recipe-yaml-parse"
    printf 'FAIL %s\n' "$failed_check" >>"$log"
    fail "Vib preflight failed: $failed_check"
    warn "This explains a silent 'vib build recipe.yml' exit."
    warn "YAML parser details and source context are in the preflight log:"
    warn "  $log"
    grep -nE 'YAML_(VALIDATION_DEPENDENCY_ERROR|PARSE_ERROR|PARSE_UNEXPECTED_ERROR|ERROR_LOCATION|CONTEXT|STRUCTURE_ERROR)|^>> ' "$log" >&2 || true
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS recipe-yaml-parse\n' >>"$log"

  if ! validate_required_recipe_plugins "$workdir" "$log"; then
    failed_check="recipe-plugin-validation"
    printf 'FAIL %s\n' "$failed_check" >>"$log"
    fail "Vib preflight failed: $failed_check"
    warn "Most likely causes: wrong plugin architecture, missing symbols, or unresolved shared-library dependency."
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS recipe-plugin-validation\n' >>"$log"

  if [[ ! -d "$workdir/plugins" ]] || ! find "$workdir/plugins" -type f | grep -q .; then
    failed_check="plugins-present"
    printf 'FAIL %s: no Vib plugin files under %s/plugins\n' "$failed_check" "$workdir" >>"$log"
    fail "Vib preflight failed: $failed_check"
    print_failure_tail "$log"
    return 1
  fi
  printf 'PASS plugins-present\n' >>"$log"

  if grep -Eq '^[[:space:]]*type:[[:space:]]*fsguard[[:space:]]*$' "$workdir/recipe.yml"; then
    if [[ ! -s "$workdir/plugins/fsguard.so" ]]; then
      failed_check="fsguard-plugin-present"
      printf 'FAIL %s: recipe uses fsguard but %s/plugins/fsguard.so is missing\n' "$failed_check" "$workdir" >>"$log"
      fail "Vib preflight failed: $failed_check"
      print_failure_tail "$log"
      return 1
    fi
    printf 'PASS fsguard-plugin-present\n' >>"$log"
  fi

  printf '\nPRELIGHT_RESULT: PASS\n' >>"$log"
  ok "Vib preflight completed for $label."
  return 0
}



patch_known_unavailable_packages_before_vib() {
  # Vib consumes modules/*.yml before it generates the Containerfile. Therefore
  # unavailable package removal must happen before `vib build recipe.yml`.
  #
  # Regression fixed in 2.7.3:
  #   Some upstream apt modules use a shorthand:
  #
  #     sources:
  #       - packages:
  #       - pkg-a
  #       - pkg-b
  #
  #   which PyYAML reads as:
  #     [{"packages": null}, "pkg-a", "pkg-b"]
  #
  #   Vib's apt plugin accepts/normalizes this shorthand internally, but our
  #   validator rejected it. This function now normalizes shorthand into the
  #   canonical Vib shape before removing optional packages:
  #
  #     sources:
  #       - packages:
  #           - pkg-a
  #           - pkg-b
  local repo="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-pre-vib-unavailable-package-patch-$(date -u +%H%M%S).log"
  local pkg file backup tmp changed_any=0 normalized_any=0

  [[ "$ALLOW_MISSING_OPTIONAL_PACKAGES" == "1" ]] || return 0
  mkdir -p "$OUTPUT_DIR/logs"
  : > "$log"

  printf 'Pre-Vib unavailable package YAML patch log\n' >>"$log"
  printf 'Repository: %s\n' "$repo" >>"$log"
  printf 'Packages: %s\n\n' "$KNOWN_UNAVAILABLE_PACKAGES" >>"$log"

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    tmp="$file.builder-patched.$$"

    if python3 - "$file" "$tmp" "$KNOWN_UNAVAILABLE_PACKAGES" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
packages_to_remove = set(sys.argv[3].split())

try:
    import yaml
except Exception as exc:
    print(f"ERROR: PyYAML import failed: {exc}", file=sys.stderr)
    sys.exit(10)

try:
    data = yaml.safe_load(src.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"ERROR: YAML parse failed for {src}: {exc}", file=sys.stderr)
    sys.exit(11)

changed = False
normalized = False

def normalize_apt_sources(obj):
    global changed, normalized

    if isinstance(obj, dict):
        if obj.get("type") == "apt" and isinstance(obj.get("sources"), list):
            sources = obj["sources"]
            canonical = []
            pending_packages = []
            changed_here = False

            for item in sources:
                if isinstance(item, dict):
                    # If there is a pending shorthand package list, flush it as
                    # its own source before starting a new mapping.
                    if pending_packages:
                        canonical.append({"packages": pending_packages})
                        pending_packages = []
                        changed_here = True

                    if "packages" in item and item["packages"] is None:
                        item = dict(item)
                        item["packages"] = []
                        changed_here = True

                    canonical.append(item)
                elif isinstance(item, str):
                    pending_packages.append(item)
                    changed_here = True
                else:
                    canonical.append(item)

            if pending_packages:
                canonical.append({"packages": pending_packages})
                changed_here = True

            if changed_here:
                obj["sources"] = canonical
                changed = True
                normalized = True

        for value in obj.values():
            normalize_apt_sources(value)
    elif isinstance(obj, list):
        for item in obj:
            normalize_apt_sources(item)

def remove_pkg(obj):
    global changed
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "packages" and isinstance(v, list):
                nv = [x for x in v if x not in packages_to_remove]
                if len(nv) != len(v):
                    obj[k] = nv
                    changed = True
            else:
                remove_pkg(v)
    elif isinstance(obj, list):
        for item in obj:
            remove_pkg(item)

def validate_apt_shape(obj, path="root"):
    if isinstance(obj, dict):
        if obj.get("type") == "apt":
            sources = obj.get("sources")
            if not isinstance(sources, list):
                raise TypeError(f"{path}.sources must be list, got {type(sources).__name__}")
            for i, source in enumerate(sources):
                if not isinstance(source, dict):
                    raise TypeError(f"{path}.sources[{i}] must be mapping, got {type(source).__name__}")
                packages = source.get("packages")
                if packages is not None and not isinstance(packages, list):
                    raise TypeError(f"{path}.sources[{i}].packages must be list, got {type(packages).__name__}")
        for k, v in obj.items():
            validate_apt_shape(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            validate_apt_shape(item, f"{path}[{i}]")

normalize_apt_sources(data)
remove_pkg(data)
validate_apt_shape(data)

if not changed:
    sys.exit(2)

dst.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False), encoding="utf-8")
if normalized:
    print("NORMALIZED_APT_SOURCES_SHORTHAND", file=sys.stderr)
sys.exit(0)
PY
    then
      backup="$file.builder-backup-previb-normalize.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$file" "$backup"
      mv "$tmp" "$file"
      changed_any=1
      {
        printf 'PATCHED/NORMALIZED pre-Vib YAML\n'
        printf 'File: %s\n' "$file"
        printf 'Backup: %s\n' "$backup"
        printf 'Diff:\n'
        diff -u "$backup" "$file" || true
        printf '\n'
      } >>"$log"
      warn "Pre-Vib normalized/removed optional package tokens in $(realpath --relative-to="$repo" "$file" 2>/dev/null || printf '%s' "$file")"
    else
      rc=$?
      rm -f "$tmp"
      if [[ "$rc" -ne 2 ]]; then
        fail "Pre-Vib YAML package normalization/removal failed for $file"
        print_failure_tail "$log"
        return "$rc"
      fi
    fi
  done < <(
    {
      [[ -d "$repo/modules" ]] && find "$repo/modules" -type f \( -name '*.yml' -o -name '*.yaml' \) || true
      [[ -f "$repo/recipe.yml" ]] && printf '%s\n' "$repo/recipe.yml"
    } | sort -u
  )

  validate_vib_apt_module_yaml_shapes "$repo" "$label" "$log" || return $?

  if [[ "$changed_any" -eq 1 ]]; then
    warn "Pre-Vib unavailable package patch/normalization applied. Log: $log"
  else
    ok "No pre-Vib unavailable package tokens or shorthand apt sources found for $label."
  fi
}



run_vib_build_with_diagnostics() {
  local label="$1"
  local workdir="$2"
  local action
  local safe

  safe="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g')"

  while true; do
    patch_known_unavailable_packages_before_vib "$workdir" "$safe"
    prepare_repo_for_vib_user "$workdir"
    if ! vib_preflight "$workdir" "$label"; then
      action="$(command_failure_menu "Vib preflight for $label" "$workdir" "$LAST_COMMAND_LOG" "1")"
      case "$action" in
        shell) open_shell "$workdir" ;;
        retry) continue ;;
        abort|*) die "Build aborted after Vib preflight failure. See log: $LAST_COMMAND_LOG" ;;
      esac
    fi

    run_logged "Build $label with Vib" "$workdir" vib build recipe.yml
    return 0
  done
}



patch_known_debian_changelog_dates() {
  # Repair known Debian packaging timestamp defects before container build.
  #
  # Observed failure:
  #   dh_installchangelogs: Could not parse timestamp
  #   'Wed, 24 July 2024 22:01:00 +0000'
  #
  # Debian changelog trailer dates must use abbreviated English month names,
  # e.g. "Wed, 24 Jul 2024 22:01:00 +0000".
  local repo="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-debian-changelog-date-repair-$(date -u +%H%M%S).log"
  local file backup tmp changed_any=0

  [[ "$PATCH_KNOWN_DEBIAN_CHANGELOG_DATES" == "1" ]] || {
    info "Debian changelog date repair disabled: PATCH_KNOWN_DEBIAN_CHANGELOG_DATES=$PATCH_KNOWN_DEBIAN_CHANGELOG_DATES"
    return 0
  }

  [[ -d "$repo/sources" ]] || return 0
  mkdir -p "$OUTPUT_DIR/logs"
  : > "$log"

  printf 'Debian changelog date repair log\n' >>"$log"
  printf 'Repository: %s\n\n' "$repo" >>"$log"

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    tmp="$file.builder-datefix.$$"

    if python3 - "$file" "$tmp" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

months = {
    "January": "Jan", "February": "Feb", "March": "Mar", "April": "Apr",
    "May": "May", "June": "Jun", "July": "Jul", "August": "Aug",
    "September": "Sep", "October": "Oct", "November": "Nov", "December": "Dec",
}

changed = False
out = []
trailer_re = re.compile(r"^(\s*--\s+.+?\s{2,}[A-Z][a-z]{2},\s+\d{1,2}\s+)([A-Za-z]+)(\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4}\s*)$")

for line in src.read_text(encoding="utf-8").splitlines(keepends=True):
    newline = ""
    body = line
    if line.endswith("\n"):
        newline = "\n"
        body = line[:-1]

    m = trailer_re.match(body)
    if m and m.group(2) in months:
        body = m.group(1) + months[m.group(2)] + m.group(3)
        changed = True

    out.append(body + newline)

dst.write_text("".join(out), encoding="utf-8")
sys.exit(0 if changed else 2)
PY
    then
      backup="$file.builder-backup-datefix.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$file" "$backup"
      mv "$tmp" "$file"
      changed_any=1
      {
        printf 'PATCHED changelog: %s\n' "$file"
        printf 'Backup: %s\n' "$backup"
        printf 'Diff:\n'
        diff -u "$backup" "$file" || true
        printf '\n'
      } >>"$log"
      warn "Repaired Debian changelog date format in $(realpath --relative-to="$repo" "$file" 2>/dev/null || printf '%s' "$file")"
    else
      rm -f "$tmp"
    fi
  done < <(find "$repo/sources" -path '*/debian/changelog' -type f | sort)

  if [[ "$changed_any" -eq 1 ]]; then
    warn "Debian changelog date repair applied. Log: $log"
  else
    ok "No Debian changelog date repairs needed for $label."
  fi
}

patch_known_unavailable_packages() {
  # YAML-aware and Containerfile-aware optional package removal.
  #
  # Regression fixed in 2.7.0:
  #   The previous raw token-removal logic also patched Vib module YAML files
  #   line-by-line. That can corrupt apt module structure and produce:
  #     json: cannot unmarshal string into Go struct field AptModule.sources of type api.Source
  #
  # This implementation:
  #   - uses PyYAML for *.yml/*.yaml files and preserves the expected
  #     sources: [ { packages: [...] } ] structure,
  #   - uses text token removal only for generated Containerfile/Dockerfile,
  #   - validates apt modules after patching,
  #   - creates backups and logs diffs.
  local repo="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-known-unavailable-package-patch-$(date -u +%H%M%S).log"
  local pkg file backup tmp changed_any=0

  [[ "$ALLOW_MISSING_OPTIONAL_PACKAGES" == "1" ]] || {
    info "Optional package removal disabled: ALLOW_MISSING_OPTIONAL_PACKAGES=$ALLOW_MISSING_OPTIONAL_PACKAGES"
    return 0
  }

  mkdir -p "$OUTPUT_DIR/logs"
  : > "$log"

  printf 'Known unavailable package patch log\n' >>"$log"
  printf 'Repository: %s\n' "$repo" >>"$log"
  printf 'Packages: %s\n\n' "$KNOWN_UNAVAILABLE_PACKAGES" >>"$log"

  for pkg in $KNOWN_UNAVAILABLE_PACKAGES; do
    # Patch Vib YAML modules structurally.
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      grep -qw -- "$pkg" "$file" || continue

      backup="$file.builder-backup-yaml-remove-${pkg//[^A-Za-z0-9_.-]/_}.$(date -u +%Y%m%d%H%M%S)"
      tmp="$file.builder-patched.$$"

      if python3 - "$file" "$tmp" "$pkg" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
pkg = sys.argv[3]

try:
    import yaml
except Exception as exc:
    print(f"ERROR: PyYAML import failed: {exc}", file=sys.stderr)
    sys.exit(10)

try:
    data = yaml.safe_load(src.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"ERROR: YAML parse failed for {src}: {exc}", file=sys.stderr)
    sys.exit(11)

changed = False

def remove_pkg_from_obj(obj):
    global changed
    if isinstance(obj, dict):
        for key, value in list(obj.items()):
            if key == "packages" and isinstance(value, list):
                new_value = [x for x in value if x != pkg]
                if len(new_value) != len(value):
                    obj[key] = new_value
                    changed = True
            else:
                remove_pkg_from_obj(value)
    elif isinstance(obj, list):
        for item in obj:
            remove_pkg_from_obj(item)

remove_pkg_from_obj(data)

if not changed:
    sys.exit(2)

# Validate Vib apt module shape where present. The apt plugin expects sources to
# be a list of mappings, not strings.
def validate_apt_shape(obj, path="root"):
    if isinstance(obj, dict):
        if obj.get("type") == "apt":
            sources = obj.get("sources")
            if sources is not None:
                if not isinstance(sources, list):
                    raise TypeError(f"{path}.sources must be list, got {type(sources).__name__}")
                for i, source in enumerate(sources):
                    if not isinstance(source, dict):
                        raise TypeError(f"{path}.sources[{i}] must be mapping, got {type(source).__name__}")
                    if "packages" in source and not isinstance(source["packages"], list):
                        raise TypeError(f"{path}.sources[{i}].packages must be list, got {type(source['packages']).__name__}")
        for k, v in obj.items():
            validate_apt_shape(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            validate_apt_shape(item, f"{path}[{i}]")

validate_apt_shape(data)

dst.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False), encoding="utf-8")
sys.exit(0)
PY
      then
        cp -a "$file" "$backup"
        mv "$tmp" "$file"
        changed_any=1
        {
          printf 'PATCHED YAML package: %s\n' "$pkg"
          printf 'File: %s\n' "$file"
          printf 'Backup: %s\n' "$backup"
          printf 'Diff:\n'
          diff -u "$backup" "$file" || true
          printf '\n'
        } >>"$log"
        warn "Removed optional unavailable package '$pkg' from YAML $(realpath --relative-to="$repo" "$file" 2>/dev/null || printf '%s' "$file")"
      else
        rc=$?
        rm -f "$tmp"
        if [[ "$rc" -ne 2 ]]; then
          fail "Failed YAML-aware optional package patch for $file"
          warn "Patch log: $log"
          return "$rc"
        fi
      fi
    done < <(false)

    # Patch generated Containerfile/Dockerfile text command lines only.
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      grep -qw -- "$pkg" "$file" || continue

      backup="$file.builder-backup-text-remove-${pkg//[^A-Za-z0-9_.-]/_}.$(date -u +%Y%m%d%H%M%S)"
      tmp="$file.builder-patched.$$"
      cp -a "$file" "$backup"

      python3 - "$file" "$tmp" "$pkg" <<'PY'
import re, sys
src, dst, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
changed = False
out = []
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        new = re.sub(r'(?<![A-Za-z0-9_.+-])' + re.escape(pkg) + r'(?![A-Za-z0-9_.+-])', '', line)
        new = re.sub(r'[ \t]{2,}', ' ', new)
        if new != line:
            changed = True
        out.append(new)
with open(dst, "w", encoding="utf-8") as f:
    f.writelines(out)
sys.exit(0 if changed else 2)
PY
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        mv "$tmp" "$file"
        changed_any=1
        {
          printf 'PATCHED Containerfile package: %s\n' "$pkg"
          printf 'File: %s\n' "$file"
          printf 'Backup: %s\n' "$backup"
          printf 'Diff:\n'
          diff -u "$backup" "$file" || true
          printf '\n'
        } >>"$log"
        warn "Removed optional unavailable package '$pkg' from generated build file $(basename "$file")"
      else
        rm -f "$tmp"
      fi
    done < <(grep -RIl -- "$pkg" "$repo/Containerfile" "$repo/Dockerfile" 2>/dev/null || true)
  done

  validate_vib_apt_module_yaml_shapes "$repo" "$label" "$log" || return $?

  if [[ "$changed_any" -eq 1 ]]; then
    warn "Known unavailable package patch applied. Log: $log"
  else
    ok "No known unavailable package tokens found to patch for $label."
  fi
}

validate_vib_apt_module_yaml_shapes() {
  local repo="$1"
  local label="$2"
  local log="${3:-$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-apt-yaml-shape-validation-$(date -u +%H%M%S).log}"

  mkdir -p "$OUTPUT_DIR/logs"

  python3 - "$repo" >>"$log" 2>&1 <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])

try:
    import yaml
except Exception as exc:
    print(f"APT_YAML_VALIDATION_ERROR: PyYAML import failed: {exc}")
    sys.exit(10)

bad = []

def normalize_shape_for_validation(obj):
    if isinstance(obj, dict):
        if obj.get("type") == "apt" and isinstance(obj.get("sources"), list):
            sources = obj["sources"]
            canonical = []
            pending = []
            for item in sources:
                if isinstance(item, dict):
                    if pending:
                        canonical.append({"packages": pending})
                        pending = []
                    if item.get("packages") is None and "packages" in item:
                        item = dict(item)
                        item["packages"] = []
                    canonical.append(item)
                elif isinstance(item, str):
                    pending.append(item)
                else:
                    canonical.append(item)
            if pending:
                canonical.append({"packages": pending})
            obj["sources"] = canonical
        for v in obj.values():
            normalize_shape_for_validation(v)
    elif isinstance(obj, list):
        for item in obj:
            normalize_shape_for_validation(item)

def validate_file(path: Path):
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        bad.append((str(path), f"YAML parse error: {exc}"))
        return

    normalize_shape_for_validation(data)

    def walk(obj, trail):
        if isinstance(obj, dict):
            if obj.get("type") == "apt":
                sources = obj.get("sources")
                if sources is not None:
                    if not isinstance(sources, list):
                        bad.append((str(path), f"{trail}.sources must be list, got {type(sources).__name__}"))
                    else:
                        for i, source in enumerate(sources):
                            if not isinstance(source, dict):
                                bad.append((str(path), f"{trail}.sources[{i}] must be mapping, got {type(source).__name__}"))
                            elif "packages" in source and not isinstance(source["packages"], list):
                                bad.append((str(path), f"{trail}.sources[{i}].packages must be list, got {type(source['packages']).__name__}"))
            for k, v in obj.items():
                walk(v, f"{trail}.{k}")
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                walk(item, f"{trail}[{i}]")

    walk(data, "root")

for base in [repo / "modules", repo / "sources"]:
    if base.exists():
        for path in sorted(list(base.rglob("*.yml")) + list(base.rglob("*.yaml"))):
            validate_file(path)

if bad:
    print("APT_YAML_SHAPE_VALIDATION_FAIL")
    for path, msg in bad:
        print(f"{path}: {msg}")
    sys.exit(1)

print("APT_YAML_SHAPE_VALIDATION_OK")
PY
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "Vib apt module YAML shape validation failed for $label."
    warn "This would cause Vib errors such as: json: cannot unmarshal string into Go struct field AptModule.sources"
    print_failure_tail "$log"
    return "$rc"
  fi
  ok "Vib apt module YAML shape validation passed for $label."
  return 0
}

diagnose_generated_container_context() {
  # After Vib succeeds, it has generated the Dockerfile/Containerfile context
  # that podman will build. The observed failure:
  #   exec container process (missing dynamic library?) `/bin/sh`: No such file or directory
  # immediately after:
  #   ADD includes.container /
  # points at /etc/ld.so.preload or another dynamic-linker-affecting file inside
  # includes.container. This diagnostic emits the high-risk files before the
  # container build starts.
  local repo="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-container-context-diagnostics-$(date -u +%H%M%S).log"

  mkdir -p "$OUTPUT_DIR/logs"

  {
    printf '### Container context diagnostics for %s\n' "$label"
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### PWD: %s\n\n' "$repo"

    cd "$repo" || exit 0

    printf '## Build file candidates\n'
    ls -l Containerfile Dockerfile 2>/dev/null || true
    printf '\n'

    printf '## High-risk includes.container files and directories\n'
    printf 'Top-level lib state in build context:\n'
    ls -ld includes.container/lib includes.container/usr/lib includes.container/usr/lib/firmware 2>/dev/null || true
    printf '\n'
    find includes.container -maxdepth 5 \( \
      -path '*/ld.so.preload' -o \
      -path '*/ld-linux*' -o \
      -path '*/ld.so*' -o \
      -path '*/libc.so*' -o \
      -path '*/libpthread.so*' -o \
      -path '*/lib/firmware*' -o \
      -path '*/usr/lib/firmware*' \
    \) -print -exec ls -ld {} \; 2>/dev/null || true
    printf '\n'

    if [[ -f includes.container/ld.so.preload ]]; then
      printf '## includes.container/ld.so.preload content\n'
      sed -n '1,120p' includes.container/ld.so.preload || true
      printf '\n'
      printf '## Referenced preload files and whether they exist in build context\n'
      while IFS= read -r preload; do
        preload="${preload%%#*}"
        preload="$(printf '%s' "$preload" | xargs 2>/dev/null || true)"
        [[ -z "$preload" ]] && continue
        printf 'preload entry: %s\n' "$preload"
        if [[ -e "includes.container/$preload" ]]; then
          printf '  exists in includes.container: includes.container/%s\n' "$preload"
        else
          printf '  missing from includes.container: includes.container/%s\n' "$preload"
        fi
      done < includes.container/ld.so.preload
    fi
  } >"$log" 2>&1

  printf 'Container context diagnostic log:\n  %s\n' "$log" >&2
}

maybe_disable_ld_so_preload_for_container_build() {
  # Workaround for the observed generated container failure.
  #
  # Rationale:
  #   The upstream core image ships includes.container/ld.so.preload. Vib's
  #   generated Dockerfile applies includes.container early:
  #      ADD includes.container /
  #   If /etc/ld.so.preload references a library that is not yet present or is
  #   wrong for the build stage, subsequent RUN commands can fail before /bin/sh
  #   starts, producing the misleading runtime message:
  #      exec container process (missing dynamic library?) `/bin/sh`: No such file or directory
  #
  # Policy:
  #   auto = disable only when includes.container/ld.so.preload exists and a
  #          referenced absolute preload path is not present in includes.container.
  #   1    = always disable for the container build.
  #   0    = never disable.
  #
  # This function renames the file before podman build and leaves a note beside
  # it. It is intentionally reversible and only affects the build context.
  local repo="$1"
  local preload="$repo/includes.container/ld.so.preload"
  local disabled="$repo/includes.container/ld.so.preload.builder-disabled"
  local note="$repo/includes.container/ld.so.preload.builder-note.txt"
  local policy="$DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD"
  local should_disable=0
  local entry trimmed

  [[ -f "$preload" ]] || return 0

  case "$policy" in
    1|yes|true|always)
      should_disable=1
      ;;
    0|no|false|never)
      should_disable=0
      ;;
    auto|"")
      while IFS= read -r entry; do
        trimmed="${entry%%#*}"
        trimmed="$(printf '%s' "$trimmed" | xargs 2>/dev/null || true)"
        [[ -z "$trimmed" ]] && continue
        # Only reason about absolute paths. Relative preload entries are rare
        # and should not be guessed.
        if [[ "$trimmed" == /* && ! -e "$repo/includes.container/$trimmed" ]]; then
          should_disable=1
          break
        fi
      done < "$preload"
      ;;
    *)
      warn "Unknown DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD=$policy; using auto."
      ;;
  esac

  if [[ "$should_disable" -eq 1 ]]; then
    warn "Disabling includes.container/ld.so.preload for container build context."
    warn "Reason: it can break /bin/sh execution immediately after ADD includes.container /."
    if [[ -f "$disabled" ]]; then
      rm -f "$preload"
    else
      mv "$preload" "$disabled"
    fi
    cat > "$note" <<EOF
This file was generated by $SCRIPT_NAME $SCRIPT_VERSION.

The original includes.container/ld.so.preload was moved to:
  includes.container/ld.so.preload.builder-disabled

Reason:
  The generated container build applies includes.container early. If ld.so.preload
  references a library that is not available at that moment, /bin/sh can fail
  before the RUN command starts with:
    exec container process (missing dynamic library?) /bin/sh: No such file or directory

Policy:
  DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD=$DISABLE_LD_SO_PRELOAD_DURING_CONTAINER_BUILD

Review whether the preload file is required in the final image before release.
EOF
  else
    ok "Leaving includes.container/ld.so.preload enabled for container build."
  fi
}


probe_includes_container_runtime_effect() {
  # Build a tiny throwaway image that does only:
  #   FROM ghcr.io/vanilla-os/pico:dev
  #   RUN /bin/sh -c 'echo before'
  #   ADD includes.container /
  #   RUN inspect high-risk files and execute /bin/sh again
  #
  # This isolates whether includes.container itself makes /bin/sh unusable.
  # It gives a much clearer diagnostic than the full generated Containerfile.
  local repo="$1"
  local label="$2"
  local probe_dir="$TMP_DIR/container-context-probe-${label}-$$"
  local probe_log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-includes-container-runtime-probe-$(date -u +%H%M%S).log"
  local status

  mkdir -p "$probe_dir" "$OUTPUT_DIR/logs"
  cp -a "$repo/includes.container" "$probe_dir/includes.container"

  cat > "$probe_dir/Containerfile" <<'EOF'
FROM ghcr.io/vanilla-os/pico:dev
RUN /bin/sh -c 'echo PRE_ADD_SHELL_OK'
ADD includes.container /
RUN echo POST_ADD_INSPECTION_START ; \
    ls -la /bin/sh /etc/ld.so.preload /ld.so.preload /ld.so.preload.builder-disabled /syscall_config.yml /vanilla.key 2>/dev/null || true ; \
    if [ -f /etc/ld.so.preload ]; then echo ETC_LD_SO_PRELOAD_CONTENT ; cat /etc/ld.so.preload ; fi ; \
    if [ -f /ld.so.preload ]; then echo ROOT_LD_SO_PRELOAD_CONTENT ; cat /ld.so.preload ; fi ; \
    echo POST_ADD_SHELL_TEST ; \
    /bin/sh -c 'echo POST_ADD_SHELL_OK'
EOF

  info "Running includes.container runtime-effect probe for $label"
  printf 'Probe log: %s\n' "$probe_log" >&2

  set +e
  podman image build $(podman_network_args) --no-cache -t "local/${label}-includes-probe:$BUILD_DATE" "$probe_dir" >"$probe_log" 2>&1
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    fail "includes.container runtime-effect probe failed for $label."
    warn "This confirms that files added by includes.container break /bin/sh before the full build proceeds."
    print_failure_tail "$probe_log"
    return "$status"
  fi

  ok "includes.container runtime-effect probe passed for $label."
  return 0
}




normalize_firmware_paths_for_usrmerge() {
  # Debian/Pico images are usr-merged: /lib is normally a symlink into /usr/lib.
  # Adding an includes.container top-level lib/ tree can poison the container
  # build context by replacing or masking that symlink during ADD includes.container /,
  # causing the dynamic loader path needed by /bin/sh to become unavailable.
  #
  # Therefore firmware staged as:
  #   includes.container/lib/firmware/...
  # is moved before probe/build to:
  #   includes.container/usr/lib/firmware/...
  #
  # The resulting installed path is still valid on usr-merged systems, where
  # /lib/firmware and /usr/lib/firmware are the same logical firmware tree.
  local repo="$1"
  local label="$2"
  local src_fw="$repo/includes.container/lib/firmware"
  local dst_fw="$repo/includes.container/usr/lib/firmware"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-firmware-usrmerge-normalization-$(date -u +%H%M%S).log"

  [[ "$NORMALIZE_FIRMWARE_TO_USR_LIB" == "1" ]] || return 0
  [[ -d "$src_fw" ]] || return 0

  mkdir -p "$OUTPUT_DIR/logs" "$dst_fw"

  {
    printf '### Firmware usrmerge normalization\n'
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### repo: %s\n' "$repo"
    printf 'Moving firmware from:\n  %s\n' "$src_fw"
    printf 'to:\n  %s\n\n' "$dst_fw"
    printf 'Before:\n'
    find "$src_fw" -type f -print | sort || true
  } >"$log"

  # Copy/merge, then remove only the firmware subtree. If lib/ becomes empty,
  # remove it so ADD includes.container / cannot create or mask top-level /lib.
  rsync -a "$src_fw"/ "$dst_fw"/
  rm -rf "$src_fw"

  # Remove empty parent lib directory only if empty.
  rmdir "$repo/includes.container/lib" 2>/dev/null || true

  {
    printf '\nAfter destination:\n'
    find "$dst_fw" -type f -print | sort || true
    printf '\nTop-level lib state:\n'
    ls -ld "$repo/includes.container/lib" 2>/dev/null || printf 'includes.container/lib absent\n'
  } >>"$log"

  warn "Normalized firmware to usr-merged path to avoid top-level /lib ADD breakage."
  warn "Firmware normalization log: $log"
}

is_preserved_include_path() {
  # Return true for paths that must never be excluded from includes.container
  # reconstruction. Firmware blobs are not executable runtime components and
  # should not be classified by a /bin/sh liveness probe. Previous versions
  # falsely excluded Qualcomm firmware files here, defeating the build-time
  # firmware incorporation requirement.
  local rel="$1"

  if [[ "$PRESERVE_FIRMWARE_IN_INCLUDES_RECONSTRUCTION" == "1" ]]; then
    case "$rel" in
      lib/firmware/*|usr/lib/firmware/*)
        return 0
        ;;
    esac
  fi

  return 1
}

file_breaks_shell_when_added() {
  # Return 0 if adding exactly one file from includes.container into the pico
  # base image causes /bin/sh to become unusable. This identifies the actual
  # runtime-breaking file instead of guessing.
  local repo="$1"
  local rel="$2"
  local label="$3"
  local probe_dir="$TMP_DIR/include-file-probe-${label}-$(printf '%s' "$rel" | sed -E 's/[^A-Za-z0-9_.-]+/_/g')-$$"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-include-file-probe-$(printf '%s' "$rel" | sed -E 's/[^A-Za-z0-9_.-]+/_/g')-$(date -u +%H%M%S).log"
  local status

  mkdir -p "$probe_dir/includes.container/$(dirname "$rel")" "$OUTPUT_DIR/logs"
  cp -a "$repo/includes.container/$rel" "$probe_dir/includes.container/$rel"

  cat > "$probe_dir/Containerfile" <<'EOF'
FROM ghcr.io/vanilla-os/pico:dev
RUN /bin/sh -c 'echo PRE_ADD_SHELL_OK'
ADD includes.container /
RUN /bin/sh -c 'echo POST_ADD_SHELL_OK'
EOF

  set +e
  podman image build $(podman_network_args) --no-cache -t "local/${label}-single-include-probe:$(date +%s)" "$probe_dir" >"$log" 2>&1
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$log" > "$probe_dir/failing-log-path.txt"
    return 0
  fi

  return 1
}

reconstruct_includes_container_safely() {
  # If the full includes.container tree breaks /bin/sh, test each top-level file
  # independently and reconstruct includes.container without the files that
  # poison the runtime. This is slower, but deterministic and produces an audit
  # trail listing the excluded paths.
  local repo="$1"
  local label="$2"
  local original="$repo/includes.container"
  local backup="$repo/includes.container.builder-original.$(date -u +%Y%m%d%H%M%S)"
  local rebuilt="$repo/includes.container.builder-rebuilt.$$"
  local manifest="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-includes-container-reconstruction-$(date -u +%H%M%S).txt"
  local rel broken_count=0 total_count=0

  [[ "$RECONSTRUCT_INCLUDES_CONTAINER_ON_RUNTIME_BREAK" == "1" ]] || return 1
  [[ -d "$original" ]] || return 1

  mkdir -p "$rebuilt" "$OUTPUT_DIR/logs"
  : > "$manifest"

  normalize_firmware_paths_for_usrmerge "$repo" "$label"
  warn "Reconstructing includes.container by probing each file."
  warn "This is slower, but it will identify the file(s) that break /bin/sh."
  printf 'Original includes.container: %s\n' "$original" >>"$manifest"
  printf 'Backup will be: %s\n\n' "$backup" >>"$manifest"

  while IFS= read -r rel; do
    total_count=$((total_count + 1))
    if is_preserved_include_path "$rel"; then
      printf 'PRESERVE include file without shell probe: %s\n' "$rel" >&2
      printf 'PRESERVE %s\n' "$rel" >>"$manifest"
      mkdir -p "$rebuilt/$(dirname "$rel")"
      cp -a "$original/$rel" "$rebuilt/$rel"
      continue
    fi

    printf 'Testing include file: %s\n' "$rel" >&2
    printf 'TEST %s\n' "$rel" >>"$manifest"

    if file_breaks_shell_when_added "$repo" "$rel" "$label"; then
      broken_count=$((broken_count + 1))
      printf 'EXCLUDE runtime-breaking file: %s\n' "$rel" | tee -a "$manifest" >&2
      continue
    fi

    mkdir -p "$rebuilt/$(dirname "$rel")"
    cp -a "$original/$rel" "$rebuilt/$rel"
    printf 'KEEP %s\n' "$rel" >>"$manifest"
  done < <(cd "$original" && find . -type f -printf '%P\n' | sort)

  mv "$original" "$backup"
  mv "$rebuilt" "$original"

  cat > "$original/BUILDER-INCLUDES-RECONSTRUCTION.txt" <<EOF
This includes.container tree was reconstructed by $SCRIPT_NAME $SCRIPT_VERSION.

Reason:
  The original includes.container made /bin/sh unusable immediately after:
    ADD includes.container /

Original backup:
  $backup

Reconstruction manifest:
  $manifest

Files excluded:
EOF

  grep '^EXCLUDE ' "$manifest" >> "$original/BUILDER-INCLUDES-RECONSTRUCTION.txt" || true

  warn "includes.container reconstruction complete."
  warn "Files tested: $total_count"
  warn "Files excluded: $broken_count"
  warn "Manifest: $manifest"

  if [[ "$broken_count" -eq 0 ]]; then
    warn "No single file broke /bin/sh by itself. The breakage may require file interaction."
    return 1
  fi

  return 0
}

quarantine_runtime_breaking_includes_files() {
  # Conservative remediation for the observed failure. If the includes probe
  # fails even after ld.so.preload is disabled, move remaining known dynamic
  # runtime instrumentation files out of includes.container before podman build.
  #
  # The ARM build can still proceed; the quarantine note records what was moved.
  local repo="$1"
  local quarantine_dir="$repo/includes.container.builder-quarantine"
  local note="$repo/includes.container.builder-quarantine/README.txt"
  local moved=0
  local f rel

  mkdir -p "$quarantine_dir"

  for rel in \
    "ld.so.preload" \
    "etc/ld.so.preload" \
    "syscall_config.yml"
  do
    f="$repo/includes.container/$rel"
    if [[ -e "$f" ]]; then
      mkdir -p "$quarantine_dir/$(dirname "$rel")"
      mv "$f" "$quarantine_dir/$rel"
      moved=$((moved + 1))
      warn "Quarantined runtime-risk include: includes.container/$rel"
    fi
  done

  if [[ "$moved" -gt 0 ]]; then
    cat > "$note" <<EOF
This directory was created by $SCRIPT_NAME $SCRIPT_VERSION.

The files here were moved out of includes.container because the generated
container build failed immediately after:

  ADD includes.container /

with:

  exec container process (missing dynamic library?) /bin/sh: No such file or directory

This indicates dynamic-loader or runtime-instrumentation breakage in the build
stage before any package commands can run.

Moved files should be reviewed before release. If they are required in the final
image, they must be restored at a later safe stage, after the libraries they
reference exist.
EOF
  fi

  return 0
}



verify_preserved_firmware_after_reconstruction() {
  local repo="$1"
  local label="$2"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-firmware-preservation-check-$(date -u +%H%M%S).log"
  local count=0

  mkdir -p "$OUTPUT_DIR/logs"

  {
    printf '### Firmware preservation check for %s\n' "$label"
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### repo: %s\n\n' "$repo"
    printf 'Firmware files in includes.container:\n'
    find "$repo/includes.container" -type f \( -path '*/lib/firmware/*' -o -path '*/usr/lib/firmware/*' \) -print | sort || true
  } >"$log"

  count="$(find "$repo/includes.container" -type f \( -path '*/lib/firmware/*' -o -path '*/usr/lib/firmware/*' \) -print 2>/dev/null | wc -l | awk '{print $1}')"

  if [[ "${count:-0}" -gt 0 ]]; then
    ok "Firmware preservation check passed for $label: $count firmware file(s) remain in includes.container."
    printf 'Firmware preservation log:\n  %s\n' "$log" >&2
  else
    warn "No firmware files found in includes.container after reconstruction for $label."
    warn "If Qualcomm firmware was expected, inspect staging and reconstruction logs."
    warn "Firmware preservation log: $log"
  fi
}

podman_network_args() {
  case "${PODMAN_BUILD_NETWORK,,}" in
    host)
      printf '%s\n' "--network=host"
      ;;
    default|"")
      printf '%s\n' ""
      ;;
    none)
      printf '%s\n' "--network=none"
      ;;
    *)
      printf '%s\n' "--network=$PODMAN_BUILD_NETWORK"
      ;;
  esac
}

preflight_podman_build_dns() {
  local label="$1"
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-${label}-podman-build-dns-preflight-$(date -u +%H%M%S).log"
  local network_arg
  local status=0
  local choice

  mkdir -p "$OUTPUT_DIR/logs"
  network_arg="$(podman_network_args)"

  info "Running Podman build-network DNS preflight for $label"
  printf 'DNS preflight log: %s\n' "$log" >&2
  printf 'Podman build network policy: %s\n' "$PODMAN_BUILD_NETWORK" >&2

  {
    printf '### Podman build DNS preflight for %s\n' "$label"
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### network arg: %s\n\n' "${network_arg:-default}"

    printf '## Host resolver\n'
    cat /etc/resolv.conf || true
    printf '\n'

    printf '## Container DNS checks\n'
    podman run --rm ${network_arg:+$network_arg} ghcr.io/vanilla-os/pico:dev /bin/sh -lc '
      set -e
      echo "container /etc/resolv.conf:"
      cat /etc/resolv.conf || true
      echo
      for h in repo3.vanillaos.org deb.debian.org github.com ghcr.io; do
        echo "checking $h"
        if command -v getent >/dev/null 2>&1; then
          getent hosts "$h"
        elif command -v python3 >/dev/null 2>&1; then
          python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$h"
        else
          ping -c 1 "$h"
        fi
      done
    '
  } >"$log" 2>&1 || status=$?

  if [[ "$status" -ne 0 ]]; then
    fail "Podman build-network DNS preflight failed."
    warn "This predicts apt failures inside podman image build."
    warn "Current PODMAN_BUILD_NETWORK=$PODMAN_BUILD_NETWORK"
    print_failure_tail "$log"

    choice="$(menu "Podman Build DNS Failure

DNS resolution failed inside a disposable container using the same network mode
that will be used for podman image build. Host DNS may still be fine; the issue
is container networking." "1" \
      "1|Retry using host networking [DEFAULT]|Set PODMAN_BUILD_NETWORK=host and re-run DNS preflight." \
      "2|Continue anyway|Attempt the build despite failed DNS preflight." \
      "3|Open shell to repair Podman/DNS|Inspect resolv.conf, podman network, firewalls, or VM DNS." \
      "4|Abort build|Stop before the expensive container build.")"

    case "$choice" in
      1)
        PODMAN_BUILD_NETWORK="host"
        preflight_podman_build_dns "$label"
        return $?
        ;;
      2)
        warn "Continuing despite failed Podman DNS preflight."
        return 0
        ;;
      3)
        open_shell "$WORKDIR"
        preflight_podman_build_dns "$label"
        return $?
        ;;
      4|*)
        return 1
        ;;
    esac
  fi

  ok "Podman build-network DNS preflight passed."
  return 0
}

podman_build_with_optional_no_cache() {
  local label="$1"
  local repo="$2"
  local tag="$3"
  local network_arg
  local safe_label
  local log
  local status

  safe_label="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g')"
  network_arg="$(podman_network_args)"

  preflight_podman_build_dns "$safe_label" \
    || die "Podman build DNS preflight failed. Set PODMAN_BUILD_NETWORK=host or repair container DNS."

  if [[ "$STREAM_LONG_COMMAND_OUTPUT" == "1" ]]; then
    mkdir -p "$OUTPUT_DIR/logs"
    log="$OUTPUT_DIR/logs/${BUILD_DATE}-${safe_label}-$(date -u +%H%M%S).log"
    LAST_COMMAND_LOG="$log"

    info "$label"
    printf 'Working directory: %s\n' "$repo" >&2
    if [[ "$PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE" == "1" ]]; then
      printf 'Command: podman image build %s --no-cache -t %s .\n' "${network_arg:-}" "$tag" >&2
    else
      printf 'Command: podman image build %s -t %s .\n' "${network_arg:-}" "$tag" >&2
    fi
    printf 'Command log: %s\n' "$log" >&2

    {
      printf '### %s\n' "$label"
      printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '### PWD: %s\n' "$repo"
      if [[ "$PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE" == "1" ]]; then
        printf '### COMMAND: podman image build %s --no-cache -t %s .\n\n' "${network_arg:-}" "$tag"
      else
        printf '### COMMAND: podman image build %s -t %s .\n\n' "${network_arg:-}" "$tag"
      fi
    } > "$log"

    set +e
    (
      cd "$repo" || exit 97
      if [[ "$PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE" == "1" ]]; then
        if [[ -n "$network_arg" ]]; then
          podman image build "$network_arg" --no-cache -t "$tag" .
        else
          podman image build --no-cache -t "$tag" .
        fi
      else
        if [[ -n "$network_arg" ]]; then
          podman image build "$network_arg" -t "$tag" .
        else
          podman image build -t "$tag" .
        fi
      fi
    ) 2>&1 | tee -a "$log"
    status=${PIPESTATUS[0]}
    set -e

    if [[ "$status" -eq 0 ]]; then
      ok "$label completed successfully."
      return 0
    fi

    classify_container_build_failure "$log"
    action="$(command_failure_menu "$label" "$repo" "$log" "$status")"
    case "$action" in
      shell) open_shell "$repo" ;;
      logshell) open_shell "$OUTPUT_DIR/logs" ;;
      retry) podman_build_with_optional_no_cache "$label" "$repo" "$tag"; return $? ;;
      diagnose) warn "Deep diagnostics are currently implemented for Vib commands only." ;;
      abort|*) die "Build aborted after failed command. See log: $log" ;;
    esac
  else
    if [[ "$PODMAN_BUILD_NO_CACHE_AFTER_CONTEXT_CHANGE" == "1" ]]; then
      if [[ -n "$network_arg" ]]; then
        run_logged "$label" "$repo" podman image build "$network_arg" --no-cache -t "$tag" .
      else
        run_logged "$label" "$repo" podman image build --no-cache -t "$tag" .
      fi
    else
      if [[ -n "$network_arg" ]]; then
        run_logged "$label" "$repo" podman image build "$network_arg" -t "$tag" .
      else
        run_logged "$label" "$repo" podman image build -t "$tag" .
      fi
    fi
  fi
}

build_container_image_with_context_workarounds() {
  local label="$1"
  local repo="$2"
  local tag="$3"
  local safe_label

  safe_label="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g')"

  patch_known_debian_changelog_dates "$repo" "$safe_label"
  patch_known_unavailable_packages "$repo" "$safe_label"
  normalize_firmware_paths_for_usrmerge "$repo" "$safe_label"
  diagnose_generated_container_context "$repo" "$safe_label"
  maybe_disable_ld_so_preload_for_container_build "$repo"

  if ! probe_includes_container_runtime_effect "$repo" "$safe_label"; then
    warn "Attempting conservative quarantine of remaining runtime-risk include files."
    quarantine_runtime_breaking_includes_files "$repo"
    diagnose_generated_container_context "$repo" "${safe_label}-after-quarantine"
    if ! probe_includes_container_runtime_effect "$repo" "${safe_label}-after-quarantine"; then
      warn "includes.container still breaks /bin/sh after quarantine."
      if reconstruct_includes_container_safely "$repo" "$safe_label"; then
        diagnose_generated_container_context "$repo" "${safe_label}-after-reconstruction"
        verify_preserved_firmware_after_reconstruction "$repo" "${safe_label}-after-reconstruction"
        probe_includes_container_runtime_effect "$repo" "${safe_label}-after-reconstruction" \
          || die "Reconstructed includes.container still breaks /bin/sh. Review reconstruction manifest and probe logs."
      else
        die "includes.container still breaks /bin/sh and safe reconstruction did not resolve it. Review probe logs before continuing."
      fi
    fi
  fi

  verify_preserved_firmware_after_reconstruction "$repo" "$safe_label"
  podman_build_with_optional_no_cache "$label" "$repo" "$tag"
}


build_images() {
  ensure_vib_run_user
  local core="$SOURCES_DIR/core-image"
  local desktop="$SOURCES_DIR/desktop-image"

  if [[ -d "$core" ]]; then
    run_vib_build_with_diagnostics "core image" "$core"
    build_container_image_with_context_workarounds "Build local core container image" "$core" "local/vanilla-core:$PROFILE-$BUILD_DATE"
  else
    warn "core-image source directory is missing; skipping core image build."
  fi

  if [[ -d "$desktop" ]]; then
    run_vib_build_with_diagnostics "desktop image" "$desktop"
    build_container_image_with_context_workarounds "Build local desktop container image" "$desktop" "local/vanilla-desktop:$PROFILE-$BUILD_DATE"
  else
    warn "desktop-image source directory is missing; skipping desktop image build."
  fi
}

live_iso_runtime_cmd() {
  case "${LIVE_ISO_CONTAINER_RUNTIME,,}" in
    docker) printf '%s\n' "docker" ;;
    podman|"") printf '%s\n' "podman" ;;
    *)
      warn "Unknown LIVE_ISO_CONTAINER_RUNTIME=$LIVE_ISO_CONTAINER_RUNTIME; using podman."
      printf '%s\n' "podman"
      ;;
  esac
}


image_architecture_matches_platform() {
  local runtime="$1"
  local image="$2"
  local expected_platform="$3"
  local expected_arch actual_arch

  expected_arch="${expected_platform#linux/}"
  case "$expected_arch" in
    arm64) expected_arch="arm64" ;;
    amd64) expected_arch="amd64" ;;
  esac

  actual_arch="$("$runtime" image inspect "$image" --format '{{.Architecture}}' 2>/dev/null | head -n1 || true)"
  [[ -n "$actual_arch" ]] || return 1
  [[ "$actual_arch" == "$expected_arch" ]]
}

select_live_iso_helper_image() {
  # Pick the first image that can actually run /bin/bash for the requested
  # platform. This avoids the observed failure where pico:main resolves to amd64
  # on an aarch64 host and then fails with Exec format error.
  local runtime="$1"
  local candidate log status

  log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-iso-helper-selection-$(date -u +%H%M%S).log"
  mkdir -p "$OUTPUT_DIR/logs"

  {
    printf '### Live ISO helper image selection\n'
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### runtime: %s\n' "$runtime"
    printf '### requested platform: %s\n' "$LIVE_ISO_CONTAINER_PLATFORM"
    printf '### initial image: %s\n' "$LIVE_ISO_CONTAINER_IMAGE"
    printf '### candidates: %s\n\n' "$LIVE_ISO_CONTAINER_FALLBACK_IMAGES"
  } >"$log"

  for candidate in "$LIVE_ISO_CONTAINER_IMAGE" $LIVE_ISO_CONTAINER_FALLBACK_IMAGES; do
    printf 'Testing live ISO helper image candidate: %s\n' "$candidate" >&2
    {
      printf '\n## Candidate: %s\n' "$candidate"
      "$runtime" pull --platform "$LIVE_ISO_CONTAINER_PLATFORM" "$candidate"
      "$runtime" image inspect "$candidate" --format 'architecture={{.Architecture}} os={{.Os}}' || true
      "$runtime" run --rm --platform "$LIVE_ISO_CONTAINER_PLATFORM" "$candidate" /bin/bash -lc 'uname -m; command -v bash; echo LIVE_ISO_HELPER_OK'
    } >>"$log" 2>&1
    status=$?

    if [[ "$status" -eq 0 ]] && image_architecture_matches_platform "$runtime" "$candidate" "$LIVE_ISO_CONTAINER_PLATFORM"; then
      LIVE_ISO_CONTAINER_IMAGE="$candidate"
      ok "Selected live ISO helper image: $LIVE_ISO_CONTAINER_IMAGE"
      printf 'Selection log:\n  %s\n' "$log" >&2
      return 0
    fi

    warn "Rejected live ISO helper image candidate: $candidate"
  done

  fail "No usable live ISO helper image found for $LIVE_ISO_CONTAINER_PLATFORM."
  warn "Selection log: $log"
  print_failure_tail "$log"
  return 1
}

preflight_live_iso_container() {
  local live="$1"
  local runtime
  local log="$OUTPUT_DIR/logs/${BUILD_DATE}-live-iso-container-preflight-$(date -u +%H%M%S).log"
  local status=0
  local choice

  runtime="$(live_iso_runtime_cmd)"
  mkdir -p "$OUTPUT_DIR/logs"

  select_live_iso_helper_image "$runtime" || return $?

  info "Running live ISO container architecture preflight."
  printf 'Live ISO runtime: %s\n' "$runtime" >&2
  printf 'Live ISO container image: %s\n' "$LIVE_ISO_CONTAINER_IMAGE" >&2
  printf 'Live ISO container platform: %s\n' "$LIVE_ISO_CONTAINER_PLATFORM" >&2
  printf 'Preflight log: %s\n' "$log" >&2

  {
    printf '### Live ISO container preflight\n'
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### host uname: %s\n' "$(uname -m)"
    printf '### runtime: %s\n' "$runtime"
    printf '### image: %s\n' "$LIVE_ISO_CONTAINER_IMAGE"
    printf '### platform: %s\n\n' "$LIVE_ISO_CONTAINER_PLATFORM"

    printf '## runtime version\n'
    "$runtime" version 2>&1 || true
    printf '\n'

    printf '## image pull\n'
    "$runtime" pull --platform "$LIVE_ISO_CONTAINER_PLATFORM" "$LIVE_ISO_CONTAINER_IMAGE"
    printf '\n'

    printf '## local image inspection\n'
    "$runtime" image inspect "$LIVE_ISO_CONTAINER_IMAGE" 2>&1 || true
    printf '\n'

    printf '## architecture check\n'
    "$runtime" image inspect "$LIVE_ISO_CONTAINER_IMAGE" --format 'architecture={{.Architecture}} os={{.Os}}'
    printf '\n'

    printf '## execution probe\n'
    "$runtime" run --rm --platform "$LIVE_ISO_CONTAINER_PLATFORM" "$LIVE_ISO_CONTAINER_IMAGE" /bin/bash -lc 'uname -m; echo LIVE_ISO_CONTAINER_EXEC_OK'
  } >"$log" 2>&1 || status=$?

  if [[ "$status" -ne 0 ]]; then
    fail "Live ISO container preflight failed."
    warn "This predicts Stage 9 live ISO container execution failure."
    warn "Runtime: $runtime"
    warn "Log: $log"
    print_failure_tail "$log"

    choice="$(menu "Live ISO Container Preflight Failure

The live ISO helper container could not be pulled or executed with the selected
runtime/platform. Stage 8 image builds have already completed, so this is
isolated to Stage 9." "1" \
      "1|Open shell in live-iso directory [DEFAULT]|Inspect runtime image cache and live-iso scripts, then exit to resume." \
      "2|Retry with Podman runtime|Set LIVE_ISO_CONTAINER_RUNTIME=podman and retry preflight." \
      "3|Retry with Docker runtime|Set LIVE_ISO_CONTAINER_RUNTIME=docker and retry preflight." \
      "4|Abort build|Stop and preserve logs/artifacts.")"

    case "$choice" in
      1)
        open_shell "$live"
        preflight_live_iso_container "$live"
        return $?
        ;;
      2)
        LIVE_ISO_CONTAINER_RUNTIME="podman"
        preflight_live_iso_container "$live"
        return $?
        ;;
      3)
        LIVE_ISO_CONTAINER_RUNTIME="docker"
        preflight_live_iso_container "$live"
        return $?
        ;;
      4|*)
        return "$status"
        ;;
    esac
  fi

  ok "Live ISO container preflight passed."
  return 0
}


patch_live_conf() {
  local conf="$SOURCES_DIR/live-iso/etc/terraform.conf"
  [[ -f "$conf" ]] || { warn "terraform.conf not found at $conf"; return 0; }
  cp -a "$conf" "$conf.builder-backup.$(date -u +%Y%m%d%H%M%S)"
  sed -i 's/^ARCH=.*/ARCH="arm64"/' "$conf" || true
  grep -q '^ARCH=' "$conf" || printf 'ARCH="arm64"\n' >>"$conf"
}

build_iso() {
  local live="$SOURCES_DIR/live-iso"
  local runtime
  local log
  local status
  local action

  [[ -d "$live" ]] || die "live-iso source missing."
  patch_live_conf
  preflight_live_iso_container "$live" || die "Live ISO container preflight failed. See log above."

  runtime="$(live_iso_runtime_cmd)"
  mkdir -p "$OUTPUT_DIR/logs"
  log="$OUTPUT_DIR/logs/${BUILD_DATE}-build-live-iso-$(date -u +%H%M%S).log"
  LAST_COMMAND_LOG="$log"

  info "Build live ISO"
  printf 'Working directory: %s\n' "$live" >&2
  printf 'Runtime: %s\n' "$runtime" >&2
  printf 'Container image: %s\n' "$LIVE_ISO_CONTAINER_IMAGE" >&2
  printf 'Platform: %s\n' "$LIVE_ISO_CONTAINER_PLATFORM" >&2
  printf 'Command log: %s\n' "$log" >&2

  {
    printf '### Build live ISO\n'
    printf '### UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '### PWD: %s\n' "$live"
    printf '### RUNTIME: %s\n' "$runtime"
    printf '### IMAGE: %s\n' "$LIVE_ISO_CONTAINER_IMAGE"
    printf '### PLATFORM: %s\n\n' "$LIVE_ISO_CONTAINER_PLATFORM"
  } >"$log"

  set +e
  (
    cd "$live" || exit 97
    "$runtime" run --privileged --platform "$LIVE_ISO_CONTAINER_PLATFORM" \
      --network host \
      -i \
      -v /proc:/proc \
      -v "$PWD":/working_dir \
      -w /working_dir \
      "$LIVE_ISO_CONTAINER_IMAGE" \
      /bin/bash -s etc/terraform.conf < build.sh
  ) 2>&1 | tee -a "$log"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -eq 0 ]]; then
    local expected_kver dtb_name
    expected_kver="$(resolve_custom_kernel_release || true)"
    dtb_name="$(basename "${PRIMARY_DTB:-}")"
    [[ -n "$expected_kver" && -n "$dtb_name" ]] || die "Missing expected kernel/DTB metadata for ISO verification."
    verify_built_iso_custom_boot_artifacts "$live" "$expected_kver" "$dtb_name"
    ok "Build live ISO completed successfully with verified custom kernel and DTB."
    return 0
  fi

  if grep -q "Exec format error" "$log"; then
    fail "Live ISO build failed because the helper container architecture is wrong."
    grep -n "Exec format error" "$log" >&2 || true
    warn "Current LIVE_ISO_CONTAINER_RUNTIME=$LIVE_ISO_CONTAINER_RUNTIME"
    warn "Current LIVE_ISO_CONTAINER_PLATFORM=$LIVE_ISO_CONTAINER_PLATFORM"
  elif grep -q "image not known\|no such image" "$log"; then
    fail "Live ISO build failed because the selected runtime could not resolve the helper image locally/remotely."
    grep -nE "image not known|no such image" "$log" >&2 || true
    warn "Current runtime: $runtime"
  fi

  action="$(command_failure_menu "Build live ISO" "$live" "$log" "$status")"
  case "$action" in
    shell) open_shell "$live" ;;
    logshell) open_shell "$OUTPUT_DIR/logs" ;;
    retry) build_iso; return $? ;;
    diagnose) warn "Deep diagnostics are currently implemented for Vib commands only." ;;
    abort|*) die "Build aborted after live ISO failure. See log: $log" ;;
  esac
}
# ---------------------------- release ---------------------------------

next_release_id() {
  mkdir -p "$WORKDIR"
  local n=0
  [[ -f "$BUILD_COUNTER_FILE" ]] && n="$(cat "$BUILD_COUNTER_FILE" 2>/dev/null || echo 0)"
  n=$((10#$n + 1))
  printf '%04d' "$n" >"$BUILD_COUNTER_FILE"
  printf 'r%04d' "$n"
}

git_commit_or_unknown() {
  local repo="$1"
  if [[ -d "$repo/.git" ]]; then
    git -C "$repo" rev-parse HEAD 2>/dev/null || printf 'unknown'
  else
    printf 'missing'
  fi
}

write_manifest() {
  local release_dir="$1" iso_name="$2" release_id="$3"
  local json="$release_dir/${iso_name%.iso}.build.json"
  local md="$release_dir/${iso_name%.iso}.build.md"

  {
    printf '{\n'
    printf '  "script_version": "%s",\n' "$SCRIPT_VERSION"
    printf '  "profile": "%s",\n' "$PROFILE"
    printf '  "architecture": "%s",\n' "$ARCH"
    printf '  "release_id": "%s",\n' "$release_id"
    printf '  "build_date_utc": "%s",\n' "$(date -u +%FT%TZ)"
    printf '  "workdir": "%s",\n' "$WORKDIR"
    printf '  "primary_dtb": "%s",\n' "${PRIMARY_DTB:-}"
    printf '  "qcom_mode": "%s",\n' "${QCOM_MODE:-skip}"
    printf '  "qcom_device_path": "%s",\n' "${QCOM_DEVICE_PATH:-}"
    printf '  "repositories": {\n'
    printf '    "core_image": "%s",\n' "$(git_commit_or_unknown "$SOURCES_DIR/core-image")"
    printf '    "desktop_image": "%s",\n' "$(git_commit_or_unknown "$SOURCES_DIR/desktop-image")"
    printf '    "live_iso": "%s",\n' "$(git_commit_or_unknown "$SOURCES_DIR/live-iso")"
    printf '    "pico_image": "%s"\n' "$(git_commit_or_unknown "$SOURCES_DIR/pico-image")"
    printf '  }\n'
    printf '}\n'
  } >"$json"

  {
    printf '# Build %s\n\n' "$release_id"
    printf 'Profile: `%s`\n\n' "$PROFILE"
    printf 'Architecture: `%s`\n\n' "$ARCH"
    printf 'Script version: `%s`\n\n' "$SCRIPT_VERSION"
    printf 'Primary DTB: `%s`\n\n' "${PRIMARY_DTB:-none}"
    printf 'Qualcomm firmware mode: `%s`\n\n' "${QCOM_MODE:-skip}"
    printf 'Log: `%s`\n\n' "$LOG_FILE"
  } >"$md"
}

archive_release() {
  local release_id="$1"
  local release_dir="$RELEASES_DIR/${BUILD_DATE}-${release_id}-${PROFILE}"
  mkdir -p "$release_dir/input-artifacts" "$release_dir/logs"

  local iso
  iso="$(find "$SOURCES_DIR/live-iso/builds" -type f -name '*.iso' -print 2>/dev/null | sort | tail -n1 || true)"
  if [[ -z "$iso" ]]; then
    warn "No ISO found under live-iso/builds; release directory created without ISO."
    iso_name="${RELEASE_PREFIX}-${ARCH}-${BUILD_DATE}-${release_id}-${PROFILE}.iso"
  else
    iso_name="${RELEASE_PREFIX}-${ARCH}-${BUILD_DATE}-${release_id}-${PROFILE}.iso"
    cp -a "$iso" "$release_dir/$iso_name"
    (cd "$release_dir" && sha256sum "$iso_name" >"$iso_name.sha256")
  fi

  for f in "${KERNEL_DEBS[@]:-}" "${DTB_FILES[@]:-}"; do
    [[ -f "$f" ]] && cp -a "$f" "$release_dir/input-artifacts/"
  done
  if [[ -n "${QCOM_ARCHIVE:-}" && -f "$QCOM_ARCHIVE" ]]; then
    cp -a "$QCOM_ARCHIVE" "$release_dir/input-artifacts/"
  fi
  [[ -f "$LOG_FILE" ]] && cp -a "$LOG_FILE" "$release_dir/logs/"

  write_manifest "$release_dir" "$iso_name" "$release_id"
  (cd "$release_dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt)

  ok "Release directory: $release_dir"
  printf '%s' "$release_dir"
}

verify_iso() {
  local release_dir="$1"
  local iso
  iso="$(find "$release_dir" -maxdepth 1 -type f -name '*.iso' -print | head -n1 || true)"
  [[ -n "$iso" ]] || { warn "No ISO available to verify."; return 0; }

  local reader
  reader="$(find_iso_reader)"
  info "Verifying ISO contents using $reader."
  local listing="$TMP_DIR/iso-listing-$$.txt"
  if [[ "$reader" == "isoinfo" ]]; then
    isoinfo -i "$iso" -R -f >"$listing" || warn "isoinfo failed."
  elif [[ "$reader" == "xorriso" ]]; then
    xorriso -indev "$iso" -find / -type f -print >"$listing" || warn "xorriso listing failed."
  fi

  grep -Ei 'BOOTAA64|grubaa64|EFI' "$listing" >/dev/null && ok "ARM64 EFI boot files detected." || warn "ARM64 EFI boot files not detected in listing."
  grep -Ei '\.dtb$' "$listing" >/dev/null && ok "DTB files detected in ISO." || warn "No DTB files detected in ISO listing."
}

# ------------------------------ main ----------------------------------

usage() {
  cat >&2 <<EOF
$SCRIPT_NAME $SCRIPT_VERSION

Usage:
  $SCRIPT_NAME [options]

Options:
  --workdir PATH                  Override workdir.
  --profile NAME                  Board profile name. Default: $PROFILE
  --artifacts PATH                Custom kernel/DTB artifact directory.
  --root-overlay PATH             Directory to copy into /root of target image.
  --repo-policy POLICY            ask-once, prompt, pull, continue, reclone.
  --cleanup-bad-prompt-dirs       Remove known accidental prompt-text dirs.
  -h, --help                      Show help.
EOF
}

cleanup_bad_prompt_dirs() {
  info "Scanning for accidental prompt-text directories under $WORKDIR."
  find "$WORKDIR" -maxdepth 3 -type d \( \
    -name $'\nCustom kernel'* -o \
    -name $'\nLocal Qualcomm'* -o \
    -name $'\nOptional pre-staged'* -o \
    -name '*Custom kernel*' \
  \) -print -exec rm -rf {} + 2>/dev/null || true
  ok "Cleanup scan complete."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$(normalize_path_input "$2")"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --artifacts) ARTIFACT_DIR="$(normalize_path_input "$2")"; shift 2 ;;
    --root-overlay) ROOT_OVERLAY_DIR="$(normalize_path_input "$2")"; shift 2 ;;
    --repo-policy) REPO_POLICY="$2"; shift 2 ;;
    --cleanup-bad-prompt-dirs) CLEANUP_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Recompute dependent paths after CLI overrides.
SOURCES_DIR="$WORKDIR/sources"
DOWNLOADS_DIR="$WORKDIR/downloads"
OUTPUT_DIR="$WORKDIR/output"
RELEASES_DIR="$OUTPUT_DIR/releases"
TMP_DIR="$WORKDIR/tmp"
STAGED_QCOM_DIR="$WORKDIR/staged-firmware/qcom/$PROFILE"
PRESTAGED_QCOM_DIR="$WORKDIR/prestaged-firmware/$PROFILE"
BUILD_COUNTER_FILE="$WORKDIR/.build-number"

mkdir -p "$WORKDIR" "$SOURCES_DIR" "$ARTIFACT_DIR" "$ROOT_OVERLAY_DIR" "$DOWNLOADS_DIR" "$OUTPUT_DIR" "$RELEASES_DIR" "$TMP_DIR"
setup_logging

if [[ "${CLEANUP_ONLY:-0}" == "1" ]]; then
  cleanup_bad_prompt_dirs
  exit 0
fi

cat >&2 <<EOF

Constructive Vanilla ARM64 Release Builder
Version: $SCRIPT_VERSION

Primary host assumption:
  Debian 13 VM on Apple Silicon / M3 Macintosh

Primary target profile:
  $PROFILE

Default directories:
  Workdir:       $WORKDIR
  Sources:       $SOURCES_DIR
  Artifacts:     $ARTIFACT_DIR
  Root overlay:  $ROOT_OVERLAY_DIR
  Downloads:     $DOWNLOADS_DIR
  Releases:      $RELEASES_DIR
  Repo policy:   $REPO_POLICY

EOF

stage 1 11 "Checking host dependencies."
check_dependencies

stage 2 11 "Refreshing source repositories."
choose_repo_policy_once
repair_source_tree_ownership_for_git
sync_repo "pico-image" "$PICO_REPO_URL" "$PICO_BRANCH" "$SOURCES_DIR/pico-image"
sync_repo "core-image" "$CORE_REPO_URL" "$CORE_BRANCH" "$SOURCES_DIR/core-image"
sync_repo "desktop-image" "$DESKTOP_REPO_URL" "$DESKTOP_BRANCH" "$SOURCES_DIR/desktop-image"
sync_repo "live-iso" "$LIVE_REPO_URL" "$LIVE_BRANCH" "$SOURCES_DIR/live-iso"

info "Ensuring Vib plugin bundles are installed for image recipes."
ensure_vib_plugins_for_image_repos
info "Ensuring recipe-specific Vib plugins are installed."
ensure_required_recipe_specific_plugins

info "Checking and repairing known Vib recipe YAML indentation issues."
repair_known_vib_recipes

stage 3 11 "Validating local kernel and DTB artifacts."
validate_artifacts

stage 4 11 "Configuring Qualcomm firmware staging."
configure_qcom_firmware

stage 5 11 "Staging Qualcomm firmware without modifying build host."
stage_qcom_firmware

stage 6 11 "Preparing build summary."
release_id="$(next_release_id)"
release_dir_preview="$RELEASES_DIR/${BUILD_DATE}-${release_id}-${PROFILE}"
mkdir -p "$release_dir_preview/logs"
cat >"$release_dir_preview/BUILD-PLAN.md" <<EOF
# Vanilla ARM64 Build Plan

Generated UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Profile: $PROFILE
Architecture: $ARCH
Primary DTB: ${PRIMARY_DTB:-none selected}
Artifact directory: $ARTIFACT_DIR
Root overlay directory: $ROOT_OVERLAY_DIR
Qualcomm firmware mode: ${QCOM_MODE:-skip}
Qualcomm device path: ${QCOM_DEVICE_PATH:-not applicable}

This file is written before the long-running build begins so the stamped
release directory exists during pre-build inspection.
EOF
info "Prepared stamped release directory before build: $release_dir_preview"

summary_choice="$(menu "Build Summary

Profile:
  $PROFILE

Architecture:
  $ARCH

Primary DTB:
  ${PRIMARY_DTB:-none selected}

Custom artifact directory:
  $ARTIFACT_DIR

Root overlay directory:
  $ROOT_OVERLAY_DIR

Qualcomm firmware:
  Mode: ${QCOM_MODE:-skip}
  Device path: ${QCOM_DEVICE_PATH:-not applicable}

Output release directory:
  $release_dir_preview" "1" \
  "1|Begin build|Start image and ISO creation using the settings above." \
  "2|Open an interactive shell before build|Inspect or modify files, then exit to resume." \
  "3|Abort build|Stop immediately.")"
case "$summary_choice" in
  2) open_shell "$WORKDIR" ;;
  3) die "Build aborted by operator." ;;
esac

stage 7 11 "Staging custom kernel, DTB, firmware, and /root overlay."
stage_customizations

stage 8 11 "Building core and desktop images."
build_images

stage 9 11 "Building live ISO."
build_iso

stage 10 11 "Archiving stamped release artifacts."
release_dir="$(archive_release "$release_id")"

stage 11 11 "Verifying ISO release artifact."
verify_iso "$release_dir"

ok "Build completed."
printf '\nRelease output:\n  %s\n\n' "$release_dir" >&2
