#!/usr/bin/env bash
# shellcheck shell=bash
#
# Constructive Vanilla ARM64 Release Builder
# Version: 2.3.1
#
# Purpose:
#   Build a stamped, repeatable Vanilla OS ARM64 UEFI installation ISO from
#   Vanilla ARM GitHub sources, local board/kernel artifacts, optional /root
#   overlay files, and optional Qualcomm GPU/display/video firmware extracted in an isolated
#   disposable container from alejandroqh/qcom-firmware-updater. The updater
#   is never allowed to install firmware onto the build host.
#
# Primary assumed environment:
#   - Debian 13 build VM
#   - Apple Silicon / M3 Macintosh host running a Linux VM
#   - ARM64/aarch64 userspace preferred for native arm64 container builds
#   - Target: HP Omnibook 5, UEFI firmware, Secure Boot disabled
#
# Design principles:
#   - Git repositories are upstream build inputs.
#   - Local artifact directories are first-class board/vendor inputs.
#   - Every release gets a stamped filename, manifest, checksums, logs, and
#     archived copies of the exact local inputs used.
#   - Re-runs are idempotent: existing repositories are refreshed with git pull
#     unless --skip-pull is used.
#   - User prompts always echo default values and allow retry where paths or
#     values are invalid.
#
# Important limitation:
#   Vanilla ARM repository internals may change. This script injects artifacts
#   through currently conventional includes.container / includes.chroot /
#   includes.binary locations and appends clearly marked VIB recipe modules.
#   Review generated modifications before relying on a release for production.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.3.1"
SCRIPT_NAME="Constructive Vanilla ARM64 Release Builder"

# -----------------------------
# Exit code contract
# -----------------------------
EX_USAGE=2
EX_DEPENDENCY=10
EX_GIT=20
EX_ARTIFACT=30
EX_BUILD=40
EX_ISO=50
EX_VERIFY=60

# -----------------------------
# Defaults; all can be overridden by CLI or prompt.
# -----------------------------
WORKDIR="${WORKDIR:-$HOME/src/vanilla-arm64-build-system}"
PROFILE="hp-omnibook-5"
RELEASE_PREFIX="Constructive-VanillaOS-Orchid"
ARCH="arm64"
BASECODENAME="sid"
CODENAME="orchid"
VERSION="2"
CHANNEL="stable"
PACKAGE_LISTS_SUFFIX="vanilla-installer"
SKIP_PULL=0
DRY_RUN=0
VERBOSE=0
ENABLE_QCOM_FW=1
ALLOW_DIRTY_REPOS=0
CLEAN_STAGING=1
CLEANUP_BAD_PROMPT_DIRS=0

# Repository defaults. These are intentionally centralized for traceability.
CORE_REPO_URL="https://github.com/vanilla-arm/core-image"
CORE_REPO_BRANCH="dev"
DESKTOP_REPO_URL="https://github.com/vanilla-arm/desktop-image"
DESKTOP_REPO_BRANCH="dev"
LIVE_REPO_URL="https://github.com/vanilla-arm/live-iso"
LIVE_REPO_BRANCH="orchid"
PICO_REPO_URL="https://github.com/vanilla-arm/pico-image"
PICO_REPO_BRANCH="main"
QCOM_FW_REPO_URL="https://github.com/alejandroqh/qcom-firmware-updater"
QCOM_FW_REPO_BRANCH="main"

# HP Omnibook 5 default from qcom-firmware-updater supported-device table.
QCOM_DEVICE_PATH="x1p42100/hp/omnibook-5"
QCOM_DRIVER_ARCHIVE=""
QCOM_DRIVER_URL=""
QCOM_PRESTAGED_DIR=""
QCOM_STAGED_FIRMWARE_DIR=""

ARTIFACT_DIR=""
ROOT_OVERLAY_DIR=""
CONTAINER_ENGINE=""

# These are derived after prompts/CLI parsing.
SOURCES_DIR=""
OUTPUT_DIR=""
RELEASES_DIR=""
LOGS_DIR=""
CACHE_DIR=""
TMP_DIR=""
CURRENT_RELEASE_DIR=""
BUILD_ID=""
BUILD_NUMBER=""
BUILD_DATE_UTC=""
LOG_FILE=""

# -----------------------------
# Console helpers
# -----------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_GRAY=$'\033[90m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_GRAY=""
fi

log()   { printf '%s %s\n' "${C_BLUE}==>${C_RESET}" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
ok()    { printf '%s %s\n' "${C_GREEN}OK ${C_RESET}" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
warn()  { printf '%s %s\n' "${C_YELLOW}WARN${C_RESET}" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
fail()  { printf '%s %s\n' "${C_RED}FAIL${C_RESET}" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }

run() {
  # Run a command with optional dry-run and logging support.
  # Commands are printed before execution so logs remain self-explanatory.
  printf '%s %q' "${C_GRAY}+${C_RESET}" "$1" | tee -a "${LOG_FILE:-/dev/null}"
  shift || true
  for arg in "$@"; do printf ' %q' "$arg" | tee -a "${LOG_FILE:-/dev/null}"; done
  printf '\n' | tee -a "${LOG_FILE:-/dev/null}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
}

usage() {
  cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION

Usage:
  $0 [options]

Options:
  --workdir PATH             Build system root. Default: $WORKDIR
  --artifacts PATH           Local directory containing custom *.deb and *.dtb files.
                             Default prompt value: <workdir>/artifacts/$PROFILE
  --root-overlay PATH        Local directory whose contents will populate /root.
                             Default prompt value: <workdir>/root-overlay/$PROFILE
  --profile NAME             Board/profile name. Default: $PROFILE
  --release-prefix NAME      Release filename prefix. Default: $RELEASE_PREFIX
  --qcom-device-path PATH    qcom-firmware-updater device path. Default: $QCOM_DEVICE_PATH
  --qcom-driver-archive PATH Local Qualcomm Windows Graphics Driver ZIP/EXE.
  --qcom-driver-url URL      Qualcomm Windows Graphics Driver direct URL.
  --qcom-prestaged-dir PATH  Directory already containing target /lib/firmware-style files.
  --no-qcom-fw              Do not extract/stage Qualcomm firmware.
  --skip-pull               Do not refresh existing Git repositories.
  --allow-dirty-repos       Continue if repository has uncommitted changes.
  --dry-run                 Print plan and validations without modifying files.
  --verbose                 More logging.
  --cleanup-bad-prompt-dirs  Remove known accidental prompt-text directories from <workdir>.
  -h, --help                Show this help.

Examples:
  $0
  $0 --workdir ~/src/vanilla-arm64-build-system --profile hp-omnibook-5
  $0 --artifacts /opt/vanilla-arm-artifacts/hp-omnibook-5 --qcom-driver-archive ~/Downloads/Windows_Graphics_Driver.Core.zip
USAGE
}

# -----------------------------
# Input prompting helpers
# -----------------------------
# IMPORTANT IMPLEMENTATION NOTE:
# Prompt functions may be called through command substitution, e.g.:
#   ARTIFACT_DIR="$(prompt_existing_dir_or_create ...)"
# Therefore, all human-readable prompt/menu text MUST go to stderr, while stdout
# is reserved exclusively for the returned machine-readable value. Earlier
# revisions printed menu text to stdout; if execution was interrupted, callers
# could capture multi-line prompt text as a path and create directories with
# names such as $'\n'Custom kernel...'. This revision prevents that class of bug.

ui_line() { printf '%s\n' "$*" >&2; }
ui_blank() { printf '\n' >&2; }


trim_outer_whitespace() {
  # Remove accidental leading/trailing whitespace and CR characters from
  # interactive answers. This is intentionally conservative: embedded spaces
  # are preserved so paths such as "My Driver Archive.zip" remain valid.
  local value="$1"
  value="${value//$'\r'/}"
  # shellcheck disable=SC2001
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "$value"
}

normalize_user_path() {
  # Normalize user-entered paths without changing valid embedded spaces.
  # Handles common paste mistakes:
  #   - trailing spaces after a filename
  #   - surrounding single or double quotes
  #   - leading ~/ expansion
  local value="$1"
  value="$(trim_outer_whitespace "$value")"

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  value="$(trim_outer_whitespace "$value")"
  value="${value/#\~/$HOME}"
  printf '%s' "$value"
}

open_interactive_shell() {
  local dir="${1:-$PWD}"
  ui_blank
  ui_line "*** Opening interactive shell. Type 'exit' to return to the builder. ***"
  ui_line "Directory: $dir"
  ( cd "$dir" 2>/dev/null || cd "$PWD"; "${SHELL:-/bin/bash}" ) || true
}

prompt_value() {
  local label="$1" default="$2" value=""
  ui_blank
  ui_line "$label"
  ui_line "Default: $default"
  read -r -p "$label [$default]: " value || true
  value="$(trim_outer_whitespace "$value")"
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf '%s' "$value"
}

prompt_yes_no() {
  local label="$1" default="$2" reply=""
  local suffix="[y/N]"
  [[ "$default" =~ ^[Yy]$ ]] && suffix="[Y/n]"
  while true; do
    read -r -p "$label $suffix: " reply || true
    reply="${reply:-$default}"
    case "$reply" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      \?)
        ui_line "Enter yes/y to enable or no/n to disable. Press ENTER to accept the default."
        ;;
      !)
        open_interactive_shell "$PWD"
        ;;
      *) ui_line "Invalid response: '$reply'. Please answer yes or no." ;;
    esac
  done
}

prompt_existing_dir_or_create() {
  # Forgiving directory prompt:
  #   - accepts existing directories
  #   - offers to create non-existing directories
  #   - allows retry
  #   - allows a temporary shell escape for manual preparation
  #   - uses numbered, self-describing menu choices
  # Stdout returns only the selected directory path.
  local label="$1" default="$2" path="" choice=""
  while true; do
    path="$(prompt_value "$label" "$default")"
    path="$(normalize_user_path "$path")"
    if [[ -d "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi

    while true; do
      cat >&2 <<EOF

==================================================================
Directory Required

$label

The selected directory does not exist:
  $path

Shell-escaped interpretation:
  $(printf '%q' "$path")

Path length:
  ${#path} characters

Select an action:

  1) Create this directory and continue [DEFAULT]
     The builder will create the directory now.

  2) Enter a different directory path
     Return to the path prompt.

  3) Open an interactive shell
     Prepare files/directories manually, then type 'exit' to resume.

  4) Quit the builder
     Stop without continuing this build.

Special commands:
  ?  Show this menu again
  !  Open an interactive shell
==================================================================
EOF
      read -r -p "Selection [1]: " choice || true
      choice="${choice:-1}"
      case "$choice" in
        1)
          [[ "$DRY_RUN" -eq 1 ]] || mkdir -p "$path"
          printf '%s' "$path"
          return 0
          ;;
        2|b|B)
          break
          ;;
        3|!)
          open_interactive_shell "$(dirname "$path")"
          ;;
        4|q|Q)
          fail "User cancelled while selecting directory."
          exit "$EX_USAGE"
          ;;
        \?)
          ;;
        *)
          ui_blank
          ui_line "Invalid selection: '$choice'. Please enter a number from 1 through 4."
          ;;
      esac
    done
  done
}

prompt_file_optional() {
  # Optional file prompt. Stdout returns only the selected file path or blank.
  local label="$1" default="$2" path="" choice=""
  while true; do
    path="$(prompt_value "$label" "$default")"
    path="$(normalize_user_path "$path")"
    if [[ -z "$path" ]]; then
      printf ''
      return 0
    fi
    if [[ -f "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi

    while true; do
      cat >&2 <<EOF

==================================================================
Optional File Not Found

$label

The selected file does not exist:
  $path

Shell-escaped interpretation:
  $(printf '%q' "$path")

Path length:
  ${#path} characters

Select an action:

  1) Retry the file path [DEFAULT]
     Return to the file prompt.

  2) Open an interactive shell
     Download, move, or inspect files manually, then type 'exit' to resume.

  3) Skip this optional file
     Continue without setting this value.

  4) Abort the build
     Stop immediately.

Special commands:
  ?  Show this menu again
  !  Open an interactive shell
==================================================================
EOF
      read -r -p "Selection [1]: " choice || true
      choice="${choice:-1}"
      case "$choice" in
        1|r|R|b|B)
          break
          ;;
        2|!)
          open_interactive_shell "$(dirname "$path")"
          ;;
        3|s|S|skip|SKIP)
          printf ''
          return 0
          ;;
        4|q|Q)
          fail "User cancelled while selecting optional file."
          exit "$EX_USAGE"
          ;;
        \?)
          ;;
        *)
          ui_blank
          ui_line "Invalid selection: '$choice'. Please enter a number from 1 through 4."
          ;;
      esac
    done
  done
}


prompt_qcom_firmware_input_method() {
  # Numbered, self-describing Qualcomm firmware source selection.
  # Stdout returns one of: archive, url, prestaged, shell, skip.
  local choice=""
  while true; do
    cat >&2 <<EOF

==================================================================
Qualcomm Firmware Source

Qualcomm firmware handling is intentionally isolated.
The builder will NOT install firmware onto this Debian build host.

Choose how the builder should obtain firmware for the target image:

  1) Use a local Qualcomm Windows Graphics Driver ZIP/EXE [RECOMMENDED]
     Best choice for reproducible builds. You provide a downloaded archive;
     the builder extracts firmware inside a disposable container and copies
     only the resulting /lib/firmware tree into the target image staging area.

  2) Use a direct Qualcomm driver URL
     The builder downloads/extracts in the disposable container. This is less
     reproducible unless the downloaded archive is preserved in the release.

  3) Use a pre-staged firmware directory
     Use this when you already have a directory containing the target firmware
     tree to inject, typically matching /lib/firmware/... layout.

  4) Open an interactive shell before choosing
     Inspect/edit qcom-firmware-updater inputs or prepare files manually, then
     type 'exit' to return to this menu.

  5) Skip Qualcomm firmware extraction for this build
     The ISO will be built without this firmware staging step.

Special commands:
  ?  Show this menu again
  !  Open an interactive shell
==================================================================
EOF
    read -r -p "Selection [1]: " choice || true
    choice="${choice:-1}"
    case "$choice" in
      1) printf 'archive'; return 0 ;;
      2) printf 'url'; return 0 ;;
      3) printf 'prestaged'; return 0 ;;
      4|!) open_interactive_shell "$WORKDIR" ;;
      5|s|S|skip|SKIP) printf 'skip'; return 0 ;;
      q|Q) fail "User cancelled while selecting Qualcomm firmware source."; exit "$EX_USAGE" ;;
      \?) ;;
      *) ui_blank; ui_line "Invalid selection: '$choice'. Please enter a number from 1 through 5." ;;
    esac
  done
}

print_build_summary_prompt() {
  cat >&2 <<EOF

==================================================================
Build Summary

Profile:
  $PROFILE

Architecture:
  $ARCH

Work directory:
  $WORKDIR

Sources directory:
  $SOURCES_DIR

Artifact directory:
  $ARTIFACT_DIR

Root overlay directory:
  $ROOT_OVERLAY_DIR

Release prefix:
  $RELEASE_PREFIX

Planned release:
  $BUILD_ID

Qualcomm firmware updater:
  $( [[ "$ENABLE_QCOM_FW" -eq 1 ]] && echo "Enabled" || echo "Disabled" )

qcom device path:
  $QCOM_DEVICE_PATH

Output release directory:
  $CURRENT_RELEASE_DIR

Select an action:

  1) Begin build [DEFAULT]
  2) Open an interactive shell before build
  3) Abort build

Special commands:
  ?  Show this summary again
  !  Open an interactive shell
==================================================================
EOF
  local choice=""
  while true; do
    read -r -p "Selection [1]: " choice || true
    choice="${choice:-1}"
    case "$choice" in
      1) return 0 ;;
      2|!) open_interactive_shell "$WORKDIR" ;;
      3|q|Q) fail "User aborted before build start."; exit "$EX_USAGE" ;;
      \?) print_build_summary_prompt; return $? ;;
      *) ui_line "Invalid selection: '$choice'. Please enter 1, 2, or 3." ;;
    esac
  done
}

# -----------------------------
# CLI parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2 ;;
    --artifacts) ARTIFACT_DIR="$2"; shift 2 ;;
    --root-overlay) ROOT_OVERLAY_DIR="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --release-prefix) RELEASE_PREFIX="$2"; shift 2 ;;
    --qcom-device-path) QCOM_DEVICE_PATH="$2"; shift 2 ;;
    --qcom-driver-archive) QCOM_DRIVER_ARCHIVE="$2"; shift 2 ;;
    --qcom-driver-url) QCOM_DRIVER_URL="$2"; shift 2 ;;
    --qcom-prestaged-dir) QCOM_PRESTAGED_DIR="$2"; shift 2 ;;
    --no-qcom-fw) ENABLE_QCOM_FW=0; shift ;;
    --skip-pull) SKIP_PULL=1; shift ;;
    --allow-dirty-repos) ALLOW_DIRTY_REPOS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --cleanup-bad-prompt-dirs) CLEANUP_BAD_PROMPT_DIRS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1"; usage; exit "$EX_USAGE" ;;
  esac
done

WORKDIR="${WORKDIR/#\~/$HOME}"

cleanup_bad_prompt_dirs() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 3 -type d \( -name "*Custom kernel*" -o -name "*Default:*" -o -name "*Choose [*" -o -name "*Optional /root overlay*" \) -print -exec rm -rf {} +
}

if [[ "$CLEANUP_BAD_PROMPT_DIRS" -eq 1 ]]; then
  cleanup_bad_prompt_dirs "$WORKDIR"
fi

SOURCES_DIR="$WORKDIR/sources"
OUTPUT_DIR="$WORKDIR/output"
RELEASES_DIR="$OUTPUT_DIR/releases"
LOGS_DIR="$OUTPUT_DIR/logs"
CACHE_DIR="$WORKDIR/cache"
TMP_DIR="$WORKDIR/tmp"

mkdir -p "$LOGS_DIR" "$RELEASES_DIR" "$CACHE_DIR" "$TMP_DIR" 2>/dev/null || true
LOG_FILE="$LOGS_DIR/builder-$(date -u +%Y%m%dT%H%M%SZ).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vanilla-arm64-builder-$$.log"

trap 'fail "Build failed at line $LINENO. See log: $LOG_FILE"' ERR

# -----------------------------
# Intro and prompt phase
# -----------------------------
echo "${C_BOLD}$SCRIPT_NAME v$SCRIPT_VERSION${C_RESET}"
echo "Primary target profile default: $PROFILE"
echo "Primary host assumption: Debian 13 VM on Apple Silicon/M3"
echo "Log file: $LOG_FILE"

WORKDIR="$(prompt_value "Build work directory" "$WORKDIR")"
WORKDIR="${WORKDIR/#\~/$HOME}"
SOURCES_DIR="$WORKDIR/sources"
OUTPUT_DIR="$WORKDIR/output"
RELEASES_DIR="$OUTPUT_DIR/releases"
LOGS_DIR="$OUTPUT_DIR/logs"
CACHE_DIR="$WORKDIR/cache"
TMP_DIR="$WORKDIR/tmp"
mkdir -p "$SOURCES_DIR" "$RELEASES_DIR" "$LOGS_DIR" "$CACHE_DIR" "$TMP_DIR"

PROFILE="$(prompt_value "Target profile name" "$PROFILE")"
RELEASE_PREFIX="$(prompt_value "Release filename prefix" "$RELEASE_PREFIX")"

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$WORKDIR/artifacts/$PROFILE"
fi
ARTIFACT_DIR="$(prompt_existing_dir_or_create "Custom kernel/DTB artifact directory" "$ARTIFACT_DIR")"

if [[ -z "$ROOT_OVERLAY_DIR" ]]; then
  ROOT_OVERLAY_DIR="$WORKDIR/root-overlay/$PROFILE"
fi
ROOT_OVERLAY_DIR="$(prompt_existing_dir_or_create "Optional /root overlay directory" "$ROOT_OVERLAY_DIR")"

if prompt_yes_no "Extract Qualcomm firmware into a target-image staging area?" "$([[ "$ENABLE_QCOM_FW" -eq 1 ]] && echo y || echo n)"; then
  ENABLE_QCOM_FW=1
  QCOM_DEVICE_PATH="$(prompt_value "qcom-firmware-updater device path" "$QCOM_DEVICE_PATH")"

  # If the operator supplied a Qualcomm source by command-line option, keep it.
  # Otherwise use a numbered menu rather than prose/bullets so the next action is explicit.
  if [[ -z "$QCOM_PRESTAGED_DIR" && -z "$QCOM_DRIVER_ARCHIVE" && -z "$QCOM_DRIVER_URL" ]]; then
    qcom_method="$(prompt_qcom_firmware_input_method)"
    case "$qcom_method" in
      archive)
        QCOM_DRIVER_ARCHIVE="$(prompt_file_optional "Local Qualcomm Windows Graphics Driver ZIP/EXE" "$WORKDIR/downloads/qualcomm-windows-graphics-driver.zip")"
        if [[ -z "$QCOM_DRIVER_ARCHIVE" ]]; then
          warn "No local Qualcomm driver archive selected; Qualcomm firmware extraction will be skipped."
          ENABLE_QCOM_FW=0
        fi
        ;;
      url)
        QCOM_DRIVER_URL="$(prompt_value "Direct Qualcomm Windows Graphics Driver URL" "")"
        if [[ -z "$QCOM_DRIVER_URL" ]]; then
          warn "No Qualcomm driver URL supplied; Qualcomm firmware extraction will be skipped."
          ENABLE_QCOM_FW=0
        fi
        ;;
      prestaged)
        QCOM_PRESTAGED_DIR="$(prompt_existing_dir_or_create "Pre-staged Qualcomm firmware directory" "$WORKDIR/prestaged-firmware/$PROFILE")"
        if [[ -z "$(find "$QCOM_PRESTAGED_DIR" -type f 2>/dev/null | head -1 || true)" ]]; then
          warn "Pre-staged Qualcomm firmware directory is empty; Qualcomm firmware extraction will be skipped."
          ENABLE_QCOM_FW=0
          QCOM_PRESTAGED_DIR=""
        fi
        ;;
      skip)
        ENABLE_QCOM_FW=0
        ;;
    esac
  else
    cat >&2 <<EOF

==================================================================
Qualcomm Firmware Source

A Qualcomm firmware source was supplied by command-line option or environment.
The builder will use the supplied value and will not prompt for another source.

Configured source summary:
  Local archive:        ${QCOM_DRIVER_ARCHIVE:-<none>}
  Direct URL:           ${QCOM_DRIVER_URL:-<none>}
  Pre-staged directory: ${QCOM_PRESTAGED_DIR:-<none>}
==================================================================
EOF
  fi
else
  ENABLE_QCOM_FW=0
fi

if [[ "$ENABLE_QCOM_FW" -eq 1 ]]; then
  if prompt_yes_no "Open a temporary shell before Qualcomm extraction so you can inspect/edit updater inputs?" "n"; then
    open_interactive_shell "$WORKDIR"
  fi
fi

BUILD_DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_NUMBER_FILE="$WORKDIR/.build-number"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
  last_num="$(tr -dc '0-9' < "$BUILD_NUMBER_FILE" || true)"
else
  last_num="0"
fi
next_num=$((10#$last_num + 1))
BUILD_NUMBER="$(printf 'r%04d' "$next_num")"
BUILD_ID="$(date -u +%Y%m%d)-$BUILD_NUMBER-$PROFILE"
CURRENT_RELEASE_DIR="$RELEASES_DIR/$BUILD_ID"

log "Planned release: $BUILD_ID"
log "Workdir: $WORKDIR"
log "Artifacts: $ARTIFACT_DIR"
log "Root overlay: $ROOT_OVERLAY_DIR"

print_build_summary_prompt

if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "Dry-run mode is enabled. No files should be modified beyond initial log/workdir creation."
fi

# -----------------------------
# Dependency validation and guided remediation
# -----------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || missing_cmds+=("$1")
}

refresh_container_engine() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  else
    CONTAINER_ENGINE=""
  fi
}

apt_install_common_dependencies() {
  # Debian 13 dependency path. This intentionally installs only host build tools.
  # Qualcomm extraction tools remain isolated inside disposable containers.
  local apt_bin=""
  if command -v apt >/dev/null 2>&1; then
    apt_bin="apt"
  else
    fail "apt was not found. This dependency installer is written for Debian/Ubuntu-style hosts."
    return 1
  fi

  local sudo_prefix=()
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_prefix=(sudo)
    else
      fail "This user is not root and sudo is unavailable; cannot install packages automatically."
      return 1
    fi
  fi

  cat >&2 <<EOF

==================================================================
APT Dependency Installation

The builder will install missing Debian 13 host-side packages using apt.
This does not install target firmware onto the host.

Packages requested:
  git curl ca-certificates gawk coreutils findutils tar gzip unzip
  python3 podman docker.io xorriso genisoimage jq

Purpose:
  • git/curl/python3/coreutils: repository and manifest handling
  • podman/docker.io: disposable containers and image builds
  • xorriso/genisoimage: ISO inspection and verification
  • jq: useful release/debug inspection; not required for manifest generation

Select an action:

  1) Install/refresh these packages with apt [DEFAULT]
  2) Open an interactive shell before apt install
  3) Skip apt installation and return to dependency check
  4) Abort build
==================================================================
EOF
  local choice=""
  read -r -p "Selection [1]: " choice || true
  choice="${choice:-1}"
  case "$choice" in
    1)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Dry-run: would run apt update and apt install."
        return 0
      fi
      "${sudo_prefix[@]}" "$apt_bin" update
      "${sudo_prefix[@]}" "$apt_bin" install -y \
        git curl ca-certificates gawk coreutils findutils tar gzip unzip \
        python3 podman docker.io xorriso genisoimage jq
      ;;
    2|!)
      open_interactive_shell "$WORKDIR"
      ;;
    3)
      return 0
      ;;
    4|q|Q)
      fail "User aborted during apt dependency installation."
      exit "$EX_DEPENDENCY"
      ;;
    *)
      warn "Invalid selection; returning to dependency check."
      ;;
  esac
}

install_vib_from_github_release() {
  # Vib is distributed as a release binary by Vanilla OS. The resolver below
  # avoids hard-coding a release asset name: it queries the latest release,
  # selects a Linux asset matching the build host architecture, then installs
  # the contained/direct vib executable into PATH.
  # Sources checked while creating this revision:
  #   - Vanilla OS docs: Vib is a single downloadable binary.
  #   - Vanilla-OS/Vib README: build command is `vib build recipe.yml`.
  local install_dir tmpdir api_url asset_url asset_name machine arch_regex sudo_prefix=()
  api_url="https://api.github.com/repos/Vanilla-OS/Vib/releases/latest"
  tmpdir="$TMP_DIR/vib-install-$$"
  mkdir -p "$tmpdir"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install_dir="/usr/local/bin"
  else
    install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
  fi

  machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) arch_regex='(arm64|aarch64)' ;;
    x86_64|amd64) arch_regex='(amd64|x86_64)' ;;
    *) arch_regex="$machine" ;;
  esac

  cat >&2 <<EOF

==================================================================
Vib Installation

Vib is required because the Vanilla image repositories use:
  vib build recipe.yml

The builder can download the latest Vib release from GitHub and install it.
Install destination:
  $install_dir/vib

Host architecture detected:
  $machine

Select an action:

  1) Download and install latest Vib release [DEFAULT]
  2) Open an interactive shell to install Vib manually
  3) Re-check PATH for an already-installed vib
  4) Abort build
==================================================================
EOF
  local choice=""
  read -r -p "Selection [1]: " choice || true
  choice="${choice:-1}"
  case "$choice" in
    1)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Dry-run: would download and install Vib from GitHub releases."
        return 0
      fi
      log "Querying latest Vib release metadata from GitHub."
      curl -fsSL "$api_url" -o "$tmpdir/release.json"
      asset_url="$(python3 - "$tmpdir/release.json" "$arch_regex" <<'PY'
import json, re, sys
path, arch_regex = sys.argv[1], sys.argv[2]
data = json.load(open(path, 'r', encoding='utf-8'))
assets = data.get('assets', [])
linux = []
for a in assets:
    name = a.get('name','')
    url = a.get('browser_download_url','')
    if not url:
        continue
    n = name.lower()
    if 'linux' in n and re.search(arch_regex, n, re.I):
        linux.append((name, url))
for name, url in linux:
    if re.search(r'vib', name, re.I):
        print(url)
        sys.exit(0)
if linux:
    print(linux[0][1])
    sys.exit(0)
for a in assets:
    name = a.get('name','')
    url = a.get('browser_download_url','')
    if url and re.search(arch_regex, name, re.I):
        print(url)
        sys.exit(0)
print('')
PY
)"
      if [[ -z "$asset_url" ]]; then
        fail "Could not identify a suitable Vib release asset for architecture regex: $arch_regex"
        echo "Open https://github.com/Vanilla-OS/Vib/releases and install vib manually, then rerun." | tee -a "$LOG_FILE"
        return 1
      fi
      asset_name="${asset_url##*/}"
      log "Downloading Vib asset: $asset_name"
      curl -fL "$asset_url" -o "$tmpdir/$asset_name"

      case "$asset_name" in
        *.tar.gz|*.tgz)
          tar -xzf "$tmpdir/$asset_name" -C "$tmpdir"
          ;;
        *.zip)
          unzip -q "$tmpdir/$asset_name" -d "$tmpdir"
          ;;
        *)
          cp "$tmpdir/$asset_name" "$tmpdir/vib"
          ;;
      esac

      local vib_candidate=""
      vib_candidate="$(find "$tmpdir" \( -type f -name 'vib' -o -name 'Vib' \) | head -1 || true)"
      if [[ -z "$vib_candidate" ]]; then
        vib_candidate="$(find "$tmpdir" -type f -iname '*vib*' | head -1 || true)"
      fi
      if [[ -z "$vib_candidate" ]]; then
        fail "Downloaded Vib asset did not contain an identifiable vib executable."
        open_interactive_shell "$tmpdir"
        return 1
      fi
      chmod +x "$vib_candidate"
      if [[ ! -w "$install_dir" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
          sudo_prefix=(sudo)
        else
          fail "Install directory is not writable and sudo is unavailable: $install_dir"
          return 1
        fi
      fi
      "${sudo_prefix[@]}" install -m 0755 "$vib_candidate" "$install_dir/vib"
      hash -r || true
      if ! command -v vib >/dev/null 2>&1; then
        warn "Vib was installed to $install_dir but is not currently in PATH."
        warn "Add this to PATH or rerun with PATH=$install_dir:\$PATH"
        return 1
      fi
      ok "Vib installed: $(command -v vib)"
      ;;
    2|!)
      open_interactive_shell "$WORKDIR"
      ;;
    3)
      return 0
      ;;
    4|q|Q)
      fail "User aborted during Vib installation."
      exit "$EX_DEPENDENCY"
      ;;
    *)
      warn "Invalid selection; returning to dependency check."
      ;;
  esac
}

check_host_dependencies_once() {
  missing_cmds=()
  for c in git curl sed awk find sort sha256sum date tee stat cp mkdir rm chmod grep tar gzip python3; do
    need_cmd "$c"
  done
  refresh_container_engine
  if [[ -z "$CONTAINER_ENGINE" ]]; then
    missing_cmds+=("podman-or-docker")
  fi
  if ! command -v vib >/dev/null 2>&1; then
    missing_cmds+=("vib")
  fi
  if ! command -v isoinfo >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
    missing_cmds+=("isoinfo-or-xorriso")
  fi
}

remediate_dependencies() {
  local choice=""
  while true; do
    check_host_dependencies_once
    if [[ ${#missing_cmds[@]} -eq 0 ]]; then
      ok "Dependencies available. Container engine: $CONTAINER_ENGINE"
      return 0
    fi

    fail "Missing required tools: ${missing_cmds[*]}"
    cat >&2 <<EOF

==================================================================
Dependency Remediation

The builder cannot continue until required host tools are available.

Missing:
  ${missing_cmds[*]}

Recommended action for Debian 13:
  1) Install apt-managed tools, then install/resolve Vib [DEFAULT]

Other actions:
  2) Install apt-managed tools only
  3) Install/resolve Vib only
  4) Open an interactive shell to fix dependencies manually
  5) Re-check dependencies
  6) Abort build

Notes:
  • xorriso or genisoimage supplies ISO inspection capability.
  • Vib is not treated as an apt package here; it is resolved from the
    Vanilla-OS/Vib GitHub release path or by manual shell install.
  • Qualcomm extraction dependencies are installed inside disposable containers,
    not on this build host.
==================================================================
EOF
    read -r -p "Selection [1]: " choice || true
    choice="${choice:-1}"
    case "$choice" in
      1)
        apt_install_common_dependencies || true
        if ! command -v vib >/dev/null 2>&1; then
          install_vib_from_github_release || true
        fi
        ;;
      2)
        apt_install_common_dependencies || true
        ;;
      3)
        install_vib_from_github_release || true
        ;;
      4|!)
        open_interactive_shell "$WORKDIR"
        ;;
      5)
        ;;
      6|q|Q)
        fail "Dependency remediation aborted by user."
        exit "$EX_DEPENDENCY"
        ;;
      \?)
        ;;
      *)
        warn "Invalid selection: '$choice'. Please enter a number from 1 through 6."
        ;;
    esac
  done
}

log "Checking host dependencies."
remediate_dependencies

# -----------------------------
# Artifact validation
# -----------------------------
log "Validating local kernel and DTB artifacts."
mapfile -t DEB_FILES < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.deb' | sort)
mapfile -t DTB_FILES < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.dtb' | sort)

if [[ ${#DEB_FILES[@]} -lt 1 ]]; then
  fail "No .deb files found in artifact directory: $ARTIFACT_DIR"
  exit "$EX_ARTIFACT"
fi
if [[ ${#DTB_FILES[@]} -lt 1 ]]; then
  fail "No .dtb files found in artifact directory: $ARTIFACT_DIR"
  exit "$EX_ARTIFACT"
fi
ok "Found ${#DEB_FILES[@]} deb package(s) and ${#DTB_FILES[@]} DTB file(s)."

for f in "${DEB_FILES[@]}" "${DTB_FILES[@]}"; do
  if [[ ! -s "$f" ]]; then
    fail "Artifact exists but is empty: $f"
    exit "$EX_ARTIFACT"
  fi
done

if [[ -n "$QCOM_DRIVER_ARCHIVE" && ! -s "$QCOM_DRIVER_ARCHIVE" ]]; then
  fail "Qualcomm driver archive is missing or empty: $QCOM_DRIVER_ARCHIVE"
  exit "$EX_ARTIFACT"
fi

# -----------------------------
# Prepare release directory and archive local inputs
# -----------------------------
log "Preparing release workspace."
if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$CURRENT_RELEASE_DIR/input-artifacts" "$CURRENT_RELEASE_DIR/root-overlay" "$CURRENT_RELEASE_DIR/manifests" "$CURRENT_RELEASE_DIR/logs"
  cp -a "${DEB_FILES[@]}" "${DTB_FILES[@]}" "$CURRENT_RELEASE_DIR/input-artifacts/"
  if [[ -n "$QCOM_DRIVER_ARCHIVE" ]]; then
    cp -a "$QCOM_DRIVER_ARCHIVE" "$CURRENT_RELEASE_DIR/input-artifacts/"
  fi
  if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
    cp -a "$ROOT_OVERLAY_DIR"/. "$CURRENT_RELEASE_DIR/root-overlay/" 2>/dev/null || true
  fi
fi

# -----------------------------
# Git clone/pull helpers
# -----------------------------
repo_path() { printf '%s/%s' "$SOURCES_DIR" "$1"; }

ensure_repo() {
  local name="$1" url="$2" branch="$3" path
  path="$(repo_path "$name")"
  if [[ -d "$path/.git" ]]; then
    log "Repository exists: $name"
    if [[ "$ALLOW_DIRTY_REPOS" -eq 0 ]]; then
      if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
        fail "Repository has local modifications: $path"
        echo "Use --allow-dirty-repos if you intentionally want to keep local modifications." | tee -a "$LOG_FILE"
        exit "$EX_GIT"
      fi
    fi
    if [[ "$SKIP_PULL" -eq 0 ]]; then
      run git -C "$path" fetch --all --prune || exit "$EX_GIT"
      run git -C "$path" checkout "$branch" || exit "$EX_GIT"
      run git -C "$path" pull --ff-only || exit "$EX_GIT"
    else
      warn "Skipping git pull for $name."
    fi
  else
    log "Cloning repository: $name"
    run git clone --branch "$branch" "$url" "$path" || exit "$EX_GIT"
  fi
}

ensure_repo "pico-image" "$PICO_REPO_URL" "$PICO_REPO_BRANCH"
ensure_repo "core-image" "$CORE_REPO_URL" "$CORE_REPO_BRANCH"
ensure_repo "desktop-image" "$DESKTOP_REPO_URL" "$DESKTOP_REPO_BRANCH"
ensure_repo "live-iso" "$LIVE_REPO_URL" "$LIVE_REPO_BRANCH"
if [[ "$ENABLE_QCOM_FW" -eq 1 ]]; then
  ensure_repo "qcom-firmware-updater" "$QCOM_FW_REPO_URL" "$QCOM_FW_REPO_BRANCH"
fi


# -----------------------------
# Qualcomm firmware isolated extraction
# -----------------------------
extract_qcom_firmware_isolated() {
  # qcom-firmware-updater is useful, but its normal behavior is target-host
  # installation into /lib/firmware. That must never be allowed to modify the
  # Debian build VM. This function either copies a pre-staged firmware tree, or
  # runs the updater inside a disposable container and copies only the resulting
  # /lib/firmware payload out to a builder-controlled staging directory.
  QCOM_STAGED_FIRMWARE_DIR="$WORKDIR/staged-firmware/qcom/$PROFILE"

  [[ "$ENABLE_QCOM_FW" -eq 1 ]] || return 0

  log "Preparing isolated Qualcomm firmware staging area."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  rm -rf "$QCOM_STAGED_FIRMWARE_DIR"
  mkdir -p "$QCOM_STAGED_FIRMWARE_DIR"

  if [[ -n "$QCOM_PRESTAGED_DIR" ]]; then
    log "Copying pre-staged Qualcomm firmware from: $QCOM_PRESTAGED_DIR"
    cp -a "$QCOM_PRESTAGED_DIR"/. "$QCOM_STAGED_FIRMWARE_DIR"/ 2>/dev/null || true
  elif [[ -n "$QCOM_DRIVER_ARCHIVE" || -n "$QCOM_DRIVER_URL" ]]; then
    local cname archive_base run_args image
    cname="qcom-fw-extract-${PROFILE}-$$"
    image="debian:13"
    run_args=""

    if [[ -n "$QCOM_DRIVER_ARCHIVE" ]]; then
      archive_base="$(basename "$QCOM_DRIVER_ARCHIVE")"
      run_args="/input/$archive_base"
    else
      run_args="--url '$QCOM_DRIVER_URL'"
    fi

    log "Running qcom-firmware-updater inside disposable container: $cname"
    log "No firmware will be installed onto the build host. Only container /lib/firmware output will be copied out."

    # Remove any stale container with the same generated name.
    "$CONTAINER_ENGINE" rm -f "$cname" >/dev/null 2>&1 || true

    if [[ -n "$QCOM_DRIVER_ARCHIVE" ]]; then
      "$CONTAINER_ENGINE" run --name "$cname" \
        -v "$(repo_path qcom-firmware-updater):/updater:ro" \
        -v "$QCOM_DRIVER_ARCHIVE:/input/$archive_base:ro" \
        "$image" /bin/bash -lc "set -eux; apt update; apt install -y ca-certificates curl unzip 7zip msitools zstd bash; cd /updater; chmod +x ./qcom-firmware-updater.sh || true; ./qcom-firmware-updater.sh --device-path '$QCOM_DEVICE_PATH' $run_args" \
        2>&1 | tee -a "$LOG_FILE"
    else
      "$CONTAINER_ENGINE" run --name "$cname" \
        -v "$(repo_path qcom-firmware-updater):/updater:ro" \
        "$image" /bin/bash -lc "set -eux; apt update; apt install -y ca-certificates curl unzip 7zip msitools zstd bash; cd /updater; chmod +x ./qcom-firmware-updater.sh || true; ./qcom-firmware-updater.sh --device-path '$QCOM_DEVICE_PATH' $run_args" \
        2>&1 | tee -a "$LOG_FILE"
    fi

    mkdir -p "$QCOM_STAGED_FIRMWARE_DIR"
    "$CONTAINER_ENGINE" cp "$cname:/lib/firmware/." "$QCOM_STAGED_FIRMWARE_DIR"/ 2>&1 | tee -a "$LOG_FILE" || {
      fail "Could not copy /lib/firmware from disposable Qualcomm extraction container."
      "$CONTAINER_ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
      exit "$EX_ARTIFACT"
    }
    "$CONTAINER_ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
  else
    warn "Qualcomm firmware enabled, but no pre-staged directory, local archive, or URL was supplied. Skipping firmware extraction."
    return 0
  fi

  if [[ -z "$(find "$QCOM_STAGED_FIRMWARE_DIR" -type f 2>/dev/null | head -1 || true)" ]]; then
    fail "Qualcomm firmware staging produced no files: $QCOM_STAGED_FIRMWARE_DIR"
    exit "$EX_ARTIFACT"
  fi

  ok "Qualcomm firmware staged at: $QCOM_STAGED_FIRMWARE_DIR"
}

# -----------------------------
# Source tree modification helpers
# -----------------------------
copy_artifacts_to_container_includes() {
  local repo="$1" include_dir staging_dir root_dir
  include_dir="$(repo_path "$repo")/includes.container"
  staging_dir="$include_dir/opt/constructive-build/input-artifacts"
  root_dir="$include_dir/root"
  log "Staging artifacts into $repo container includes."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$staging_dir" "$root_dir"
  rm -rf "$staging_dir"/*
  cp -a "${DEB_FILES[@]}" "${DTB_FILES[@]}" "$staging_dir/"
  if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
    cp -a "$ROOT_OVERLAY_DIR"/. "$root_dir/" 2>/dev/null || true
  fi
  if [[ "$ENABLE_QCOM_FW" -eq 1 && -n "$QCOM_STAGED_FIRMWARE_DIR" && -d "$QCOM_STAGED_FIRMWARE_DIR" ]]; then
    mkdir -p "$include_dir/lib/firmware"
    cp -a "$QCOM_STAGED_FIRMWARE_DIR"/. "$include_dir/lib/firmware/"
  fi
}

copy_artifacts_to_live_iso() {
  local live include_chroot include_binary chroot_staging binary_dtb root_dir
  live="$(repo_path live-iso)"
  include_chroot="$live/etc/config/includes.chroot"
  include_binary="$live/etc/config/includes.binary"
  chroot_staging="$include_chroot/opt/constructive-build/input-artifacts"
  binary_dtb="$include_binary/boot/dtbs"
  root_dir="$include_chroot/root"
  log "Staging artifacts into live ISO chroot and binary includes."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$chroot_staging" "$binary_dtb" "$root_dir"
  rm -rf "$chroot_staging"/* "$binary_dtb"/*
  cp -a "${DEB_FILES[@]}" "${DTB_FILES[@]}" "$chroot_staging/"
  cp -a "${DTB_FILES[@]}" "$binary_dtb/"
  if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
    cp -a "$ROOT_OVERLAY_DIR"/. "$root_dir/" 2>/dev/null || true
  fi
  if [[ "$ENABLE_QCOM_FW" -eq 1 && -n "$QCOM_STAGED_FIRMWARE_DIR" && -d "$QCOM_STAGED_FIRMWARE_DIR" ]]; then
    mkdir -p "$include_chroot/lib/firmware"
    cp -a "$QCOM_STAGED_FIRMWARE_DIR"/. "$include_chroot/lib/firmware/"
  fi
}

write_core_module_script() {
  local repo="$1" module_path
  module_path="$(repo_path "$repo")/modules/99-constructive-custom-arm64.yml"
  log "Writing generated VIB module for $repo."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$module_path")"
  cat > "$module_path" <<MODULE
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# This module installs custom ARM64 kernel/headers/modules .deb files,
# installs board DTBs, uses already staged firmware includes, and refreshes
# initramfs inside the image at build time.
name: constructive-custom-arm64
type: shell
commands:
  - mkdir -p /boot/dtbs /usr/lib/linux-image-custom /opt/constructive-build
  - if ls /opt/constructive-build/input-artifacts/*.deb >/dev/null 2>&1; then dpkg -i /opt/constructive-build/input-artifacts/*.deb || apt -f install -y; fi
  - if ls /opt/constructive-build/input-artifacts/*.dtb >/dev/null 2>&1; then cp -a /opt/constructive-build/input-artifacts/*.dtb /boot/dtbs/; cp -a /opt/constructive-build/input-artifacts/*.dtb /usr/lib/linux-image-custom/; fi
MODULE
  cat >> "$module_path" <<'MODULE'
  - update-initramfs -c -k all || update-initramfs -u -k all || true
  - update-grub || true
MODULE
}

append_recipe_include() {
  local repo="$1" recipe marker include_line
  recipe="$(repo_path "$repo")/recipe.yml"
  marker="# constructive-custom-arm64 module include"
  include_line="  - modules/99-constructive-custom-arm64.yml"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if [[ ! -f "$recipe" ]]; then
    warn "No recipe.yml found in $repo; generated module will not be referenced automatically."
    return 0
  fi
  if grep -q "99-constructive-custom-arm64.yml" "$recipe"; then
    ok "$repo recipe already references generated module."
    return 0
  fi
  cat >> "$recipe" <<RECIPE_APPEND

$marker
$include_line
RECIPE_APPEND
  warn "Appended generated module reference to $repo/recipe.yml. Review syntax if upstream recipe format changed."
}

write_live_hook() {
  local hook
  hook="$(repo_path live-iso)/etc/config/hooks/live/010-constructive-custom-arm64.chroot"
  log "Writing live ISO chroot hook."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<HOOK
#!/bin/sh
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Installs custom kernel packages and DTBs in live chroot; Qualcomm firmware is copied by live-build includes.
set -eu
mkdir -p /boot/dtbs /usr/lib/linux-image-custom
if ls /opt/constructive-build/input-artifacts/*.deb >/dev/null 2>&1; then
  dpkg -i /opt/constructive-build/input-artifacts/*.deb || apt -f install -y
fi
if ls /opt/constructive-build/input-artifacts/*.dtb >/dev/null 2>&1; then
  cp -a /opt/constructive-build/input-artifacts/*.dtb /boot/dtbs/
  cp -a /opt/constructive-build/input-artifacts/*.dtb /usr/lib/linux-image-custom/
fi
HOOK
  cat >> "$hook" <<'HOOK'
update-initramfs -c -k all || update-initramfs -u -k all || true
update-grub || true
HOOK
  chmod +x "$hook"
}

write_grub_dtb_fragment() {
  # Vanilla live-iso GRUB layout may vary. This writes a fragment and a note.
  # It intentionally does not destructively rewrite upstream GRUB files.
  local live fragment dtb_name
  live="$(repo_path live-iso)"
  dtb_name="$(basename "${DTB_FILES[0]}")"
  fragment="$live/etc/config/includes.binary/boot/grub/constructive-custom-dtb.cfg"
  log "Writing non-destructive GRUB DTB fragment for ISO review."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$fragment")"
  cat > "$fragment" <<GRUB
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION
# Review and merge into the active live ISO GRUB menu if upstream build files do not include this fragment.
menuentry "Vanilla OS ARM64 - $PROFILE custom DTB" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
    devicetree /boot/dtbs/$dtb_name
}
GRUB
  warn "Generated GRUB DTB fragment: $fragment"
  warn "Confirm upstream live-iso GRUB config includes or imports this fragment. If not, manually merge devicetree /boot/dtbs/$dtb_name into the active menuentry."
}

write_terraform_conf() {
  local conf
  conf="$(repo_path live-iso)/etc/terraform.conf"
  log "Ensuring live ISO terraform.conf targets arm64."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if [[ ! -f "$conf" ]]; then
    fail "Missing terraform.conf at $conf"
    exit "$EX_ISO"
  fi
  python3 - "$conf" <<PY
from pathlib import Path
p=Path('$conf')
text=p.read_text()
values={
 'ARCH':'$ARCH',
 'BASECODENAME':'$BASECODENAME',
 'CODENAME':'$CODENAME',
 'VERSION':'$VERSION',
 'CHANNEL':'$CHANNEL',
 'PACKAGE_LISTS_SUFFIX':'$PACKAGE_LISTS_SUFFIX',
}
for k,v in values.items():
    import re
    pattern=re.compile(rf'^{k}=.*$', re.M)
    line=f'{k}="{v}"'
    if pattern.search(text):
        text=pattern.sub(line,text)
    else:
        text += '\n' + line + '\n'
p.write_text(text)
PY
}

# -----------------------------
# Generate preliminary manifests embedded into ISO before build
# -----------------------------
json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n"))[1:-1])'; }
sha_file() { sha256sum "$1" | awk '{print $1}'; }

write_prebuild_manifest() {
  local dest_live dest_core dest_desktop manifest
  manifest="$TMP_DIR/BUILD-INFO.json"
  log "Writing pre-build manifest for embedding."
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  {
    echo "{"
    echo "  \"script_name\": \"$SCRIPT_NAME\","
    echo "  \"script_version\": \"$SCRIPT_VERSION\","
    echo "  \"build_id\": \"$BUILD_ID\","
    echo "  \"build_number\": \"$BUILD_NUMBER\","
    echo "  \"build_date_utc\": \"$BUILD_DATE_UTC\","
    echo "  \"profile\": \"$PROFILE\","
    echo "  \"architecture\": \"$ARCH\","
    echo "  \"release_prefix\": \"$RELEASE_PREFIX\","
    echo "  \"qcom_firmware_enabled\": $([[ "$ENABLE_QCOM_FW" -eq 1 ]] && echo true || echo false),"
    echo "  \"qcom_device_path\": \"$QCOM_DEVICE_PATH\","
    echo "  \"local_artifacts\": ["
    local first=1 f base sha size
    for f in "${DEB_FILES[@]}" "${DTB_FILES[@]}"; do
      base="$(basename "$f")"; sha="$(sha_file "$f")"; size="$(stat -c '%s' "$f")"
      [[ $first -eq 0 ]] && echo ","
      printf '    {"filename":"%s","source_path":"%s","sha256":"%s","size_bytes":%s}' "$(printf '%s' "$base" | json_escape)" "$(printf '%s' "$f" | json_escape)" "$sha" "$size"
      first=0
    done
    echo
    echo "  ],"
    echo "  \"repositories\": {"
    local comma=""
    for r in pico-image core-image desktop-image live-iso qcom-firmware-updater; do
      [[ "$r" == "qcom-firmware-updater" && "$ENABLE_QCOM_FW" -ne 1 ]] && continue
      if [[ -d "$(repo_path "$r")/.git" ]]; then
        printf '%s    "%s": {"commit":"%s","branch":"%s","url":"%s"}' "$comma" "$r" "$(git -C "$(repo_path "$r")" rev-parse HEAD)" "$(git -C "$(repo_path "$r")" rev-parse --abbrev-ref HEAD)" "$(git -C "$(repo_path "$r")" remote get-url origin)"
        comma=",\n"
      fi
    done
    echo
    echo "  }"
    echo "}"
  } > "$manifest"

  cat > "$TMP_DIR/BUILD-INFO.md" <<MD
# $RELEASE_PREFIX $BUILD_ID

- Builder: $SCRIPT_NAME v$SCRIPT_VERSION
- Date UTC: $BUILD_DATE_UTC
- Profile: $PROFILE
- Architecture: $ARCH
- Qualcomm firmware updater enabled: $ENABLE_QCOM_FW
- Qualcomm device path: $QCOM_DEVICE_PATH

This file was embedded before ISO creation. The release directory contains the final manifest with ISO checksum.
MD

  for dest in \
    "$(repo_path live-iso)/etc/config/includes.binary" \
    "$(repo_path live-iso)/etc/config/includes.chroot" \
    "$(repo_path core-image)/includes.container" \
    "$(repo_path desktop-image)/includes.container"; do
    mkdir -p "$dest"
    cp -a "$TMP_DIR/BUILD-INFO.json" "$TMP_DIR/BUILD-INFO.md" "$dest/"
  done
}

# -----------------------------
# Apply source modifications
# -----------------------------
extract_qcom_firmware_isolated
if [[ "$ENABLE_QCOM_FW" -eq 1 && -n "$QCOM_STAGED_FIRMWARE_DIR" && -d "$QCOM_STAGED_FIRMWARE_DIR" && "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$CURRENT_RELEASE_DIR/input-artifacts/qcom-firmware-staged"
  cp -a "$QCOM_STAGED_FIRMWARE_DIR"/. "$CURRENT_RELEASE_DIR/input-artifacts/qcom-firmware-staged/"
fi

copy_artifacts_to_container_includes "core-image"
copy_artifacts_to_container_includes "desktop-image"
copy_artifacts_to_live_iso
write_core_module_script "core-image"
write_core_module_script "desktop-image"
append_recipe_include "core-image"
append_recipe_include "desktop-image"
write_live_hook
write_grub_dtb_fragment
write_terraform_conf
write_prebuild_manifest

# -----------------------------
# Build phase
# -----------------------------
build_container_image() {
  local repo="$1" tag="$2" path
  path="$(repo_path "$repo")"
  log "Building VIB image content for $repo."
  if [[ ! -f "$path/recipe.yml" ]]; then
    fail "Missing recipe.yml in $path"
    exit "$EX_BUILD"
  fi
  ( cd "$path" && run vib build recipe.yml ) || exit "$EX_BUILD"
  log "Building container image tag $tag from $repo."
  ( cd "$path" && run "$CONTAINER_ENGINE" image build -t "$tag" . ) || exit "$EX_BUILD"
}

build_iso() {
  local live
  live="$(repo_path live-iso)"
  log "Building live ISO."
  if [[ ! -f "$live/build.sh" ]]; then
    fail "Missing live-iso build.sh at $live/build.sh"
    exit "$EX_ISO"
  fi
  if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    ( cd "$live" && run docker run --privileged -i -v /proc:/proc -v "$live":/working_dir -w /working_dir ghcr.io/vanilla-os/pico:main /bin/bash -s etc/terraform.conf < build.sh ) || exit "$EX_ISO"
  else
    ( cd "$live" && run podman run --privileged -i -v /proc:/proc -v "$live":/working_dir:Z -w /working_dir ghcr.io/vanilla-os/pico:main /bin/bash -s etc/terraform.conf < build.sh ) || exit "$EX_ISO"
  fi
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  ok "Dry-run plan completed. Build would now run core-image, desktop-image, and live-iso."
  echo "Resolved execution command for real build:" | tee -a "$LOG_FILE"
  echo "  $0 --workdir '$WORKDIR' --profile '$PROFILE' --artifacts '$ARTIFACT_DIR' --root-overlay '$ROOT_OVERLAY_DIR' --release-prefix '$RELEASE_PREFIX' --qcom-device-path '$QCOM_DEVICE_PATH'" | tee -a "$LOG_FILE"
  exit 0
fi

build_container_image "core-image" "ghcr.io/vanilla-os/core:$BUILD_ID"
build_container_image "desktop-image" "ghcr.io/vanilla-os/desktop:$BUILD_ID"
build_iso

# -----------------------------
# Locate, stamp, copy, and verify ISO
# -----------------------------
log "Locating generated ISO."
mapfile -t ISO_CANDIDATES < <(find "$(repo_path live-iso)/builds" -type f \( -name '*.iso' -o -name '*.ISO' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')
if [[ ${#ISO_CANDIDATES[@]} -lt 1 ]]; then
  fail "No ISO found under live-iso/builds."
  exit "$EX_ISO"
fi
SOURCE_ISO="${ISO_CANDIDATES[0]}"
FINAL_ISO_NAME="$RELEASE_PREFIX-$ARCH-$BUILD_ID.iso"
FINAL_ISO="$CURRENT_RELEASE_DIR/$FINAL_ISO_NAME"
mkdir -p "$CURRENT_RELEASE_DIR"
cp -a "$SOURCE_ISO" "$FINAL_ISO"
ok "Stamped ISO: $FINAL_ISO"

sha256sum "$FINAL_ISO" > "$CURRENT_RELEASE_DIR/$FINAL_ISO_NAME.sha256"
sha256sum "$CURRENT_RELEASE_DIR/input-artifacts"/* > "$CURRENT_RELEASE_DIR/input-artifacts.sha256" 2>/dev/null || true
cp -a "$LOG_FILE" "$CURRENT_RELEASE_DIR/logs/"

log "Verifying ISO contents."
VERIFY_FILE_LIST="$CURRENT_RELEASE_DIR/iso-file-list.txt"
if command -v isoinfo >/dev/null 2>&1; then
  isoinfo -i "$FINAL_ISO" -R -f > "$VERIFY_FILE_LIST" || true
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -indev "$FINAL_ISO" -find / -type f > "$VERIFY_FILE_LIST" 2>/dev/null || true
fi

if [[ ! -s "$VERIFY_FILE_LIST" ]]; then
  fail "Could not list ISO contents."
  exit "$EX_VERIFY"
fi

grep -Ei 'EFI|BOOTAA64|grubaa64' "$VERIFY_FILE_LIST" >/dev/null || { fail "EFI ARM64 boot files not detected in ISO listing."; exit "$EX_VERIFY"; }
grep -Ei '\.dtb$' "$VERIFY_FILE_LIST" >/dev/null || { fail "DTB files not detected in ISO listing."; exit "$EX_VERIFY"; }
grep -E 'BUILD-INFO\.(json|md)' "$VERIFY_FILE_LIST" >/dev/null || warn "Embedded BUILD-INFO files not detected in ISO listing."
ok "ISO verification completed."

# -----------------------------
# Final manifest and release notes
# -----------------------------
ISO_SHA="$(sha_file "$FINAL_ISO")"
ISO_SIZE="$(stat -c '%s' "$FINAL_ISO")"
FINAL_JSON="$CURRENT_RELEASE_DIR/$RELEASE_PREFIX-$ARCH-$BUILD_ID.build.json"
FINAL_MD="$CURRENT_RELEASE_DIR/$RELEASE_PREFIX-$ARCH-$BUILD_ID.build.md"

cp -a "$TMP_DIR/BUILD-INFO.json" "$FINAL_JSON.pre-iso.json" 2>/dev/null || true
cat > "$FINAL_JSON" <<JSON
{
  "script_name": "$SCRIPT_NAME",
  "script_version": "$SCRIPT_VERSION",
  "build_id": "$BUILD_ID",
  "build_number": "$BUILD_NUMBER",
  "build_date_utc": "$BUILD_DATE_UTC",
  "profile": "$PROFILE",
  "architecture": "$ARCH",
  "release_prefix": "$RELEASE_PREFIX",
  "iso_filename": "$FINAL_ISO_NAME",
  "iso_sha256": "$ISO_SHA",
  "iso_size_bytes": $ISO_SIZE,
  "artifact_directory": "$ARTIFACT_DIR",
  "root_overlay_directory": "$ROOT_OVERLAY_DIR",
  "qcom_firmware_enabled": $([[ "$ENABLE_QCOM_FW" -eq 1 ]] && echo true || echo false),
  "qcom_device_path": "$QCOM_DEVICE_PATH",
  "qcom_driver_archive": "${QCOM_DRIVER_ARCHIVE}",
  "qcom_driver_url": "${QCOM_DRIVER_URL}",
  "qcom_prestaged_dir": "${QCOM_PRESTAGED_DIR}",
  "qcom_staged_firmware_dir": "${QCOM_STAGED_FIRMWARE_DIR}",
  "repositories": {
    "pico-image": {"commit":"$(git -C "$(repo_path pico-image)" rev-parse HEAD)", "branch":"$(git -C "$(repo_path pico-image)" rev-parse --abbrev-ref HEAD)"},
    "core-image": {"commit":"$(git -C "$(repo_path core-image)" rev-parse HEAD)", "branch":"$(git -C "$(repo_path core-image)" rev-parse --abbrev-ref HEAD)"},
    "desktop-image": {"commit":"$(git -C "$(repo_path desktop-image)" rev-parse HEAD)", "branch":"$(git -C "$(repo_path desktop-image)" rev-parse --abbrev-ref HEAD)"},
    "live-iso": {"commit":"$(git -C "$(repo_path live-iso)" rev-parse HEAD)", "branch":"$(git -C "$(repo_path live-iso)" rev-parse --abbrev-ref HEAD)"}
  }
}
JSON

cat > "$FINAL_MD" <<MD
# $RELEASE_PREFIX $BUILD_ID

## Result

- Status: successful
- ISO: \\`$FINAL_ISO_NAME\\`
- SHA-256: \\`$ISO_SHA\\`
- Size bytes: \\`$ISO_SIZE\\`

## Build

- Builder: $SCRIPT_NAME v$SCRIPT_VERSION
- Date UTC: $BUILD_DATE_UTC
- Profile: $PROFILE
- Architecture: $ARCH
- Workdir: \\`$WORKDIR\\`

## Inputs

- Artifact directory: \\`$ARTIFACT_DIR\\`
- Root overlay directory: \\`$ROOT_OVERLAY_DIR\\`
- Qualcomm firmware updater enabled: $ENABLE_QCOM_FW
- Qualcomm device path: \\`$QCOM_DEVICE_PATH\\`

## Repositories

- pico-image: \\`$(git -C "$(repo_path pico-image)" rev-parse --short HEAD)\\`
- core-image: \\`$(git -C "$(repo_path core-image)" rev-parse --short HEAD)\\`
- desktop-image: \\`$(git -C "$(repo_path desktop-image)" rev-parse --short HEAD)\\`
- live-iso: \\`$(git -C "$(repo_path live-iso)" rev-parse --short HEAD)\\`

## Notes

The release directory includes archived local input artifacts, root overlay contents, checksums, ISO file listing, logs, and JSON/Markdown build manifests.
MD

# Increment the persistent build number only after successful ISO generation and verification.
printf '%04d\n' "$next_num" > "$BUILD_NUMBER_FILE"

ok "Release complete: $CURRENT_RELEASE_DIR"
ok "ISO SHA-256: $ISO_SHA"
echo
printf '%s\n' "${C_BOLD}Final ISO:${C_RESET} $FINAL_ISO"
printf '%s\n' "${C_BOLD}Release manifest:${C_RESET} $FINAL_JSON"
printf '%s\n' "${C_BOLD}Log:${C_RESET} $LOG_FILE"
