#!/usr/bin/env bash
# Conception VanillaOS ARM64 Builder
# Version 7.0.8
#
# Architecture:
#   - The installed system is a Vib custom OCI image layered on
#     ghcr.io/vanilla-os/desktop:dev.
#   - The graphical installer ISO is built from a clean official live-iso
#     checkout using the proven Pico workflow.
#   - The upstream live graphical package closure is never modified.
#   - Only boot-critical hardware content is remastered into the completed ISO:
#     kernel, modules, initramfs, DTB, firmware, and GRUB references.
#
# v7.0.8 corrections after the v7.0.7 package-selection field test:
#   - Fixes the payload fallback that incorrectly classified a linux-headers
#     package as boot-critical merely because it contained the conventional
#     /lib/modules/<release>/build symlink.
#   - Header, tools, development, and metadata package classes are now rejected
#     before any payload-based fallback is considered.
#   - An unrecognized package is selected only when its complete dpkg archive
#     listing contains a regular /boot/vmlinuz-<release> file or an actual
#     regular kernel module object (*.ko, *.ko.gz, *.ko.xz, or *.ko.zst).
#   - Adds a second fail-closed selection guard immediately before staging the
#     target OCI package transaction.
#   - Module verification no longer accepts directories or build/source
#     symlinks as evidence of runtime kernel modules.
#   - Adds an exact regression test for a headers package containing
#     /lib/modules/<release>/build -> /usr/src/linux-headers-<release>.
#   - Preserves all v7.0.7 source, Vib/FsGuard, firmware, DTB, package archive,
#     target OCI, and live graphical package-closure safeguards.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_VERSION="7.0.8"
SCRIPT_NAME="$(basename "$0")"

# ----------------------------- defaults ---------------------------------

WORKDIR="${WORKDIR:-$HOME/src/vanilla-arm64-build-system}"
PROFILE="${PROFILE:-hp-omnibook-5}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
ROOT_SOURCE="${ROOT_SOURCE:-}"
DTB_FILE_OVERRIDE="${DTB_FILE_OVERRIDE:-}"
FIRMWARE_SOURCE_OVERRIDE="${FIRMWARE_SOURCE_OVERRIDE:-}"
EXPECTED_CUSTOM_KERNEL_RELEASE="${EXPECTED_CUSTOM_KERNEL_RELEASE:-}"

CUSTOM_IMAGE_REPO_URL="${CUSTOM_IMAGE_REPO_URL:-https://github.com/Vanilla-OS/custom-image.git}"
CUSTOM_IMAGE_REF="${CUSTOM_IMAGE_REF:-main}"
CUSTOM_IMAGE_BASE="${CUSTOM_IMAGE_BASE:-ghcr.io/vanilla-os/desktop:dev}"

LIVE_ISO_REPO_URL="${LIVE_ISO_REPO_URL:-https://github.com/Vanilla-OS/live-iso.git}"
LIVE_ISO_REF="${LIVE_ISO_REF:-orchid}"
LIVE_ISO_CONTAINER_IMAGE="${LIVE_ISO_CONTAINER_IMAGE:-ghcr.io/vanilla-os/pico:dev}"
LIVE_ISO_RUNTIME="${LIVE_ISO_RUNTIME:-docker}"

QCOM_UPDATER_REPO_URL="${QCOM_UPDATER_REPO_URL:-https://github.com/alejandroqh/qcom-firmware-updater.git}"
QCOM_UPDATER_REF="${QCOM_UPDATER_REF:-main}"
QCOM_DEVICE_PATH_DEFAULT="${QCOM_DEVICE_PATH_DEFAULT:-x1p42100/hp/omnibook-5}"
QCOM_DEVICE_PATH="${QCOM_DEVICE_PATH:-$QCOM_DEVICE_PATH_DEFAULT}"

OCI_RUNTIME="${OCI_RUNTIME:-podman}"
OCI_BUILD_NETWORK="${OCI_BUILD_NETWORK:-host}"
TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-}"
ABROOT_IMAGE_NAME="${ABROOT_IMAGE_NAME:-}"
PUSH_TARGET_IMAGE="${PUSH_TARGET_IMAGE:-0}"

VIB_VERSION="${VIB_VERSION:-1.1.0}"
VIB_BIN="${VIB_BIN:-}"
VIB_DETECTED_VERSION=""
FSGUARD_PLUGIN_REPO="${FSGUARD_PLUGIN_REPO:-Vanilla-OS/vib-fsguard}"
FSGUARD_PLUGIN_VERSION="${FSGUARD_PLUGIN_VERSION:-auto}"
FSGUARD_PLUGIN_FILE=""
FSGUARD_PLUGIN_RESOLVED_TAG=""
FSGUARD_PLUGIN_RELEASE_METADATA=""
FSGUARD_PLUGIN_ASSET_URL=""

REPO_POLICY="${REPO_POLICY:-ask-once}"
FIRMWARE_MODE="${FIRMWARE_MODE:-ask}"
FIRMWARE_ARCHIVE="${FIRMWARE_ARCHIVE:-}"
FIRMWARE_URL="${FIRMWARE_URL:-}"
FIRMWARE_PRESTAGED="${FIRMWARE_PRESTAGED:-}"
FIRMWARE_CONTAINER_NETWORK="${FIRMWARE_CONTAINER_NETWORK:-ask}"

MIN_GRAPHICAL_PACKAGE_COUNT="${MIN_GRAPHICAL_PACKAGE_COUNT:-1400}"
MIN_FREE_GIB="${MIN_FREE_GIB:-40}"
ALLOW_HOST_PACKAGE_REMOVALS="${ALLOW_HOST_PACKAGE_REMOVALS:-0}"

PLAN_ONLY=0
KEEP_TMP=0
INTERACTIVE_MODE="auto"
ASSUME_YES=0

CURRENT_STAGE="initialization"
CURRENT_LOG=""
SESSION_ID="$(date -u +%Y%m%d-%H%M%S)"
RELEASE_ID=""
BUILD_DATE="$(date -u +%Y%m%d)"

# Runtime-computed paths. recompute_paths must be called after CLI parsing.
SOURCES_DIR=""
DOWNLOADS_DIR=""
CACHE_DIR=""
OUTPUT_DIR=""
LOG_DIR=""
TMP_DIR=""
TMP_ROOT=""
RELEASES_DIR=""
RELEASE_DIR=""
CUSTOM_IMAGE_SOURCE=""
CUSTOM_PROJECT=""
LIVE_ISO_SOURCE=""
LEGACY_LIVE_ISO_SOURCE=""
CORE_IMAGE_SOURCE=""
DESKTOP_IMAGE_SOURCE=""
LIVE_BUILD_DIR=""
QCOM_UPDATER_DIR=""
STAGED_FIRMWARE_DIR=""
FINAL_ISO=""
BUILD_COUNTER_FILE=""

# Discovered inputs.
declare -a KERNEL_DEBS=()
declare -a TARGET_KERNEL_DEBS=()
declare -a TARGET_EXCLUDED_KERNEL_DEBS=()
declare -a LIVE_KERNEL_DEBS=()
declare -a DTB_CANDIDATES=()
KERNEL_RELEASE=""
DTB_FILE=""
DTB_NAME=""
FIRMWARE_SOURCE=""
FIRMWARE_PROBE_REL=""
ROOT_PROBE_REL=""
UPSTREAM_ISO=""
UPSTREAM_MANIFEST=""
UPSTREAM_REMOVE_MANIFEST=""
LIVE_SOURCE_COMMIT=""
CUSTOM_SOURCE_COMMIT=""
SOURCES_SYNCHRONIZED=0

# ----------------------------- presentation -----------------------------

C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
ok()   { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }
hr()   { printf '%*s\n' 78 '' | tr ' ' '-'; }

stage() {
  CURRENT_STAGE="$1"
  printf '\n[%s]\n' "$CURRENT_STAGE"
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_path_input() {
  local s
  s="$(trim "$1")"
  if [[ ${#s} -ge 2 ]]; then
    [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]] && s="${s:1:${#s}-2}"
    [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]] && s="${s:1:${#s}-2}"
  fi
  case "$s" in
    '~') s="$HOME" ;;
    '~/'*) s="$HOME/${s#~/}" ;;
  esac
  printf '%s' "$s"
}

shell_escape() { printf '%q' "$1"; }

is_interactive() {
  [[ "$INTERACTIVE_MODE" == "1" ]]
}

open_shell() {
  local dir="${1:-$PWD}"
  mkdir -p "$dir"
  printf '\n*** Interactive shell. Type exit to return to the builder. ***\n' >&2
  printf 'Directory: %s\n' "$dir" >&2
  (cd "$dir" && "${SHELL:-/bin/bash}")
}

menu() {
  local title="$1"; shift
  local default="$1"; shift
  local ans opt n label desc

  if ! is_interactive; then
    printf '%s' "$default"
    return 0
  fi

  while true; do
    printf '\n' >&2
    hr >&2
    printf '%b\n\n' "$title" >&2
    for opt in "$@"; do
      IFS='|' read -r n label desc <<<"$opt"
      if [[ "$n" == "$default" ]]; then
        printf '  %s) %s [DEFAULT]\n' "$n" "$label" >&2
      else
        printf '  %s) %s\n' "$n" "$label" >&2
      fi
      [[ -n "${desc:-}" ]] && printf '     %s\n\n' "$desc" >&2
    done
    printf '  !  Open an interactive shell\n' >&2
    printf '  ?  Reprint this menu\n' >&2
    hr >&2
    read -rp "Selection [$default]: " ans
    ans="$(trim "${ans:-$default}")"
    case "$ans" in
      '!') open_shell "$PWD"; continue ;;
      '?') continue ;;
    esac
    for opt in "$@"; do
      IFS='|' read -r n label desc <<<"$opt"
      [[ "$ans" == "$n" ]] && { printf '%s' "$ans"; return 0; }
    done
    printf 'Invalid selection: %s\n' "$(shell_escape "$ans")" >&2
  done
}

prompt_text() {
  local title="$1" default="$2" ans
  if ! is_interactive; then
    printf '%s' "$default"
    return 0
  fi
  printf '\n%s\nDefault: %s\n' "$title" "$default" >&2
  read -rp "$title [$default]: " ans
  printf '%s' "$(trim "${ans:-$default}")"
}

prompt_path() {
  local title="$1" default="$2" ans
  if ! is_interactive; then
    printf '%s' "$default"
    return 0
  fi
  printf '\n%s\nDefault: %s\n' "$title" "$default" >&2
  read -rp "$title [$default]: " ans
  normalize_path_input "${ans:-$default}"
}

confirm_or_abort() {
  (( ASSUME_YES == 1 )) && return 0
  local choice
  choice="$(menu "Build Confirmation\n\nOfficial Git sources have already been synchronized and validated. Review the resolved plan before allowing firmware staging, container builds, and ISO remastering." "1" \
    "1|Proceed with the complete build|Execute the validated plan." \
    "2|Open a shell in the work directory|Inspect or change files, then return to this confirmation." \
    "3|Abort before build execution|Preserve validated source checkouts and leave artifacts untouched.")"
  case "$choice" in
    1) return 0 ;;
    2) open_shell "$WORKDIR"; confirm_or_abort ;;
    3) die "Build aborted by operator after source validation; synchronized repositories were preserved." ;;
  esac
}

# ------------------------------- traps ----------------------------------

on_error() {
  local rc=$?
  fail "Unexpected failure during: $CURRENT_STAGE"
  fail "Line: ${BASH_LINENO[0]:-unknown}; exit status: $rc"
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    fail "Last 80 log lines: $CURRENT_LOG"
    if [[ -s "$CURRENT_LOG" ]]; then
      tail -n 80 "$CURRENT_LOG" >&2 || true
    else
      fail "The failing command produced an empty log."
    fi
  fi
  exit "$rc"
}
trap on_error ERR

CHROOT_MOUNT_ROOT=""
cleanup_chroot_mounts() {
  local root="${CHROOT_MOUNT_ROOT:-}"
  [[ -n "$root" ]] || return 0
  umount -lf "$root/run" 2>/dev/null || true
  umount -lf "$root/dev/pts" 2>/dev/null || true
  umount -lf "$root/dev" 2>/dev/null || true
  umount -lf "$root/proc" 2>/dev/null || true
  umount -lf "$root/sys" 2>/dev/null || true
  CHROOT_MOUNT_ROOT=""
}

cleanup() {
  cleanup_chroot_mounts
  if [[ -n "$CUSTOM_PROJECT" && -d "$CUSTOM_PROJECT" && -d "$CUSTOM_IMAGE_SOURCE/.git" ]]; then
    git -C "$CUSTOM_IMAGE_SOURCE" worktree remove --force "$CUSTOM_PROJECT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LIVE_BUILD_DIR" && -d "$LIVE_BUILD_DIR" && -d "$LIVE_ISO_SOURCE/.git" ]]; then
    git -C "$LIVE_ISO_SOURCE" worktree remove --force "$LIVE_BUILD_DIR" >/dev/null 2>&1 || true
  fi
  if (( KEEP_TMP == 0 )); then
    [[ -n "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT" 2>/dev/null || true
  else
    warn "Temporary work retained: $TMP_ROOT"
  fi
}
trap cleanup EXIT

run_logged() {
  local name="$1"; shift
  CURRENT_LOG="$LOG_DIR/${SESSION_ID}-${name}.log"
  mkdir -p "$LOG_DIR"
  info "Log: $CURRENT_LOG"
  "$@" 2>&1 | tee "$CURRENT_LOG"
}

# ------------------------------- usage ----------------------------------

usage() {
  cat <<EOF
Usage:
  sudo $SCRIPT_NAME [--execute|--plan] [options]

Interactive behavior:
  Interactive menus are enabled by default when stdin is a terminal. The
  --execute switch does not disable questions. Use --non-interactive only for
  fully preconfigured automation.

Options:
  --execute                       Run the build after configuration.
  --plan, --dry-run               Resolve inputs and print the exact plan only.
  --non-interactive               Use environment/CLI values without menus.
  --yes                           Accept final confirmation and safe installs.
  --keep-tmp                      Preserve remaster and diagnostic work trees.
  --workdir PATH                  Build-system root.
  --profile NAME                  Hardware profile.
  --artifact-dir PATH             Profile kernel/DTB input directory.
  --root-source PATH              Directory copied into target OCI /root.
  --firmware-dir PATH             Existing firmware tree; paths relative to
                                  /usr/lib/firmware.
  --repo-policy POLICY            ask-once, prompt, refresh, continue, reclone.
  --target-image REF              Full target OCI build/push reference.
  --abroot-image NAME             ABRoot image name, normally owner/image.
  --live-ref REF                  live-iso branch, tag, or commit.
  --custom-image-ref REF          custom-image branch, tag, or commit.
  --push-target-image             Push target OCI after local verification.
  -h, --help                      Show this help.

Vib toolchain defaults:
  VIB_VERSION=1.1.0
  FSGUARD_PLUGIN_REPO=Vanilla-OS/vib-fsguard
  FSGUARD_PLUGIN_VERSION=auto     Select newest release containing the exact
                                  fsguard-<host-arch>.so asset.
  GITHUB_TOKEN=<optional>         Raise GitHub API rate limits.

Preferred input layout:
  WORKDIR/artifacts/$PROFILE/
  ├── kernel-debs/
  │   ├── linux-image-<release>_*.deb
  │   ├── linux-modules-<release>_*.deb
  │   └── other matching kernel .deb files
  ├── dtb/
  │   └── x1p42100-hp-omnibook-5.dtb
  └── firmware/
      └── qcom/...                # relative to /usr/lib/firmware

Target /root overlay used by the current project tree:
  WORKDIR/artifacts/root/

Compatibility paths:
  ARTIFACT_DIR/*.deb
  ARTIFACT_DIR/*.dtb
  ARTIFACT_DIR/root/
  WORKDIR/root-overlay/$PROFILE/
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --execute) PLAN_ONLY=0; shift ;;
      --plan|--dry-run) PLAN_ONLY=1; shift ;;
      --non-interactive) INTERACTIVE_MODE=0; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --keep-tmp) KEEP_TMP=1; shift ;;
      --workdir) [[ $# -ge 2 ]] || die "--workdir requires a path"; WORKDIR="$(normalize_path_input "$2")"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile requires a value"; PROFILE="$2"; shift 2 ;;
      --artifact-dir) [[ $# -ge 2 ]] || die "--artifact-dir requires a path"; ARTIFACT_DIR="$(normalize_path_input "$2")"; shift 2 ;;
      --root-source) [[ $# -ge 2 ]] || die "--root-source requires a path"; ROOT_SOURCE="$(normalize_path_input "$2")"; shift 2 ;;
      --firmware-dir) [[ $# -ge 2 ]] || die "--firmware-dir requires a path"; FIRMWARE_SOURCE_OVERRIDE="$(normalize_path_input "$2")"; FIRMWARE_MODE="prestaged"; shift 2 ;;
      --repo-policy) [[ $# -ge 2 ]] || die "--repo-policy requires a value"; REPO_POLICY="$2"; shift 2 ;;
      --target-image) [[ $# -ge 2 ]] || die "--target-image requires a value"; TARGET_IMAGE_REF="$2"; shift 2 ;;
      --abroot-image) [[ $# -ge 2 ]] || die "--abroot-image requires a value"; ABROOT_IMAGE_NAME="$2"; shift 2 ;;
      --live-ref) [[ $# -ge 2 ]] || die "--live-ref requires a value"; LIVE_ISO_REF="$2"; shift 2 ;;
      --custom-image-ref) [[ $# -ge 2 ]] || die "--custom-image-ref requires a value"; CUSTOM_IMAGE_REF="$2"; shift 2 ;;
      --push-target-image) PUSH_TARGET_IMAGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

recompute_paths() {
  ARTIFACT_DIR="${ARTIFACT_DIR:-$WORKDIR/artifacts/$PROFILE}"
  TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-localhost/conception/vanilla-desktop-${PROFILE}:${BUILD_DATE}}"
  VIB_BIN="${VIB_BIN:-$WORKDIR/tools/vib}"

  SOURCES_DIR="$WORKDIR/sources"
  DOWNLOADS_DIR="$WORKDIR/downloads"
  CACHE_DIR="$WORKDIR/cache"
  OUTPUT_DIR="$WORKDIR/output"
  LOG_DIR="$OUTPUT_DIR/logs"
  TMP_DIR="$WORKDIR/tmp"
  TMP_ROOT="$TMP_DIR/v7.0.8-${SESSION_ID}"
  RELEASES_DIR="$OUTPUT_DIR/releases"
  CUSTOM_IMAGE_SOURCE="$SOURCES_DIR/custom-image"
  CUSTOM_PROJECT="$TMP_ROOT/custom-image-project"
  LIVE_ISO_SOURCE="$SOURCES_DIR/live-iso"
  LEGACY_LIVE_ISO_SOURCE="$SOURCES_DIR/live-iso-v7"
  CORE_IMAGE_SOURCE="$SOURCES_DIR/core-image"
  DESKTOP_IMAGE_SOURCE="$SOURCES_DIR/desktop-image"
  LIVE_BUILD_DIR="$TMP_ROOT/live-iso-worktree"
  QCOM_UPDATER_DIR="$SOURCES_DIR/qcom-firmware-updater"
  STAGED_FIRMWARE_DIR="$WORKDIR/staged-firmware/$PROFILE"
  BUILD_COUNTER_FILE="$WORKDIR/.build-number"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root for container, mount, chroot, and ISO operations."
}

setup_directories() {
  mkdir -p "$WORKDIR" "$SOURCES_DIR" "$DOWNLOADS_DIR" "$CACHE_DIR" \
    "$OUTPUT_DIR" "$LOG_DIR" "$TMP_DIR" "$TMP_ROOT" "$RELEASES_DIR" \
    "$ARTIFACT_DIR"
}

setup_logging() {
  local log_file="$LOG_DIR/${SESSION_ID}-builder.log"
  exec > >(tee -a "$log_file") 2> >(tee -a "$log_file" >&2)
  info "Builder log: $log_file"
}

# ---------------------- interactive configuration -----------------------

normalize_repo_policy() {
  case "${REPO_POLICY,,}" in
    ask|ask-once|once) REPO_POLICY="ask-once" ;;
    prompt|interactive) REPO_POLICY="prompt" ;;
    refresh|pull|update) REPO_POLICY="refresh" ;;
    continue|keep|offline|existing) REPO_POLICY="continue" ;;
    reclone|fresh|clone) REPO_POLICY="reclone" ;;
    *) die "Invalid repository policy: $REPO_POLICY" ;;
  esac
}

choose_repo_policy() {
  normalize_repo_policy
  [[ "$REPO_POLICY" != "ask-once" ]] && { info "Repository policy supplied: $REPO_POLICY"; return; }
  local choice
  choice="$(menu "Repository Source Validation and Synchronization\n\nIn execute mode, this selection is applied immediately after the host dependency preflight. The builder validates origin URL, requested ref, current commit, and dirty state. Missing repositories are cloned before the remaining build questions continue." "1" \
    "1|Refresh and validate official sources [RECOMMENDED]|Fetch/prune, use the requested ref, and require a clean checkout." \
    "2|Use existing validated sources without network refresh|Missing repositories are still cloned; existing refs must resolve locally." \
    "3|Prompt separately for each repository|Choose continue, refresh, reclone, shell, or abort for each checkout." \
    "4|Re-clone all configured repositories|Delete existing configured checkouts and clone clean sources." \
    "5|Open a shell in sources/ before choosing|Inspect or repair source directories, then return." \
    "6|Abort|Stop before any Git operations.")"
  case "$choice" in
    1) REPO_POLICY="refresh" ;;
    2) REPO_POLICY="continue" ;;
    3) REPO_POLICY="prompt" ;;
    4) REPO_POLICY="reclone" ;;
    5) open_shell "$SOURCES_DIR"; REPO_POLICY="ask-once"; choose_repo_policy ;;
    6) die "Build aborted before Git source handling." ;;
  esac
  ok "Repository policy: $REPO_POLICY"
}

choose_artifact_directory() {
  local choice
  while true; do
    if [[ -d "$ARTIFACT_DIR" ]]; then
      local deb_count dtb_count
      deb_count="$(find "$ARTIFACT_DIR/kernel-debs" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null | sort -u | wc -l)"
      dtb_count="$(find "$ARTIFACT_DIR/dtb" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.dtb' -print 2>/dev/null | sort -u | wc -l)"
      printf '\nArtifact directory candidate:\n  %s\n  Debian packages: %s\n  DTBs: %s\n' "$ARTIFACT_DIR" "$deb_count" "$dtb_count" >&2
      if (( deb_count > 0 && dtb_count > 0 )); then
        if ! is_interactive; then return 0; fi
        choice="$(menu "Kernel and DTB Artifact Directory" "1" \
          "1|Use this artifact directory|Continue with the displayed package and DTB counts." \
          "2|Choose another directory|Enter a different profile artifact path." \
          "3|Open a shell here|Inspect or add files, then return." \
          "4|Abort|Stop because required hardware artifacts are unavailable.")"
        case "$choice" in
          1) return 0 ;;
          2) ARTIFACT_DIR="$(prompt_path "Custom kernel and DTB artifact directory" "$ARTIFACT_DIR")" ;;
          3) open_shell "$ARTIFACT_DIR" ;;
          4) die "Artifact selection aborted." ;;
        esac
      else
        if ! is_interactive; then
          die "Artifact directory lacks required .deb or .dtb files: $ARTIFACT_DIR"
        fi
      fi
    fi

    choice="$(menu "Incomplete Artifact Directory\n\nExpected:\n  kernel-debs/*.deb or direct *.deb files\n  dtb/*.dtb or a direct *.dtb file\n\nCurrent path:\n  $ARTIFACT_DIR" "1" \
      "1|Choose another directory|Enter the correct profile artifact path." \
      "2|Open a shell in the current directory|Copy or inspect files, then retry." \
      "3|Retry validation|Use after adding files externally." \
      "4|Abort|Stop immediately.")"
    case "$choice" in
      1) ARTIFACT_DIR="$(prompt_path "Custom kernel and DTB artifact directory" "$ARTIFACT_DIR")"; mkdir -p "$ARTIFACT_DIR" ;;
      2) open_shell "$ARTIFACT_DIR" ;;
      3) : ;;
      4) die "Required hardware artifacts were not supplied." ;;
    esac
  done
}

select_default_root_source() {
  local candidates=(
    "$WORKDIR/artifacts/root"
    "$ARTIFACT_DIR/root"
    "$WORKDIR/root-overlay/$PROFILE"
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done
  printf ''
}

choose_root_overlay() {
  [[ -n "$ROOT_SOURCE" ]] || ROOT_SOURCE="$(select_default_root_source)"
  if ! is_interactive; then
    [[ -z "$ROOT_SOURCE" || -d "$ROOT_SOURCE" ]] || die "ROOT_SOURCE is not a directory: $ROOT_SOURCE"
    return
  fi

  local choice default_desc
  default_desc="${ROOT_SOURCE:-none detected}"
  choice="$(menu "Target OCI /root Overlay\n\nFiles below the selected directory are copied into /root in the custom target OCI. They are not added to the live installer ISO.\n\nDetected/default path:\n  $default_desc" "1" \
    "1|Use the detected/default /root source|Use WORKDIR/artifacts/root when present, then profile-local compatibility paths." \
    "2|Choose another directory|Enter a directory whose contents should become /root/." \
    "3|Skip the /root overlay|Build the target OCI without additional /root content." \
    "4|Open a shell before choosing|Inspect the artifact tree and return.")"
  case "$choice" in
    1) [[ -z "$ROOT_SOURCE" || -d "$ROOT_SOURCE" ]] || die "Default root source does not exist: $ROOT_SOURCE" ;;
    2) ROOT_SOURCE="$(prompt_path "Directory copied into target /root" "${ROOT_SOURCE:-$WORKDIR/artifacts/root}")"; [[ -d "$ROOT_SOURCE" ]] || die "Root source does not exist: $ROOT_SOURCE" ;;
    3) ROOT_SOURCE="" ;;
    4) open_shell "$WORKDIR/artifacts"; choose_root_overlay ;;
  esac
}

existing_profile_firmware_dir() {
  local candidates=(
    "$ARTIFACT_DIR/firmware"
    "$ARTIFACT_DIR/usr/lib/firmware"
    "$ARTIFACT_DIR/qcom"
  )
  local d
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] || continue
    if find "$d" -type f -print -quit 2>/dev/null | grep -q .; then
      printf '%s' "$d"
      return 0
    fi
  done
  printf ''
}

choose_firmware_source() {
  local detected
  detected="$(existing_profile_firmware_dir)"

  if [[ -n "$FIRMWARE_SOURCE_OVERRIDE" ]]; then
    FIRMWARE_MODE="prestaged"
    FIRMWARE_PRESTAGED="$FIRMWARE_SOURCE_OVERRIDE"
  fi

  if ! is_interactive; then
    case "${FIRMWARE_MODE,,}" in
      ask|auto)
        if [[ -n "$detected" ]]; then
          FIRMWARE_MODE="prestaged"
          FIRMWARE_PRESTAGED="$detected"
        else
          FIRMWARE_MODE="skip"
        fi
        ;;
      existing)
        [[ -n "$detected" ]] || die "FIRMWARE_MODE=existing but no profile firmware tree was found."
        FIRMWARE_MODE="prestaged"
        FIRMWARE_PRESTAGED="$detected"
        ;;
      prestaged) [[ -n "$FIRMWARE_PRESTAGED" ]] || die "FIRMWARE_PRESTAGED is required." ;;
      archive) [[ -f "$FIRMWARE_ARCHIVE" ]] || die "FIRMWARE_ARCHIVE does not exist: $FIRMWARE_ARCHIVE" ;;
      url) [[ -n "$FIRMWARE_URL" ]] || die "FIRMWARE_URL is required." ;;
      skip) : ;;
      *) die "Unsupported FIRMWARE_MODE: $FIRMWARE_MODE" ;;
    esac
    return
  fi

  local choice default_option="1"
  [[ -n "$detected" ]] || default_option="2"
  choice="$(menu "Qualcomm Firmware Source Selection\n\nFirmware staging is isolated. No firmware is installed onto the build host.\n\nDetected profile firmware tree:\n  ${detected:-none}" "$default_option" \
    "1|Use the existing profile firmware tree [RECOMMENDED]|Use ARTIFACT_DIR/firmware or a compatible existing path." \
    "2|Choose a pre-staged firmware directory|Select an existing tree representing /usr/lib/firmware." \
    "3|Extract from a local Qualcomm Windows driver archive|Run qcom-firmware-updater inside a disposable container." \
    "4|Download and extract from a direct Qualcomm driver URL|Download into cache, then use the isolated updater workflow." \
    "5|Open a shell before choosing|Inspect downloads, firmware, or source files manually." \
    "6|Skip Qualcomm firmware for this build|Continue with an explicit warning and no firmware-presence predicate.")"
  case "$choice" in
    1)
      [[ -n "$detected" ]] || { warn "No existing profile firmware tree was detected."; choose_firmware_source; return; }
      FIRMWARE_MODE="prestaged"; FIRMWARE_PRESTAGED="$detected"
      ;;
    2)
      FIRMWARE_MODE="prestaged"
      FIRMWARE_PRESTAGED="$(prompt_path "Pre-staged firmware directory" "${detected:-$ARTIFACT_DIR/firmware}")"
      [[ -d "$FIRMWARE_PRESTAGED" ]] || die "Firmware directory does not exist: $FIRMWARE_PRESTAGED"
      ;;
    3)
      FIRMWARE_MODE="archive"
      FIRMWARE_ARCHIVE="$(prompt_path "Local Qualcomm Windows driver ZIP/EXE" "$DOWNLOADS_DIR/qualcomm-windows-graphics-driver.zip")"
      [[ -f "$FIRMWARE_ARCHIVE" ]] || die "Firmware archive does not exist: $FIRMWARE_ARCHIVE"
      QCOM_DEVICE_PATH="$(prompt_text "qcom-firmware-updater device path" "$QCOM_DEVICE_PATH_DEFAULT")"
      ;;
    4)
      FIRMWARE_MODE="url"
      FIRMWARE_URL="$(prompt_text "Direct Qualcomm driver URL" "$FIRMWARE_URL")"
      [[ -n "$FIRMWARE_URL" ]] || die "A firmware URL is required."
      QCOM_DEVICE_PATH="$(prompt_text "qcom-firmware-updater device path" "$QCOM_DEVICE_PATH_DEFAULT")"
      ;;
    5) open_shell "$WORKDIR"; choose_firmware_source ;;
    6) FIRMWARE_MODE="skip" ;;
  esac
}

derive_abroot_image_name() {
  local ref="$1"
  ref="${ref#docker://}"
  ref="${ref%@*}"
  local first="${ref%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == "localhost" ) ]]; then
    ref="${ref#*/}"
  fi
  local last="${ref##*/}"
  last="${last%%:*}"
  if [[ "$ref" == */* ]]; then
    ref="${ref%/*}/$last"
  else
    ref="$last"
  fi
  printf '%s' "$ref"
}

choose_target_image() {
  if is_interactive; then
    TARGET_IMAGE_REF="$(prompt_text "Custom target OCI reference" "$TARGET_IMAGE_REF")"
    local push_choice
    push_choice="$(menu "Target OCI Publication\n\nThe graphical installer must be able to resolve and pull the selected target image. localhost references are suitable only for local verification." "1" \
      "1|Build locally without pushing|Record the reference and leave publication for a later explicit step." \
      "2|Build and push after verification|The selected runtime must already be authenticated to the registry." \
      "3|Open a shell before choosing|Authenticate or inspect container storage, then return.")"
    case "$push_choice" in
      1) PUSH_TARGET_IMAGE=0 ;;
      2) PUSH_TARGET_IMAGE=1 ;;
      3) open_shell "$WORKDIR"; choose_target_image; return ;;
    esac
  fi

  [[ -n "$ABROOT_IMAGE_NAME" ]] || ABROOT_IMAGE_NAME="$(derive_abroot_image_name "$TARGET_IMAGE_REF")"
  if is_interactive; then
    ABROOT_IMAGE_NAME="$(prompt_text "ABRoot image name stored in the target image (owner/image, lowercase)" "$ABROOT_IMAGE_NAME")"
  fi
  [[ "$ABROOT_IMAGE_NAME" == "${ABROOT_IMAGE_NAME,,}" ]] || die "ABROOT_IMAGE_NAME must be lowercase: $ABROOT_IMAGE_NAME"
  [[ "$ABROOT_IMAGE_NAME" == */* ]] || warn "ABROOT_IMAGE_NAME normally has owner/image form: $ABROOT_IMAGE_NAME"
}

print_builder_banner() {
  cat >&2 <<EOF

${C_BOLD}Conception VanillaOS ARM64 Container-Model Builder${C_RESET}
Version: $SCRIPT_VERSION

Work directory:   $WORKDIR
Profile:          $PROFILE
Artifact default: $ARTIFACT_DIR
Sources:          $SOURCES_DIR

v$SCRIPT_VERSION applies the selected Git source action before the remaining
artifact, firmware, target-image, and build-confirmation questions. --execute
does not suppress interactive questions.
EOF
}

configure_repository_interactively() {
  print_builder_banner
  choose_repo_policy
}

configure_build_inputs_interactively() {
  choose_artifact_directory
  choose_root_overlay
  choose_firmware_source
  choose_target_image
}

# ----------------------- host dependency safety -------------------------

command_exists() { command -v "$1" >/dev/null 2>&1; }

collect_missing_apt_packages() {
  local -A package_seen=()
  local -a missing_commands=()
  local cmd pkg

  while IFS='|' read -r cmd pkg; do
    command_exists "$cmd" && continue
    missing_commands+=("$cmd")
    package_seen["$pkg"]=1
  done <<EOF_DEPS
apt|apt
git|git
curl|curl
jq|jq
rsync|rsync
python3|python3
find|findutils
awk|gawk
grep|grep
sed|sed
tar|tar
dpkg-deb|dpkg
xorriso|xorriso
unsquashfs|squashfs-tools
mksquashfs|squashfs-tools
mount|util-linux
umount|util-linux
chroot|coreutils
sha256sum|coreutils
md5sum|coreutils
file|file
zstd|zstd
$OCI_RUNTIME|$([[ "$OCI_RUNTIME" == "docker" ]] && printf docker.io || printf podman)
$LIVE_ISO_RUNTIME|$([[ "$LIVE_ISO_RUNTIME" == "docker" ]] && printf docker.io || printf podman)
EOF_DEPS

  MISSING_COMMANDS=("${missing_commands[@]}")
  MISSING_APT_PACKAGES=()
  for pkg in "${!package_seen[@]}"; do MISSING_APT_PACKAGES+=("$pkg"); done
  mapfile -t MISSING_APT_PACKAGES < <(printf '%s\n' "${MISSING_APT_PACKAGES[@]}" | sort -u)
}

install_host_dependencies_safely() {
  collect_missing_apt_packages
  if ((${#MISSING_COMMANDS[@]} == 0)); then
    ok "All required host commands are present."
    return 0
  fi

  fail "Missing host commands: ${MISSING_COMMANDS[*]}"
  info "Corresponding apt packages: ${MISSING_APT_PACKAGES[*]}"

  if (( PLAN_ONLY == 1 )); then
    die "Plan mode does not modify the host. Install the listed packages and rerun."
  fi

  local choice
  if (( ASSUME_YES == 0 )); then
    choice="$(menu "Host Dependency Installation\n\nOnly packages needed for Git, Vib/container execution, squashfs handling, and ISO mastering are proposed. initramfs-tools is deliberately not a host dependency." "1" \
      "1|Run apt update, simulate, then install missing packages|Abort or ask again if APT proposes removals." \
      "2|Open a shell to install dependencies manually|Return and re-check afterward." \
      "3|Abort|Do not change the host.")"
    case "$choice" in
      1) : ;;
      2) open_shell "$WORKDIR"; install_host_dependencies_safely; return ;;
      3) die "Missing host dependencies." ;;
    esac
  fi

  apt update
  local simulation="$TMP_ROOT/apt-install-simulation.txt"
  apt -s install -y "${MISSING_APT_PACKAGES[@]}" | tee "$simulation"

  if grep -Eq '^(REMOVING:|The following packages will be REMOVED:)' "$simulation"; then
    fail "APT simulation proposes package removals."
    grep -A20 -E '^(REMOVING:|The following packages will be REMOVED:)' "$simulation" >&2 || true
    if [[ "$ALLOW_HOST_PACKAGE_REMOVALS" != "1" ]]; then
      if ! is_interactive; then
        die "Refusing host package removals. Set ALLOW_HOST_PACKAGE_REMOVALS=1 only after explicit review."
      fi
      choice="$(menu "APT Removal Guard\n\nThe proposed dependency installation would remove host packages. The default is to abort." "2" \
        "1|Allow the reviewed removals and continue|Use only when the simulation is understood and intentional." \
        "2|Abort without installing [RECOMMENDED]|Preserve the current host package configuration." \
        "3|Open a shell for manual resolution|Return after correcting the host.")"
      case "$choice" in
        1) : ;;
        2) die "Host package removal guard stopped the build." ;;
        3) open_shell "$WORKDIR"; install_host_dependencies_safely; return ;;
      esac
    fi
  fi

  DEBIAN_FRONTEND=noninteractive apt install -y "${MISSING_APT_PACKAGES[@]}"
  collect_missing_apt_packages
  ((${#MISSING_COMMANDS[@]} == 0)) || die "Commands remain missing after apt installation: ${MISSING_COMMANDS[*]}"
  ok "Host dependencies installed without an unreviewed package transition."
}

check_free_space() {
  local available_kib required_kib
  available_kib="$(df -Pk "$WORKDIR" | awk 'NR==2 {print $4}')"
  required_kib=$((MIN_FREE_GIB * 1024 * 1024))
  [[ "$available_kib" =~ ^[0-9]+$ ]] || die "Unable to determine free space for $WORKDIR"
  if (( available_kib < required_kib )); then
    die "Insufficient free space: require at least ${MIN_FREE_GIB} GiB under $WORKDIR."
  fi
  ok "Free-space preflight passed: $((available_kib / 1024 / 1024)) GiB available."
}

# ------------------------ artifact discovery -----------------------------

package_field() {
  local deb="$1" field="$2"
  dpkg-deb -f "$deb" "$field" 2>/dev/null || true
}

write_deb_content_listing() {
  local deb="$1" output="$2"
  # Do not pipe dpkg-deb into grep -q. A consumer that exits early closes the
  # pipe and makes dpkg-deb report a SIGPIPE/Broken pipe diagnostic. Complete
  # the archive listing first, then inspect the stable file.
  dpkg-deb -c "$deb" > "$output"
}

deb_listing_has_regular_boot_kernel() {
  # A boot kernel must be a regular archive member. Directories and symlinks do
  # not qualify. dpkg-deb -c emits the Unix mode/type in field 1.
  local listing="$1" release="$2"
  awk -v release="$release" '
    $1 ~ /^-/ {
      path=$NF
      sub(/^\.\//, "", path)
      if (path == "boot/vmlinuz-" release) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$listing"
}

deb_listing_has_runtime_module_object() {
  # A headers package commonly contains:
  #   /lib/modules/<release>/build -> /usr/src/linux-headers-<release>
  # That symlink is not a runtime module payload. Require at least one regular
  # kernel object, including the compressed forms used by Debian-family images.
  local listing="$1" release="$2"
  awk -v release="$release" '
    $1 ~ /^-/ {
      path=$NF
      sub(/^\.\//, "", path)
      prefix1="lib/modules/" release "/"
      prefix2="usr/lib/modules/" release "/"
      if ((index(path, prefix1) == 1 || index(path, prefix2) == 1) &&
          path ~ /\.ko(\.(gz|xz|zst))?$/) {
        found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$listing"
}

select_kernel_release_from_candidates() {
  local -a releases=("$@")
  mapfile -t releases < <(printf '%s\n' "${releases[@]}" | sed '/^$/d' | sort -u)

  if [[ -n "$EXPECTED_CUSTOM_KERNEL_RELEASE" ]]; then
    local r found=0
    for r in "${releases[@]}"; do [[ "$r" == "$EXPECTED_CUSTOM_KERNEL_RELEASE" ]] && found=1; done
    (( found == 1 )) || die "Expected kernel release '$EXPECTED_CUSTOM_KERNEL_RELEASE' was not found. Detected: ${releases[*]:-none}"
    printf '%s' "$EXPECTED_CUSTOM_KERNEL_RELEASE"
    return
  fi

  ((${#releases[@]} > 0)) || die "No custom linux-image release could be derived from Debian package metadata or complete archive listings."
  if ((${#releases[@]} == 1)); then
    printf '%s' "${releases[0]}"
    return
  fi

  if ! is_interactive; then
    die "Multiple custom kernel releases detected: ${releases[*]}. Set EXPECTED_CUSTOM_KERNEL_RELEASE."
  fi

  local options=() i=1 choice
  for r in "${releases[@]}"; do
    options+=("$i|Use kernel release $r|Select this exact uname -r value for target OCI and live ISO boot artifacts.")
    i=$((i+1))
  done
  choice="$(menu "Multiple Kernel Releases Detected" "1" "${options[@]}")"
  printf '%s' "${releases[$((choice-1))]}"
}

classify_kernel_deb_for_target() {
  # Print one stable class for reporting and target-install policy.
  local deb="$1"
  local pkg
  pkg="$(package_field "$deb" Package)"

  case "$pkg" in
    linux-image-*|linux-modules-*|linux-modules-extra-*)
      printf '%s\n' boot
      ;;
    linux-headers-*|linux-*-headers-*)
      printf '%s\n' headers
      ;;
    linux-qcom-*-tools-*|linux-tools-*|linux-*-tools-*)
      printf '%s\n' tools
      ;;
    linux-libc-dev|*-dev|*-dbgsym|*-dbg)
      printf '%s\n' development
      ;;
    linux-buildinfo-*|*.buildinfo|*.changes)
      printf '%s\n' metadata
      ;;
    *)
      printf '%s\n' other
      ;;
  esac
}

array_contains_exact() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

write_kernel_package_selection_manifest() {
  local manifest="$TMP_ROOT/kernel-package-selection.tsv"
  local deb pkg version arch class target live reason

  {
    printf 'package\tversion\tarchitecture\tclass\ttarget_install\tlive_boot\tarchive_path\tsource_deb\treason\n'
    for deb in "${KERNEL_DEBS[@]}"; do
      pkg="$(package_field "$deb" Package)"
      version="$(package_field "$deb" Version)"
      arch="$(package_field "$deb" Architecture)"
      class="$(classify_kernel_deb_for_target "$deb")"
      target=no
      live=no
      reason="reference-only"

      if array_contains_exact "$deb" "${TARGET_KERNEL_DEBS[@]}"; then
        target=yes
        reason="boot-critical target package"
      elif [[ "$class" == tools ]]; then
        reason="optional tools excluded; may require unavailable linux-tools-common"
      elif [[ "$class" == headers ]]; then
        reason="headers excluded from immutable runtime image"
      elif [[ "$class" == development ]]; then
        reason="development package excluded from immutable runtime image"
      elif [[ "$class" == metadata ]]; then
        reason="build metadata excluded from runtime installation"
      else
        reason="not selected as boot-critical for $KERNEL_RELEASE"
      fi

      if array_contains_exact "$deb" "${LIVE_KERNEL_DEBS[@]}"; then
        live=yes
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pkg" "$version" "$arch" "$class" "$target" "$live" \
        "/root/custom-kernel-packages/$(basename "$deb")" "$deb" "$reason"
    done
  } > "$manifest"
}

discover_kernel_and_dtb_inputs() {
  KERNEL_DEBS=()
  TARGET_KERNEL_DEBS=()
  TARGET_EXCLUDED_KERNEL_DEBS=()
  LIVE_KERNEL_DEBS=()
  DTB_CANDIDATES=()
  mkdir -p "$TMP_ROOT/deb-listings"

  mapfile -t KERNEL_DEBS < <(
    find "$ARTIFACT_DIR/kernel-debs" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null |
      sort -u
  )
  ((${#KERNEL_DEBS[@]} > 0)) || die "No .deb files found in $ARTIFACT_DIR/kernel-debs or $ARTIFACT_DIR."

  local -a release_candidates=()
  local deb pkg version arch listing rel
  local image_pkg_count=0 module_pkg_count=0
  : > "$TMP_ROOT/debian-package-inventory.tsv"

  for deb in "${KERNEL_DEBS[@]}"; do
    pkg="$(package_field "$deb" Package)"
    version="$(package_field "$deb" Version)"
    arch="$(package_field "$deb" Architecture)"
    [[ -n "$pkg" ]] || die "Unable to read Debian package metadata: $deb"
    [[ "$arch" == "arm64" || "$arch" == "all" ]] || die "Package $pkg has unsupported architecture '$arch': $deb"

    printf '%s\t%s\t%s\t%s\n' "$pkg" "$version" "$arch" "$deb" >> "$TMP_ROOT/debian-package-inventory.tsv"
    listing="$TMP_ROOT/deb-listings/$(basename "$deb").contents.txt"
    write_deb_content_listing "$deb" "$listing"

    case "$pkg" in
      linux-image-arm64|linux-image-generic*|linux-image-virtual*)
        ;;
      linux-image-unsigned-*)
        rel="${pkg#linux-image-unsigned-}"
        release_candidates+=("$rel")
        image_pkg_count=$((image_pkg_count+1))
        ;;
      linux-image-*)
        rel="${pkg#linux-image-}"
        release_candidates+=("$rel")
        image_pkg_count=$((image_pkg_count+1))
        ;;
    esac

    # Payload fallback for unusually named image packages. Only regular
    # /boot/vmlinuz-* archive members qualify; symlinks and directories do not.
    while IFS= read -r rel; do
      [[ -n "$rel" ]] && release_candidates+=("$rel")
    done < <(
      awk '
        $1 ~ /^-/ {
          path=$NF
          sub(/^\.\//, "", path)
          if (path ~ /^boot\/vmlinuz-/) {
            sub(/^boot\/vmlinuz-/, "", path)
            print path
          }
        }
      ' "$listing"
    )
  done

  KERNEL_RELEASE="$(select_kernel_release_from_candidates "${release_candidates[@]}")"

  local class selected_reason
  for deb in "${KERNEL_DEBS[@]}"; do
    pkg="$(package_field "$deb" Package)"
    class="$(classify_kernel_deb_for_target "$deb")"
    listing="$TMP_ROOT/deb-listings/$(basename "$deb").contents.txt"
    selected_reason=""

    case "$pkg" in
      linux-image-$KERNEL_RELEASE|linux-image-unsigned-$KERNEL_RELEASE|linux-image-$KERNEL_RELEASE-*|linux-image-unsigned-$KERNEL_RELEASE-*)
        LIVE_KERNEL_DEBS+=("$deb")
        selected_reason="package name identifies selected kernel image"
        ;;
      linux-modules-$KERNEL_RELEASE|linux-modules-$KERNEL_RELEASE-*|linux-modules-extra-$KERNEL_RELEASE|linux-modules-extra-$KERNEL_RELEASE-*)
        LIVE_KERNEL_DEBS+=("$deb")
        module_pkg_count=$((module_pkg_count+1))
        selected_reason="package name identifies selected runtime modules"
        ;;
      *)
        # Never allow known non-runtime classes to reach the payload fallback.
        # In particular, linux-headers packages can contain the conventional
        # /lib/modules/<release>/build symlink and must remain excluded.
        case "$class" in
          headers|tools|development|metadata)
            continue
            ;;
        esac

        if deb_listing_has_regular_boot_kernel "$listing" "$KERNEL_RELEASE"; then
          LIVE_KERNEL_DEBS+=("$deb")
          selected_reason="regular kernel image payload fallback"
        elif deb_listing_has_runtime_module_object "$listing" "$KERNEL_RELEASE"; then
          LIVE_KERNEL_DEBS+=("$deb")
          module_pkg_count=$((module_pkg_count+1))
          selected_reason="regular runtime module object payload fallback"
        fi
        ;;
    esac

    if [[ -n "$selected_reason" ]]; then
      info "Boot package selection: $pkg — $selected_reason"
    fi
  done
  mapfile -t LIVE_KERNEL_DEBS < <(printf '%s\n' "${LIVE_KERNEL_DEBS[@]}" | sort -u)

  # Fail closed if a known non-runtime class entered selection through any
  # future rule change.
  for deb in "${LIVE_KERNEL_DEBS[@]}"; do
    class="$(classify_kernel_deb_for_target "$deb")"
    pkg="$(package_field "$deb" Package)"
    case "$class" in
      headers|tools|development|metadata)
        die "Internal package-selection guard rejected non-runtime package: $pkg ($class)"
        ;;
    esac
  done

  # Install the same boot-critical image/module closure into the target OCI.
  # Optional headers, tools, development packages, and metadata remain archived
  # under /root/custom-kernel-packages and do not enter APT dependency solving.
  TARGET_KERNEL_DEBS=("${LIVE_KERNEL_DEBS[@]}")
  local candidate
  for candidate in "${KERNEL_DEBS[@]}"; do
    if ! array_contains_exact "$candidate" "${TARGET_KERNEL_DEBS[@]}"; then
      TARGET_EXCLUDED_KERNEL_DEBS+=("$candidate")
    fi
  done
  mapfile -t TARGET_KERNEL_DEBS < <(printf '%s\n' "${TARGET_KERNEL_DEBS[@]}" | sort -u)
  if ((${#TARGET_EXCLUDED_KERNEL_DEBS[@]} > 0)); then
    mapfile -t TARGET_EXCLUDED_KERNEL_DEBS < <(
      printf '%s\n' "${TARGET_EXCLUDED_KERNEL_DEBS[@]}" | sort -u
    )
  fi

  (( image_pkg_count > 0 )) || warn "No package named linux-image-$KERNEL_RELEASE was found; the release came from archive contents."
  ((${#LIVE_KERNEL_DEBS[@]} > 0)) || die "No boot-critical image/module packages selected for $KERNEL_RELEASE."
  (( module_pkg_count > 0 )) || {
    local has_modules=0
    for deb in "${LIVE_KERNEL_DEBS[@]}"; do
      listing="$TMP_ROOT/deb-listings/$(basename "$deb").contents.txt"
      if deb_listing_has_runtime_module_object "$listing" "$KERNEL_RELEASE"; then
        has_modules=1
      fi
    done
    (( has_modules == 1 )) ||       die "No selected package contains a regular runtime module object for $KERNEL_RELEASE."
  }

  mapfile -t DTB_CANDIDATES < <(
    find "$ARTIFACT_DIR/dtb" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.dtb' -print 2>/dev/null |
      sort -u
  )
  ((${#DTB_CANDIDATES[@]} > 0)) || die "No DTB found in $ARTIFACT_DIR/dtb or $ARTIFACT_DIR."

  if [[ -n "$DTB_FILE_OVERRIDE" ]]; then
    [[ -f "$DTB_FILE_OVERRIDE" ]] || die "DTB override does not exist: $DTB_FILE_OVERRIDE"
    DTB_FILE="$DTB_FILE_OVERRIDE"
  elif ((${#DTB_CANDIDATES[@]} == 1)); then
    DTB_FILE="${DTB_CANDIDATES[0]}"
  elif is_interactive; then
    local opts=() i=1 choice candidate
    for candidate in "${DTB_CANDIDATES[@]}"; do
      opts+=("$i|Use $(basename "$candidate")|$candidate")
      i=$((i+1))
    done
    choice="$(menu "Primary Device Tree Selection" "1" "${opts[@]}")"
    DTB_FILE="${DTB_CANDIDATES[$((choice-1))]}"
  else
    die "Multiple DTBs found. Set DTB_FILE_OVERRIDE or use interactive mode."
  fi

  DTB_NAME="$(basename "$DTB_FILE")"
  write_kernel_package_selection_manifest

  ok "Custom kernel release: $KERNEL_RELEASE"
  ok "Supplied kernel-related packages: ${#KERNEL_DEBS[@]}"
  ok "Boot-critical target OCI packages selected for installation: ${#TARGET_KERNEL_DEBS[@]}"
  ok "Reference-only target OCI packages excluded from APT: ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}"
  ok "Boot-critical live ISO packages: ${#LIVE_KERNEL_DEBS[@]}"
  ok "All supplied packages will be archived in target /root/custom-kernel-packages."
  ok "Selected DTB: $DTB_FILE"

  local excluded class pkg
  for excluded in "${TARGET_EXCLUDED_KERNEL_DEBS[@]}"; do
    pkg="$(package_field "$excluded" Package)"
    class="$(classify_kernel_deb_for_target "$excluded")"
    warn "Target APT exclusion: $pkg ($class); archived for reference only."
  done
}

# ------------------------- repository handling --------------------------

normalize_git_url() {
  local url="$1"
  url="${url%.git}"
  url="${url%/}"
  printf '%s' "$url"
}

repo_state() {
  local path="$1"
  if [[ ! -d "$path/.git" ]]; then printf 'missing'; return; fi
  local branch commit dirty origin
  branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"
  commit="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
  origin="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  [[ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]] && dirty=dirty || dirty=clean
  printf 'branch=%s commit=%s state=%s origin=%s' "${branch:-detached}" "${commit:-unknown}" "$dirty" "${origin:-unknown}"
}

repo_action_menu() {
  local name="$1" path="$2" ref="$3"
  menu "Repository Validation\n\nRepository: $name\nPath:       $path\nRequested:  $ref\nState:      $(repo_state "$path")" "2" \
    "1|Continue with existing validated checkout|No fetch; requested ref must resolve locally and checkout must be clean." \
    "2|Refresh from origin [RECOMMENDED]|Fetch/prune and checkout the requested branch, tag, or commit." \
    "3|Re-clone clean|Delete this checkout and clone the configured origin again." \
    "4|Open a shell here|Inspect or repair the checkout, then return." \
    "5|Abort|Stop source preparation."
}

checkout_requested_ref() {
  local path="$1" ref="$2" allow_fetch="$3"
  (( allow_fetch == 1 )) && git -C "$path" fetch --all --tags --prune

  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    if git -C "$path" show-ref --verify --quiet "refs/heads/$ref"; then
      git -C "$path" checkout "$ref"
      (( allow_fetch == 1 )) && git -C "$path" merge --ff-only "origin/$ref"
    else
      git -C "$path" checkout -b "$ref" --track "origin/$ref"
    fi
  elif git -C "$path" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    git -C "$path" checkout --detach "$ref"
  elif (( allow_fetch == 1 )); then
    git -C "$path" fetch origin "$ref"
    git -C "$path" checkout --detach FETCH_HEAD
  else
    die "Requested ref '$ref' is not available locally in $path."
  fi
}

check_git_remote_access() {
  local name="$1" url="$2"
  info "Checking remote access for $name: $url"
  git ls-remote "$url" HEAD >/dev/null 2>&1 ||     die "Unable to access configured Git remote for $name: $url"
  ok "$name remote is reachable."
}

verify_required_source_checkouts() {
  [[ -d "$CUSTOM_IMAGE_SOURCE/.git" ]] ||     die "Required custom-image checkout is absent after synchronization: $CUSTOM_IMAGE_SOURCE"
  [[ -d "$LIVE_ISO_SOURCE/.git" ]] ||     die "Required live-iso checkout is absent after synchronization: $LIVE_ISO_SOURCE"
  [[ -n "$CUSTOM_SOURCE_COMMIT" ]] || die "custom-image source commit was not recorded."
  [[ -n "$LIVE_SOURCE_COMMIT" ]] || die "live-iso source commit was not recorded."
  [[ -z "$(git -C "$CUSTOM_IMAGE_SOURCE" status --porcelain)" ]] ||     die "custom-image checkout is dirty after synchronization."
  [[ -z "$(git -C "$LIVE_ISO_SOURCE" status --porcelain)" ]] ||     die "live-iso checkout is dirty after synchronization."

  SOURCES_SYNCHRONIZED=1
  ok "Required source checkouts are present and clean."
  info "custom-image: $CUSTOM_IMAGE_SOURCE @ $CUSTOM_SOURCE_COMMIT"
  info "live-iso:     $LIVE_ISO_SOURCE @ $LIVE_SOURCE_COMMIT"
}

report_repository_plan_state() {
  info "Plan mode is non-mutating: repositories will not be cloned, fetched, reset, or refreshed."
  info "Selected execute-time repository policy: $REPO_POLICY"
  info "custom-image current state: $(source_checkout_summary "$CUSTOM_IMAGE_SOURCE")"
  info "live-iso current state:     $(source_checkout_summary "$LIVE_ISO_SOURCE")"
  info "core-image retained state:  $(source_checkout_summary "$CORE_IMAGE_SOURCE")"
  info "desktop-image retained:     $(source_checkout_summary "$DESKTOP_IMAGE_SOURCE")"
  info "qcom updater state:         $(source_checkout_summary "$QCOM_UPDATER_DIR")"

  if [[ -e "$LEGACY_LIVE_ISO_SOURCE" ]]; then
    warn "Legacy live-iso-v7 path is present and will be normalized in execute mode when safe."
  fi

  if [[ ! -d "$CUSTOM_IMAGE_SOURCE/.git" || ! -d "$LIVE_ISO_SOURCE/.git" ]]; then
    warn "One or both required source checkouts are absent. Execute mode will create them using policy '$REPO_POLICY'."
  fi

  return 0
}

source_checkout_summary() {
  local path="$1"
  if [[ -d "$path/.git" ]]; then
    repo_state "$path"
  elif [[ -e "$path" ]]; then
    printf 'present but not a Git checkout'
  else
    printf 'absent'
  fi
  return 0
}

normalize_live_iso_source_path() {
  # v7.0.2-v7.0.4 used sources/live-iso-v7. The repository itself is still the
  # official VanillaOS live-iso checkout, so the version suffix adds no useful
  # distinction. Migrate only when the canonical destination is absent and the
  # legacy directory is a clean checkout with the expected origin.
  [[ "$LIVE_ISO_SOURCE" == "$SOURCES_DIR/live-iso" ]] || \
    die "Internal source-layout guard: canonical live ISO path is not sources/live-iso."

  if [[ -d "$LIVE_ISO_SOURCE/.git" ]]; then
    if [[ -d "$LEGACY_LIVE_ISO_SOURCE/.git" ]]; then
      warn "Both canonical and legacy live-iso checkouts exist."
      warn "Using:    $LIVE_ISO_SOURCE"
      warn "Leaving:  $LEGACY_LIVE_ISO_SOURCE"
    fi
    return 0
  fi

  [[ -e "$LIVE_ISO_SOURCE" ]] && \
    die "Canonical live-iso path exists but is not a Git checkout: $LIVE_ISO_SOURCE"

  if [[ -d "$LEGACY_LIVE_ISO_SOURCE/.git" ]]; then
    local legacy_origin expected_origin
    legacy_origin="$(
      normalize_git_url "$(git -C "$LEGACY_LIVE_ISO_SOURCE" remote get-url origin)"
    )"
    expected_origin="$(normalize_git_url "$LIVE_ISO_REPO_URL")"

    [[ "$legacy_origin" == "$expected_origin" ]] || {
      warn "Legacy live-iso-v7 checkout has an unexpected origin: $legacy_origin"
      warn "It will be preserved; a canonical live-iso checkout will be cloned."
      return 0
    }

    [[ -z "$(git -C "$LEGACY_LIVE_ISO_SOURCE" status --porcelain)" ]] || {
      warn "Legacy live-iso-v7 checkout is dirty and will not be moved."
      warn "It will be preserved; resolve it manually or allow a fresh canonical clone."
      return 0
    }

    info "Migrating legacy source checkout to canonical path:"
    info "  from: $LEGACY_LIVE_ISO_SOURCE"
    info "  to:   $LIVE_ISO_SOURCE"
    mv "$LEGACY_LIVE_ISO_SOURCE" "$LIVE_ISO_SOURCE"
    ok "Canonical live-iso source path restored."
  elif [[ -e "$LEGACY_LIVE_ISO_SOURCE" ]]; then
    warn "Legacy path exists but is not a Git checkout and will be preserved: $LEGACY_LIVE_ISO_SOURCE"
  fi

  return 0
}

report_preserved_source_layout() {
  info "Source checkout layout:"
  info "  custom-image:          $(source_checkout_summary "$CUSTOM_IMAGE_SOURCE")"
  info "  live-iso:              $(source_checkout_summary "$LIVE_ISO_SOURCE")"
  info "  core-image:            $(source_checkout_summary "$CORE_IMAGE_SOURCE")"
  info "  desktop-image:         $(source_checkout_summary "$DESKTOP_IMAGE_SOURCE")"
  info "  qcom-firmware-updater: $(source_checkout_summary "$QCOM_UPDATER_DIR")"

  if [[ -e "$LEGACY_LIVE_ISO_SOURCE" ]]; then
    warn "Legacy source path remains present: $LEGACY_LIVE_ISO_SOURCE"
  fi

  # This is a reporting function. Optional absent source trees are normal and
  # must never become its return status under `set -e`.
  return 0
}

sync_repo() {
  local name="$1" url="$2" ref="$3" path="$4"
  mkdir -p "$(dirname "$path")"

  if [[ -e "$path" && ! -d "$path/.git" ]]; then
    if ! is_interactive; then die "$path exists but is not a Git repository."; fi
    local nongit
    nongit="$(menu "Non-Git Source Directory\n\n$name expects a Git checkout at:\n  $path" "2" \
      "1|Open a shell|Inspect or move the directory manually." \
      "2|Move it aside and clone clean|Rename with a timestamp suffix." \
      "3|Abort|Stop source handling.")"
    case "$nongit" in
      1) open_shell "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
      2) mv "$path" "${path}.non-git.$(date -u +%Y%m%d%H%M%S)" ;;
      3) die "Non-Git source directory encountered." ;;
    esac
  fi

  if [[ ! -d "$path/.git" ]]; then
    check_git_remote_access "$name" "$url"
    info "Cloning $name from $url into $path"
    git clone "$url" "$path"
    git -C "$path" config --local advice.detachedHead false
    checkout_requested_ref "$path" "$ref" 1
  else
    git config --global --add safe.directory "$path" >/dev/null 2>&1 || true
    local actual expected policy="$REPO_POLICY" choice
    actual="$(normalize_git_url "$(git -C "$path" remote get-url origin 2>/dev/null || true)")"
    expected="$(normalize_git_url "$url")"
    if [[ "$actual" != "$expected" ]]; then
      if ! is_interactive; then die "$name origin mismatch: expected $expected, found $actual"; fi
      choice="$(menu "Repository Origin Mismatch\n\n$name\nExpected: $expected\nActual:   $actual" "2" \
        "1|Use the existing origin for this run|Continue only after explicit operator acceptance." \
        "2|Re-clone from the configured official origin [RECOMMENDED]|Replace the checkout." \
        "3|Open a shell|Inspect remotes manually." \
        "4|Abort|Stop.")"
      case "$choice" in
        1) warn "Using nonconfigured origin for $name: $actual" ;;
        2) rm -rf "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
        3) open_shell "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
        4) die "Repository origin validation failed." ;;
      esac
    fi

    if [[ "$policy" == "prompt" ]]; then
      choice="$(repo_action_menu "$name" "$path" "$ref")"
      case "$choice" in
        1) policy=continue ;;
        2) policy=refresh ;;
        3) policy=reclone ;;
        4) open_shell "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
        5) die "Repository handling aborted." ;;
      esac
    fi

    case "$policy" in
      continue)
        [[ -z "$(git -C "$path" status --porcelain)" ]] || die "$name checkout is dirty under continue policy: $path"
        checkout_requested_ref "$path" "$ref" 0
        ;;
      refresh)
        check_git_remote_access "$name" "$url"
        [[ -z "$(git -C "$path" status --porcelain)" ]] || {
          if ! is_interactive; then die "$name checkout is dirty: $path"; fi
          choice="$(menu "Dirty Git Checkout\n\n$name contains local changes:\n  $path" "2" \
            "1|Open a shell and resolve manually|Return after commit, stash, or reset." \
            "2|Re-clone clean [RECOMMENDED]|Replace the dirty checkout." \
            "3|Abort|Preserve the checkout and stop.")"
          case "$choice" in
            1) open_shell "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
            2) rm -rf "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
            3) die "Dirty checkout preserved; build stopped." ;;
          esac
        }
        checkout_requested_ref "$path" "$ref" 1
        ;;
      reclone)
        rm -rf "$path"
        sync_repo "$name" "$url" "$ref" "$path"
        return
        ;;
      *) die "Unsupported repository policy: $policy" ;;
    esac
  fi

  local current_origin
  current_origin="$(normalize_git_url "$(git -C "$path" remote get-url origin)")"
  [[ "$current_origin" == "$(normalize_git_url "$url")" ]] || warn "$name is using accepted alternate origin: $current_origin"
  [[ -z "$(git -C "$path" status --porcelain)" ]] || die "$name checkout is not clean after synchronization."
  ok "$name validated: $(repo_state "$path")"
}

sync_required_repositories() {
  info "Beginning required official source synchronization."
  normalize_live_iso_source_path
  report_preserved_source_layout
  sync_repo "VanillaOS custom-image" "$CUSTOM_IMAGE_REPO_URL" "$CUSTOM_IMAGE_REF" "$CUSTOM_IMAGE_SOURCE"
  sync_repo "VanillaOS live-iso" "$LIVE_ISO_REPO_URL" "$LIVE_ISO_REF" "$LIVE_ISO_SOURCE"
  CUSTOM_SOURCE_COMMIT="$(git -C "$CUSTOM_IMAGE_SOURCE" rev-parse HEAD)"
  LIVE_SOURCE_COMMIT="$(git -C "$LIVE_ISO_SOURCE" rev-parse HEAD)"
  verify_required_source_checkouts
  return 0
}

# ------------------------- firmware staging ------------------------------

normalize_firmware_source_into_stage() {
  local src="$1"
  rm -rf "$STAGED_FIRMWARE_DIR"
  mkdir -p "$STAGED_FIRMWARE_DIR"

  if [[ "$(basename "$src")" == "qcom" ]]; then
    mkdir -p "$STAGED_FIRMWARE_DIR/qcom"
    rsync -aHAX "$src/" "$STAGED_FIRMWARE_DIR/qcom/"
  elif [[ -d "$src/usr/lib/firmware" ]]; then
    rsync -aHAX "$src/usr/lib/firmware/" "$STAGED_FIRMWARE_DIR/"
  elif [[ -d "$src/lib/firmware" ]]; then
    rsync -aHAX "$src/lib/firmware/" "$STAGED_FIRMWARE_DIR/"
  else
    rsync -aHAX "$src/" "$STAGED_FIRMWARE_DIR/"
  fi
}

qcom_network_argument() {
  case "${FIRMWARE_CONTAINER_NETWORK,,}" in
    host) printf '%s' '--network=host'; return ;;
    default|bridge) printf ''; return ;;
    skip) printf 'SKIP'; return ;;
  esac
  local choice
  choice="$(menu "Disposable Firmware Container Network\n\nTemporary package installation occurs only inside the extraction container." "1" \
    "1|Use host networking [RECOMMENDED]|Avoid common Podman container DNS failures." \
    "2|Use default container networking|Use when container DNS is already verified." \
    "3|Open a shell before continuing|Inspect container networking." \
    "4|Skip firmware extraction|Continue without firmware.")"
  case "$choice" in
    1) printf '%s' '--network=host' ;;
    2) printf '' ;;
    3) open_shell "$WORKDIR"; qcom_network_argument ;;
    4) printf 'SKIP' ;;
  esac
}

extract_qcom_firmware_isolated() {
  sync_repo "qcom-firmware-updater" "$QCOM_UPDATER_REPO_URL" "$QCOM_UPDATER_REF" "$QCOM_UPDATER_DIR"

  local work="$TMP_ROOT/qcom-extract"
  rm -rf "$work" "$STAGED_FIRMWARE_DIR"
  mkdir -p "$work/input" "$work/out" "$STAGED_FIRMWARE_DIR"

  if [[ "$FIRMWARE_MODE" == "archive" ]]; then
    cp -a "$FIRMWARE_ARCHIVE" "$work/input/$(basename "$FIRMWARE_ARCHIVE")"
  fi

  local runner="$work/run-qcom-extract.sh"
  cat > "$runner" <<'QCOM_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf 'qcom-container: %s\n' "$*"; }

getent hosts deb.debian.org >/dev/null 2>&1 || {
  log "DNS preflight failed for deb.debian.org"
  exit 70
}

apt-get update
if ! apt-get install -y --no-install-recommends \
  ca-certificates curl unzip msitools 7zip zstd rsync bash coreutils findutils file grep sed gawk; then
  apt-get install -y --no-install-recommends \
    ca-certificates curl unzip msitools p7zip-full zstd rsync bash coreutils findutils file grep sed gawk
fi
printf '#!/usr/bin/env bash\nexec "$@"\n' > /usr/local/bin/sudo
chmod 0755 /usr/local/bin/sudo

mkdir -p /out/lib/firmware /out/logs /work
cp -a /updater /work/qcom-firmware-updater
cd /work/qcom-firmware-updater

orig="$(cat ./qcom-firmware-updater.sh)"
orig="${orig%$'\n'}"
case "$orig" in
  *'main "$@"') orig="${orig%main \"\$@\"}" ;;
esac
printf '%s\n' "$orig" > /work/qcom-functions.sh
cat >> /work/qcom-functions.sh <<'CAPTURE_EOF'

capture_main() {
  parse_args "$@"
  check_deps
  if [[ -z "$DEVICE_PATH" ]]; then detect_device; else info "Using manual device path: $DEVICE_PATH"; fi
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
  local extract_root fw_staging dest
  extract_root=$(extract_exe "$input_path")
  fw_staging=$(find_firmware "$extract_root")
  dest="/out/lib/firmware/qcom/$DEVICE_PATH"
  mkdir -p "$dest"
  cp -a "$fw_staging"/. "$dest"/
  chmod -R a+rX /out/lib/firmware || true
  find "$dest" -type f | sort > /out/logs/captured-firmware-files.txt
  info "Captured $(find "$dest" -type f | wc -l) firmware file(s) into $dest"
}

capture_main "$@"
CAPTURE_EOF
chmod 0755 /work/qcom-functions.sh

if [[ -n "${QCOM_URL:-}" ]]; then
  bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" --url "$QCOM_URL" 2>&1 | tee /out/logs/qcom-capture.log
else
  input_file="$(find /input -maxdepth 1 -type f | sort | sed -n '1p')"
  [[ -n "$input_file" ]] || { log "No firmware archive supplied"; exit 71; }
  bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" "$input_file" 2>&1 | tee /out/logs/qcom-capture.log
fi
QCOM_RUNNER
  chmod 0755 "$runner"

  local net_arg runtime="$OCI_RUNTIME" rc
  net_arg="$(qcom_network_argument)"
  [[ "$net_arg" != "SKIP" ]] || { FIRMWARE_MODE=skip; return 0; }

  local -a cmd=("$runtime" run --rm --privileged)
  [[ -n "$net_arg" ]] && cmd+=("$net_arg")
  cmd+=(
    -e "QCOM_URL=${FIRMWARE_URL:-}"
    -e "QCOM_DEVICE_PATH=$QCOM_DEVICE_PATH"
    -v "$QCOM_UPDATER_DIR:/updater:ro"
    -v "$work/input:/input:ro"
    -v "$work/out:/out"
    -v "$runner:/run-qcom-extract.sh:ro"
    debian:13 /bin/bash /run-qcom-extract.sh
  )

  set +e
  "${cmd[@]}"
  rc=$?
  set -e

  if (( rc != 0 )); then
    warn "Isolated firmware extraction exited with status $rc."
    if ! is_interactive; then die "Firmware extraction failed."; fi
    local choice
    choice="$(menu "Firmware Extraction Failure\n\nWorkspace retained at:\n  $work" "2" \
      "1|Open a shell and inspect the workspace|Return after manual correction." \
      "2|Choose a pre-staged firmware directory [RECOMMENDED]|Use an already extracted tree." \
      "3|Continue without firmware|Skip firmware predicates." \
      "4|Abort|Stop the build.")"
    case "$choice" in
      1) open_shell "$work"; extract_qcom_firmware_isolated; return ;;
      2) FIRMWARE_MODE=prestaged; FIRMWARE_PRESTAGED="$(prompt_path "Pre-staged firmware directory" "$ARTIFACT_DIR/firmware")"; stage_firmware; return ;;
      3) FIRMWARE_MODE=skip; return ;;
      4) die "Firmware extraction failed." ;;
    esac
  fi

  if [[ -d "$work/out/lib/firmware" ]]; then
    normalize_firmware_source_into_stage "$work/out/lib/firmware"
  fi
}

stage_firmware() {
  case "${FIRMWARE_MODE,,}" in
    skip)
      rm -rf "$STAGED_FIRMWARE_DIR"
      mkdir -p "$STAGED_FIRMWARE_DIR"
      FIRMWARE_SOURCE=""
      warn "Continuing without staged Qualcomm firmware."
      return
      ;;
    prestaged)
      [[ -d "$FIRMWARE_PRESTAGED" ]] || die "Firmware source does not exist: $FIRMWARE_PRESTAGED"
      normalize_firmware_source_into_stage "$FIRMWARE_PRESTAGED"
      ;;
    archive|url)
      extract_qcom_firmware_isolated
      [[ "$FIRMWARE_MODE" == "skip" ]] && { FIRMWARE_SOURCE=""; return; }
      ;;
    *) die "Unsupported firmware mode: $FIRMWARE_MODE" ;;
  esac

  if ! find "$STAGED_FIRMWARE_DIR" -type f -print -quit | grep -q .; then
    die "Firmware mode '$FIRMWARE_MODE' produced no staged files under $STAGED_FIRMWARE_DIR."
  fi
  FIRMWARE_SOURCE="$STAGED_FIRMWARE_DIR"
  FIRMWARE_PROBE_REL="$(find "$FIRMWARE_SOURCE" -type f -printf '%P\n' | LC_ALL=C sort | sed -n '1p')"
  ok "Staged firmware root: $FIRMWARE_SOURCE"
  ok "Firmware probe: $FIRMWARE_PROBE_REL"
}

# ---------------------------- build plan --------------------------------

peek_next_release_id() {
  local current=0
  [[ -f "$BUILD_COUNTER_FILE" ]] && read -r current < "$BUILD_COUNTER_FILE" || true
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  printf 'r%04d' $((current + 1))
}

reserve_release_id() {
  local current=0
  [[ -f "$BUILD_COUNTER_FILE" ]] && read -r current < "$BUILD_COUNTER_FILE" || true
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  current=$((current + 1))
  printf '%s\n' "$current" > "$BUILD_COUNTER_FILE"
  printf 'r%04d' "$current"
}

print_plan() {
  local preview_id
  preview_id="$(peek_next_release_id)"
  cat <<EOF

Resolved v$SCRIPT_VERSION plan
--------------------
Work directory:             $WORKDIR
Profile:                    $PROFILE
Artifact directory:         $ARTIFACT_DIR
Kernel release:             $KERNEL_RELEASE
Supplied local .debs:       ${#KERNEL_DEBS[@]}
Target OCI install .debs:   ${#TARGET_KERNEL_DEBS[@]}
Target OCI excluded .debs:  ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}
Target OCI archived .debs:  ${#KERNEL_DEBS[@]}
Live boot .debs:            ${#LIVE_KERNEL_DEBS[@]}
DTB:                        $DTB_FILE
Firmware mode:              $FIRMWARE_MODE
Firmware source:            ${FIRMWARE_SOURCE:-to be staged during execution}
Target /root source:        ${ROOT_SOURCE:-none}
Repository policy:          $REPO_POLICY
Sources synchronized:       $SOURCES_SYNCHRONIZED
custom-image source:        $CUSTOM_IMAGE_REPO_URL @ $CUSTOM_IMAGE_REF
custom-image checkout:      $(repo_state "$CUSTOM_IMAGE_SOURCE")
live-iso source:            $LIVE_ISO_REPO_URL @ $LIVE_ISO_REF
live-iso checkout:          $(source_checkout_summary "$LIVE_ISO_SOURCE")
core-image retained:        $(source_checkout_summary "$CORE_IMAGE_SOURCE")
desktop-image retained:     $(source_checkout_summary "$DESKTOP_IMAGE_SOURCE")
qcom updater checkout:      $(source_checkout_summary "$QCOM_UPDATER_DIR")
Target OCI base:            $CUSTOM_IMAGE_BASE
Target OCI reference:       $TARGET_IMAGE_REF
ABRoot image name:          $ABROOT_IMAGE_NAME
Push target OCI:            $PUSH_TARGET_IMAGE
Pico image:                 $LIVE_ISO_CONTAINER_IMAGE
Requested Vib version:      $VIB_VERSION
FsGuard plugin request:     $FSGUARD_PLUGIN_REPO @ $FSGUARD_PLUGIN_VERSION
Expected release ID:        $preview_id
Minimum graphical packages: $MIN_GRAPHICAL_PACKAGE_COUNT

Safety invariants:
  - No host initramfs implementation is installed or replaced.
  - dpkg-deb archive listings complete before any grep validation.
  - Only named boot packages or packages with regular kernel/module objects
    enter target or live package transactions.
  - /lib/modules/<release>/build and source symlinks never qualify as modules.
  - Optional tools, headers, development, and metadata .debs are reference-only.
  - Official live package lists are never edited.
  - The pristine upstream graphical manifest is accepted before remastering.
  - Final filesystem.packages and filesystem.packages-remove are byte-identical
    to the pristine upstream ISO.
  - Only boot-critical hardware payload is added to the live filesystem.

Exact non-interactive execute command:
  sudo WORKDIR=$(printf '%q' "$WORKDIR") PROFILE=$(printf '%q' "$PROFILE") \\
    ARTIFACT_DIR=$(printf '%q' "$ARTIFACT_DIR") ROOT_SOURCE=$(printf '%q' "$ROOT_SOURCE") \\
    FIRMWARE_MODE=$(printf '%q' "$FIRMWARE_MODE") FIRMWARE_PRESTAGED=$(printf '%q' "$FIRMWARE_PRESTAGED") \\
    REPO_POLICY=$(printf '%q' "$REPO_POLICY") TARGET_IMAGE_REF=$(printf '%q' "$TARGET_IMAGE_REF") \\
    ABROOT_IMAGE_NAME=$(printf '%q' "$ABROOT_IMAGE_NAME") \\
    $0 --execute --non-interactive
EOF
}

prepare_custom_image_worktree() {
  rm -rf "$CUSTOM_PROJECT"
  git -C "$CUSTOM_IMAGE_SOURCE" worktree add --detach "$CUSTOM_PROJECT" "$CUSTOM_SOURCE_COMMIT"
  [[ -f "$CUSTOM_PROJECT/recipe.yml" ]] || die "Official custom-image worktree is incomplete."
  ok "Clean custom-image worktree prepared at commit $CUSTOM_SOURCE_COMMIT."
}

# ---------------------------- Vib tooling --------------------------------

host_arch() {
  case "$(uname -m)" in
    aarch64|arm64) printf arm64 ;;
    x86_64|amd64) printf amd64 ;;
    *) die "Unsupported host architecture for Vib: $(uname -m)" ;;
  esac
}

normalize_version_tag() {
  local version="$1"
  [[ "$version" == v* ]] && printf '%s' "$version" || printf 'v%s' "$version"
}

version_ge() {
  local actual="$1" required="$2"
  [[ -n "$actual" && -n "$required" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | sed -n '1p')" == "$required" ]]
}

download_atomic() {
  local url="$1" destination="$2"
  local partial="${destination}.partial"
  mkdir -p "$(dirname "$destination")"
  rm -f "$partial"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 \
    "$url" -o "$partial"
  [[ -s "$partial" ]] || die "Downloaded file is empty: $url"
  mv -f "$partial" "$destination"
}

github_api_curl() {
  local -a args=(
    -fsSL
    --retry 3
    --retry-delay 2
    --connect-timeout 30
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  [[ -n "${GITHUB_TOKEN:-}" ]] && \
    args+=( -H "Authorization: Bearer $GITHUB_TOKEN" )
  curl "${args[@]}" "$@"
}

resolve_fsguard_release_asset() {
  local arch="$1"
  local asset_name="fsguard-$arch.so"
  local metadata selection available
  local requested="${FSGUARD_PLUGIN_VERSION}"

  if [[ "${requested,,}" == "auto" || "${requested,,}" == "latest-compatible" ]]; then
    metadata="$TMP_ROOT/vib-fsguard-releases.json"
    info "Querying $FSGUARD_PLUGIN_REPO releases for newest asset: $asset_name"
    github_api_curl \
      "https://api.github.com/repos/$FSGUARD_PLUGIN_REPO/releases?per_page=100" \
      -o "$metadata" || die "Unable to query FsGuard release metadata."

    selection="$(
      jq -r --arg asset "$asset_name" '
        [
          .[]
          | select(.draft == false)
          | select(.prerelease == false)
          | . as $release
          | $release.assets[]?
          | select(.name == $asset)
          | [$release.tag_name, .browser_download_url]
        ][0] // empty
        | @tsv
      ' "$metadata"
    )"
  else
    local tag
    tag="$(normalize_version_tag "$requested")"
    metadata="$TMP_ROOT/vib-fsguard-release-${tag}.json"
    info "Querying $FSGUARD_PLUGIN_REPO release $tag for asset: $asset_name"
    github_api_curl \
      "https://api.github.com/repos/$FSGUARD_PLUGIN_REPO/releases/tags/$tag" \
      -o "$metadata" || die "Unable to query FsGuard release metadata for $tag."

    selection="$(
      jq -r --arg asset "$asset_name" '
        . as $release
        | [
            $release.assets[]?
            | select(.name == $asset)
            | [$release.tag_name, .browser_download_url]
          ][0] // empty
        | @tsv
      ' "$metadata"
    )"
  fi

  if [[ -z "$selection" ]]; then
    available="$(
      jq -r '
        if type == "array" then
          .[] | .tag_name as $tag | .assets[]? | "\($tag):\(.name)"
        else
          .tag_name as $tag | .assets[]? | "\($tag):\(.name)"
        end
      ' "$metadata" | sed -n '1,80p'
    )"
    fail "No exact FsGuard release asset was found for architecture $arch: $asset_name"
    fail "Requested selector: $requested"
    if [[ -n "$available" ]]; then
      fail "Available release assets examined:"
      printf '%s\n' "$available" >&2
    fi
    return 1
  fi

  FSGUARD_PLUGIN_RESOLVED_TAG="${selection%%$'\t'*}"
  FSGUARD_PLUGIN_ASSET_URL="${selection#*$'\t'}"
  FSGUARD_PLUGIN_RELEASE_METADATA="$metadata"

  [[ -n "$FSGUARD_PLUGIN_RESOLVED_TAG" ]] || return 1
  [[ -n "$FSGUARD_PLUGIN_ASSET_URL" ]] || return 1

  ok "Resolved FsGuard plugin: $FSGUARD_PLUGIN_REPO $FSGUARD_PLUGIN_RESOLVED_TAG / $asset_name"
}

vib_exec() {
  # Vib requires sudo identity variables whenever it detects uid 0. Direct root
  # shells do not provide them, so use a deterministic build-only root context.
  local vib_home="/home/root"
  local vib_cache="$CACHE_DIR/vib-root"
  [[ "$(id -u)" -eq 0 ]] && mkdir -p "$vib_home"
  mkdir -p "$vib_cache"

  env \
    SUDO_UID=0 \
    SUDO_GID=0 \
    SUDO_USER=root \
    HOME="$vib_home" \
    XDG_CACHE_HOME="$vib_cache" \
    "$VIB_BIN" "$@"
}

probe_vib_binary() {
  local output rc detected
  set +e
  output="$(vib_exec --version 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    warn "Vib preflight failed with exit status $rc: $VIB_BIN"
    [[ -n "$output" ]] && warn "$output" || warn "Vib produced no diagnostic output."
    return 1
  fi

  detected="$(printf '%s\n' "$output" | grep -Eo '[0-9]+(\.[0-9]+){2}' | sed -n '1p' || true)"
  [[ -n "$detected" ]] || {
    warn "Unable to parse a semantic version from Vib output: ${output:-<empty>}"
    return 1
  }

  version_ge "$detected" "1.0.7" || {
    warn "Selected Vib version $detected is older than recipe requirement 1.0.7."
    return 1
  }

  VIB_DETECTED_VERSION="$detected"
  info "Vib version output: $output"
  ok "Vib preflight passed with normalized root execution context."
}

download_builder_local_vib() {
  local arch="$1" tag
  tag="$(normalize_version_tag "$VIB_VERSION")"
  VIB_BIN="$WORKDIR/tools/vib"
  mkdir -p "$(dirname "$VIB_BIN")"
  info "Downloading Vib $tag for $arch to $VIB_BIN"
  download_atomic \
    "https://github.com/Vanilla-OS/Vib/releases/download/$tag/vib-$arch" \
    "$VIB_BIN"
  chmod 0755 "$VIB_BIN"
}

verify_plugin_elf_architecture() {
  local plugin="$1" arch="$2" description
  [[ -s "$plugin" ]] || die "Required Vib plugin is absent or empty: $plugin"

  description="$(file -b "$plugin")"
  printf '%s\n' "$description" | grep -Fq 'ELF 64-bit' || \
    die "Vib plugin is not a 64-bit ELF object: $plugin ($description)"
  printf '%s\n' "$description" | grep -Fq 'shared object' || \
    die "Vib plugin is not an ELF shared object: $plugin ($description)"

  case "$arch" in
    arm64)
      printf '%s\n' "$description" | grep -Eq 'ARM aarch64|ARM64|AArch64' || \
        die "Vib plugin architecture mismatch; expected arm64: $plugin ($description)"
      ;;
    amd64)
      printf '%s\n' "$description" | grep -Eq 'x86-64|x86_64|AMD x86-64' || \
        die "Vib plugin architecture mismatch; expected amd64: $plugin ($description)"
      ;;
    *) die "Unsupported Vib plugin architecture: $arch" ;;
  esac
}

install_core_vib_plugins() {
  # Official Vib release archives contain build/plugins. Official vib-gh-action
  # extracts the archive and moves build/plugins to project-local plugins.
  local arch="$1" tag archive extract_root source_dir plugin_dir
  tag="$(normalize_version_tag "$VIB_DETECTED_VERSION")"
  archive="$CACHE_DIR/vib-$tag-plugins-$arch.tar.gz"
  extract_root="$TMP_ROOT/vib-core-plugins-extract"
  source_dir="$extract_root/build/plugins"
  plugin_dir="$CUSTOM_PROJECT/plugins"

  if [[ ! -s "$archive" ]]; then
    info "Downloading Vib core plugin bundle $tag for $arch."
    download_atomic \
      "https://github.com/Vanilla-OS/Vib/releases/download/$tag/plugins-$arch.tar.gz" \
      "$archive"
  else
    info "Using cached Vib core plugin bundle: $archive"
  fi

  tar -tzf "$archive" > "$TMP_ROOT/vib-core-plugin-archive.inventory"
  grep -Eq '^build/plugins/' "$TMP_ROOT/vib-core-plugin-archive.inventory" || \
    die "Unexpected Vib core plugin archive layout: $archive"

  rm -rf "$extract_root" "$plugin_dir"
  mkdir -p "$extract_root" "$plugin_dir"
  tar -xzf "$archive" -C "$extract_root"

  [[ -d "$source_dir" ]] || die "Core plugin extraction did not produce $source_dir"
  find "$source_dir" -maxdepth 1 -type f -name '*.so' -print -quit | grep -q . || \
    die "Core Vib plugin bundle contains no shared objects."

  rsync -a "$source_dir/" "$plugin_dir/"
  ok "Installed Vib core plugins from $tag."
}

install_fsguard_vib_plugin() {
  # FsGuard is external to the core Vib plugin archive. Resolve an exact
  # architecture-specific release asset from GitHub metadata and install it
  # under the module loader name plugins/fsguard.so.
  local arch="$1"
  local asset_name cached_asset plugin_dir final_plugin cache_tag

  resolve_fsguard_release_asset "$arch" || \
    die "Unable to resolve a compatible FsGuard Vib plugin."

  asset_name="fsguard-$arch.so"
  cache_tag="${FSGUARD_PLUGIN_RESOLVED_TAG//\//-}"
  cached_asset="$CACHE_DIR/vib-fsguard-$cache_tag-$arch.so"
  plugin_dir="$CUSTOM_PROJECT/plugins"
  final_plugin="$plugin_dir/fsguard.so"

  if [[ ! -s "$cached_asset" ]]; then
    info "Downloading external FsGuard plugin $FSGUARD_PLUGIN_RESOLVED_TAG for $arch."
    download_atomic "$FSGUARD_PLUGIN_ASSET_URL" "$cached_asset"
  else
    info "Using cached external FsGuard plugin: $cached_asset"
  fi

  verify_plugin_elf_architecture "$cached_asset" "$arch"
  install -m 0644 "$cached_asset" "$final_plugin"
  verify_plugin_elf_architecture "$final_plugin" "$arch"

  FSGUARD_PLUGIN_FILE="$final_plugin"
  ok "Installed FsGuard plugin with exact Vib loader name: $final_plugin"
}


verify_vib_plugin_set() {
  local arch="$1" plugin_dir="$CUSTOM_PROJECT/plugins"
  local inventory="$TMP_ROOT/vib-plugin-inventory.txt"
  local count

  [[ -s "$plugin_dir/fsguard.so" ]] || \
    die "Required external Vib plugin is absent: $plugin_dir/fsguard.so"
  verify_plugin_elf_architecture "$plugin_dir/fsguard.so" "$arch"

  find "$plugin_dir" -maxdepth 1 -type f -name '*.so' \
    -printf '%f\t%s bytes\n' | LC_ALL=C sort > "$inventory"
  count="$(wc -l < "$inventory" | tr -d '[:space:]')"
  [[ "$count" =~ ^[0-9]+$ ]] || die "Unable to count installed Vib plugins."
  (( count > 0 )) || die "No Vib plugins were installed."

  sha256sum "$plugin_dir"/*.so > "$TMP_ROOT/vib-plugin-checksums.sha256"
  ok "Validated $count project-local Vib plugin shared object(s)."
  info "Required plugin present: $plugin_dir/fsguard.so"
}

capture_vib_diagnostics() {
  local reason="$1"
  local diag="$LOG_DIR/${SESSION_ID}-vib-diagnostics"
  mkdir -p "$diag"

  printf '%s\n' "$reason" > "$diag/FAILURE.txt"
  printf '%s\n' "$VIB_BIN" > "$diag/vib-executable.path"
  file "$VIB_BIN" > "$diag/vib-executable.file" 2>&1 || true
  sha256sum "$VIB_BIN" > "$diag/vib-executable.sha256" 2>/dev/null || true

  set +e
  vib_exec --version > "$diag/vib-version.txt" 2>&1
  printf '%s\n' "$?" > "$diag/vib-version.exit-status"
  set -e

  for f in \
    "$CUSTOM_PROJECT/recipe.yml" \
    "$CUSTOM_PROJECT/Containerfile" \
    "$CUSTOM_PROJECT/CONCEPTION-INPUTS.txt" \
    "$TMP_ROOT/vib-core-plugin-archive.inventory" \
    "$TMP_ROOT/vib-plugin-inventory.txt" \
    "$TMP_ROOT/vib-plugin-checksums.sha256" \
    "$FSGUARD_PLUGIN_RELEASE_METADATA"
  do
    [[ -f "$f" ]] && cp -a "$f" "$diag/"
  done

  if [[ -d "$CUSTOM_PROJECT/modules" ]]; then
    mkdir -p "$diag/modules"
    cp -a "$CUSTOM_PROJECT/modules/." "$diag/modules/"
  fi
  if [[ -d "$CUSTOM_PROJECT/plugins" ]]; then
    mkdir -p "$diag/plugins"
    cp -a "$CUSTOM_PROJECT/plugins/." "$diag/plugins/"
    find "$CUSTOM_PROJECT/plugins" -printf '%M %u:%g %s %p\n' \
      > "$diag/plugin-filesystem-inventory.txt" 2>&1 || true
  fi

  (
    printf 'uid=%s gid=%s user=%s\n' "$(id -u)" "$(id -g)" "$(id -un)"
    printf 'SUDO_UID=%q\n' "${SUDO_UID:-}"
    printf 'SUDO_GID=%q\n' "${SUDO_GID:-}"
    printf 'SUDO_USER=%q\n' "${SUDO_USER:-}"
    printf 'PWD=%q\n' "$PWD"
    printf 'CUSTOM_PROJECT=%q\n' "$CUSTOM_PROJECT"
    printf 'SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'VIB_DETECTED_VERSION=%q\n' "$VIB_DETECTED_VERSION"
    printf 'FSGUARD_PLUGIN_REPO=%q\n' "$FSGUARD_PLUGIN_REPO"
    printf 'FSGUARD_PLUGIN_VERSION=%q\n' "$FSGUARD_PLUGIN_VERSION"
    printf 'FSGUARD_PLUGIN_RESOLVED_TAG=%q\n' "$FSGUARD_PLUGIN_RESOLVED_TAG"
    printf 'FSGUARD_PLUGIN_ASSET_URL=%q\n' "$FSGUARD_PLUGIN_ASSET_URL"
    printf 'FSGUARD_PLUGIN_FILE=%q\n' "$FSGUARD_PLUGIN_FILE"
  ) > "$diag/execution-context.txt"

  warn "Vib diagnostic bundle retained at: $diag"
}

run_logged_vib() {
  local name="$1"; shift
  local rc
  CURRENT_LOG="$LOG_DIR/${SESSION_ID}-${name}.log"
  mkdir -p "$LOG_DIR"
  info "Log: $CURRENT_LOG"

  set +e
  vib_exec "$@" 2>&1 | tee "$CURRENT_LOG"
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc != 0 )); then
    [[ -s "$CURRENT_LOG" ]] || {
      fail "Vib exited with status $rc and produced no output."
      fail "This is consistent with failure before Cobra command execution."
    }
    capture_vib_diagnostics "Vib command failed: $*; exit status: $rc"
    return "$rc"
  fi
}

install_vib_and_plugins() {
  local arch choice selected_system=0
  arch="$(host_arch)"

  if command_exists vib && [[ ! -x "$VIB_BIN" ]]; then
    if is_interactive; then
      choice="$(menu "Vib Executable Selection\n\nSystem Vib detected:\n  $(command -v vib)\nBuilder-local default:\n  $WORKDIR/tools/vib\n\nThe selected binary and exact plugin set are validated before recipe generation." "1" \
        "1|Use and validate the existing system Vib|Use its exact detected version for the matching core plugin bundle." \
        "2|Download the official pinned builder-local Vib|Use version $(normalize_version_tag "$VIB_VERSION")." \
        "3|Open a shell|Inspect Vib and plugin versions manually." \
        "4|Abort|Stop.")"
      case "$choice" in
        1) VIB_BIN="$(command -v vib)"; selected_system=1 ;;
        2) VIB_BIN="$WORKDIR/tools/vib" ;;
        3) open_shell "$WORKDIR"; install_vib_and_plugins; return ;;
        4) die "Vib selection aborted." ;;
      esac
    else
      VIB_BIN="$(command -v vib)"
      selected_system=1
    fi
  fi

  [[ -n "$VIB_BIN" ]] || VIB_BIN="$WORKDIR/tools/vib"
  [[ -x "$VIB_BIN" ]] || download_builder_local_vib "$arch"

  if ! probe_vib_binary; then
    if (( selected_system == 1 )); then
      if is_interactive; then
        choice="$(menu "System Vib Validation Failed\n\nThe existing system Vib could not pass the normalized version preflight." "1" \
          "1|Download pinned builder-local Vib [RECOMMENDED]|Use official Vib $(normalize_version_tag "$VIB_VERSION")." \
          "2|Open a shell|Inspect the system Vib manually." \
          "3|Abort|Stop.")"
        case "$choice" in
          1) download_builder_local_vib "$arch" ;;
          2) open_shell "$WORKDIR"; install_vib_and_plugins; return ;;
          3) die "Vib validation failed." ;;
        esac
      else
        warn "System Vib validation failed; switching to pinned builder-local Vib."
        download_builder_local_vib "$arch"
      fi
      probe_vib_binary || die "Builder-local Vib failed validation."
    else
      die "Selected Vib executable failed validation: $VIB_BIN"
    fi
  fi

  install_core_vib_plugins "$arch"
  install_fsguard_vib_plugin "$arch"
  verify_vib_plugin_set "$arch"

  ok "Vib executable: $VIB_BIN"
  ok "Vib detected version: $VIB_DETECTED_VERSION"
  ok "Vib execution identity: uid=0 gid=0 user=root through normalized SUDO_* context"
  ok "Project-local Vib plugins: $CUSTOM_PROJECT/plugins"
  ok "FsGuard plugin: $FSGUARD_PLUGIN_REPO @ $FSGUARD_PLUGIN_RESOLVED_TAG"
}

# ------------------------ custom target OCI ------------------------------

prepare_custom_image_project() {
  [[ -e "$CUSTOM_PROJECT/.git" ]] || die "custom-image checkout is unavailable: $CUSTOM_PROJECT"
  [[ -f "$CUSTOM_PROJECT/modules/80-set-image-abroot-config.yml" ]] || \
    die "Official custom-image ABRoot module is missing."

  rm -rf \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/root" \
    "$CUSTOM_PROJECT/includes.container/image-info"

  mkdir -p \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/root" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/includes.container/usr/local/sbin" \
    "$CUSTOM_PROJECT/modules"

  local deb class pkg listing
  for deb in "${TARGET_KERNEL_DEBS[@]}"; do
    class="$(classify_kernel_deb_for_target "$deb")"
    pkg="$(package_field "$deb" Package)"
    listing="$TMP_ROOT/deb-listings/$(basename "$deb").contents.txt"

    case "$class" in
      headers|tools|development|metadata)
        die "Refusing to stage non-runtime target package: $pkg ($class)"
        ;;
    esac

    case "$class" in
      boot)
        ;;
      other)
        if ! deb_listing_has_regular_boot_kernel "$listing" "$KERNEL_RELEASE" &&
           ! deb_listing_has_runtime_module_object "$listing" "$KERNEL_RELEASE"; then
          die "Unrecognized selected package lacks a regular boot payload: $pkg"
        fi
        ;;
    esac

    cp -a "$deb" "$CUSTOM_PROJECT/includes.container/deb-pkgs/"
  done

  # Assert the staged transaction itself contains no known non-runtime package.
  for deb in "$CUSTOM_PROJECT/includes.container/deb-pkgs/"*.deb; do
    class="$(classify_kernel_deb_for_target "$deb")"
    pkg="$(package_field "$deb" Package)"
    case "$class" in
      headers|tools|development|metadata)
        die "Staged target transaction contains forbidden package: $pkg ($class)"
        ;;
    esac
  done

  if [[ -n "$FIRMWARE_SOURCE" ]]; then
    rsync -aHAX "$FIRMWARE_SOURCE/" "$CUSTOM_PROJECT/includes.container/usr/lib/firmware/"
  fi
  cp -a "$DTB_FILE" "$CUSTOM_PROJECT/includes.container/boot/dtbs/$DTB_NAME"

  if [[ -n "$ROOT_SOURCE" ]]; then
    rsync -aHAX "$ROOT_SOURCE/" "$CUSTOM_PROJECT/includes.container/root/"
    ROOT_PROBE_REL="$(find "$ROOT_SOURCE" -type f -printf '%P\n' | LC_ALL=C sort | sed -n '1p' || true)"
  else
    ROOT_PROBE_REL=""
  fi

  # Preserve every supplied package without forcing optional build artifacts
  # into the immutable runtime package transaction.
  mkdir -p "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages"
  for deb in "${KERNEL_DEBS[@]}"; do
    cp -a "$deb" "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages/"
  done
  cp -a "$TMP_ROOT/kernel-package-selection.tsv" \
    "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages/PACKAGE-SELECTION.tsv"
  cat > "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages/README.txt" <<'PACKAGE_ARCHIVE_README'
These Debian packages are retained as build and diagnostic artifacts.

Only packages marked target_install=yes in PACKAGE-SELECTION.tsv were installed
into the immutable target image. Headers, development packages, build metadata,
and optional tools remain archived here so they cannot introduce unavailable
runtime dependencies such as linux-tools-common.
PACKAGE_ARCHIVE_README

  printf '%s' "$CUSTOM_IMAGE_BASE" > "$CUSTOM_PROJECT/includes.container/image-info/base-image-name"
  printf '%s' "$ABROOT_IMAGE_NAME" > "$CUSTOM_PROJECT/includes.container/image-info/image-name"

  cat > "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh" <<'INSTALL_DEBS_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob
packages=(/deb-pkgs/*.deb)
((${#packages[@]} > 0)) || { echo "No local hardware .deb packages were included" >&2; exit 1; }
apt-get update
# Only the boot-critical image/module closure is staged here. Optional headers,
# tools, development packages, and metadata are archived under
# /root/custom-kernel-packages and never enter this APT transaction.
printf 'Installing selected boot-critical local packages:\n'
printf '  %s\n' "${packages[@]}"
apt-get install -y "${packages[@]}"
INSTALL_DEBS_EOF
  chmod 0755 "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh"

  cat > "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-hardware-finalize" <<EOF_FINALIZE
#!/usr/bin/env bash
set -Eeuo pipefail
release='$KERNEL_RELEASE'
dtb='$DTB_NAME'
firmware_probe='$FIRMWARE_PROBE_REL'

test -s "/boot/vmlinuz-\$release"
test -d "/usr/lib/modules/\$release" || test -d "/lib/modules/\$release"
test -s "/boot/dtbs/\$dtb"

command -v depmod >/dev/null 2>&1 && depmod -a "\$release"
if [[ ! -e "/boot/initrd.img-\$release" ]]; then
  touch "/boot/initrd.img-\$release"
fi
ln -sfn "boot/vmlinuz-\$release" /vmlinuz
ln -sfn "boot/initrd.img-\$release" /initrd.img
printf '%s\n' "\$release" > /usr/lib/conception-kernel-release
printf '%s\n' "\$dtb" > /usr/lib/conception-dtb
if [[ -n "\$firmware_probe" ]]; then
  test -s "/usr/lib/firmware/\$firmware_probe" || test -s "/lib/firmware/\$firmware_probe"
fi
EOF_FINALIZE
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-hardware-finalize"

  cat > "$CUSTOM_PROJECT/modules/50-install-hardware-debs.yml" <<'MODULE_DEBS_EOF'
name: install-hardware-debs
type: shell
commands:
  - bash /deb-pkgs/install-debs.sh
  - rm -rf /deb-pkgs
MODULE_DEBS_EOF

  cat > "$CUSTOM_PROJECT/modules/60-select-hardware-kernel.yml" <<'MODULE_HW_EOF'
name: select-hardware-kernel
type: shell
commands:
  - /usr/local/sbin/conception-hardware-finalize
MODULE_HW_EOF

  cat > "$CUSTOM_PROJECT/recipe.yml" <<EOF_RECIPE
name: Conception VanillaOS Desktop for $PROFILE
id: conception-$PROFILE
vibversion: 1.0.7

stages:
  - id: build
    base: $CUSTOM_IMAGE_BASE
    addincludes: true
    singlelayer: false
    labels:
      maintainer: Conception
      conception.profile: $PROFILE
      conception.kernel: $KERNEL_RELEASE
      conception.dtb: $DTB_NAME
    args:
      DEBIAN_FRONTEND: noninteractive
    runs:
      commands:
        - echo 'APT::Install-Recommends "1";' > /etc/apt/apt.conf.d/01conception-recommends
    modules:
      - name: init-setup
        type: shell
        commands:
          - lpkg --unlock
          - apt-get update

      - name: hardware-modules
        type: includes
        includes:
          - modules/50-install-hardware-debs.yml
          - modules/60-select-hardware-kernel.yml

      - name: set-image-name-abroot
        type: includes
        includes:
          - modules/80-set-image-abroot-config.yml

      - name: cleanup
        type: shell
        commands:
          - apt-get autoremove -y
          - apt-get clean
          - lpkg --lock

      - name: fsguard
        type: fsguard
        CustomFsGuard: false
        FsGuardLocation: "/usr/sbin/FsGuard"
        GenerateKey: true
        FilelistPaths: ["/usr/bin"]
        modules:
          - name: remove-prev-fsguard
            type: shell
            commands:
              - rm -rf /FsGuard
              - rm -f ./minisign.pub ./minisign.key
              - chmod +x /usr/sbin/init

      - name: cleanup2
        type: shell
        commands:
          - rm -rf /tmp/*
          - rm -rf /var/tmp/*
EOF_RECIPE

  cat > "$CUSTOM_PROJECT/CONCEPTION-INPUTS.txt" <<EOF_INPUTS
Kernel packages discovered from:
  $ARTIFACT_DIR/kernel-debs/
  Compatibility fallback: $ARTIFACT_DIR/*.deb

Package handling:
  Supplied:          ${#KERNEL_DEBS[@]}
  Target installed: ${#TARGET_KERNEL_DEBS[@]} boot-critical image/module packages
  Target excluded:  ${#TARGET_EXCLUDED_KERNEL_DEBS[@]} optional/reference packages
  Target archived:  all supplied packages under /root/custom-kernel-packages
  Selection record: /root/custom-kernel-packages/PACKAGE-SELECTION.tsv

Selected release:
  $KERNEL_RELEASE

Selected DTB:
  $DTB_FILE

Firmware source copied as paths relative to /usr/lib/firmware:
  ${FIRMWARE_SOURCE:-none}

Target /root overlay:
  ${ROOT_SOURCE:-none}

ABRoot image name:
  $ABROOT_IMAGE_NAME

Build/push reference:
  $TARGET_IMAGE_REF
EOF_INPUTS

  ok "Prepared official custom-image-derived Vib project: $CUSTOM_PROJECT"
}

build_target_oci() {
  pushd "$CUSTOM_PROJECT" >/dev/null
  if ! run_logged_vib "vib-generate-containerfile" build recipe.yml; then
    die "Vib failed to generate Containerfile. Review the retained diagnostic bundle."
  fi
  [[ -s Containerfile ]] || {
    capture_vib_diagnostics "Vib returned success but did not generate Containerfile."
    die "Vib did not generate Containerfile."
  }

  local -a build_cmd=("$OCI_RUNTIME" build --pull=always --tag "$TARGET_IMAGE_REF" --file Containerfile)
  [[ -n "$OCI_BUILD_NETWORK" ]] && build_cmd+=(--network "$OCI_BUILD_NETWORK")
  build_cmd+=(.)
  run_logged "build-target-oci" "${build_cmd[@]}"
  popd >/dev/null

  "$OCI_RUNTIME" image inspect "$TARGET_IMAGE_REF" >/dev/null
  verify_target_oci

  if [[ "$PUSH_TARGET_IMAGE" == "1" ]]; then
    run_logged "push-target-oci" "$OCI_RUNTIME" push "$TARGET_IMAGE_REF"
  elif [[ "$TARGET_IMAGE_REF" == localhost/* ]]; then
    warn "The target OCI reference is local-only. The graphical installer cannot pull it from another environment."
  fi
}

verify_target_oci() {
  local verify_script="$TMP_ROOT/verify-target-oci.sh"
  local expected_packages="$TMP_ROOT/target-installed-package-names.txt"
  local deb pkg
  : > "$expected_packages"
  for deb in "${TARGET_KERNEL_DEBS[@]}"; do
    pkg="$(package_field "$deb" Package)"
    printf '%s\n' "$pkg" >> "$expected_packages"
  done
  LC_ALL=C sort -u -o "$expected_packages" "$expected_packages"

  cat > "$verify_script" <<'VERIFY_OCI_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
release="$1"
dtb="$2"
abroot_name="$3"
firmware_probe="$4"
root_probe="$5"
expected_archive_count="$6"
expected_package_file="$7"

test -s "/boot/vmlinuz-$release"
test -d "/usr/lib/modules/$release" || test -d "/lib/modules/$release"
test -e "/boot/initrd.img-$release"
test "$(readlink -f /vmlinuz)" = "/boot/vmlinuz-$release"
test "$(readlink -f /initrd.img)" = "/boot/initrd.img-$release"
test -s "/boot/dtbs/$dtb"
grep -Fxq "$release" /usr/lib/conception-kernel-release
grep -Fxq "$dtb" /usr/lib/conception-dtb
grep -Fq "$abroot_name" /usr/share/abroot/abroot.json
# Protect the desktop layer from unintended local-package dependency removals.
dpkg-query -W gnome-shell mutter gdm3 network-manager >/dev/null
command -v gnome-shell >/dev/null
command -v NetworkManager >/dev/null

while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  dpkg-query -W -f='${Status}\n' "$package" | grep -Fxq 'install ok installed'
done < "$expected_package_file"

test -s /root/custom-kernel-packages/PACKAGE-SELECTION.tsv
test -s /root/custom-kernel-packages/README.txt
actual_archive_count="$(find /root/custom-kernel-packages -maxdepth 1 -type f -name '*.deb' | wc -l)"
test "$actual_archive_count" -eq "$expected_archive_count"

if [[ -n "$firmware_probe" ]]; then
  test -s "/usr/lib/firmware/$firmware_probe" || test -s "/lib/firmware/$firmware_probe"
fi
if [[ -n "$root_probe" ]]; then
  test -e "/root/$root_probe"
fi
VERIFY_OCI_EOF
  chmod 0755 "$verify_script"

  run_logged "verify-target-oci" "$OCI_RUNTIME" run --rm \
    -v "$verify_script:/verify-target-oci.sh:ro" \
    -v "$expected_packages:/expected-target-packages.txt:ro" \
    --entrypoint /bin/bash "$TARGET_IMAGE_REF" \
    /verify-target-oci.sh "$KERNEL_RELEASE" "$DTB_NAME" "$ABROOT_IMAGE_NAME" \
    "$FIRMWARE_PROBE_REL" "$ROOT_PROBE_REL" "${#KERNEL_DEBS[@]}" \
    /expected-target-packages.txt
  ok "Target OCI verification passed."
}

# --------------------------- live ISO build ------------------------------

prepare_pristine_live_worktree() {
  rm -rf "$LIVE_BUILD_DIR"
  git -C "$LIVE_ISO_SOURCE" worktree add --detach "$LIVE_BUILD_DIR" "$LIVE_SOURCE_COMMIT"

  local conf="$LIVE_BUILD_DIR/etc/terraform.conf"
  local build="$LIVE_BUILD_DIR/build.sh"
  [[ -f "$conf" && -f "$build" ]] || die "Official live-iso build inputs are missing."

  (
    cd "$LIVE_BUILD_DIR"
    find etc/config -type f \
      \( -path '*/package-lists*/*' -o -name '*.list.chroot' -o -name '*.list.binary' \) \
      -print0 | sort -z | xargs -0 sha256sum
  ) > "$TMP_ROOT/upstream-package-lists.before.sha256"

  sed -i -E 's/^ARCH=.*/ARCH="arm64"/' "$conf"
  grep -q '^ARCH="arm64"$' "$conf" || die "Unable to select ARM64 in terraform.conf."

  # The official orchid build script may still hard-code only the final AMD64
  # source path. This replacement happens after lb build and cannot alter the
  # package closure or live filesystem content.
  if grep -Fq 'tmp/amd64/live-image-amd64.hybrid.iso' "$build"; then
    sed -i 's#tmp/amd64/live-image-amd64\.hybrid\.iso#tmp/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso#' "$build"
  fi

  local changed unexpected
  changed="$(git -C "$LIVE_BUILD_DIR" diff --name-only)"
  unexpected="$(printf '%s\n' "$changed" | grep -Ev '^(build\.sh|etc/terraform\.conf)$' || true)"
  [[ -z "$unexpected" ]] || die "Refusing live-iso source modifications outside build.sh and terraform.conf: $unexpected"
  ok "Pristine live-iso worktree prepared at commit $LIVE_SOURCE_COMMIT."
}

build_pristine_live_iso() {
  pushd "$LIVE_BUILD_DIR" >/dev/null
  CURRENT_LOG="$LOG_DIR/${SESSION_ID}-build-pristine-live-iso.log"
  info "Log: $CURRENT_LOG"

  "$LIVE_ISO_RUNTIME" run --rm --privileged --network host -i \
    -v /proc:/proc \
    -v "$LIVE_BUILD_DIR:/working_dir" \
    -w /working_dir \
    "$LIVE_ISO_CONTAINER_IMAGE" \
    /bin/bash -s etc/terraform.conf < build.sh \
    2>&1 | tee "$CURRENT_LOG"
  popd >/dev/null

  UPSTREAM_ISO="$(find "$LIVE_BUILD_DIR/builds/arm64" "$LIVE_BUILD_DIR/builds" \
    -type f -name '*.iso' -print 2>/dev/null | sort -u | tail -n1 || true)"
  [[ -n "$UPSTREAM_ISO" && -s "$UPSTREAM_ISO" ]] || die "The pristine official ARM64 ISO was not produced."

  (
    cd "$LIVE_BUILD_DIR"
    find etc/config -type f \
      \( -path '*/package-lists*/*' -o -name '*.list.chroot' -o -name '*.list.binary' \) \
      -print0 | sort -z | xargs -0 sha256sum
  ) > "$TMP_ROOT/upstream-package-lists.after.sha256"
  cmp -s "$TMP_ROOT/upstream-package-lists.before.sha256" "$TMP_ROOT/upstream-package-lists.after.sha256" || \
    die "Official live package-list source files changed during the build."

  verify_pristine_graphical_iso
}

extract_iso_file() {
  local iso="$1" iso_path="$2" destination="$3"
  rm -f "$destination"
  xorriso -osirrox on -indev "$iso" -extract "$iso_path" "$destination" >/dev/null 2>&1
}

verify_pristine_graphical_iso() {
  UPSTREAM_MANIFEST="$TMP_ROOT/upstream-filesystem.packages"
  UPSTREAM_REMOVE_MANIFEST="$TMP_ROOT/upstream-filesystem.packages-remove"
  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.packages "$UPSTREAM_MANIFEST"
  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.packages-remove "$UPSTREAM_REMOVE_MANIFEST"

  local required=(vanilla-installer gnome-shell gnome-session mutter gdm3 xwayland network-manager)
  local pkg
  for pkg in "${required[@]}"; do
    grep -Eq "^${pkg}([[:space:]]|$)" "$UPSTREAM_MANIFEST" || \
      die "Pristine official ISO lacks required graphical package: $pkg"
  done

  local count
  count="$(wc -l < "$UPSTREAM_MANIFEST")"
  (( count >= MIN_GRAPHICAL_PACKAGE_COUNT )) || \
    die "Pristine official ISO has only $count packages; minimum is $MIN_GRAPHICAL_PACKAGE_COUNT. Refusing to remaster an incomplete source."

  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.squashfs "$TMP_ROOT/upstream-filesystem.squashfs"
  local squash_bytes
  squash_bytes="$(stat -c %s "$TMP_ROOT/upstream-filesystem.squashfs")"

  sha256sum "$UPSTREAM_MANIFEST" > "$TMP_ROOT/upstream-manifest.sha256"
  sha256sum "$UPSTREAM_REMOVE_MANIFEST" > "$TMP_ROOT/upstream-remove-manifest.sha256"
  ok "Pristine graphical ISO accepted: $count packages, $squash_bytes-byte squashfs."
}

mount_chroot_filesystems() {
  local root="$1"
  CHROOT_MOUNT_ROOT="$root"
  mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/dev/pts" "$root/run"
  mount --bind /dev "$root/dev"
  mount --bind /dev/pts "$root/dev/pts"
  mount -t proc proc "$root/proc"
  mount -t sysfs sys "$root/sys"
  mount --bind /run "$root/run"
}

patch_live_grub_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  sed -i -E \
    -e "s#(/live/)?vmlinuz-[^[:space:]'\"]+#/live/vmlinuz-${KERNEL_RELEASE}#g" \
    -e "s#(/live/)?initrd\.img-[^[:space:]'\"]+#/live/initrd.img-${KERNEL_RELEASE}#g" \
    "$file"

  python3 - "$file" "$DTB_NAME" <<'PATCH_GRUB_PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
dtb = sys.argv[2]
lines = path.read_text(errors="replace").splitlines()
out = []
for line in lines:
    if "devicetree /boot/dtbs/" in line:
        continue
    out.append(line)
    stripped = line.lstrip()
    if stripped.startswith("linux ") or stripped.startswith("linuxefi "):
        indent = line[:len(line)-len(stripped)]
        out.append(f"{indent}devicetree /boot/dtbs/{dtb}")
path.write_text("\n".join(out) + "\n")
PATCH_GRUB_PY
}

remaster_boot_hardware_only() {
  local iso_tree="$TMP_ROOT/iso-tree"
  local squash_root="$TMP_ROOT/squash-root"
  local original_squash="$TMP_ROOT/original-filesystem.squashfs"
  local new_squash="$TMP_ROOT/new-filesystem.squashfs"
  local compression

  rm -rf "$iso_tree" "$squash_root"
  mkdir -p "$iso_tree" "$squash_root"

  info "Extracting pristine official ISO tree."
  xorriso -osirrox on -indev "$UPSTREAM_ISO" -extract / "$iso_tree" >/dev/null 2>&1
  cp -a "$iso_tree/live/filesystem.squashfs" "$original_squash"

  compression="$(unsquashfs -s "$original_squash" | awk '/Compression/{print $2; exit}')"
  [[ -n "$compression" ]] || compression=xz
  unsquashfs -d "$squash_root" "$original_squash" >/dev/null

  local deb
  for deb in "${LIVE_KERNEL_DEBS[@]}"; do
    info "Extracting live boot package payload: $(basename "$deb")"
    dpkg-deb -x "$deb" "$squash_root"
  done

  mkdir -p "$squash_root/usr/lib/firmware" "$squash_root/boot/dtbs"
  if [[ -n "$FIRMWARE_SOURCE" ]]; then
    rsync -aHAX "$FIRMWARE_SOURCE/" "$squash_root/usr/lib/firmware/"
  fi
  cp -a "$DTB_FILE" "$squash_root/boot/dtbs/$DTB_NAME"

  [[ -s "$squash_root/boot/vmlinuz-$KERNEL_RELEASE" ]] || \
    die "Live squashfs lacks /boot/vmlinuz-$KERNEL_RELEASE after package extraction."
  [[ -d "$squash_root/usr/lib/modules/$KERNEL_RELEASE" || -d "$squash_root/lib/modules/$KERNEL_RELEASE" ]] || \
    die "Live squashfs lacks the module tree for $KERNEL_RELEASE."

  mount_chroot_filesystems "$squash_root"
  chroot "$squash_root" /bin/bash -Eeuo pipefail -c "
    release='$KERNEL_RELEASE'
    command -v depmod >/dev/null 2>&1 && depmod -a \"\$release\"
    rm -f \"/boot/initrd.img-\$release\"
    if command -v update-initramfs >/dev/null 2>&1; then
      update-initramfs -c -k \"\$release\"
    elif command -v dracut >/dev/null 2>&1; then
      dracut --force \"/boot/initrd.img-\$release\" \"\$release\"
    else
      echo 'Neither update-initramfs nor dracut exists inside the pristine live filesystem.' >&2
      exit 90
    fi
    test -s \"/boot/initrd.img-\$release\"
  "
  cleanup_chroot_mounts

  rm -f "$iso_tree/live"/vmlinuz-* "$iso_tree/live"/initrd.img-*
  cp -a "$squash_root/boot/vmlinuz-$KERNEL_RELEASE" "$iso_tree/live/vmlinuz-$KERNEL_RELEASE"
  cp -a "$squash_root/boot/initrd.img-$KERNEL_RELEASE" "$iso_tree/live/initrd.img-$KERNEL_RELEASE"
  mkdir -p "$iso_tree/boot/dtbs"
  cp -a "$DTB_FILE" "$iso_tree/boot/dtbs/$DTB_NAME"

  # Preserve both official package manifests byte-for-byte. The custom live
  # kernel is a boot payload overlay, not a package-list or APT transaction.
  cp -a "$UPSTREAM_MANIFEST" "$iso_tree/live/filesystem.packages"
  cp -a "$UPSTREAM_REMOVE_MANIFEST" "$iso_tree/live/filesystem.packages-remove"

  while IFS= read -r -d '' cfg; do
    patch_live_grub_file "$cfg"
  done < <(find "$iso_tree/boot/grub" "$iso_tree/EFI" -type f \
    \( -name '*.cfg' -o -name 'grub.cfg' -o -name 'loopback.cfg' \) -print0 2>/dev/null)

  rm -f "$new_squash"
  mksquashfs "$squash_root" "$new_squash" -noappend -comp "$compression" >/dev/null
  mv "$new_squash" "$iso_tree/live/filesystem.squashfs"

  if [[ -f "$iso_tree/live/filesystem.size" ]]; then
    du -sx --block-size=1 "$squash_root" | awk '{print $1}' > "$iso_tree/live/filesystem.size"
  fi

  (
    cd "$iso_tree"
    find . -type f ! -name md5sum.txt ! -name md5sum.README -print0 |
      sort -z | xargs -0 md5sum > md5sum.txt
  )

  mkdir -p "$RELEASE_DIR"
  rm -f "$FINAL_ISO"
  xorriso -as mkisofs \
    -r -J -joliet-long \
    -V "Vanilla OS" \
    -o "$FINAL_ISO" \
    -c boot.catalog \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -boot-load-size 6976 \
    "$iso_tree" >/dev/null 2>&1

  [[ -s "$FINAL_ISO" ]] || die "Final remastered ISO was not created."
}

# -------------------------- final verification ---------------------------

verify_final_release() {
  local verify_dir="$TMP_ROOT/final-verify"
  local final_manifest="$verify_dir/filesystem.packages"
  local final_remove="$verify_dir/filesystem.packages-remove"
  local final_squash="$verify_dir/filesystem.squashfs"
  local squash_listing="$verify_dir/squashfs.list"
  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"

  extract_iso_file "$FINAL_ISO" /live/filesystem.packages "$final_manifest"
  extract_iso_file "$FINAL_ISO" /live/filesystem.packages-remove "$final_remove"
  cmp -s "$UPSTREAM_MANIFEST" "$final_manifest" || die "Final filesystem.packages differs from pristine upstream."
  cmp -s "$UPSTREAM_REMOVE_MANIFEST" "$final_remove" || die "Final filesystem.packages-remove differs from pristine upstream."

  extract_iso_file "$FINAL_ISO" "/live/vmlinuz-$KERNEL_RELEASE" "$verify_dir/vmlinuz"
  extract_iso_file "$FINAL_ISO" "/live/initrd.img-$KERNEL_RELEASE" "$verify_dir/initrd"
  extract_iso_file "$FINAL_ISO" "/boot/dtbs/$DTB_NAME" "$verify_dir/$DTB_NAME"
  [[ -s "$verify_dir/vmlinuz" ]] || die "Final ISO lacks the nonempty custom kernel."
  [[ -s "$verify_dir/initrd" ]] || die "Final ISO lacks the nonempty custom initramfs."
  [[ -s "$verify_dir/$DTB_NAME" ]] || die "Final ISO lacks the selected DTB."

  extract_iso_file "$FINAL_ISO" /boot/grub/grub.cfg "$verify_dir/grub.cfg"
  grep -Fq "/live/vmlinuz-$KERNEL_RELEASE" "$verify_dir/grub.cfg" || die "Final GRUB config does not select the custom kernel."
  grep -Fq "devicetree /boot/dtbs/$DTB_NAME" "$verify_dir/grub.cfg" || die "Final GRUB config lacks the selected DTB directive."

  extract_iso_file "$FINAL_ISO" /live/filesystem.squashfs "$final_squash"
  unsquashfs -ll "$final_squash" > "$squash_listing"
  grep -Eq "(usr/)?lib/modules/${KERNEL_RELEASE}/" "$squash_listing" || die "Final squashfs lacks custom modules."
  grep -Fq "boot/dtbs/$DTB_NAME" "$squash_listing" || die "Final squashfs lacks selected DTB."
  if [[ -n "$FIRMWARE_PROBE_REL" ]]; then
    grep -Fq "usr/lib/firmware/$FIRMWARE_PROBE_REL" "$squash_listing" || \
      die "Final squashfs lacks firmware probe: $FIRMWARE_PROBE_REL"
  fi

  local el_torito="$verify_dir/el-torito.txt"
  xorriso -indev "$FINAL_ISO" -report_el_torito as_mkisofs > "$el_torito" 2>&1
  grep -Fq -- "-e '/boot/grub/efi.img'" "$el_torito" || die "Final ISO lacks the expected ARM64 El Torito EFI image."

  sha256sum "$FINAL_ISO" > "$FINAL_ISO.sha256"
  cp -a "$TMP_ROOT/upstream-package-lists.before.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-remove-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/debian-package-inventory.tsv" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/kernel-package-selection.tsv" "$RELEASE_DIR/"
  mkdir -p "$RELEASE_DIR/deb-listings"
  cp -a "$TMP_ROOT/deb-listings/." "$RELEASE_DIR/deb-listings/"
  [[ -f "$TMP_ROOT/vib-plugin-inventory.txt" ]] && cp -a "$TMP_ROOT/vib-plugin-inventory.txt" "$RELEASE_DIR/"
  [[ -f "$TMP_ROOT/vib-plugin-checksums.sha256" ]] && cp -a "$TMP_ROOT/vib-plugin-checksums.sha256" "$RELEASE_DIR/"
  [[ -n "$FSGUARD_PLUGIN_RELEASE_METADATA" && -f "$FSGUARD_PLUGIN_RELEASE_METADATA" ]] && \
    cp -a "$FSGUARD_PLUGIN_RELEASE_METADATA" "$RELEASE_DIR/"
  printf '%s\n' "$CUSTOM_SOURCE_COMMIT" > "$RELEASE_DIR/custom-image-source.commit"
  printf '%s\n' "$LIVE_SOURCE_COMMIT" > "$RELEASE_DIR/live-iso-source.commit"

  cat > "$RELEASE_DIR/CUSTOM-TARGET-IMAGE.txt" <<EOF_TARGET
Custom VanillaOS target image
==============================
Build reference:   $TARGET_IMAGE_REF
ABRoot image name: $ABROOT_IMAGE_NAME
Base image:        $CUSTOM_IMAGE_BASE
Profile:           $PROFILE
Kernel:            $KERNEL_RELEASE
DTB:               $DTB_NAME
Built:             $(date -u --iso-8601=seconds)

Graphical installer custom-image entry:
  $TARGET_IMAGE_REF

The installer must be able to resolve and pull this reference. A localhost
reference is not reachable from a separate live environment unless the image is
made available through a registry or an explicitly supported local mechanism.
EOF_TARGET

  cat > "$RELEASE_DIR/BUILD-MANIFEST.txt" <<EOF_MANIFEST
Conception VanillaOS ARM64 build
Version:                     $SCRIPT_VERSION
Release ID:                  $RELEASE_ID
Profile:                     $PROFILE
Kernel release:              $KERNEL_RELEASE
Supplied kernel .debs:       ${#KERNEL_DEBS[@]}
Target-installed .debs:      ${#TARGET_KERNEL_DEBS[@]}
Target-excluded .debs:       ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}
Target archive location:     /root/custom-kernel-packages
Live boot .debs:             ${#LIVE_KERNEL_DEBS[@]}
DTB:                         $DTB_NAME
Firmware source:             ${FIRMWARE_SOURCE:-none}
Target /root source:         ${ROOT_SOURCE:-none}
Target OCI:                  $TARGET_IMAGE_REF
ABRoot image name:           $ABROOT_IMAGE_NAME
Target OCI base:             $CUSTOM_IMAGE_BASE
Vib version:                 $VIB_DETECTED_VERSION
FsGuard plugin:              $FSGUARD_PLUGIN_REPO @ $FSGUARD_PLUGIN_RESOLVED_TAG
custom-image source commit:  $CUSTOM_SOURCE_COMMIT
live-iso source commit:      $LIVE_SOURCE_COMMIT
Pristine ISO:                $UPSTREAM_ISO
Final ISO:                   $FINAL_ISO
Live package manifests:      byte-identical before and after remaster
Built:                       $(date -u --iso-8601=seconds)
EOF_MANIFEST

  ok "Final ISO: $FINAL_ISO"
  ok "Target OCI: $TARGET_IMAGE_REF"
  ok "Both live package manifests remained byte-identical."
}

# ------------------------------- main -----------------------------------

main() {
  parse_args "$@"
  [[ "$INTERACTIVE_MODE" != "auto" ]] || {
    if [[ -t 0 && -t 1 ]]; then INTERACTIVE_MODE=1; else INTERACTIVE_MODE=0; fi
  }

  recompute_paths
  require_root
  setup_directories
  setup_logging

  stage "1/12 Selecting the official Git source policy"
  configure_repository_interactively

  stage "2/12 Checking host dependencies without changing initramfs implementation"
  install_host_dependencies_safely
  check_free_space

  stage "3/12 Applying and verifying the official Git source action"
  if (( PLAN_ONLY == 1 )); then
    report_repository_plan_state
  else
    sync_required_repositories
  fi

  stage "4/12 Resolving interactive build inputs and validating hardware artifacts"
  configure_build_inputs_interactively
  discover_kernel_and_dtb_inputs
  print_plan
  if (( PLAN_ONLY == 1 )); then
    ok "Plan mode complete. No repository checkout, firmware staging, container build, or ISO build was performed."
    exit 0
  fi

  (( SOURCES_SYNCHRONIZED == 1 )) ||     die "Internal guard: execute mode reached confirmation without synchronized official sources."
  confirm_or_abort

  RELEASE_ID="$(reserve_release_id)"
  RELEASE_DIR="$RELEASES_DIR/${BUILD_DATE}-${RELEASE_ID}-${PROFILE}"
  FINAL_ISO="$RELEASE_DIR/Conception-VanillaOS-Orchid-arm64-${BUILD_DATE}-${RELEASE_ID}-${PROFILE}.iso"
  mkdir -p "$RELEASE_DIR"

  stage "5/12 Staging Qualcomm firmware without modifying the build host"
  stage_firmware

  stage "6/12 Preparing a clean custom-image worktree and resolving Vib/plugins"
  prepare_custom_image_worktree
  install_vib_and_plugins

  stage "7/12 Preparing the official custom-image-derived hardware recipe"
  prepare_custom_image_project

  stage "8/12 Building and verifying the desktop:dev-derived target OCI"
  build_target_oci

  stage "9/12 Preparing and building a pristine graphical ARM64 live ISO"
  prepare_pristine_live_worktree
  build_pristine_live_iso

  stage "10/12 Remastering only boot-critical hardware content"
  remaster_boot_hardware_only

  stage "11/12 Verifying package-closure preservation and release artifacts"
  verify_final_release

  stage "12/12 Complete"
  cat "$RELEASE_DIR/BUILD-MANIFEST.txt"
}

main "$@"
