#!/usr/bin/env bash
# VanillaOS-SnapdragonX ARM64 Builder
# Version 8.5-r5.1
#
# v8.5-r5.1 Stage-1 dispatcher restoration
# --------------------------------------------
# Corrective point revision to the v8.5-r5 stable-Reunion convergence milestone.
# The delivered r5 transformation inadvertently omitted print_builder_banner()
# and configure_repository_interactively(), even though main() still invoked the
# latter at Stage 1. The omission caused an immediate exit 127 before any source
# synchronization, host dependency installation, firmware staging, OCI build, or
# ISO build. r5.1 restores the exact accepted r4 Stage-1 wrapper semantics:
# print the builder banner, then invoke choose_repo_policy(). No Reunion, hardware,
# storage, Installer, OCI, firmware, kernel, GDM, or live-ISO behavior is changed.
# r5.1 also adds a pure-Bash internal Stage 1-13 function-contract gate before
# profile discovery so a future structurally incomplete artifact fails explicitly.
#
# ==== MILESTONE ==============================================================
# v8.5-r5 — Vanilla OS 3.0 "Reunion" stable-release convergence
# ============================================================================
# Canonical accepted parent:
#   build-vanilla-arm64-release-v8.5-r4.sh
#   SHA-256 24b1b4d86dd4bf01c9d101d0f21e2d1908267d92814a2ad2c48f3f2695990180
#
# This milestone aligns the accepted v8.5-r4 Snapdragon X build architecture
# with the formal Vanilla OS 3 Reunion release contract published 2026-08-24.
# It deliberately does not begin the v8.6 simplification/refactoring program.
#
# Stable Reunion convergence changes:
#   - target base defaults to ghcr.io/vanilla-os/gnome:latest;
#   - FsGuard generation/acquisition/evidence is removed because Reunion
#     removed FsGuard from the stable boot/image composition;
#   - project-owned executable payload moves out of ABRoot's writable
#     /usr/local, /opt, and /root topology into immutable /usr/libexec and
#     /usr/lib project namespaces;
#   - stable VSO native identity is explicit: vso-native stack,
#     ghcr.io/vanilla-os/vso:latest, managed apx-vso-native instance, with
#     Debian testing recorded as the upstream VSO image base contract;
#   - Distrobox v2/2.0.0-rc.4 coherence checks and opaque source-build version
#     acceptance remain intact;
#   - generic ARM64 remains upstream-owned through live-iso:orchid with
#     LIVE_ARM64_PACKAGE_POLICY=upstream-native;
#   - Pico remains the live/build substrate and the validated Podman runtime is
#     the default for both OCI and live-ISO container execution;
#   - moving stable OCI tags are resolved to manifest digests and emitted as
#     build evidence;
#   - the architecture-suffix naming change is audited without weakening the
#     package-name-independent kernel and firmware intake engines.
#
# Inherited accepted r4 correction:
#   - final squashfs systemd enablement evidence is checked against the complete
#     materialized unsquashfs listing. No unsquashfs|grep-q pipeline is used
#     under global pipefail, avoiding the accepted r3 false-negative/SIGPIPE.
#
# Frozen project-owned behavior for this milestone:
#   hardware profiles; package-semantic kernel intake/dependency closure; exact
#   DTB selection; firmware provenance/board-data policy; Snapdragon boot
#   arguments; live-only GDM timed login; external storage correctness guard;
#   canonical Installer dispatcher and exactly-one autostart; systemd-owned
#   ISO-local OCI Distribution v2 bridge; embedded target OCI; and deterministic
#   target/final-ISO digest/evidence binding.
#
# Naming transition:
#   v8.5-r4 and earlier: build-vanilla-arm64-release-v<version>*
#   v8.5-r5 and later:   build-vanilla-snapdragon-x-v<version>*
# Version numbering remains continuous; only the artifact basename changes.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_VERSION="8.5-r5.1"

# Resolve the real script location before any path defaults are constructed.
# This deliberately does not depend on PWD, HOME, or the account selected by
# sudo. A repository clone therefore remains self-contained wherever it lives.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_PARENT="$(cd -P -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink -- "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" == /* ]] || SCRIPT_SOURCE="$SCRIPT_PARENT/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "$SCRIPT_SOURCE")"
SCRIPT_NAME="$(basename -- "$SCRIPT_PATH")"

# Tilde input entered after sudo should resolve to the original caller where
# possible, not silently to /root. Shell-expanded paths are already absolute;
# this affects only literal '~' and '~/' values passed through CLI/config.
CALLER_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
  [[ -n "$_sudo_home" ]] && CALLER_HOME="$_sudo_home"
fi
unset _sudo_home

# Record whether profile-resolvable values were explicitly supplied through the
# environment. The profile loader may replace ordinary defaults, but never an
# explicit environment value. Full CLI parsing occurs after profile loading and
# therefore has the highest precedence.
ENV_PROFILE_SET="${PROFILE+x}"
ENV_ARTIFACT_DIR_SET="${ARTIFACT_DIR+x}"
ENV_KERNEL_DEB_DIR_SET="${KERNEL_DEB_DIR+x}"
ENV_KERNEL_IMAGE_DEB_SET="${KERNEL_IMAGE_DEB_OVERRIDE+x}"
ENV_ROOT_SOURCE_SET="${ROOT_SOURCE+x}"
ENV_DTB_FILE_SET="${DTB_FILE_OVERRIDE+x}"
ENV_DTB_NAME_SET="${DTB_INSTALLED_NAME_OVERRIDE+x}"
ENV_FIRMWARE_SOURCE_SET="${FIRMWARE_SOURCE_OVERRIDE+x}"
ENV_FIRMWARE_QCOM_SOC_DEB_SET="${FIRMWARE_QCOM_SOC_DEB+x}"
ENV_FIRMWARE_QCOM_SOC_SHA256_SET="${FIRMWARE_QCOM_SOC_SHA256+x}"
ENV_FIRMWARE_QCOM_SOC_VERSION_SET="${FIRMWARE_QCOM_SOC_EXPECTED_VERSION+x}"
ENV_FIRMWARE_QCOM_SOC_POLICY_SET="${FIRMWARE_QCOM_SOC_POLICY+x}"
ENV_FIRMWARE_PACKAGE_OVERRIDES_SET="${FIRMWARE_PACKAGE_OVERRIDES_JSON+x}"
ENV_KERNEL_RELEASE_SET="${EXPECTED_CUSTOM_KERNEL_RELEASE+x}"
ENV_KERNEL_RELEASE_POLICY_SET="${KERNEL_RELEASE_POLICY+x}"
ENV_CUSTOM_IMAGE_BASE_SET="${CUSTOM_IMAGE_BASE+x}"
ENV_VSO_NATIVE_IMAGE_SET="${VSO_NATIVE_IMAGE+x}"
ENV_TARGET_IMAGE_SET="${TARGET_IMAGE_REF+x}"
ENV_TARGET_REPOSITORY_SET="${TARGET_IMAGE_REPOSITORY+x}"
ENV_ABROOT_IMAGE_SET="${ABROOT_IMAGE_NAME+x}"
ENV_DELIVERY_MODE_SET="${DELIVERY_MODE+x}"
ENV_INSTALLER_STORAGE_GUARD_POLICY_SET="${INSTALLER_STORAGE_GUARD_POLICY+x}"
ENV_REGISTRY_IMAGE_SET="${REGISTRY_IMAGE_REF+x}"
ENV_ISO_LAYOUT_PATH_SET="${ISO_IMAGE_LAYOUT_PATH+x}"
ENV_MIN_FREE_GIB_SET="${MIN_FREE_GIB+x}"

# ----------------------------- defaults ---------------------------------

# The repository containing this script is the default build root. Explicit
# WORKDIR and --workdir values remain authoritative overrides.
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
PROFILE="${PROFILE:-hp-omnibook-5}"
PROFILE_FILE="${PROFILE_FILE:-}"
PROFILE_SCHEMA_VERSION="${PROFILE_SCHEMA_VERSION:-2}"
PROFILE_DISPLAY_NAME="${PROFILE_DISPLAY_NAME:-}"
PROFILE_ARCHITECTURE="${PROFILE_ARCHITECTURE:-arm64}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
KERNEL_DEB_DIR="${KERNEL_DEB_DIR:-}"
KERNEL_IMAGE_DEB_OVERRIDE="${KERNEL_IMAGE_DEB_OVERRIDE:-}"
ROOT_SOURCE="${ROOT_SOURCE:-}"
DTB_FILE_OVERRIDE="${DTB_FILE_OVERRIDE:-}"
DTB_INSTALLED_NAME_OVERRIDE="${DTB_INSTALLED_NAME_OVERRIDE:-}"
FIRMWARE_SOURCE_OVERRIDE="${FIRMWARE_SOURCE_OVERRIDE:-}"

# Generic Qualcomm firmware package input. "require" is the v8.0.4 HP closing
# milestone default. The exact package bytes must be pinned by either the
# environment/CLI SHA-256 or a sidecar checksum file.
FIRMWARE_QCOM_SOC_POLICY="${FIRMWARE_QCOM_SOC_POLICY:-require}"
FIRMWARE_QCOM_SOC_DEB="${FIRMWARE_QCOM_SOC_DEB:-}"
FIRMWARE_QCOM_SOC_SHA256="${FIRMWARE_QCOM_SOC_SHA256:-}"
FIRMWARE_QCOM_SOC_EXPECTED_VERSION="${FIRMWARE_QCOM_SOC_EXPECTED_VERSION:-}"
FIRMWARE_QCOM_SOC_ACTUAL_VERSION=""
FIRMWARE_QCOM_SOC_ACTUAL_SHA256=""
FIRMWARE_QCOM_SOC_CHECKSUM_SOURCE=""
FIRMWARE_QCOM_SOC_CHECKSUM_CANDIDATE=""

# Schema-v2 firmware package state. The legacy firmware-qcom-soc variables and
# CLI flags remain supported as a compatibility override for that one package,
# but all resolution and extraction is performed by the generic package engine.
FIRMWARE_PACKAGE_OVERRIDES_JSON="${FIRMWARE_PACKAGE_OVERRIDES_JSON:-}"
FIRMWARE_PACKAGE_SPECS_FILE=""
FIRMWARE_PACKAGES_RESOLVED_FILE=""
FIRMWARE_PACKAGE_INVENTORY_FILE=""
FIRMWARE_PACKAGE_LOCK_FILE=""
FIRMWARE_CHECKSUM_CANDIDATE=""
FIRMWARE_CHECKSUM_SOURCE=""
FIRMWARE_BOARD_POLICY="none"
FIRMWARE_BOARD_RAW_PATH=""
FIRMWARE_BOARD_COMPRESSED_PATH=""
FIRMWARE_BOARD_SUBSYSTEM=""
FIRMWARE_BOARD_MAGIC=""
FIRMWARE_BOARD_RAW_SHA256=""
FIRMWARE_BOARD_COMPRESSED_SHA256=""
PROFILE_FILE_SOURCE=""

# Known-good HP WCN6855 board-data pair previously acceptance-tested for the
# QCNFA765 subsystem 103c:8d9a. These remain overridable only for deliberate
# profile evolution and are checked before an expensive image build.
HP_ATH11K_BOARD_BIN_SHA256="${HP_ATH11K_BOARD_BIN_SHA256:-dd17d8aaccdc3e8a0a82d0fd6858934d7c87cfc10c2658cfbb570e604d692afc}"
HP_ATH11K_BOARD_ZST_SHA256="${HP_ATH11K_BOARD_ZST_SHA256:-756d0d3134db83182eefa7286993f924286e71eb75faab1a46d1fb80e68b0e0a}"

EXPECTED_CUSTOM_KERNEL_RELEASE="${EXPECTED_CUSTOM_KERNEL_RELEASE:-}"
KERNEL_RELEASE_POLICY="${KERNEL_RELEASE_POLICY:-prefer}"

CUSTOM_IMAGE_REPO_URL="${CUSTOM_IMAGE_REPO_URL:-https://github.com/Vanilla-OS/custom-image.git}"
CUSTOM_IMAGE_REF="${CUSTOM_IMAGE_REF:-main}"
CUSTOM_IMAGE_BASE="${CUSTOM_IMAGE_BASE:-ghcr.io/vanilla-os/gnome:latest}"
VSO_NATIVE_IMAGE="${VSO_NATIVE_IMAGE:-ghcr.io/vanilla-os/vso:latest}"
VSO_NATIVE_STACK="vso-native"
VSO_NATIVE_INSTANCE="apx-vso-native"
VSO_NATIVE_UPSTREAM_BASE="debian:testing"

LIVE_ISO_REPO_URL="${LIVE_ISO_REPO_URL:-https://github.com/Vanilla-OS/live-iso.git}"
LIVE_ISO_REF="${LIVE_ISO_REF:-orchid}"
SOURCE_STALE_WARN_DAYS="${SOURCE_STALE_WARN_DAYS:-180}"
LIVE_ISO_CONTAINER_IMAGE="${LIVE_ISO_CONTAINER_IMAGE:-ghcr.io/vanilla-os/pico:latest}"

# Both harness OCI construction and the official Pico live-ISO runtime shape
# have been validated under Podman on the Reunion self-buildhost. Keep either
# variable overridable for hosts that deliberately use another compatible OCI
# runtime, but converge on Podman by default.
OCI_RUNTIME="${OCI_RUNTIME:-podman}"
LIVE_ISO_RUNTIME="${LIVE_ISO_RUNTIME:-$OCI_RUNTIME}"
OCI_BUILD_NETWORK="${OCI_BUILD_NETWORK:-host}"

# Stable Reunion owns generic ARM64 package selection through live-build
# ARCHITECTURES conditionals. Keep the r4.1 projection engine only as an
# explicit compatibility path for historical refs; never apply it silently to
# the current Reunion tree.
LIVE_ARM64_PACKAGE_POLICY="${LIVE_ARM64_PACKAGE_POLICY:-upstream-native}"

# Legacy projection compatibility contract. These are the exact exclusions
# accepted by r4.1 for older live-iso snapshots that lacked upstream
# ARCHITECTURES conditionals. They are intentionally preserved, explicit, and
# environment-overridable; broad "remove every unavailable package" behavior
# remains prohibited.
LIVE_ARM64_PACKAGE_LIST_SUFFIX="${LIVE_ARM64_PACKAGE_LIST_SUFFIX:-vanilla-installer-arm64}"
LIVE_ARM64_EXCLUDE_PACKAGES="${LIVE_ARM64_EXCLUDE_PACKAGES:-grub-efi-amd64,grub-efi-amd64-bin,grub-efi-amd64-signed,shim-helpers-amd64-signed,intel-microcode,amd64-microcode,iucode-tool,virtualbox-guest-utils,virtualbox-guest-x11}"

QCOM_UPDATER_REPO_URL="${QCOM_UPDATER_REPO_URL:-https://github.com/alejandroqh/qcom-firmware-updater.git}"
QCOM_UPDATER_REF="${QCOM_UPDATER_REF:-main}"
QCOM_DEVICE_PATH_DEFAULT="${QCOM_DEVICE_PATH_DEFAULT:-x1p42100/hp/omnibook-5}"
QCOM_DEVICE_PATH="${QCOM_DEVICE_PATH:-$QCOM_DEVICE_PATH_DEFAULT}"

TARGET_IMAGE_REPOSITORY="${TARGET_IMAGE_REPOSITORY:-}"
TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-}"
ABROOT_IMAGE_NAME="${ABROOT_IMAGE_NAME:-}"
PUSH_TARGET_IMAGE="${PUSH_TARGET_IMAGE:-0}"

# Installed-image delivery. iso-oci embeds the verified OCI layout and serves it
# through a loopback-only registry bridge. registry uses REGISTRY_IMAGE_REF.
DELIVERY_MODE="${DELIVERY_MODE:-}"
REGISTRY_IMAGE_REF="${REGISTRY_IMAGE_REF:-}"
ISO_IMAGE_LAYOUT_PATH="${ISO_IMAGE_LAYOUT_PATH:-}"
EMBEDDED_IMAGE_TAG="${EMBEDDED_IMAGE_TAG:-}"
LOCAL_REGISTRY_HOST="${LOCAL_REGISTRY_HOST:-127.0.0.1}"
LOCAL_REGISTRY_PORT="${LOCAL_REGISTRY_PORT:-5000}"
LOCAL_REGISTRY_LOGICAL_HOST="${LOCAL_REGISTRY_LOGICAL_HOST:-oci.vanillaos-snapdragonx.invalid}"
LOCAL_REGISTRY_NAMESPACE="${LOCAL_REGISTRY_NAMESPACE:-vanillaos-snapdragonx}"
INSTALLER_AUTOSTART="${INSTALLER_AUTOSTART:-1}"
INSTALLER_IGNORE_CPU="${INSTALLER_IGNORE_CPU:-1}"
INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE="${INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE:-1}"
INSTALLER_STORAGE_GUARD_POLICY="${INSTALLER_STORAGE_GUARD_POLICY:-repair}"

# Live-only session policy. These settings never enter the target OCI.
LIVE_GDM_TIMED_LOGIN_DELAY="${LIVE_GDM_TIMED_LOGIN_DELAY:-5}"
LIVE_GDM_TIMED_LOGIN_USER="vanilla"
LIVE_GDM_LIVE_CONFIG_REL="etc/live/config.conf.d/vanillaos-snapdragonx.conf"
LIVE_GDM_DAEMON_CONFIG_REL="etc/gdm3/daemon.conf"

VIB_VERSION="${VIB_VERSION:-1.1.0}"
VIB_RECIPE_VERSION="${VIB_RECIPE_VERSION:-1.1.0}"
VIB_BIN="${VIB_BIN:-}"
VIB_DETECTED_VERSION=""

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
PROFILE_SELECTOR_EXPLICIT=0
[[ -n "$ENV_PROFILE_SET" ]] && PROFILE_SELECTOR_EXPLICIT=1

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
PROFILE_FILE_RESOLVED=""
PROFILE_RESOLVED_JSON=""
PROFILE_VALIDATION_REPORT=""
ROOT_OVERLAY_INVENTORY=""
EMBEDDED_OCI_LAYOUT=""
EMBEDDED_OCI_INVENTORY=""
EMBEDDED_OCI_TREE_HASH=""
TARGET_IMAGE_MANIFEST_DIGEST=""
LOCAL_INSTALL_IMAGE_REF=""
INSTALLER_DEFAULT_IMAGE_REF=""
INSTALLER_PATCH_MANIFEST=""
INSTALLED_BOOT_EXPECTED_JSON=""
FIRMWARE_PROVENANCE_DIR=""
FIRMWARE_MERGE_REPORT=""
FIRMWARE_STAGED_INVENTORY=""
LIVE_KERNEL_CMDLINE_JSON=""
LIVE_KERNEL_CMDLINE_EVIDENCE=""
TARGET_STORAGE_HOOK_FILE=""
TARGET_STORAGE_HOOK_SHA256_FILE=""
TARGET_STORAGE_HOOK_EVIDENCE_JSON=""
TARGET_ABROOT_CONFIG_EVIDENCE=""
TARGET_BASE_INSPECT_JSON=""
TARGET_USERLAND_COHERENCE_REPORT=""
REUNION_CONVERGENCE_MANIFEST=""
UPSTREAM_OCI_PROVENANCE_JSON=""
REUNION_ARCHITECTURE_NAME_AUDIT=""

# Discovered inputs.
declare -a KERNEL_DEBS=()
declare -a TARGET_KERNEL_DEBS=()
declare -a TARGET_EXCLUDED_KERNEL_DEBS=()
declare -a LIVE_KERNEL_DEBS=()
declare -a DTB_CANDIDATES=()
declare -a PROFILE_FIRMWARE_PROBES=()
declare -a PROFILE_FIRMWARE_REQUIRED_PATHS=()
declare -a PROFILE_INITRAMFS_PROBES=()
declare -a PROFILE_INSTALLED_PATH_PROBES=()
declare -a PROFILE_KERNEL_CMDLINE_APPEND=()
KERNEL_RELEASE=""
KERNEL_RELEASE_REQUESTED=""
KERNEL_IMAGE_DEB=""
KERNEL_PACKAGE_CLOSURE_JSON=""
DTB_FILE=""
DTB_NAME=""
FIRMWARE_SOURCE=""
FIRMWARE_PROBE_REL=""
ROOT_PROBE_REL=""
UPSTREAM_ISO=""
UPSTREAM_MANIFEST=""
UPSTREAM_REMOVE_MANIFEST=""
LIVE_PACKAGE_LIST_SOURCE_SUFFIX=""
LIVE_PACKAGE_LIST_SOURCE_DIR=""
LIVE_PACKAGE_LIST_DERIVED_DIR=""
LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST=""
LIVE_PACKAGE_LIST_PACKAGE_INVENTORY=""
LIVE_PACKAGE_CANDIDATE_REPORT=""
SOURCE_PROVENANCE_MANIFEST=""
GRUB_PATCH_MANIFEST=""
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

  # A stage may fail during an unlogged preflight before run_logged() selects a
  # new command log. Clear the previous stage's path so the error handler never
  # presents stale output as though it belonged to the current failure.
  CURRENT_LOG=""
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
    '~') s="$CALLER_HOME" ;;
    '~/'*) s="$CALLER_HOME/${s:2}" ;;
  esac
  printf '%s' "$s"
}

canonicalize_workdir() {
  local value
  value="$(normalize_path_input "$1")"
  [[ -n "$value" ]] || die "WORKDIR resolved empty"
  if [[ "$value" != /* ]]; then
    value="$PWD/$value"
  fi
  readlink -m -- "$value"
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
  else
    fail "No command-specific log was active for this stage preflight failure."
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
  cat <<EOF_USAGE
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
  --profile NAME                  Hardware profile identifier.
  --profile-file PATH             Hardware-profile JSON manifest.
  --artifact-dir PATH             Profile artifact directory.
  --kernel-deb-dir PATH           Directory containing Debian kernel-related .debs.
  --kernel-image-deb PATH         Exact package owning /boot/vmlinuz-<release>
                                  when more than one supplied package qualifies.
  --kernel-release RELEASE        Preferred or required exact uname -r.
  --kernel-release-policy POLICY  prefer, require, or auto. Default: prefer.
  --dtb-file PATH                 Exact DTB source file.
  --dtb-name NAME                 Installed DTB filename.
  --root-source PATH              Legacy root-overlay source. In Reunion r5 its
                                  contents are preserved beneath immutable
                                  /usr/lib/vanillaos-snapdragonx/root-source-overlay
                                  rather than written to ABRoot's /root.
  --firmware-dir PATH             Profile-specific firmware tree; paths are
                                  relative to /usr/lib/firmware.
  --qcom-soc-firmware-deb PATH    Legacy override for the firmware-qcom-soc package.
  --qcom-soc-firmware-sha256 HEX  Expected SHA-256 for that exact package.
  --qcom-soc-firmware-version VER Optional exact Debian package version.
  --qcom-soc-firmware-policy P    require, auto, or skip. Default: require.

Checksum pin behavior:
  Plan mode never writes an input artifact. When no pin exists, it reports the
  observed package SHA-256 and includes that exact digest in the printed execute
  command. Interactive execute can atomically create the package-specific
  sidecar after explicit operator approval. Non-interactive execute requires a
  sidecar, profile/environment value, or --qcom-soc-firmware-sha256.
  --repo-policy POLICY            ask-once, prompt, refresh, continue, reclone.
  --target-image REF              Full target OCI build/push reference.
  --abroot-image NAME             ABRoot image name, normally owner/image.
  --delivery-mode MODE            iso-oci or registry.
  --registry-image REF            Registry source used in registry mode.
  --iso-image-path PATH           ISO path for the embedded OCI layout.
  --local-registry-port PORT      Loopback registry bridge port.
  --local-registry-logical-host HOST
                                  Port-free logical registry hostname remapped
                                  to the loopback bridge. Default:
                                  oci.vanillaos-snapdragonx.invalid
  --storage-guard-policy POLICY   Encrypted /var recipe policy: repair, strict,
                                  or off. Default: repair.
  --live-package-policy POLICY    upstream-native or legacy-projection.
                                  Default: upstream-native.
  --live-gdm-delay SECONDS        Timed login delay for live user vanilla.
                                  Default: 5; valid range: 1..60.
  --live-ref REF                  live-iso branch, tag, or commit.
  --custom-image-ref REF          custom-image branch, tag, or commit.
  --push-target-image             Push target OCI after local verification.
  -h, --help                      Show this help.

Stable Reunion source contract:
  custom-image Git checkout: main branch (scaffold/modules only)
  live-iso Git checkout:     orchid (Vanilla OS 3 / Reunion)
  target OCI base:           ghcr.io/vanilla-os/gnome:latest
  live build container:      ghcr.io/vanilla-os/pico:latest
  VSO native image:          ghcr.io/vanilla-os/vso:latest
  VSO managed instance:      apx-vso-native
  VSO upstream base:         debian:testing
  live package policy:       upstream-native

  Branch names, image names, tags, and resolved digests are separate taxonomy
  layers. Exact Git commits and moving OCI tag digests are recorded as evidence.

Vib toolchain defaults:
  VIB_VERSION=1.1.0
  VIB_RECIPE_VERSION=1.1.0
  LIVE_GDM_TIMED_LOGIN_DELAY=5   Live-only GDM timed login (1..60 seconds).

ARM64 live-ISO package policy:
  LIVE_ARM64_PACKAGE_POLICY=upstream-native

  Current Reunion live-iso carries architecture-aware package-list conditionals
  and an architecture-aware build.sh. In upstream-native mode those canonical
  files are used byte-for-byte and validated before/after the build.

  Historical compatibility remains available with:
    LIVE_ARM64_PACKAGE_POLICY=legacy-projection
    LIVE_ARM64_PACKAGE_LIST_SUFFIX=vanilla-installer-arm64
    LIVE_ARM64_EXCLUDE_PACKAGES=grub-efi-amd64,grub-efi-amd64-bin,
        grub-efi-amd64-signed,shim-helpers-amd64-signed,intel-microcode,
        amd64-microcode,iucode-tool,virtualbox-guest-utils,virtualbox-guest-x11

Hardware profile lookup order:
  --profile-file PATH
  WORKDIR/profiles/$PROFILE/profile.json
  WORKDIR/profiles/$PROFILE.json
  synthesized compatibility profile when neither file exists

Profile precedence:
  CLI option > environment variable > profile manifest > deterministic discovery

Portable project root:
  By default WORKDIR is the canonical directory containing this script. The
  project can therefore be cloned and executed beneath ~/src, ~/build,
  /opt/projects, or another path without compatibility symlinks.

Preferred input layout:
  WORKDIR/artifacts/$PROFILE/
  ├── firmware-debs/
  │   ├── <arbitrary-firmware-package-name>.deb
  │   └── <arbitrary-firmware-package-name>.deb.sha256
  ├── kernel-debs/
  │   ├── <any-name>.deb          # owns regular /boot/vmlinuz-<uname-r>
  │   ├── <any-name>.deb          # owns runtime .ko files for that uname-r
  │   └── optional local dependency/support .debs
  ├── dtb/
  │   └── x1p42100-hp-omnibook-5.dtb
  └── firmware/                  # profile overlay relative to /usr/lib/firmware
      ├── ath11k/WCN6855/hw2.1/board-2.bin
      ├── ath11k/WCN6855/hw2.1/board-2.bin.zst
      └── qcom/x1p42100/hp/omnibook-5/...

Kernel package filenames and Package fields are not selectors. The harness uses
Debian control metadata, conventional payload paths, and local dependency
relationships. --kernel-image-deb resolves duplicate image ownership explicitly.

Firmware package names are discovered by Debian control metadata. Profile-required paths for the HP X1-45 compatibility profile resolve to:
  qcom/gen71500_sqe.fw
  qcom/gen71500_gmu.bin
  qcom/x1p42100/gen71500_zap.mbn

Legacy root-overlay input is preserved as immutable project data at:
  /usr/lib/vanillaos-snapdragonx/root-source-overlay/

Compatibility input paths:
  ARTIFACT_DIR/*.deb
  ARTIFACT_DIR/*.dtb
  ARTIFACT_DIR/root/
  WORKDIR/root-overlay/$PROFILE/
EOF_USAGE
}

preparse_profile_args() {
  # Resolve only values required to locate the profile before applying it. The
  # complete parser runs later and retains authoritative CLI precedence.
  local -a args=("$@")
  local i=0
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --workdir)
        (( i + 1 < ${#args[@]} )) || die "--workdir requires a path"
        WORKDIR="$(canonicalize_workdir "${args[$((i+1))]}")"
        i=$((i+2))
        ;;
      --profile)
        (( i + 1 < ${#args[@]} )) || die "--profile requires a value"
        PROFILE="${args[$((i+1))]}"
        PROFILE_SELECTOR_EXPLICIT=1
        i=$((i+2))
        ;;
      --profile-file)
        (( i + 1 < ${#args[@]} )) || die "--profile-file requires a path"
        PROFILE_FILE="$(normalize_path_input "${args[$((i+1))]}")"
        i=$((i+2))
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) i=$((i+1)) ;;
    esac
  done
}

parse_args() {
  while (($#)); do
    case "$1" in
      --execute) PLAN_ONLY=0; shift ;;
      --plan|--dry-run) PLAN_ONLY=1; shift ;;
      --non-interactive) INTERACTIVE_MODE=0; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --keep-tmp) KEEP_TMP=1; shift ;;
      --workdir) [[ $# -ge 2 ]] || die "--workdir requires a path"; WORKDIR="$(canonicalize_workdir "$2")"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile requires a value"; PROFILE="$2"; PROFILE_SELECTOR_EXPLICIT=1; shift 2 ;;
      --profile-file) [[ $# -ge 2 ]] || die "--profile-file requires a path"; PROFILE_FILE="$(normalize_path_input "$2")"; shift 2 ;;
      --artifact-dir) [[ $# -ge 2 ]] || die "--artifact-dir requires a path"; ARTIFACT_DIR="$(normalize_path_input "$2")"; shift 2 ;;
      --kernel-deb-dir) [[ $# -ge 2 ]] || die "--kernel-deb-dir requires a path"; KERNEL_DEB_DIR="$(normalize_path_input "$2")"; shift 2 ;;
      --kernel-image-deb) [[ $# -ge 2 ]] || die "--kernel-image-deb requires a path"; KERNEL_IMAGE_DEB_OVERRIDE="$(normalize_path_input "$2")"; shift 2 ;;
      --kernel-release) [[ $# -ge 2 ]] || die "--kernel-release requires a value"; EXPECTED_CUSTOM_KERNEL_RELEASE="$2"; shift 2 ;;
      --kernel-release-policy) [[ $# -ge 2 ]] || die "--kernel-release-policy requires prefer, require, or auto"; KERNEL_RELEASE_POLICY="${2,,}"; shift 2 ;;
      --dtb-file) [[ $# -ge 2 ]] || die "--dtb-file requires a path"; DTB_FILE_OVERRIDE="$(normalize_path_input "$2")"; shift 2 ;;
      --dtb-name) [[ $# -ge 2 ]] || die "--dtb-name requires a value"; DTB_INSTALLED_NAME_OVERRIDE="$2"; shift 2 ;;
      --root-source) [[ $# -ge 2 ]] || die "--root-source requires a path"; ROOT_SOURCE="$(normalize_path_input "$2")"; shift 2 ;;
      --firmware-dir) [[ $# -ge 2 ]] || die "--firmware-dir requires a path"; FIRMWARE_SOURCE_OVERRIDE="$(normalize_path_input "$2")"; FIRMWARE_MODE="prestaged"; shift 2 ;;
      --qcom-soc-firmware-deb) [[ $# -ge 2 ]] || die "--qcom-soc-firmware-deb requires a path"; FIRMWARE_QCOM_SOC_DEB="$(normalize_path_input "$2")"; shift 2 ;;
      --qcom-soc-firmware-sha256) [[ $# -ge 2 ]] || die "--qcom-soc-firmware-sha256 requires a hash"; FIRMWARE_QCOM_SOC_SHA256="${2,,}"; shift 2 ;;
      --qcom-soc-firmware-version) [[ $# -ge 2 ]] || die "--qcom-soc-firmware-version requires a value"; FIRMWARE_QCOM_SOC_EXPECTED_VERSION="$2"; shift 2 ;;
      --qcom-soc-firmware-policy) [[ $# -ge 2 ]] || die "--qcom-soc-firmware-policy requires require, auto, or skip"; FIRMWARE_QCOM_SOC_POLICY="$2"; shift 2 ;;
      --repo-policy) [[ $# -ge 2 ]] || die "--repo-policy requires a value"; REPO_POLICY="$2"; shift 2 ;;
      --target-image) [[ $# -ge 2 ]] || die "--target-image requires a value"; TARGET_IMAGE_REF="$2"; shift 2 ;;
      --abroot-image) [[ $# -ge 2 ]] || die "--abroot-image requires a value"; ABROOT_IMAGE_NAME="$2"; shift 2 ;;
      --delivery-mode) [[ $# -ge 2 ]] || die "--delivery-mode requires iso-oci or registry"; DELIVERY_MODE="$2"; shift 2 ;;
      --registry-image) [[ $# -ge 2 ]] || die "--registry-image requires a value"; REGISTRY_IMAGE_REF="$2"; shift 2 ;;
      --iso-image-path) [[ $# -ge 2 ]] || die "--iso-image-path requires a value"; ISO_IMAGE_LAYOUT_PATH="$2"; shift 2 ;;
      --local-registry-port) [[ $# -ge 2 ]] || die "--local-registry-port requires a value"; LOCAL_REGISTRY_PORT="$2"; shift 2 ;;
      --local-registry-logical-host) [[ $# -ge 2 ]] || die "--local-registry-logical-host requires a value"; LOCAL_REGISTRY_LOGICAL_HOST="$2"; shift 2 ;;
      --storage-guard-policy) [[ $# -ge 2 ]] || die "--storage-guard-policy requires repair, strict, or off"; INSTALLER_STORAGE_GUARD_POLICY="${2,,}"; shift 2 ;;
      --live-package-policy) [[ $# -ge 2 ]] || die "--live-package-policy requires upstream-native or legacy-projection"; LIVE_ARM64_PACKAGE_POLICY="${2,,}"; shift 2 ;;
      --live-gdm-delay) [[ $# -ge 2 ]] || die "--live-gdm-delay requires a value"; LIVE_GDM_TIMED_LOGIN_DELAY="$2"; shift 2 ;;
      --live-ref) [[ $# -ge 2 ]] || die "--live-ref requires a value"; LIVE_ISO_REF="$2"; shift 2 ;;
      --custom-image-ref) [[ $# -ge 2 ]] || die "--custom-image-ref requires a value"; CUSTOM_IMAGE_REF="$2"; shift 2 ;;
      --push-target-image) PUSH_TARGET_IMAGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

recompute_paths() {
  WORKDIR="$(canonicalize_workdir "$WORKDIR")"
  ARTIFACT_DIR="${ARTIFACT_DIR:-$WORKDIR/artifacts/$PROFILE}"
  KERNEL_DEB_DIR="${KERNEL_DEB_DIR:-$ARTIFACT_DIR/kernel-debs}"
  [[ -z "$KERNEL_IMAGE_DEB_OVERRIDE" ]] || KERNEL_IMAGE_DEB_OVERRIDE="$(canonicalize_workdir "$KERNEL_IMAGE_DEB_OVERRIDE")"
  TARGET_IMAGE_REPOSITORY="${TARGET_IMAGE_REPOSITORY:-localhost/vanillaos-snapdragonx/vanilla-desktop-${PROFILE}}"
  TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-${TARGET_IMAGE_REPOSITORY}:${BUILD_DATE}}"
  ISO_IMAGE_LAYOUT_PATH="${ISO_IMAGE_LAYOUT_PATH:-/target-images/$PROFILE}"
  DELIVERY_MODE="${DELIVERY_MODE:-iso-oci}"
  VIB_BIN="${VIB_BIN:-$WORKDIR/tools/vib}"

  SOURCES_DIR="$WORKDIR/sources"
  DOWNLOADS_DIR="$WORKDIR/downloads"
  CACHE_DIR="$WORKDIR/cache"
  OUTPUT_DIR="$WORKDIR/output"
  LOG_DIR="$OUTPUT_DIR/logs"
  TMP_DIR="$WORKDIR/tmp"
  TMP_ROOT="$TMP_DIR/v${SCRIPT_VERSION}-${SESSION_ID}"
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
  PROFILE_RESOLVED_JSON="$TMP_ROOT/profile.resolved.json"
  PROFILE_VALIDATION_REPORT="$TMP_ROOT/profile-validation.tsv"
  ROOT_OVERLAY_INVENTORY="$TMP_ROOT/root-overlay-inventory.sha256"
  EMBEDDED_OCI_LAYOUT="$TMP_ROOT/embedded-target-oci"
  EMBEDDED_OCI_INVENTORY="$TMP_ROOT/embedded-image-inventory.tsv"
  EMBEDDED_OCI_TREE_HASH="$TMP_ROOT/target-image-layout.sha256"
  INSTALLER_PATCH_MANIFEST="$TMP_ROOT/installer-patch-manifest.tsv"
  INSTALLED_BOOT_EXPECTED_JSON="$TMP_ROOT/installed-boot-expected.json"
  FIRMWARE_PROVENANCE_DIR="$TMP_ROOT/firmware-provenance"
  FIRMWARE_MERGE_REPORT="$FIRMWARE_PROVENANCE_DIR/firmware-merge.tsv"
  FIRMWARE_STAGED_INVENTORY="$FIRMWARE_PROVENANCE_DIR/staged-firmware.sha256"
  FIRMWARE_PACKAGE_SPECS_FILE="$TMP_ROOT/firmware-package-specs.json"
  FIRMWARE_PACKAGES_RESOLVED_FILE="$TMP_ROOT/firmware-packages.resolved.json"
  FIRMWARE_PACKAGE_INVENTORY_FILE="$FIRMWARE_PROVENANCE_DIR/firmware-packages.tsv"
  FIRMWARE_PACKAGE_LOCK_FILE="$FIRMWARE_PROVENANCE_DIR/firmware-package-lock.json"
  LIVE_KERNEL_CMDLINE_JSON="$TMP_ROOT/live-kernel-command-line.json"
  LIVE_KERNEL_CMDLINE_EVIDENCE="$TMP_ROOT/live-kernel-command-line-evidence.txt"
  TARGET_STORAGE_HOOK_FILE="$TMP_ROOT/target-090-abroot-unlock-var.sh"
  TARGET_STORAGE_HOOK_SHA256_FILE="$TMP_ROOT/target-090-abroot-unlock-var.sh.sha256"
  TARGET_STORAGE_HOOK_EVIDENCE_JSON="$TMP_ROOT/target-storage-hook-evidence.json"
  TARGET_ABROOT_CONFIG_EVIDENCE="$TMP_ROOT/target-abroot.json"
  TARGET_BASE_INSPECT_JSON="$TMP_ROOT/target-base-inspect.json"
  TARGET_USERLAND_COHERENCE_REPORT="$TMP_ROOT/target-userland-coherence.txt"
  REUNION_CONVERGENCE_MANIFEST="$TMP_ROOT/reunion-convergence.tsv"
  UPSTREAM_OCI_PROVENANCE_JSON="$TMP_ROOT/upstream-oci-provenance.json"
  REUNION_ARCHITECTURE_NAME_AUDIT="$TMP_ROOT/reunion-architecture-name-audit.txt"
  KERNEL_PACKAGE_CLOSURE_JSON="$TMP_ROOT/kernel-package-closure.json"
}

resolve_profile_path() {
  local value="$1"
  [[ -n "$value" ]] || { printf ''; return 0; }
  value="$(normalize_path_input "$value")"
  if [[ "$value" == /* ]]; then
    printf '%s' "$value"
  else
    printf '%s/%s' "$WORKDIR" "$value"
  fi
}

json_bool_to_flag() {
  case "$1" in
    true|1|yes) printf '1' ;;
    false|0|no|'') printf '0' ;;
    *) die "Invalid JSON boolean value: $1" ;;
  esac
}

array_has_value() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

append_unique_values() {
  local array_name="$1"
  shift
  local -n target_array="$array_name"
  local value
  for value in "$@"; do
    [[ -n "$value" ]] || continue
    array_has_value "$value" "${target_array[@]}" || target_array+=("$value")
  done
}

validate_relative_firmware_probe() {
  local probe="$1"
  [[ -n "$probe" ]] || die "Firmware probe resolved empty"
  [[ "$probe" != /* ]] || die "Firmware probe must be relative to /usr/lib/firmware: $probe"
  [[ "$probe" != *$'\n'* && "$probe" != *$'\r'* ]] || die "Firmware probe contains a newline: $probe"
  case "/$probe/" in
    */../*|*/./*) die "Unsafe firmware probe path: $probe" ;;
  esac
}

reconcile_profile_hardware_requirements() {
  # Schema-v2 profiles are authoritative. No vendor, GPU, wireless subsystem,
  # or package path is inferred from PROFILE here. This prevents a generic,
  # Lenovo, Dell, or future target from inheriting HP-only board-data rules.
  local probe argument

  # required_paths is the schema-v2 spelling. PROFILE_FIRMWARE_PROBES remains
  # as an internal compatibility array consumed by the established target and
  # live-image validators.
  PROFILE_FIRMWARE_PROBES=()
  append_unique_values PROFILE_FIRMWARE_PROBES "${PROFILE_FIRMWARE_REQUIRED_PATHS[@]}"

  case "$FIRMWARE_BOARD_POLICY" in
    none) : ;;
    optional|required) : ;;
    *) die "Invalid firmware.board_data.policy: $FIRMWARE_BOARD_POLICY" ;;
  esac

  if [[ "$FIRMWARE_BOARD_POLICY" != "none" ]]; then
    [[ -n "$FIRMWARE_BOARD_RAW_PATH" ]] || \
      die "firmware.board_data.raw_path is required when policy=$FIRMWARE_BOARD_POLICY"
    validate_relative_firmware_probe "$FIRMWARE_BOARD_RAW_PATH"
    [[ -z "$FIRMWARE_BOARD_COMPRESSED_PATH" ]] || \
      validate_relative_firmware_probe "$FIRMWARE_BOARD_COMPRESSED_PATH"
    if [[ "$FIRMWARE_BOARD_POLICY" == "required" ]]; then
      append_unique_values PROFILE_FIRMWARE_PROBES "$FIRMWARE_BOARD_RAW_PATH"
      [[ -z "$FIRMWARE_BOARD_COMPRESSED_PATH" ]] || \
        append_unique_values PROFILE_FIRMWARE_PROBES "$FIRMWARE_BOARD_COMPRESSED_PATH"
    fi
  fi

  for probe in "${PROFILE_FIRMWARE_PROBES[@]}" "${PROFILE_INITRAMFS_PROBES[@]}"; do
    [[ -n "$probe" ]] || continue
    validate_relative_firmware_probe "$probe"
  done
  for argument in "${PROFILE_KERNEL_CMDLINE_APPEND[@]}"; do
    [[ -n "$argument" ]] || continue
    [[ "$argument" != *[[:space:]]* ]] || \
      die "Kernel command-line additions must be one token each: $argument"
    [[ "$argument" != *$'\n'* && "$argument" != *$'\r'* ]] || \
      die "Kernel command-line addition contains a newline: $argument"
  done

  printf '%s\n' "${PROFILE_KERNEL_CMDLINE_APPEND[@]}" | \
    jq -Rsc 'split("\n") | map(select(length > 0)) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)' \
    > "$LIVE_KERNEL_CMDLINE_JSON"
  mapfile -t PROFILE_KERNEL_CMDLINE_APPEND < <(jq -r '.[]' "$LIVE_KERNEL_CMDLINE_JSON")
}

synthesize_compatibility_profile() {
  PROFILE_FILE_RESOLVED="$TMP_ROOT/profile.synthesized.json"
  PROFILE_FILE_SOURCE="$PROFILE_FILE_RESOLVED"

  local required_paths_json cmdline_json packages_json board_json
  required_paths_json='[]'
  cmdline_json='[]'
  packages_json='[
    {
      "package": "firmware-qcom-soc",
      "architecture": "all",
      "required": true,
      "source": null,
      "sha256": null,
      "expected_version": null
    },
    {
      "package": "firmware-qcom-dsp",
      "architecture": "all",
      "required": false,
      "source": null,
      "sha256": null,
      "expected_version": null
    }
  ]'
  board_json='{"policy":"none"}'

  if [[ "$PROFILE" == "hp-omnibook-5" ]]; then
    required_paths_json='[
      "qcom/gen71500_sqe.fw",
      "qcom/gen71500_gmu.bin",
      "qcom/x1p42100/gen71500_zap.mbn"
    ]'
    cmdline_json='[
      "clk_ignore_unused",
      "pd_ignore_unused",
      "cma=128M",
      "efi=noruntime",
      "console=tty0"
    ]'
    board_json="$(jq -n \
      --arg raw 'ath11k/WCN6855/hw2.1/board-2.bin' \
      --arg compressed 'ath11k/WCN6855/hw2.1/board-2.bin.zst' \
      --arg subsystem '103c:8d9a' \
      --arg magic 'QCA-ATH11K-BOARD' \
      --arg raw_sha "$HP_ATH11K_BOARD_BIN_SHA256" \
      --arg compressed_sha "$HP_ATH11K_BOARD_ZST_SHA256" \
      '{policy:"required",raw_path:$raw,compressed_path:$compressed,subsystem:$subsystem,magic:$magic,raw_sha256:$raw_sha,compressed_sha256:$compressed_sha}')"
  fi

  jq -n \
    --arg profile "$PROFILE" \
    --arg display "$PROFILE" \
    --arg artifacts "$ARTIFACT_DIR" \
    --arg kernel_dir "$KERNEL_DEB_DIR" \
    --arg kernel_image_deb "$KERNEL_IMAGE_DEB_OVERRIDE" \
    --arg kernel_release "$EXPECTED_CUSTOM_KERNEL_RELEASE" \
    --arg kernel_release_policy "$KERNEL_RELEASE_POLICY" \
    --arg dtb "$DTB_FILE_OVERRIDE" \
    --arg dtb_name "$DTB_INSTALLED_NAME_OVERRIDE" \
    --arg root "$ROOT_SOURCE" \
    --arg firmware "$FIRMWARE_SOURCE_OVERRIDE" \
    --arg qcom "$QCOM_DEVICE_PATH" \
    --arg base "$CUSTOM_IMAGE_BASE" \
    --arg repo "$TARGET_IMAGE_REPOSITORY" \
    --arg abroot "$ABROOT_IMAGE_NAME" \
    --arg iso_path "$ISO_IMAGE_LAYOUT_PATH" \
    --arg registry "$REGISTRY_IMAGE_REF" \
    --arg delivery "$DELIVERY_MODE" \
    --argjson min_free "$MIN_FREE_GIB" \
    --argjson packages "$packages_json" \
    --argjson required_paths "$required_paths_json" \
    --argjson board_data "$board_json" \
    --argjson cmdline "$cmdline_json" \
    '{
      schema_version: 2,
      profile: $profile,
      display_name: $display,
      architecture: "arm64",
      artifacts: {
        directory: $artifacts,
        root_overlay: (if $root == "" then null else $root end)
      },
      kernel: {
        deb_directory: $kernel_dir,
        image_deb: (if $kernel_image_deb == "" then null else $kernel_image_deb end),
        expected_release: (if $kernel_release == "" then null else $kernel_release end),
        release_policy: $kernel_release_policy,
        allow_single_release_discovery: true,
        command_line_append: $cmdline
      },
      dtb: {
        source: (if $dtb == "" then null else $dtb end),
        installed_name: (if $dtb_name == "" then null else $dtb_name end)
      },
      firmware: {
        mode: (if $firmware == "" then "ask" else "prestaged" end),
        source: (if $firmware == "" then null else $firmware end),
        device_path: $qcom,
        packages: $packages,
        required_paths: $required_paths,
        board_data: $board_data,
        initramfs_probes: []
      },
      target_image: {
        base: $base,
        local_repository: $repo,
        abroot_name: (if $abroot == "" then null else $abroot end),
        iso_layout_path: $iso_path,
        registry_fallback: (if $registry == "" then null else $registry end)
      },
      installer: {
        default_delivery: $delivery,
        auto_start: true,
        ignore_cpu: true,
        allow_custom_image_override: true,
        storage_guard_policy: "repair"
      },
      validation: {
        installed_paths: [],
        minimum_free_gib: $min_free
      }
    }' > "$PROFILE_FILE_RESOLVED"
  warn "No profile manifest was found. A schema-v2 compatibility profile was synthesized: $PROFILE_FILE_RESOLVED"
}

firmware_package_required_flag() {
  case "${1,,}" in
    true|1|yes|required|require|strict) printf true ;;
    false|0|no|optional|auto|'') printf false ;;
    *) die "Invalid firmware package required value: $1" ;;
  esac
}

apply_legacy_firmware_package_override() {
  # The established qcom-soc CLI/environment interface remains a compatibility
  # override. It modifies only the firmware-qcom-soc entry and does not prevent
  # profiles from declaring other packages such as firmware-qcom-dsp.
  if [[ -z "$ENV_FIRMWARE_QCOM_SOC_DEB_SET" &&
        -z "$ENV_FIRMWARE_QCOM_SOC_SHA256_SET" &&
        -z "$ENV_FIRMWARE_QCOM_SOC_VERSION_SET" &&
        -z "$ENV_FIRMWARE_QCOM_SOC_POLICY_SET" ]]; then
    return 0
  fi

  local required=true disabled=false
  case "${FIRMWARE_QCOM_SOC_POLICY,,}" in
    skip|none|disabled) required=false; disabled=true ;;
    auto|optional) required=false ;;
    require|required|strict|'') required=true ;;
    *) die "Invalid Qualcomm SoC firmware compatibility policy: $FIRMWARE_QCOM_SOC_POLICY" ;;
  esac

  jq \
    --arg source "$FIRMWARE_QCOM_SOC_DEB" \
    --arg sha "${FIRMWARE_QCOM_SOC_SHA256,,}" \
    --arg version "$FIRMWARE_QCOM_SOC_EXPECTED_VERSION" \
    --argjson required "$required" \
    --argjson disabled "$disabled" \
    '
      map(select(.package != "firmware-qcom-soc" or (.architecture // "all") != "all"))
      + (if $disabled then [] else [{
          package:"firmware-qcom-soc",
          architecture:"all",
          required:$required,
          source:(if $source=="" then null else $source end),
          sha256:(if $sha=="" then null else $sha end),
          expected_version:(if $version=="" then null else $version end)
        }] end)
    ' "$FIRMWARE_PACKAGE_SPECS_FILE" > "$FIRMWARE_PACKAGE_SPECS_FILE.tmp"
  mv -f "$FIRMWARE_PACKAGE_SPECS_FILE.tmp" "$FIRMWARE_PACKAGE_SPECS_FILE"
}

apply_firmware_package_json_overrides() {
  [[ -n "$FIRMWARE_PACKAGE_OVERRIDES_JSON" ]] || return 0
  printf '%s' "$FIRMWARE_PACKAGE_OVERRIDES_JSON" | jq -e 'type=="array"' >/dev/null || \
    die "FIRMWARE_PACKAGE_OVERRIDES_JSON must be a JSON array"
  printf '%s' "$FIRMWARE_PACKAGE_OVERRIDES_JSON" > "$TMP_ROOT/firmware-package-overrides.json"
  jq -s '
    def key: (.package + "\u0000" + (.architecture // "all"));
    reduce .[1][] as $override (.[0];
      map(select(key != ($override | key))) + [$override]
    )
  ' "$FIRMWARE_PACKAGE_SPECS_FILE" "$TMP_ROOT/firmware-package-overrides.json" \
    > "$FIRMWARE_PACKAGE_SPECS_FILE.tmp"
  mv -f "$FIRMWARE_PACKAGE_SPECS_FILE.tmp" "$FIRMWARE_PACKAGE_SPECS_FILE"
}

validate_firmware_package_specs() {
  jq -e '
    type == "array" and
    all(.[];
      (type == "object") and
      (.package | type == "string" and test("^[a-z0-9][a-z0-9+.-]+$")) and
      ((.architecture // "all") | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
      ((.required // false) | type == "boolean") and
      ((.source // null) == null or (.source | type == "string" and length > 0)) and
      ((.sha256 // null) == null or (.sha256 | type == "string" and test("^[0-9A-Fa-f]{64}$"))) and
      ((.expected_version // null) == null or (.expected_version | type == "string" and length > 0))
    ) and
    (([.[] | (.package + "\u0000" + (.architecture // "all"))] | length) ==
     ([.[] | (.package + "\u0000" + (.architecture // "all"))] | unique | length))
  ' "$FIRMWARE_PACKAGE_SPECS_FILE" >/dev/null || \
    die "firmware.packages contains an invalid or duplicate package declaration"
}

normalize_hardware_profile_schema() {
  local input="$1" schema profile normalized
  schema="$(jq -r '.schema_version // empty' "$input")"
  profile="$(jq -r '.profile // empty' "$input")"

  case "$schema" in
    2)
      PROFILE_FILE_RESOLVED="$input"
      ;;
    1)
      normalized="$TMP_ROOT/profile.schema2.json"
      jq \
        --arg hp_raw_sha "$HP_ATH11K_BOARD_BIN_SHA256" \
        --arg hp_zst_sha "$HP_ATH11K_BOARD_ZST_SHA256" \
        '
        .schema_version = 2
        | .firmware = (.firmware // {})
        | .firmware.packages = (
            if (.firmware.qcom_soc_package? != null) then
              if ((.firmware.qcom_soc_package.policy // "require") | IN("skip","none","disabled")) then []
              else [{
                package: "firmware-qcom-soc",
                architecture: "all",
                required: ((.firmware.qcom_soc_package.policy // "require") | IN("require","required","strict")),
                source: (.firmware.qcom_soc_package.source // null),
                sha256: (.firmware.qcom_soc_package.sha256 // null),
                expected_version: (.firmware.qcom_soc_package.expected_version // null)
              }] end
            else [] end
          )
        | .firmware.required_paths = (.firmware.required_paths // .firmware.probes // [])
        | .firmware.board_data = (
            if .profile == "hp-omnibook-5" then {
              policy: "required",
              raw_path: "ath11k/WCN6855/hw2.1/board-2.bin",
              compressed_path: "ath11k/WCN6855/hw2.1/board-2.bin.zst",
              subsystem: "103c:8d9a",
              magic: "QCA-ATH11K-BOARD",
              raw_sha256: $hp_raw_sha,
              compressed_sha256: $hp_zst_sha
            } else {policy:"none"} end
          )
        | del(.firmware.qcom_soc_package, .firmware.probes)
        ' "$input" > "$normalized"
      PROFILE_FILE_RESOLVED="$normalized"
      warn "Migrated schema-1 hardware profile '$profile' to schema 2 in memory: $normalized"
      ;;
    *) die "Unsupported hardware-profile schema version '$schema'; supported versions are 1 and 2" ;;
  esac
}

load_hardware_profile() {
  local candidate profile_id schema_version value

  if [[ -n "$PROFILE_FILE" ]]; then
    PROFILE_FILE_RESOLVED="$(resolve_profile_path "$PROFILE_FILE")"
  else
    for candidate in \
      "$WORKDIR/profiles/$PROFILE/profile.json" \
      "$WORKDIR/profiles/$PROFILE.json"; do
      if [[ -f "$candidate" ]]; then
        PROFILE_FILE_RESOLVED="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$PROFILE_FILE_RESOLVED" ]]; then
    synthesize_compatibility_profile
  fi

  [[ -f "$PROFILE_FILE_RESOLVED" ]] || die "Hardware profile does not exist: $PROFILE_FILE_RESOLVED"
  jq -e . "$PROFILE_FILE_RESOLVED" >/dev/null || die "Hardware profile is not valid JSON: $PROFILE_FILE_RESOLVED"
  PROFILE_FILE_SOURCE="$PROFILE_FILE_RESOLVED"
  normalize_hardware_profile_schema "$PROFILE_FILE_RESOLVED"
  schema_version="$(jq -r '.schema_version // empty' "$PROFILE_FILE_RESOLVED")"
  [[ "$schema_version" == "$PROFILE_SCHEMA_VERSION" ]] || \
    die "Internal profile migration did not produce schema version $PROFILE_SCHEMA_VERSION"

  profile_id="$(jq -r '.profile // empty' "$PROFILE_FILE_RESOLVED")"
  [[ "$profile_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || \
    die "Unsafe or missing hardware-profile identifier: $profile_id"
  if [[ "$profile_id" != "$PROFILE" ]]; then
    if [[ -n "$PROFILE_FILE" && "$PROFILE_SELECTOR_EXPLICIT" == "0" ]]; then
      info "Adopting profile identifier from explicit manifest: $profile_id"
      PROFILE="$profile_id"
    else
      die "Selected profile '$PROFILE' does not match manifest profile '$profile_id'"
    fi
  fi

  PROFILE_DISPLAY_NAME="$(jq -r '.display_name // .profile' "$PROFILE_FILE_RESOLVED")"
  PROFILE_ARCHITECTURE="$(jq -r '.architecture // "arm64"' "$PROFILE_FILE_RESOLVED")"
  [[ "$PROFILE_ARCHITECTURE" == "arm64" ]] || \
    die "v$SCRIPT_VERSION supports ARM64 profiles only; profile requested $PROFILE_ARCHITECTURE"

  if [[ -z "$ENV_ARTIFACT_DIR_SET" ]]; then
    value="$(jq -r '.artifacts.directory // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || ARTIFACT_DIR="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_KERNEL_DEB_DIR_SET" ]]; then
    value="$(jq -r '.kernel.deb_directory // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || KERNEL_DEB_DIR="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_KERNEL_IMAGE_DEB_SET" ]]; then
    value="$(jq -r '.kernel.image_deb // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || KERNEL_IMAGE_DEB_OVERRIDE="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_ROOT_SOURCE_SET" ]]; then
    value="$(jq -r '.artifacts.root_overlay // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || ROOT_SOURCE="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_DTB_FILE_SET" ]]; then
    value="$(jq -r '.dtb.source // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || DTB_FILE_OVERRIDE="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_DTB_NAME_SET" ]]; then
    value="$(jq -r '.dtb.installed_name // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || DTB_INSTALLED_NAME_OVERRIDE="$value"
  fi
  if [[ -z "$ENV_KERNEL_RELEASE_SET" ]]; then
    value="$(jq -r '.kernel.expected_release // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || EXPECTED_CUSTOM_KERNEL_RELEASE="$value"
  fi
  if [[ -z "$ENV_KERNEL_RELEASE_POLICY_SET" ]]; then
    value="$(jq -r '.kernel.release_policy // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || KERNEL_RELEASE_POLICY="$value"
  fi
  if [[ -z "$ENV_FIRMWARE_SOURCE_SET" ]]; then
    value="$(jq -r '.firmware.source // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || FIRMWARE_SOURCE_OVERRIDE="$(resolve_profile_path "$value")"
  fi
  value="$(jq -r '.firmware.mode // empty' "$PROFILE_FILE_RESOLVED")"
  [[ -z "$value" || "$FIRMWARE_MODE" != "ask" ]] || FIRMWARE_MODE="$value"
  value="$(jq -r '.firmware.device_path // empty' "$PROFILE_FILE_RESOLVED")"
  [[ -z "$value" ]] || QCOM_DEVICE_PATH="$value"

  if [[ -z "$ENV_CUSTOM_IMAGE_BASE_SET" ]]; then
    value="$(jq -r '.target_image.base // empty' "$PROFILE_FILE_RESOLVED")"
    case "$value" in
      ghcr.io/vanilla-os/desktop:dev|ghcr.io/vanilla-os/gnome:dev)
        warn "Profile uses pre-release Reunion desktop taxonomy '$value'; resolving to stable ghcr.io/vanilla-os/gnome:latest for v$SCRIPT_VERSION."
        value="ghcr.io/vanilla-os/gnome:latest"
        ;;
    esac
    [[ -z "$value" ]] || CUSTOM_IMAGE_BASE="$value"
  fi
  if [[ -z "$ENV_TARGET_REPOSITORY_SET" ]]; then
    value="$(jq -r '.target_image.local_repository // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || TARGET_IMAGE_REPOSITORY="$value"
  fi
  if [[ -z "$ENV_TARGET_IMAGE_SET" && -n "$TARGET_IMAGE_REPOSITORY" ]]; then
    TARGET_IMAGE_REF="${TARGET_IMAGE_REPOSITORY}:${BUILD_DATE}"
  fi
  if [[ -z "$ENV_ABROOT_IMAGE_SET" ]]; then
    value="$(jq -r '.target_image.abroot_name // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || ABROOT_IMAGE_NAME="$value"
  fi
  if [[ -z "$ENV_ISO_LAYOUT_PATH_SET" ]]; then
    value="$(jq -r '.target_image.iso_layout_path // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || ISO_IMAGE_LAYOUT_PATH="$value"
  fi
  if [[ -z "$ENV_REGISTRY_IMAGE_SET" ]]; then
    value="$(jq -r '.target_image.registry_fallback // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || REGISTRY_IMAGE_REF="$value"
  fi
  if [[ -z "$ENV_DELIVERY_MODE_SET" ]]; then
    value="$(jq -r '.installer.default_delivery // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || DELIVERY_MODE="$value"
  fi

  INSTALLER_AUTOSTART="$(json_bool_to_flag "$(jq -r '.installer.auto_start // true' "$PROFILE_FILE_RESOLVED")")"
  INSTALLER_IGNORE_CPU="$(json_bool_to_flag "$(jq -r '.installer.ignore_cpu // true' "$PROFILE_FILE_RESOLVED")")"
  INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE="$(json_bool_to_flag "$(jq -r '.installer.allow_custom_image_override // true' "$PROFILE_FILE_RESOLVED")")"

  if [[ -z "$ENV_INSTALLER_STORAGE_GUARD_POLICY_SET" ]]; then
    value="$(jq -r '.installer.storage_guard_policy // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || INSTALLER_STORAGE_GUARD_POLICY="${value,,}"
  fi

  if [[ -z "$ENV_MIN_FREE_GIB_SET" ]]; then
    value="$(jq -r '.validation.minimum_free_gib // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || MIN_FREE_GIB="$value"
  fi

  mapfile -t PROFILE_FIRMWARE_REQUIRED_PATHS < <(jq -r '.firmware.required_paths[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_INITRAMFS_PROBES < <(jq -r '.firmware.initramfs_probes[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_INSTALLED_PATH_PROBES < <(jq -r '.validation.installed_paths[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_KERNEL_CMDLINE_APPEND < <(jq -r '.kernel.command_line_append[]? // empty' "$PROFILE_FILE_RESOLVED")

  FIRMWARE_BOARD_POLICY="$(jq -r '.firmware.board_data.policy // "none"' "$PROFILE_FILE_RESOLVED" | tr '[:upper:]' '[:lower:]')"
  FIRMWARE_BOARD_RAW_PATH="$(jq -r '.firmware.board_data.raw_path // empty' "$PROFILE_FILE_RESOLVED")"
  FIRMWARE_BOARD_COMPRESSED_PATH="$(jq -r '.firmware.board_data.compressed_path // empty' "$PROFILE_FILE_RESOLVED")"
  FIRMWARE_BOARD_SUBSYSTEM="$(jq -r '.firmware.board_data.subsystem // empty' "$PROFILE_FILE_RESOLVED")"
  FIRMWARE_BOARD_MAGIC="$(jq -r '.firmware.board_data.magic // empty' "$PROFILE_FILE_RESOLVED")"
  FIRMWARE_BOARD_RAW_SHA256="$(jq -r '.firmware.board_data.raw_sha256 // empty' "$PROFILE_FILE_RESOLVED" | tr '[:upper:]' '[:lower:]')"
  FIRMWARE_BOARD_COMPRESSED_SHA256="$(jq -r '.firmware.board_data.compressed_sha256 // empty' "$PROFILE_FILE_RESOLVED" | tr '[:upper:]' '[:lower:]')"

  jq '.firmware.packages // []' "$PROFILE_FILE_RESOLVED" > "$FIRMWARE_PACKAGE_SPECS_FILE"
  apply_legacy_firmware_package_override
  apply_firmware_package_json_overrides
  validate_firmware_package_specs
  printf '[]\n' > "$FIRMWARE_PACKAGES_RESOLVED_FILE"
  reconcile_profile_hardware_requirements

  [[ "$ISO_IMAGE_LAYOUT_PATH" == /target-images/* ]] || \
    die "ISO image-layout path must be beneath /target-images: $ISO_IMAGE_LAYOUT_PATH"
  [[ "$LOCAL_REGISTRY_PORT" =~ ^[0-9]+$ ]] && (( LOCAL_REGISTRY_PORT >= 1024 && LOCAL_REGISTRY_PORT <= 65535 )) || \
    die "Invalid unprivileged local registry port: $LOCAL_REGISTRY_PORT"

  case "$LOCAL_REGISTRY_HOST" in
    127.0.0.1|localhost) : ;;
    *) die "The embedded registry bridge must remain loopback-only: $LOCAL_REGISTRY_HOST" ;;
  esac
  [[ "$LOCAL_REGISTRY_LOGICAL_HOST" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || \
    die "Invalid logical local-registry host: $LOCAL_REGISTRY_LOGICAL_HOST"
  [[ "$LOCAL_REGISTRY_LOGICAL_HOST" == *.* ]] || \
    die "Logical local-registry host must be fully qualified: $LOCAL_REGISTRY_LOGICAL_HOST"
  [[ "$LOCAL_REGISTRY_LOGICAL_HOST" != *:* ]] || \
    die "Logical local-registry host must not contain a port: $LOCAL_REGISTRY_LOGICAL_HOST"
  [[ "$LOCAL_REGISTRY_NAMESPACE" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || \
    die "Invalid local-registry namespace: $LOCAL_REGISTRY_NAMESPACE"

  case "$DELIVERY_MODE" in
    iso-oci) : ;;
    registry)
      [[ -n "$REGISTRY_IMAGE_REF" ]] || die "registry delivery requires REGISTRY_IMAGE_REF or target_image.registry_fallback"
      ;;
    *) die "Unsupported delivery mode: $DELIVERY_MODE" ;;
  esac

  case "$KERNEL_RELEASE_POLICY" in
    prefer|require|auto) : ;;
    *) die "Unsupported kernel release policy: $KERNEL_RELEASE_POLICY" ;;
  esac

  case "$INSTALLER_STORAGE_GUARD_POLICY" in
    repair|strict|off) : ;;
    *) die "Unsupported installer storage-guard policy: $INSTALLER_STORAGE_GUARD_POLICY" ;;
  esac

  ok "Loaded hardware profile: $PROFILE_DISPLAY_NAME ($PROFILE)"
  info "Profile manifest: $PROFILE_FILE_RESOLVED"
}

write_resolved_profile() {
  local firmware_json initramfs_json installed_json cmdline_json package_specs package_resolved board_json
  firmware_json="$(printf '%s\n' "${PROFILE_FIRMWARE_PROBES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  initramfs_json="$(printf '%s\n' "${PROFILE_INITRAMFS_PROBES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  installed_json="$(printf '%s\n' "${PROFILE_INSTALLED_PATH_PROBES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  cmdline_json="$(printf '%s\n' "${PROFILE_KERNEL_CMDLINE_APPEND[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  package_specs="$(cat "$FIRMWARE_PACKAGE_SPECS_FILE" 2>/dev/null || printf '[]')"
  package_resolved="$(cat "$FIRMWARE_PACKAGES_RESOLVED_FILE" 2>/dev/null || printf '[]')"
  board_json="$(jq -n \
    --arg policy "$FIRMWARE_BOARD_POLICY" \
    --arg raw "$FIRMWARE_BOARD_RAW_PATH" \
    --arg compressed "$FIRMWARE_BOARD_COMPRESSED_PATH" \
    --arg subsystem "$FIRMWARE_BOARD_SUBSYSTEM" \
    --arg magic "$FIRMWARE_BOARD_MAGIC" \
    --arg raw_sha "$FIRMWARE_BOARD_RAW_SHA256" \
    --arg compressed_sha "$FIRMWARE_BOARD_COMPRESSED_SHA256" \
    '{policy:$policy,raw_path:(if $raw=="" then null else $raw end),compressed_path:(if $compressed=="" then null else $compressed end),subsystem:(if $subsystem=="" then null else $subsystem end),magic:(if $magic=="" then null else $magic end),raw_sha256:(if $raw_sha=="" then null else $raw_sha end),compressed_sha256:(if $compressed_sha=="" then null else $compressed_sha end)}')"

  jq -n \
    --argjson schema "$PROFILE_SCHEMA_VERSION" \
    --arg profile "$PROFILE" \
    --arg display "$PROFILE_DISPLAY_NAME" \
    --arg architecture "$PROFILE_ARCHITECTURE" \
    --arg source_profile "$PROFILE_FILE_SOURCE" \
    --arg normalized_profile "$PROFILE_FILE_RESOLVED" \
    --arg artifact_dir "$ARTIFACT_DIR" \
    --arg kernel_dir "$KERNEL_DEB_DIR" \
    --arg kernel_image_deb "$KERNEL_IMAGE_DEB_OVERRIDE" \
    --arg kernel_release "$EXPECTED_CUSTOM_KERNEL_RELEASE" \
    --arg kernel_release_policy "$KERNEL_RELEASE_POLICY" \
    --arg selected_kernel_release "$KERNEL_RELEASE" \
    --arg dtb_source "$DTB_FILE_OVERRIDE" \
    --arg dtb_name "$DTB_INSTALLED_NAME_OVERRIDE" \
    --arg root_source "$ROOT_SOURCE" \
    --arg firmware_mode "$FIRMWARE_MODE" \
    --arg firmware_source "$FIRMWARE_SOURCE_OVERRIDE" \
    --arg device_path "$QCOM_DEVICE_PATH" \
    --arg base "$CUSTOM_IMAGE_BASE" \
    --arg target_ref "$TARGET_IMAGE_REF" \
    --arg abroot "$ABROOT_IMAGE_NAME" \
    --arg iso_path "$ISO_IMAGE_LAYOUT_PATH" \
    --arg delivery "$DELIVERY_MODE" \
    --arg storage_guard_policy "$INSTALLER_STORAGE_GUARD_POLICY" \
    --arg registry "$REGISTRY_IMAGE_REF" \
    --argjson autostart "$INSTALLER_AUTOSTART" \
    --argjson ignore_cpu "$INSTALLER_IGNORE_CPU" \
    --argjson allow_custom "$INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE" \
    --argjson min_free "$MIN_FREE_GIB" \
    --argjson firmware_packages "$package_specs" \
    --argjson firmware_packages_resolved "$package_resolved" \
    --argjson firmware_probes "$firmware_json" \
    --argjson board_data "$board_json" \
    --argjson initramfs_probes "$initramfs_json" \
    --argjson installed_paths "$installed_json" \
    --argjson cmdline "$cmdline_json" \
    '{
      schema_version: $schema,
      profile: $profile,
      display_name: $display,
      architecture: $architecture,
      source_profile: $source_profile,
      normalized_profile: $normalized_profile,
      resolved: {
        artifact_directory: $artifact_dir,
        kernel_deb_directory: $kernel_dir,
        kernel_image_deb_override: (if $kernel_image_deb == "" then null else $kernel_image_deb end),
        requested_kernel_release: (if $kernel_release == "" then null else $kernel_release end),
        kernel_release_policy: $kernel_release_policy,
        selected_kernel_release: (if $selected_kernel_release == "" then null else $selected_kernel_release end),
        dtb_source: (if $dtb_source == "" then null else $dtb_source end),
        dtb_installed_name: (if $dtb_name == "" then null else $dtb_name end),
        root_overlay: (if $root_source == "" then null else $root_source end),
        firmware_mode: $firmware_mode,
        firmware_source: (if $firmware_source == "" then null else $firmware_source end),
        firmware_device_path: $device_path,
        firmware_packages: $firmware_packages,
        firmware_packages_resolved: $firmware_packages_resolved,
        firmware_required_paths: $firmware_probes,
        firmware_board_data: $board_data,
        initramfs_probes: $initramfs_probes,
        kernel_command_line_append: $cmdline,
        target_base: $base,
        target_image: $target_ref,
        abroot_image: $abroot,
        iso_layout_path: $iso_path,
        delivery_mode: $delivery,
        installer_storage_guard_policy: $storage_guard_policy,
        registry_fallback: (if $registry == "" then null else $registry end),
        installer_autostart: $autostart,
        installer_ignore_cpu: $ignore_cpu,
        allow_custom_image_override: $allow_custom,
        installed_path_probes: $installed_paths,
        minimum_free_gib: $min_free
      }
    }' > "$PROFILE_RESOLVED_JSON"

  {
    printf 'check\tstatus\tdetail\n'
    printf 'schema_version\tpass\t%s\n' "$PROFILE_SCHEMA_VERSION"
    printf 'profile_identifier\tpass\t%s\n' "$PROFILE"
    printf 'architecture\tpass\t%s\n' "$PROFILE_ARCHITECTURE"
    printf 'artifact_directory\tresolved\t%s\n' "$ARTIFACT_DIR"
    printf 'kernel_deb_directory\tresolved\t%s\n' "$KERNEL_DEB_DIR"
    printf 'kernel_image_deb\t%s\t%s\n' "$([[ -n "$KERNEL_IMAGE_DEB_OVERRIDE" ]] && printf selected || printf discovery)" "${KERNEL_IMAGE_DEB_OVERRIDE:-payload discovery}"
    printf 'kernel_release_policy\tresolved\t%s\n' "$KERNEL_RELEASE_POLICY"
    printf 'kernel_release_requested\t%s\t%s\n' "$([[ -n "$EXPECTED_CUSTOM_KERNEL_RELEASE" ]] && printf configured || printf auto)" "${EXPECTED_CUSTOM_KERNEL_RELEASE:-none}"
    printf 'kernel_release_selected\t%s\t%s\n' "$([[ -n "$KERNEL_RELEASE" ]] && printf resolved || printf pending)" "${KERNEL_RELEASE:-not-yet-discovered}"
    printf 'dtb_source\t%s\t%s\n' "$([[ -n "$DTB_FILE_OVERRIDE" ]] && printf resolved || printf discovery)" "${DTB_FILE_OVERRIDE:-deterministic discovery}"
    printf 'firmware_package_specs\tpass\t%s declarations\n' "$(jq 'length' "$FIRMWARE_PACKAGE_SPECS_FILE")"
    printf 'firmware_packages_resolved\t%s\t%s packages\n' "$([[ $(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE") -gt 0 ]] && printf pass || printf pending)" "$(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")"
    printf 'firmware_required_paths\tpass\t%s\n' "${PROFILE_FIRMWARE_PROBES[*]:-none}"
    printf 'firmware_board_data_policy\tpass\t%s\n' "$FIRMWARE_BOARD_POLICY"
    printf 'kernel_command_line\tresolved\t%s\n' "${PROFILE_KERNEL_CMDLINE_APPEND[*]:-none}"
    printf 'delivery_mode\tpass\t%s\n' "$DELIVERY_MODE"
    printf 'installer_storage_guard_policy\tpass\t%s\n' "$INSTALLER_STORAGE_GUARD_POLICY"
    printf 'iso_layout_path\tpass\t%s\n' "$ISO_IMAGE_LAYOUT_PATH"
  } > "$PROFILE_VALIDATION_REPORT"
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
  choice="$(menu "Legacy Root Overlay Compatibility Input\n\nReunion makes /root persistent through /var/root. r5 therefore preserves any selected legacy root-overlay bytes under immutable /usr/lib/vanillaos-snapdragonx/root-source-overlay instead of placing project payload in /root.\n\nDetected/default path:\n  $default_desc" "1" \
    "1|Use the detected/default compatibility source|Preserve the source under the project immutable-data namespace." \
    "2|Choose another directory|Enter a directory whose contents should be preserved as compatibility data." \
    "3|Skip the legacy root overlay|Build without additional compatibility content." \
    "4|Open a shell before choosing|Inspect the artifact tree and return.")"
  case "$choice" in
    1) [[ -z "$ROOT_SOURCE" || -d "$ROOT_SOURCE" ]] || die "Default root source does not exist: $ROOT_SOURCE" ;;
    2) ROOT_SOURCE="$(prompt_path "Legacy root-overlay compatibility directory" "${ROOT_SOURCE:-$WORKDIR/artifacts/root}")"; [[ -d "$ROOT_SOURCE" ]] || die "Root source does not exist: $ROOT_SOURCE" ;;
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

${C_BOLD}VanillaOS-SnapdragonX ARM64 Container-Model Builder${C_RESET}
Version: $SCRIPT_VERSION

Work directory:   $WORKDIR
Profile:          $PROFILE ($PROFILE_DISPLAY_NAME)
Profile source:   $PROFILE_FILE_SOURCE
Profile normalized:$PROFILE_FILE_RESOLVED
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

choose_installer_delivery() {
  if is_interactive; then
    local choice default_choice=1
    [[ "$DELIVERY_MODE" == "registry" ]] && default_choice=2
    choice="$(menu "Installed Image Delivery

ISO-local delivery embeds the verified target OCI layout and requires no external network. Registry mode remains available as an explicit fallback." "$default_choice"       "1|Embed and install the verified OCI from this ISO [RECOMMENDED]|Start a loopback-only registry bridge over the ISO-local OCI layout."       "2|Install from an external registry reference|Use the profile registry fallback or enter an explicit image reference."       "3|Open a shell before choosing|Inspect target image and profile settings.")"
    case "$choice" in
      1) DELIVERY_MODE="iso-oci" ;;
      2)
        DELIVERY_MODE="registry"
        REGISTRY_IMAGE_REF="$(prompt_text "Registry image reference" "${REGISTRY_IMAGE_REF:-$TARGET_IMAGE_REF}")"
        ;;
      3) open_shell "$WORKDIR"; choose_installer_delivery; return ;;
    esac
  fi

  case "$DELIVERY_MODE" in
    iso-oci) : ;;
    registry) [[ -n "$REGISTRY_IMAGE_REF" ]] || die "Registry delivery requires an image reference." ;;
    *) die "Unsupported installer delivery mode: $DELIVERY_MODE" ;;
  esac
}

configure_build_inputs_interactively() {
  choose_artifact_directory
  choose_root_overlay
  choose_firmware_source
  choose_target_image
  choose_installer_delivery
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
skopeo|skopeo
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
  dpkg-deb -c "$deb" > "$output"
}

deb_listing_has_regular_boot_kernel() {
  local listing="$1" release="$2"
  awk -v release="$release" '
    $1 ~ /^-/ { path=$NF; sub(/^\.\//, "", path); if (path == "boot/vmlinuz-" release) found=1 }
    END { exit(found ? 0 : 1) }
  ' "$listing"
}

deb_listing_has_runtime_module_object() {
  local listing="$1" release="$2"
  awk -v release="$release" '
    $1 ~ /^-/ {
      path=$NF; sub(/^\.\//, "", path)
      prefix1="lib/modules/" release "/"; prefix2="usr/lib/modules/" release "/"
      if ((index(path, prefix1) == 1 || index(path, prefix2) == 1) && path ~ /\.ko(\.(gz|xz|zst))?$/) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$listing"
}

deb_listing_has_kernel_auxiliary_payload() {
  local listing="$1" release="$2"
  awk -v release="$release" '
    $1 ~ /^-/ {
      path=$NF; sub(/^\.\//, "", path)
      if (path == "boot/config-" release || path == "boot/System.map-" release ||
          index(path, "usr/lib/linux-image-" release "/") == 1 || index(path, "lib/linux-image-" release "/") == 1 ||
          index(path, "boot/dtb-" release "/") == 1 || index(path, "boot/dtb/" release "/") == 1) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$listing"
}

kernel_deb_listing_path() {
  local deb="$1" key
  key="$(printf '%s' "$deb" | sha256sum | awk '{print $1}')"
  printf '%s/deb-listings/%s.contents.txt' "$TMP_ROOT" "$key"
}

kernel_deb_canonical_name() {
  local deb="$1" pkg version arch safe_version
  pkg="$(package_field "$deb" Package)"; version="$(package_field "$deb" Version)"; arch="$(package_field "$deb" Architecture)"
  [[ -n "$pkg" && -n "$version" && -n "$arch" ]] || die "Unable to construct canonical package name for $deb"
  safe_version="$(printf '%s' "$version" | sed -E 's/:/%3A/g; s/[^A-Za-z0-9.+~_=%-]/_/g')"
  printf '%s_%s_%s.deb' "$pkg" "$safe_version" "$arch"
}

select_kernel_release_from_candidates() {
  local -a releases=("$@")
  mapfile -t releases < <(printf '%s\n' "${releases[@]}" | sed '/^$/d' | sort -u)
  if [[ -n "$EXPECTED_CUSTOM_KERNEL_RELEASE" && "$KERNEL_RELEASE_POLICY" != "auto" ]]; then
    local r found=0
    for r in "${releases[@]}"; do [[ "$r" == "$EXPECTED_CUSTOM_KERNEL_RELEASE" ]] && found=1; done
    if (( found == 1 )); then printf '%s' "$EXPECTED_CUSTOM_KERNEL_RELEASE"; return; fi
    [[ "$KERNEL_RELEASE_POLICY" != "require" ]] || die "Required kernel release '$EXPECTED_CUSTOM_KERNEL_RELEASE' was not found. Detected: ${releases[*]:-none}"
    warn "Preferred kernel release '$EXPECTED_CUSTOM_KERNEL_RELEASE' is absent; selecting from detected payload releases: ${releases[*]:-none}"
  fi
  ((${#releases[@]} > 0)) || die "No kernel release could be derived from a regular /boot/vmlinuz-<release> package payload."
  if ((${#releases[@]} == 1)); then printf '%s' "${releases[0]}"; return; fi
  if ! is_interactive; then die "Multiple kernel releases detected: ${releases[*]}. Set --kernel-release."; fi
  local options=() i=1 choice r
  for r in "${releases[@]}"; do options+=("$i|Use kernel release $r|Select this exact uname -r."); i=$((i+1)); done
  choice="$(menu "Multiple Kernel Releases Detected" "1" "${options[@]}")"
  printf '%s' "${releases[$((choice-1))]}"
}

classify_kernel_deb_for_target() {
  local deb="$1" pkg listing
  pkg="$(package_field "$deb" Package)"; listing="$(kernel_deb_listing_path "$deb")"
  if [[ -f "$listing" ]] && awk '$1 ~ /^-/ {p=$NF; sub(/^\.\//,"",p); if (p ~ /^boot\/vmlinuz-/) f=1} END{exit(f?0:1)}' "$listing"; then
    printf '%s\n' kernel-image
  elif [[ -f "$listing" ]] && awk '$1 ~ /^-/ {p=$NF; sub(/^\.\//,"",p); if (p ~ /^(usr\/)?lib\/modules\/[^/]+\/.*\.ko(\.(gz|xz|zst))?$/) f=1} END{exit(f?0:1)}' "$listing"; then
    printf '%s\n' kernel-modules
  else
    case "$pkg" in
      linux-headers-*|linux-*-headers-*) printf '%s\n' headers ;;
      linux-qcom-*-tools-*|linux-tools-*|linux-*-tools-*) printf '%s\n' tools ;;
      linux-libc-dev|*-dev|*-dbgsym|*-dbg) printf '%s\n' development ;;
      linux-source-*|linux-buildinfo-*|*.buildinfo|*.changes) printf '%s\n' metadata ;;
      *) printf '%s\n' support ;;
    esac
  fi
}

array_contains_exact() {
  local needle="$1"; shift; local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

kernel_deb_selection_role() {
  local deb="$1"
  [[ -s "$KERNEL_PACKAGE_CLOSURE_JSON" ]] || { printf 'reference-only'; return 0; }
  jq -r --arg path "$deb" '.selected[]? | select(.path == $path) | .role' "$KERNEL_PACKAGE_CLOSURE_JSON" | sed -n '1p'
}

kernel_deb_selection_reason() {
  local deb="$1"
  [[ -s "$KERNEL_PACKAGE_CLOSURE_JSON" ]] || { printf 'not selected'; return 0; }
  jq -r --arg path "$deb" '.selected[]? | select(.path == $path) | .reason' "$KERNEL_PACKAGE_CLOSURE_JSON" | sed -n '1p'
}

write_kernel_package_selection_manifest() {
  local manifest="$TMP_ROOT/kernel-package-selection.tsv"
  local deb pkg version arch class target live role reason archive_name
  {
    printf 'package\tversion\tarchitecture\tclass\tclosure_role\ttarget_install\tlive_extract\tarchive_path\tsource_deb\treason\n'
    for deb in "${KERNEL_DEBS[@]}"; do
      pkg="$(package_field "$deb" Package)"; version="$(package_field "$deb" Version)"; arch="$(package_field "$deb" Architecture)"
      class="$(classify_kernel_deb_for_target "$deb")"; role="$(kernel_deb_selection_role "$deb")"; reason="$(kernel_deb_selection_reason "$deb")"
      archive_name="$(kernel_deb_canonical_name "$deb")"
      target=no; live=no
      array_contains_exact "$deb" "${TARGET_KERNEL_DEBS[@]}" && target=yes
      array_contains_exact "$deb" "${LIVE_KERNEL_DEBS[@]}" && live=yes
      [[ -n "$role" ]] || role=reference-only
      [[ -n "$reason" ]] || reason="not selected for $KERNEL_RELEASE"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pkg" "$version" "$arch" "$class" "$role" "$target" "$live" \
        "/usr/lib/vanillaos-snapdragonx/kernel-packages/$archive_name" "$deb" "$reason"
    done
  } > "$manifest"
}

resolve_kernel_package_closure() {
  local selector="$TMP_ROOT/select-kernel-package-closure.py"
  cat > "$selector" <<'KERNEL_SELECTOR_PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import defaultdict, deque

def die(message: str) -> None:
    print(f"kernel package closure: {message}", file=sys.stderr)
    raise SystemExit(2)

def field(path: str, name: str) -> str:
    proc = subprocess.run(["dpkg-deb", "-f", path, name], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return proc.stdout.strip() if proc.returncode == 0 else ""

def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""): h.update(chunk)
    return h.hexdigest()

def parse_listing(path: str):
    proc = subprocess.run(["dpkg-deb", "-c", path], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0: die(f"cannot list {path}: {proc.stderr.strip()}")
    regular = []
    for line in proc.stdout.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6: continue
        mode, raw_path = parts[0], parts[5]
        if " -> " in raw_path: raw_path = raw_path.split(" -> ", 1)[0]
        raw_path = raw_path.removeprefix("./")
        if mode.startswith("-"): regular.append(raw_path)
    return sorted(set(regular))

def canonical_name(pkg: str, version: str, arch: str) -> str:
    safe = version.replace(":", "%3A")
    safe = re.sub(r"[^A-Za-z0-9.+~_=%-]", "_", safe)
    return f"{pkg}_{safe}_{arch}.deb"

def parse_relations(value: str):
    groups = []
    if not value: return groups
    for group_text in value.split(","):
        alternatives = []
        for alt_text in group_text.split("|"):
            text = re.sub(r"\[[^]]*\]", "", alt_text)
            text = re.sub(r"<[^>]*>", "", text).strip()
            match = re.match(r"^([a-z0-9][a-z0-9+.-]*)(?::(?:any|native|[a-z0-9-]+))?(?:\s*\((<<|<=|=|>=|>>)\s*([^)]+)\))?", text)
            if match:
                alternatives.append({"name": match.group(1), "op": match.group(2) or "", "version": (match.group(3) or "").strip()})
        if alternatives: groups.append(alternatives)
    return groups

def version_satisfies(actual: str, op: str, required: str) -> bool:
    if not op: return True
    return subprocess.run(["dpkg", "--compare-versions", actual, op, required], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def classify(pkg: str, paths):
    if any(re.fullmatch(r"boot/vmlinuz-.+", p) for p in paths): return "kernel-image"
    if any(re.fullmatch(r"(?:usr/)?lib/modules/[^/]+/.+\.ko(?:\.(?:gz|xz|zst))?", p) for p in paths): return "kernel-modules"
    if re.match(r"linux-(?:.*-)?headers-", pkg) or pkg.startswith("linux-headers-"): return "headers"
    if "tools" in pkg and pkg.startswith("linux-"): return "tools"
    if pkg.endswith(("-dbg", "-dbgsym", "-dev")) or pkg == "linux-libc-dev": return "development"
    if pkg.startswith(("linux-source-", "linux-buildinfo-")): return "metadata"
    return "support"

if len(sys.argv) < 5 or sys.argv[4] != "--": die("internal invocation error")
output, release, override = sys.argv[1:4]
paths = [os.path.realpath(p) for p in sys.argv[5:]]
if not paths: die("no package paths supplied")

facts = []
for path in paths:
    pkg = field(path, "Package"); version = field(path, "Version"); arch = field(path, "Architecture")
    if not pkg or not version or not arch: die(f"missing Package/Version/Architecture metadata: {path}")
    regular = parse_listing(path)
    vmlinuz_releases = sorted(p[len("boot/vmlinuz-"):] for p in regular if p.startswith("boot/vmlinuz-") and len(p) > len("boot/vmlinuz-"))
    vmlinux_releases = sorted(p[len("boot/vmlinux-"):] for p in regular if p.startswith("boot/vmlinux-") and len(p) > len("boot/vmlinux-"))
    module_paths = sorted(p for p in regular if re.fullmatch(rf"(?:usr/)?lib/modules/{re.escape(release)}/.+\.ko(?:\.(?:gz|xz|zst))?", p))
    auxiliary_paths = sorted(p for p in regular if p in {f"boot/config-{release}", f"boot/System.map-{release}"} or p.startswith(f"usr/lib/linux-image-{release}/") or p.startswith(f"lib/linux-image-{release}/") or p.startswith(f"boot/dtb-{release}/") or p.startswith(f"boot/dtb/{release}/"))
    facts.append({"path": path,"package": pkg,"version": version,"architecture": arch,"sha256": sha256(path),"canonical_name": canonical_name(pkg, version, arch),"depends": field(path, "Depends"),"pre_depends": field(path, "Pre-Depends"),"provides": field(path, "Provides"),"regular_paths": regular,"vmlinuz_releases": vmlinuz_releases,"vmlinux_releases": vmlinux_releases,"module_paths": module_paths,"auxiliary_paths": auxiliary_paths,"class": classify(pkg, regular)})

by_path = {f["path"]: f for f in facts}
image_candidates = [f for f in facts if release in f["vmlinuz_releases"]]
if override:
    override = os.path.realpath(override)
    if override not in by_path: die(f"--kernel-image-deb is not in the supplied package set: {override}")
    if release not in by_path[override]["vmlinuz_releases"]: die(f"selected image package does not own /boot/vmlinuz-{release}: {override}")
    image = by_path[override]
else:
    if len(image_candidates) != 1:
        details = "; ".join(f"{f['package']}={f['version']} ({f['path']})" for f in image_candidates) or "none"
        die(f"expected exactly one owner of /boot/vmlinuz-{release}; found {len(image_candidates)}: {details}. Use --kernel-image-deb for an intentional choice.")
    image = image_candidates[0]
if image["architecture"] != "arm64": die(f"package owning /boot/vmlinuz-{release} must be Architecture: arm64; found {image['architecture']} in {image['package']}={image['version']}")
selected = {}
def add(fact, role: str, reason: str) -> bool:
    current = selected.get(fact["path"])
    if current:
        roles = set(current["role"].split("+")); roles.add(role); current["role"] = "+".join(sorted(roles))
        if reason not in current["reason"]: current["reason"] += "; " + reason
        return False
    selected[fact["path"]] = {"path": fact["path"],"package": fact["package"],"version": fact["version"],"architecture": fact["architecture"],"canonical_name": fact["canonical_name"],"role": role,"reason": reason}
    return True
add(image, "image", f"owns regular /boot/vmlinuz-{release}")
module_facts = [f for f in facts if f["module_paths"] and (release not in f["vmlinuz_releases"] or f["path"] == image["path"])]
aux_facts = [f for f in facts if f["auxiliary_paths"] and (release not in f["vmlinuz_releases"] or f["path"] == image["path"])]
for fact in module_facts:
    if fact["architecture"] != "arm64": die(f"package containing runtime modules for {release} must be Architecture: arm64; found {fact['architecture']} in {fact['package']}={fact['version']}")
module_owners = defaultdict(list)
for fact in module_facts:
    for module_path in fact["module_paths"]: module_owners[module_path].append(fact)
overlap = {p: owners for p, owners in module_owners.items() if len(owners) > 1}
if overlap:
    path, owners = sorted(overlap.items())[0]
    die(f"overlapping runtime module payload {path}: " + ", ".join(f"{f['package']}={f['version']}" for f in owners))
critical_owners = defaultdict(list); critical_facts = {image["path"]: image}
for fact in module_facts + aux_facts: critical_facts[fact["path"]] = fact
for fact in critical_facts.values():
    critical_paths = set(fact["module_paths"]) | set(fact["auxiliary_paths"])
    if fact["path"] == image["path"]: critical_paths.add(f"boot/vmlinuz-{release}")
    for critical_path in critical_paths: critical_owners[critical_path].append(fact)
critical_overlap = {path: owners for path, owners in critical_owners.items() if len(owners) > 1}
if critical_overlap:
    path, owners = sorted(critical_overlap.items())[0]
    die(f"overlapping boot-critical payload {path}: " + ", ".join(f"{f['package']}={f['version']}" for f in owners))
for fact in module_facts: add(fact, "modules", f"contains runtime module objects for {release}")
for fact in aux_facts: add(fact, "auxiliary", f"contains release-bound support payload for {release}")
module_package_names = {f["package"] for f in module_facts}; orchestrators = []
for fact in facts:
    if fact["path"] in selected: continue
    relation_names = {alt["name"] for group in (parse_relations(fact["pre_depends"]) + parse_relations(fact["depends"])) for alt in group}
    if image["package"] in relation_names and relation_names.intersection(module_package_names): orchestrators.append(fact)
if len(orchestrators) > 1: die("multiple supplied release-orchestrator packages depend directly on the selected image/modules closure: " + ", ".join(f"{f['package']}={f['version']}" for f in orchestrators))
if orchestrators: add(orchestrators[0], "orchestrator", f"depends directly on selected image and module packages for {release}")
by_name = defaultdict(list); providers = defaultdict(list)
for fact in facts:
    by_name[fact["package"]].append(fact)
    for group in parse_relations(fact["provides"]):
        for provided in group: providers[provided["name"]].append((fact, provided))
queue = deque(selected.keys()); processed = set()
while queue:
    parent_path = queue.popleft()
    if parent_path in processed: continue
    processed.add(parent_path); parent = by_path[parent_path]
    relations = parse_relations(parent["pre_depends"]) + parse_relations(parent["depends"])
    for alternatives in relations:
        chosen = None; chosen_relation = None
        for alt in alternatives:
            candidates = [f for f in by_name.get(alt["name"], []) if version_satisfies(f["version"], alt["op"], alt["version"])]
            if not candidates:
                provider_candidates = []
                for provider_fact, provided in providers.get(alt["name"], []):
                    provided_version = provided["version"]
                    if not alt["op"] or (provided_version and version_satisfies(provided_version, alt["op"], alt["version"])): provider_candidates.append(provider_fact)
                candidates = provider_candidates
            if candidates:
                identities = {(f["package"], f["version"], f["architecture"]) for f in candidates}
                if len(identities) != 1: die(f"ambiguous supplied dependency '{alt['name']}' required by {parent['package']}: " + ", ".join(f"{f['package']}={f['version']} ({f['path']})" for f in candidates))
                chosen = sorted(candidates, key=lambda f: f["path"])[0]; chosen_relation = alt; break
        if chosen is not None:
            relation_text = chosen_relation["name"]
            if chosen_relation["op"]: relation_text += f" ({chosen_relation['op']} {chosen_relation['version']})"
            if add(chosen, "dependency", f"supplied local dependency of {parent['package']}: {relation_text}"): queue.append(chosen["path"])
selected_facts = [by_path[p] for p in selected]; selected_names = defaultdict(list)
for fact in selected_facts: selected_names[fact["package"]].append(fact)
for pkg, matches in selected_names.items():
    versions = {(f["version"], f["architecture"]) for f in matches}
    if len(versions) > 1: die(f"selected closure contains multiple versions/architectures of {pkg}: " + ", ".join(f"{f['version']}/{f['architecture']}" for f in matches))
if not any(f["module_paths"] for f in selected_facts): die(f"no selected package contains runtime module objects for {release}")
selected_output = sorted(selected.values(), key=lambda x: (x["package"], x["path"])); selected_paths = {x["path"] for x in selected_output}
excluded_output = [{"path": f["path"],"package": f["package"],"version": f["version"],"architecture": f["architecture"],"canonical_name": f["canonical_name"],"class": f["class"]} for f in facts if f["path"] not in selected_paths]
fact_summary = [{"path": f["path"],"package": f["package"],"version": f["version"],"architecture": f["architecture"],"sha256": f["sha256"],"canonical_name": f["canonical_name"],"class": f["class"],"depends": f["depends"],"pre_depends": f["pre_depends"],"provides": f["provides"],"vmlinuz_releases": f["vmlinuz_releases"],"vmlinux_releases": f["vmlinux_releases"],"runtime_module_count": len(f["module_paths"]),"auxiliary_paths": f["auxiliary_paths"]} for f in facts]
result = {"schema_version": 1,"release": release,"image_deb": image["path"],"image_package": image["package"],"image_version": image["version"],"selected": selected_output,"excluded": sorted(excluded_output, key=lambda x: (x["package"], x["path"])),"facts": fact_summary}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(result, stream, indent=2, sort_keys=True); stream.write("\n")
KERNEL_SELECTOR_PY
  chmod 0755 "$selector"
  python3 "$selector" "$KERNEL_PACKAGE_CLOSURE_JSON" "$KERNEL_RELEASE" "$KERNEL_IMAGE_DEB_OVERRIDE" -- "${KERNEL_DEBS[@]}"
  jq -e --arg release "$KERNEL_RELEASE" '.schema_version == 1 and .release == $release and (.selected | length) > 0' "$KERNEL_PACKAGE_CLOSURE_JSON" >/dev/null || die "Kernel package closure output failed structural validation."
}

discover_kernel_and_dtb_inputs() {
  KERNEL_DEBS=(); TARGET_KERNEL_DEBS=(); TARGET_EXCLUDED_KERNEL_DEBS=(); LIVE_KERNEL_DEBS=(); DTB_CANDIDATES=(); KERNEL_IMAGE_DEB=""; KERNEL_RELEASE_REQUESTED="$EXPECTED_CUSTOM_KERNEL_RELEASE"
  case "$KERNEL_RELEASE_POLICY" in prefer|require|auto) : ;; *) die "Unsupported kernel release policy: $KERNEL_RELEASE_POLICY" ;; esac
  mkdir -p "$TMP_ROOT/deb-listings"
  local -a discovered_debs=()
  mapfile -t discovered_debs < <(find "$KERNEL_DEB_DIR" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null | sort -u)
  if [[ -n "$KERNEL_IMAGE_DEB_OVERRIDE" ]]; then [[ -f "$KERNEL_IMAGE_DEB_OVERRIDE" ]] || die "Kernel image package override does not exist: $KERNEL_IMAGE_DEB_OVERRIDE"; discovered_debs+=("$KERNEL_IMAGE_DEB_OVERRIDE"); fi
  mapfile -t discovered_debs < <(printf '%s\n' "${discovered_debs[@]}" | sed '/^$/d' | sort -u)
  ((${#discovered_debs[@]} > 0)) || die "No .deb files found in $KERNEL_DEB_DIR or $ARTIFACT_DIR."
  local -a release_candidates=() vmlinux_candidates=() normalized_debs=()
  local deb pkg version arch listing rel identity digest prior_digest
  declare -A identity_path=() identity_sha=()
  : > "$TMP_ROOT/debian-package-inventory.tsv"
  for deb in "${discovered_debs[@]}"; do
    deb="$(readlink -f -- "$deb")"; [[ "$deb" != *$'\n'* && "$deb" != *$'\r'* ]] || die "Kernel package path contains a newline: $deb"
    pkg="$(package_field "$deb" Package)"; version="$(package_field "$deb" Version)"; arch="$(package_field "$deb" Architecture)"
    [[ -n "$pkg" && -n "$version" && -n "$arch" ]] || die "Unable to read Debian package metadata: $deb"
    [[ "$arch" == "arm64" || "$arch" == "all" ]] || die "Package $pkg has unsupported architecture '$arch': $deb"
    identity="$pkg"$'\037'"$version"$'\037'"$arch"; digest="$(sha256sum "$deb" | awk '{print $1}')"
    if [[ -n "${identity_path[$identity]:-}" ]]; then prior_digest="${identity_sha[$identity]}"; [[ "$digest" == "$prior_digest" ]] && { warn "Ignoring byte-identical duplicate package identity: $pkg=$version/$arch ($deb)"; continue; }; die "Conflicting bytes for duplicate package identity $pkg=$version/$arch: ${identity_path[$identity]} and $deb"; fi
    identity_path[$identity]="$deb"; identity_sha[$identity]="$digest"; normalized_debs+=("$deb")
    printf '%s\t%s\t%s\t%s\t%s\n' "$pkg" "$version" "$arch" "$digest" "$deb" >> "$TMP_ROOT/debian-package-inventory.tsv"
    listing="$(kernel_deb_listing_path "$deb")"; write_deb_content_listing "$deb" "$listing"
    while IFS= read -r rel; do [[ -n "$rel" ]] && release_candidates+=("$rel"); done < <(awk '$1 ~ /^-/ {path=$NF; sub(/^\.\//,"",path); if(path ~ /^boot\/vmlinuz-/){sub(/^boot\/vmlinuz-/,"",path); print path}}' "$listing")
    while IFS= read -r rel; do [[ -n "$rel" ]] && vmlinux_candidates+=("$rel"); done < <(awk '$1 ~ /^-/ {path=$NF; sub(/^\.\//,"",path); if(path ~ /^boot\/vmlinux-/){sub(/^boot\/vmlinux-/,"",path); print path}}' "$listing")
  done
  KERNEL_DEBS=("${normalized_debs[@]}")
  if ((${#release_candidates[@]} == 0 && ${#vmlinux_candidates[@]} > 0)); then mapfile -t vmlinux_candidates < <(printf '%s\n' "${vmlinux_candidates[@]}" | sort -u); die "Only /boot/vmlinux-* payloads were found (${vmlinux_candidates[*]}). This GRUB/ABRoot harness requires /boot/vmlinuz-<release>."; fi
  KERNEL_RELEASE="$(select_kernel_release_from_candidates "${release_candidates[@]}")"
  resolve_kernel_package_closure
  KERNEL_IMAGE_DEB="$(jq -r '.image_deb' "$KERNEL_PACKAGE_CLOSURE_JSON")"
  mapfile -t TARGET_KERNEL_DEBS < <(jq -r '.selected[].path' "$KERNEL_PACKAGE_CLOSURE_JSON")
  mapfile -t LIVE_KERNEL_DEBS < <(jq -r '.selected[] | select(.role | test("(^|\\+)(image|modules|auxiliary)(\\+|$)")) | .path' "$KERNEL_PACKAGE_CLOSURE_JSON")
  mapfile -t TARGET_EXCLUDED_KERNEL_DEBS < <(jq -r '.excluded[].path' "$KERNEL_PACKAGE_CLOSURE_JSON")
  [[ -f "$KERNEL_IMAGE_DEB" ]] || die "Resolved kernel image package is unavailable: $KERNEL_IMAGE_DEB"
  ((${#TARGET_KERNEL_DEBS[@]} > 0)) || die "Kernel package closure selected no target packages."
  deb_listing_has_regular_boot_kernel "$(kernel_deb_listing_path "$KERNEL_IMAGE_DEB")" "$KERNEL_RELEASE" || die "Resolved image package no longer contains /boot/vmlinuz-$KERNEL_RELEASE"
  local has_modules=0
  for deb in "${LIVE_KERNEL_DEBS[@]}"; do listing="$(kernel_deb_listing_path "$deb")"; if deb_listing_has_runtime_module_object "$listing" "$KERNEL_RELEASE"; then has_modules=1; break; fi; done
  (( has_modules == 1 )) || die "No selected package contains a regular runtime module object for $KERNEL_RELEASE."
  mapfile -t DTB_CANDIDATES < <(find "$ARTIFACT_DIR/dtb" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.dtb' -print 2>/dev/null | sort -u)
  ((${#DTB_CANDIDATES[@]} > 0)) || die "No DTB found in $ARTIFACT_DIR/dtb or $ARTIFACT_DIR."
  if [[ -n "$DTB_FILE_OVERRIDE" ]]; then [[ -f "$DTB_FILE_OVERRIDE" ]] || die "DTB override does not exist: $DTB_FILE_OVERRIDE"; DTB_FILE="$DTB_FILE_OVERRIDE"; elif ((${#DTB_CANDIDATES[@]} == 1)); then DTB_FILE="${DTB_CANDIDATES[0]}"; elif is_interactive; then local opts=() i=1 choice candidate; for candidate in "${DTB_CANDIDATES[@]}"; do opts+=("$i|Use $(basename "$candidate")|$candidate"); i=$((i+1)); done; choice="$(menu "Primary Device Tree Selection" "1" "${opts[@]}")"; DTB_FILE="${DTB_CANDIDATES[$((choice-1))]}"; else die "Multiple DTBs found. Set DTB_FILE_OVERRIDE or use interactive mode."; fi
  DTB_NAME="${DTB_INSTALLED_NAME_OVERRIDE:-$(basename "$DTB_FILE")}"; [[ "$DTB_NAME" != */* && -n "$DTB_NAME" ]] || die "Installed DTB name must be a basename: $DTB_NAME"
  write_kernel_package_selection_manifest
  ok "Kernel release selected from payload: $KERNEL_RELEASE"; ok "Kernel image owner: $(package_field "$KERNEL_IMAGE_DEB" Package)=$(package_field "$KERNEL_IMAGE_DEB" Version)"; ok "Kernel image source: $KERNEL_IMAGE_DEB"
  ok "Supplied unique kernel-related packages: ${#KERNEL_DEBS[@]}"; ok "Resolved target/live package closure: ${#TARGET_KERNEL_DEBS[@]}"; ok "Reference-only packages excluded from installation: ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}"
  ok "Supplied packages are not archived in the target; release-side selection/closure evidence remains authoritative."; ok "Selected DTB: $DTB_FILE"
  local excluded class role
  for excluded in "${TARGET_EXCLUDED_KERNEL_DEBS[@]}"; do pkg="$(package_field "$excluded" Package)"; class="$(classify_kernel_deb_for_target "$excluded")"; role="$(kernel_deb_selection_role "$excluded")"; warn "Target APT exclusion: $pkg ($class/${role:-reference-only}); recorded in release evidence only."; done
}

normalize_git_url() { local url="$1"; url="${url%.git}"; url="${url%/}"; printf '%s' "$url"; }
repo_state() { local path="$1"; if [[ ! -d "$path/.git" ]]; then printf 'missing'; return; fi; local branch commit dirty origin; branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"; commit="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"; origin="$(git -C "$path" remote get-url origin 2>/dev/null || true)"; [[ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]] && dirty=dirty || dirty=clean; printf 'branch=%s commit=%s state=%s origin=%s' "${branch:-detached}" "${commit:-unknown}" "$dirty" "${origin:-unknown}"; }
repo_ref_kind() { local path="$1" ref="$2"; if git -C "$path" show-ref --verify --quiet "refs/heads/$ref" || git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$ref"; then printf branch; elif git -C "$path" show-ref --verify --quiet "refs/tags/$ref"; then printf tag; elif git -C "$path" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then printf commit; else printf unresolved; fi; }
repo_commit_iso_date() { git -C "$1" show -s --format=%cI HEAD 2>/dev/null || printf unknown; }
repo_commit_age_days() { local commit_epoch now_epoch; commit_epoch="$(git -C "$1" show -s --format=%ct HEAD 2>/dev/null || true)"; [[ "$commit_epoch" =~ ^[0-9]+$ ]] || { printf unknown; return 0; }; now_epoch="$(date -u +%s)"; printf '%s' "$(( (now_epoch - commit_epoch) / 86400 ))"; }
repo_exact_tags() { local tags; tags="$(git -C "$1" tag --points-at HEAD 2>/dev/null | LC_ALL=C sort | paste -sd, - || true)"; printf '%s' "${tags:-none}"; }

write_source_provenance_manifest() {
  SOURCE_PROVENANCE_MANIFEST="$TMP_ROOT/source-provenance.tsv"
  { printf 'role\trepository\trequested_ref\tref_kind\tcommit\tcommit_date_utc\tage_days\texact_tags\tcheckout\tbuild_use\n';
    printf 'custom-image\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CUSTOM_IMAGE_REPO_URL" "$CUSTOM_IMAGE_REF" "$(repo_ref_kind "$CUSTOM_IMAGE_SOURCE" "$CUSTOM_IMAGE_REF")" "$CUSTOM_SOURCE_COMMIT" "$(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE")" "$(repo_commit_age_days "$CUSTOM_IMAGE_SOURCE")" "$(repo_exact_tags "$CUSTOM_IMAGE_SOURCE")" "$CUSTOM_IMAGE_SOURCE" "template for generated custom target recipe";
    printf 'live-iso\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LIVE_ISO_REPO_URL" "$LIVE_ISO_REF" "$(repo_ref_kind "$LIVE_ISO_SOURCE" "$LIVE_ISO_REF")" "$LIVE_SOURCE_COMMIT" "$(repo_commit_iso_date "$LIVE_ISO_SOURCE")" "$(repo_commit_age_days "$LIVE_ISO_SOURCE")" "$(repo_exact_tags "$LIVE_ISO_SOURCE")" "$LIVE_ISO_SOURCE" "installer ISO source"; } > "$SOURCE_PROVENANCE_MANIFEST"
}

write_reunion_convergence_manifest() {
  local live_conf="$LIVE_ISO_SOURCE/etc/terraform.conf" live_codename="unknown" live_version="unknown" live_suffix="unknown"
  [[ -f "$live_conf" ]] && { live_codename="$(read_terraform_value "$live_conf" CODENAME)"; live_version="$(read_terraform_value "$live_conf" VERSION)"; live_suffix="$(read_terraform_value "$live_conf" PACKAGE_LISTS_SUFFIX)"; }
  {
    printf 'component\tselection\tbasis\n'
    printf 'milestone\tv8.5-r5\tformal Vanilla OS 3 Reunion stable-release convergence\n'
    printf 'corrective_revision\tv8.5-r5.1\trestore Stage-1 repository-policy dispatcher omitted from r5 artifact\n'
    printf 'live-iso-ref\t%s@%s\tupstream branch identifier; content codename=%s version=%s\n' "$LIVE_ISO_REF" "$LIVE_SOURCE_COMMIT" "$live_codename" "$live_version"
    printf 'live-package-lists\t%s\tupstream PACKAGE_LISTS_SUFFIX\n' "$live_suffix"
    printf 'live-package-policy\t%s\tupstream-native is canonical; r4.1 projection retained only for compatibility\n' "$LIVE_ARM64_PACKAGE_POLICY"
    printf 'live-builder\t%s\tstable Reunion ARM64 workflow substrate; digest recorded separately\n' "$LIVE_ISO_CONTAINER_IMAGE"
    printf 'custom-image\t%s@%s\tscaffold/modules only; stable announcement and desktop-image are semantic authorities\n' "$CUSTOM_IMAGE_REF" "$CUSTOM_SOURCE_COMMIT"
    printf 'target-base\t%s\tformal stable Reunion GNOME image taxonomy; digest recorded separately\n' "$CUSTOM_IMAGE_BASE"
    printf 'vib-binary\t%s\tbuilder tool request\n' "$VIB_VERSION"
    printf 'vib-recipe\t%s\tgenerated recipe declaration\n' "$VIB_RECIPE_VERSION"
    printf 'fsguard\tabsent\tremoved from Vanilla OS 3 Reunion\n'
    printf 'vso-stack\t%s\tpublished Reunion VSO native stack\n' "$VSO_NATIVE_STACK"
    printf 'vso-image\t%s\tpublished VSO OCI image; digest recorded separately\n' "$VSO_NATIVE_IMAGE"
    printf 'vso-instance\t%s\tmanaged VSO subsystem instance\n' "$VSO_NATIVE_INSTANCE"
    printf 'vso-upstream-base\t%s\tpublished vso-image source contract\n' "$VSO_NATIVE_UPSTREAM_BASE"
    printf 'distrobox\tv2 / 2.0.0-rc.4 contract\tretain opaque-source-version coherence gate\n'
    printf 'installation-transport\t%s\tISO-local OCI bridge remains first-class when iso-oci is selected\n' "$DELIVERY_MODE"
    if [[ -s "$UPSTREAM_OCI_PROVENANCE_JSON" ]]; then
      printf 'target-base-digest\t%s\tresolved ARM64 manifest digest for moving stable tag\n' "$(jq -r '.inputs[] | select(.role == "target-base") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")"
      printf 'live-builder-digest\t%s\tresolved ARM64 manifest digest for moving stable tag\n' "$(jq -r '.inputs[] | select(.role == "live-builder") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")"
      printf 'vso-native-digest\t%s\tresolved ARM64 manifest digest recorded as installed-system contract evidence\n' "$(jq -r '.inputs[] | select(.role == "vso-native") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")"
    fi
  } > "$REUNION_CONVERGENCE_MANIFEST"
}

report_source_provenance() {
  local custom_age live_age; custom_age="$(repo_commit_age_days "$CUSTOM_IMAGE_SOURCE")"; live_age="$(repo_commit_age_days "$LIVE_ISO_SOURCE")"
  info "Source-reference strategy:"; info "  custom-image: ref=$CUSTOM_IMAGE_REF kind=$(repo_ref_kind "$CUSTOM_IMAGE_SOURCE" "$CUSTOM_IMAGE_REF") commit=$(git -C "$CUSTOM_IMAGE_SOURCE" rev-parse --short HEAD) date=$(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE") age=${custom_age}d tags=$(repo_exact_tags "$CUSTOM_IMAGE_SOURCE")"; info "  live-iso: ref=$LIVE_ISO_REF kind=$(repo_ref_kind "$LIVE_ISO_SOURCE" "$LIVE_ISO_REF") commit=$(git -C "$LIVE_ISO_SOURCE" rev-parse --short HEAD) date=$(repo_commit_iso_date "$LIVE_ISO_SOURCE") age=${live_age}d tags=$(repo_exact_tags "$LIVE_ISO_SOURCE")"; info "  target base: $CUSTOM_IMAGE_BASE"; info "  live builder: $LIVE_ISO_CONTAINER_IMAGE"
  [[ "$live_age" =~ ^[0-9]+$ ]] && (( live_age > SOURCE_STALE_WARN_DAYS )) && warn "live-iso is older than ${SOURCE_STALE_WARN_DAYS} days."
  [[ "$custom_age" =~ ^[0-9]+$ ]] && (( custom_age > SOURCE_STALE_WARN_DAYS )) && warn "custom-image is older than ${SOURCE_STALE_WARN_DAYS} days."
}

repo_action_menu() {
  local name="$1" path="$2" ref="$3"
  menu "Repository Validation\n\nRepository: $name\nPath: $path\nRequested: $ref\nState: $(repo_state "$path")" "2" \
    "1|Continue with existing validated checkout|No fetch; requested ref must resolve locally and checkout must be clean." \
    "2|Refresh from origin [RECOMMENDED]|Fetch/prune and checkout the requested branch, tag, or commit." \
    "3|Re-clone clean|Delete this checkout and clone the configured origin again." \
    "4|Open a shell here|Inspect or repair the checkout, then return." \
    "5|Abort|Stop source preparation."
}
checkout_requested_ref() {
  local path="$1" ref="$2" allow_fetch="$3"; (( allow_fetch == 1 )) && git -C "$path" fetch --all --tags --prune
  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    if git -C "$path" show-ref --verify --quiet "refs/heads/$ref"; then git -C "$path" checkout "$ref"; (( allow_fetch == 1 )) && git -C "$path" merge --ff-only "origin/$ref"; else git -C "$path" checkout -b "$ref" --track "origin/$ref"; fi
  elif git -C "$path" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then git -C "$path" checkout --detach "$ref"
  elif (( allow_fetch == 1 )); then git -C "$path" fetch origin "$ref"; git -C "$path" checkout --detach FETCH_HEAD
  else die "Requested ref '$ref' is not available locally in $path."; fi
}
check_git_remote_access() { local name="$1" url="$2"; info "Checking remote access for $name: $url"; git ls-remote "$url" HEAD >/dev/null 2>&1 || die "Unable to access configured Git remote for $name: $url"; ok "$name remote is reachable."; }
verify_required_source_checkouts() { [[ -d "$CUSTOM_IMAGE_SOURCE/.git" ]] || die "Required custom-image checkout is absent after synchronization: $CUSTOM_IMAGE_SOURCE"; [[ -d "$LIVE_ISO_SOURCE/.git" ]] || die "Required live-iso checkout is absent after synchronization: $LIVE_ISO_SOURCE"; [[ -n "$CUSTOM_SOURCE_COMMIT" && -n "$LIVE_SOURCE_COMMIT" ]] || die "Required source commits were not recorded."; [[ -z "$(git -C "$CUSTOM_IMAGE_SOURCE" status --porcelain)" ]] || die "custom-image checkout is dirty after synchronization."; [[ -z "$(git -C "$LIVE_ISO_SOURCE" status --porcelain)" ]] || die "live-iso checkout is dirty after synchronization."; SOURCES_SYNCHRONIZED=1; ok "Required source checkouts are present and clean."; }
source_checkout_summary() { local path="$1"; if [[ -d "$path/.git" ]]; then repo_state "$path"; elif [[ -e "$path" ]]; then printf 'present but not a Git checkout'; else printf absent; fi; }
report_repository_plan_state() { info "Plan mode is non-mutating: repositories will not be cloned, fetched, reset, or refreshed."; info "Selected execute-time repository policy: $REPO_POLICY"; info "custom-image current state: $(source_checkout_summary "$CUSTOM_IMAGE_SOURCE")"; info "live-iso current state: $(source_checkout_summary "$LIVE_ISO_SOURCE")"; info "core-image retained state: $(source_checkout_summary "$CORE_IMAGE_SOURCE")"; info "desktop-image retained: $(source_checkout_summary "$DESKTOP_IMAGE_SOURCE")"; info "qcom updater state: $(source_checkout_summary "$QCOM_UPDATER_DIR")"; [[ ! -e "$LEGACY_LIVE_ISO_SOURCE" ]] || warn "Legacy live-iso-v7 path is present and will be normalized in execute mode when safe."; [[ -d "$CUSTOM_IMAGE_SOURCE/.git" && -d "$LIVE_ISO_SOURCE/.git" ]] || warn "One or both required source checkouts are absent. Execute mode will create them using policy '$REPO_POLICY'."; return 0; }
normalize_live_iso_source_path() {
  [[ "$LIVE_ISO_SOURCE" == "$SOURCES_DIR/live-iso" ]] || die "Internal source-layout guard: canonical live ISO path is not sources/live-iso."
  if [[ -d "$LIVE_ISO_SOURCE/.git" ]]; then [[ ! -d "$LEGACY_LIVE_ISO_SOURCE/.git" ]] || warn "Both canonical and legacy live-iso checkouts exist; using canonical."; return 0; fi
  [[ ! -e "$LIVE_ISO_SOURCE" ]] || die "Canonical live-iso path exists but is not a Git checkout: $LIVE_ISO_SOURCE"
  if [[ -d "$LEGACY_LIVE_ISO_SOURCE/.git" ]]; then
    local legacy_origin expected_origin; legacy_origin="$(normalize_git_url "$(git -C "$LEGACY_LIVE_ISO_SOURCE" remote get-url origin)")"; expected_origin="$(normalize_git_url "$LIVE_ISO_REPO_URL")"
    [[ "$legacy_origin" == "$expected_origin" ]] || { warn "Legacy live-iso-v7 checkout has unexpected origin and will be preserved."; return 0; }
    [[ -z "$(git -C "$LEGACY_LIVE_ISO_SOURCE" status --porcelain)" ]] || { warn "Legacy live-iso-v7 checkout is dirty and will not be moved."; return 0; }
    mv "$LEGACY_LIVE_ISO_SOURCE" "$LIVE_ISO_SOURCE"; ok "Canonical live-iso source path restored."
  fi
}
report_preserved_source_layout() { info "Source checkout layout:"; info "  custom-image: $(source_checkout_summary "$CUSTOM_IMAGE_SOURCE")"; info "  live-iso: $(source_checkout_summary "$LIVE_ISO_SOURCE")"; info "  core-image: $(source_checkout_summary "$CORE_IMAGE_SOURCE")"; info "  desktop-image: $(source_checkout_summary "$DESKTOP_IMAGE_SOURCE")"; info "  qcom-firmware-updater: $(source_checkout_summary "$QCOM_UPDATER_DIR")"; return 0; }
sync_repo() {
  local name="$1" url="$2" ref="$3" path="$4"; mkdir -p "$(dirname "$path")"
  if [[ -e "$path" && ! -d "$path/.git" ]]; then is_interactive || die "$path exists but is not a Git repository."; mv "$path" "${path}.non-git.$(date -u +%Y%m%d%H%M%S)"; fi
  if [[ ! -d "$path/.git" ]]; then check_git_remote_access "$name" "$url"; git clone "$url" "$path"; git -C "$path" config --local advice.detachedHead false; checkout_requested_ref "$path" "$ref" 1
  else
    git config --global --add safe.directory "$path" >/dev/null 2>&1 || true
    local actual expected policy="$REPO_POLICY" choice; actual="$(normalize_git_url "$(git -C "$path" remote get-url origin 2>/dev/null || true)")"; expected="$(normalize_git_url "$url")"
    [[ "$actual" == "$expected" ]] || die "$name origin mismatch: expected $expected, found $actual"
    if [[ "$policy" == prompt ]]; then choice="$(repo_action_menu "$name" "$path" "$ref")"; case "$choice" in 1) policy=continue;; 2) policy=refresh;; 3) policy=reclone;; 4) open_shell "$path"; sync_repo "$name" "$url" "$ref" "$path"; return;; 5) die "Repository handling aborted.";; esac; fi
    case "$policy" in
      continue) [[ -z "$(git -C "$path" status --porcelain)" ]] || die "$name checkout is dirty under continue policy: $path"; checkout_requested_ref "$path" "$ref" 0 ;;
      refresh) check_git_remote_access "$name" "$url"; [[ -z "$(git -C "$path" status --porcelain)" ]] || die "$name checkout is dirty: $path"; checkout_requested_ref "$path" "$ref" 1 ;;
      reclone) rm -rf "$path"; sync_repo "$name" "$url" "$ref" "$path"; return ;;
      *) die "Unsupported repository policy: $policy" ;;
    esac
  fi
  [[ -z "$(git -C "$path" status --porcelain)" ]] || die "$name checkout is not clean after synchronization."
  ok "$name validated: $(repo_state "$path")"
}
sync_required_repositories() { info "Beginning required official source synchronization."; normalize_live_iso_source_path; report_preserved_source_layout; sync_repo "VanillaOS custom-image" "$CUSTOM_IMAGE_REPO_URL" "$CUSTOM_IMAGE_REF" "$CUSTOM_IMAGE_SOURCE"; sync_repo "VanillaOS live-iso" "$LIVE_ISO_REPO_URL" "$LIVE_ISO_REF" "$LIVE_ISO_SOURCE"; CUSTOM_SOURCE_COMMIT="$(git -C "$CUSTOM_IMAGE_SOURCE" rev-parse HEAD)"; LIVE_SOURCE_COMMIT="$(git -C "$LIVE_ISO_SOURCE" rev-parse HEAD)"; verify_required_source_checkouts; write_source_provenance_manifest; write_reunion_convergence_manifest; report_source_provenance; return 0; }

# ------------------------- firmware staging ------------------------------
normalize_qcom_soc_firmware_policy() { case "${FIRMWARE_QCOM_SOC_POLICY,,}" in require|required|strict) FIRMWARE_QCOM_SOC_POLICY=require;; auto|optional) FIRMWARE_QCOM_SOC_POLICY=auto;; skip|none|disabled) FIRMWARE_QCOM_SOC_POLICY=skip;; *) die "Invalid Qualcomm SoC firmware package policy: $FIRMWARE_QCOM_SOC_POLICY";; esac; }
sha256_is_valid() { [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }
read_package_checksum_sidecar() {
  local deb="$1" sidecar base hash; base="$(basename "$deb")"; FIRMWARE_CHECKSUM_CANDIDATE=""; FIRMWARE_CHECKSUM_SOURCE=""; local -a sidecars=("$deb.sha256" "${deb%.deb}.sha256" "$(dirname "$deb")/SHA256SUMS")
  for sidecar in "${sidecars[@]}"; do [[ -f "$sidecar" ]] || continue; hash="$(awk -v base="$base" '$1 ~ /^[0-9A-Fa-f]{64}$/ {name=$2; sub(/^\*/,"",name); leaf=name; sub(/^.*\//,"",leaf); if(name==base||name=="./" base||leaf==base){print tolower($1);found=1;exit} if(NF==1&&fallback=="")fallback=tolower($1)} END{if(!found&&fallback!="")print fallback}' "$sidecar" | sed -n '1p')"; if sha256_is_valid "$hash"; then FIRMWARE_CHECKSUM_CANDIDATE="${hash,,}"; FIRMWARE_CHECKSUM_SOURCE="$sidecar"; return 0; fi; done; return 1
}
write_firmware_package_checksum_sidecar() { local deb="$1" actual="$2" package="$3" sidecar tmp base; base="$(basename "$deb")"; sidecar="$deb.sha256"; tmp="$(mktemp "$(dirname "$sidecar")/.${base}.sha256.tmp.XXXXXX")"; printf '%s  %s\n' "$actual" "$base" > "$tmp"; chmod 0644 "$tmp"; mv -f -- "$tmp" "$sidecar"; FIRMWARE_CHECKSUM_CANDIDATE="$actual"; FIRMWARE_CHECKSUM_SOURCE="$sidecar (created interactively)"; ok "Pinned $package checksum sidecar: $sidecar"; }

resolve_missing_firmware_package_checksum() {
  local deb="$1" actual="$2" package="$3" version="$4" choice entered
  FIRMWARE_CHECKSUM_CANDIDATE=""; FIRMWARE_CHECKSUM_SOURCE=""
  if (( PLAN_ONLY == 1 )); then warn "No persistent SHA-256 pin exists for $(basename "$deb"). Plan mode will carry the observed hash into execute."; FIRMWARE_CHECKSUM_CANDIDATE="$actual"; FIRMWARE_CHECKSUM_SOURCE="plan-observed SHA-256; not persisted"; return 0; fi
  is_interactive || return 1
  choice="$(menu "Pin Firmware Package\n\nPackage: $package ($version)\nObserved SHA: $actual" "1" "1|Trust this artifact and write sidecar|Create package .sha256." "2|Enter independent SHA-256|Continue only if it matches." "3|Abort|Leave package unpinned.")"
  case "$choice" in 1) write_firmware_package_checksum_sidecar "$deb" "$actual" "$package";; 2) entered="$(prompt_text "Expected SHA-256 for $package" "")"; sha256_is_valid "$entered" || die "Entered SHA-256 is invalid for $package"; FIRMWARE_CHECKSUM_CANDIDATE="${entered,,}"; FIRMWARE_CHECKSUM_SOURCE="interactive operator entry";; 3) die "Build aborted: $package remains unpinned.";; esac
}
firmware_deb_candidates() { local directory; for directory in "$ARTIFACT_DIR/firmware-debs" "$ARTIFACT_DIR" "$WORKDIR/firmware-debs"; do [[ -d "$directory" ]] || continue; find "$directory" -maxdepth 1 -type f -name '*.deb' -print; done | LC_ALL=C sort -u; }
resolve_firmware_packages() {
  mkdir -p "$FIRMWARE_PROVENANCE_DIR"; validate_firmware_package_specs
  printf 'package\tarchitecture\trequired\tversion\tsha256\tsource\tchecksum_source\n' > "$FIRMWARE_PACKAGE_INVENTORY_FILE"; printf '[]\n' > "$FIRMWARE_PACKAGES_RESOLVED_FILE"
  local mandatory_count; mandatory_count="$(jq '[.[] | select(.required == true)] | length' "$FIRMWARE_PACKAGE_SPECS_FILE")"
  if [[ "${FIRMWARE_MODE,,}" == skip ]]; then (( mandatory_count == 0 && ${#PROFILE_FIRMWARE_PROBES[@]} == 0 )) && [[ "$FIRMWARE_BOARD_POLICY" != required ]] || die "FIRMWARE_MODE=skip conflicts with mandatory firmware declarations."; printf '[]\n' > "$FIRMWARE_PACKAGE_LOCK_FILE"; FIRMWARE_PACKAGE_OVERRIDES_JSON='[]'; return 0; fi
  local count index package architecture required source expected_sha expected_version actual_package actual_arch actual_version actual_sha checksum_source candidate candidate_pkg candidate_arch safe
  local -a candidates=() matching=(); count="$(jq 'length' "$FIRMWARE_PACKAGE_SPECS_FILE")"
  for ((index=0; index<count; index++)); do
    package="$(jq -r ".[$index].package" "$FIRMWARE_PACKAGE_SPECS_FILE")"; architecture="$(jq -r ".[$index].architecture // \"all\"" "$FIRMWARE_PACKAGE_SPECS_FILE")"; required="$(jq -r ".[$index].required // false" "$FIRMWARE_PACKAGE_SPECS_FILE")"; source="$(jq -r ".[$index].source // empty" "$FIRMWARE_PACKAGE_SPECS_FILE")"; expected_sha="$(jq -r ".[$index].sha256 // empty" "$FIRMWARE_PACKAGE_SPECS_FILE" | tr '[:upper:]' '[:lower:]')"; expected_version="$(jq -r ".[$index].expected_version // empty" "$FIRMWARE_PACKAGE_SPECS_FILE")"
    if [[ -n "$source" ]]; then source="$(resolve_profile_path "$source")"; [[ -f "$source" ]] || die "Firmware package source does not exist for $package: $source"; else mapfile -t candidates < <(firmware_deb_candidates); matching=(); for candidate in "${candidates[@]}"; do candidate_pkg="$(package_field "$candidate" Package)"; candidate_arch="$(package_field "$candidate" Architecture)"; [[ "$candidate_pkg" == "$package" && "$candidate_arch" == "$architecture" ]] && matching+=("$candidate"); done; case "${#matching[@]}" in 0) [[ "$required" == true ]] && die "Required firmware package $package:$architecture was not found." || { info "Optional firmware package not supplied: $package:$architecture"; continue; };; 1) source="${matching[0]}";; *) die "Multiple firmware artifacts match $package:$architecture; set source explicitly.";; esac; fi
    actual_package="$(package_field "$source" Package)"; actual_arch="$(package_field "$source" Architecture)"; actual_version="$(package_field "$source" Version)"
    [[ "$actual_package" == "$package" && "$actual_arch" == "$architecture" && -n "$actual_version" ]] || die "Firmware package metadata mismatch for $package:$architecture"
    [[ -z "$expected_version" || "$actual_version" == "$expected_version" ]] || die "Firmware package version mismatch for $package: expected=$expected_version actual=$actual_version"
    actual_sha="$(sha256sum "$source" | awk '{print tolower($1)}')"; checksum_source=""
    if [[ -n "$expected_sha" ]]; then FIRMWARE_CHECKSUM_SOURCE="profile/environment override"; elif read_package_checksum_sidecar "$source"; then expected_sha="$FIRMWARE_CHECKSUM_CANDIDATE"; elif resolve_missing_firmware_package_checksum "$source" "$actual_sha" "$package" "$actual_version"; then expected_sha="$FIRMWARE_CHECKSUM_CANDIDATE"; else die "A pinned SHA-256 is required for $package. Observed: $actual_sha"; fi
    checksum_source="$FIRMWARE_CHECKSUM_SOURCE"; [[ "$actual_sha" == "$expected_sha" ]] || die "Firmware checksum mismatch for $package: expected=$expected_sha actual=$actual_sha"
    safe="$(printf '%s_%s' "$package" "$architecture" | sed 's/[^A-Za-z0-9._-]/_/g')"; dpkg-deb --info "$source" > "$FIRMWARE_PROVENANCE_DIR/$safe.package-info.txt"; dpkg-deb --contents "$source" > "$FIRMWARE_PROVENANCE_DIR/$safe.filelist.txt"; printf '%s  %s\n' "$actual_sha" "$(basename "$source")" > "$FIRMWARE_PROVENANCE_DIR/$safe.sha256"; printf '%s\n' "$checksum_source" > "$FIRMWARE_PROVENANCE_DIR/$safe.checksum-source.txt"
    jq --arg package "$package" --arg architecture "$architecture" --argjson required "$required" --arg source "$source" --arg version "$actual_version" --arg sha "$actual_sha" --arg checksum_source "$checksum_source" '. + [{package:$package,architecture:$architecture,required:$required,source:$source,version:$version,sha256:$sha,checksum_source:$checksum_source}]' "$FIRMWARE_PACKAGES_RESOLVED_FILE" > "$FIRMWARE_PACKAGES_RESOLVED_FILE.tmp"; mv -f "$FIRMWARE_PACKAGES_RESOLVED_FILE.tmp" "$FIRMWARE_PACKAGES_RESOLVED_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$package" "$architecture" "$required" "$actual_version" "$actual_sha" "$source" "$checksum_source" >> "$FIRMWARE_PACKAGE_INVENTORY_FILE"; ok "Resolved firmware package by metadata: $package:$architecture $actual_version"
  done
  cp -a "$FIRMWARE_PACKAGES_RESOLVED_FILE" "$FIRMWARE_PACKAGE_LOCK_FILE"; FIRMWARE_PACKAGE_OVERRIDES_JSON="$(jq -c '[.[] | {package,architecture,required,source,sha256,expected_version:.version}]' "$FIRMWARE_PACKAGES_RESOLVED_FILE")"
  FIRMWARE_QCOM_SOC_DEB="$(jq -r '.[] | select(.package=="firmware-qcom-soc" and .architecture=="all") | .source' "$FIRMWARE_PACKAGES_RESOLVED_FILE" | sed -n '1p')"; FIRMWARE_QCOM_SOC_ACTUAL_VERSION="$(jq -r '.[] | select(.package=="firmware-qcom-soc" and .architecture=="all") | .version' "$FIRMWARE_PACKAGES_RESOLVED_FILE" | sed -n '1p')"; FIRMWARE_QCOM_SOC_ACTUAL_SHA256="$(jq -r '.[] | select(.package=="firmware-qcom-soc" and .architecture=="all") | .sha256' "$FIRMWARE_PACKAGES_RESOLVED_FILE" | sed -n '1p')"; FIRMWARE_QCOM_SOC_SHA256="$FIRMWARE_QCOM_SOC_ACTUAL_SHA256"
}
resolve_qcom_soc_firmware_package() { resolve_firmware_packages; }
normalize_firmware_source_tree() { local src="$1" dest="$2"; rm -rf "$dest"; mkdir -p "$dest"; if [[ "$(basename "$src")" == qcom ]]; then mkdir -p "$dest/qcom"; rsync -aHAX "$src/" "$dest/qcom/"; elif [[ -d "$src/usr/lib/firmware" ]]; then rsync -aHAX "$src/usr/lib/firmware/" "$dest/"; elif [[ -d "$src/lib/firmware" ]]; then rsync -aHAX "$src/lib/firmware/" "$dest/"; else rsync -aHAX "$src/" "$dest/"; fi; }
merge_firmware_tree_fail_closed() {
  local src="$1" dest="$2" label="$3"; [[ -d "$src" ]] || die "Firmware merge source is not a directory: $src"; mkdir -p "$dest" "$(dirname "$FIRMWARE_MERGE_REPORT")"; [[ -f "$FIRMWARE_MERGE_REPORT" ]] || printf 'source\taction\trelative_path\tdetail\n' > "$FIRMWARE_MERGE_REPORT"
  local path rel target source_hash target_hash source_link target_link
  while IFS= read -r -d '' path; do rel="${path#"$src"/}"; [[ "$rel" != "$path" ]] || continue; target="$dest/$rel"; if [[ -d "$path" && ! -L "$path" ]]; then [[ ! -e "$target" || -d "$target" ]] || die "Firmware merge conflict: directory $label:$rel"; mkdir -p "$target"; continue; fi; mkdir -p "$(dirname "$target")"; if [[ -L "$path" ]]; then source_link="$(readlink "$path")"; if [[ -L "$target" ]]; then target_link="$(readlink "$target")"; [[ "$source_link" == "$target_link" ]] || die "Firmware symlink conflict for $rel"; elif [[ -e "$target" ]]; then die "Firmware merge conflict: symlink $label:$rel"; else cp -a "$path" "$target"; fi; elif [[ -f "$path" ]]; then if [[ -f "$target" && ! -L "$target" ]]; then source_hash="$(sha256sum "$path"|awk '{print $1}')"; target_hash="$(sha256sum "$target"|awk '{print $1}')"; [[ "$source_hash" == "$target_hash" ]] || die "Firmware content conflict for $rel"; elif [[ -e "$target" ]]; then die "Firmware merge conflict: $label:$rel"; else cp -a "$path" "$target"; fi; else die "Unsupported firmware object type: $path"; fi; done < <(find "$src" -mindepth 1 -print0 | LC_ALL=C sort -z)
}
extract_resolved_firmware_package_trees() { local count index package version source safe extract_root normalized_root firmware_root copyright_path; count="$(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")"; for ((index=0; index<count; index++)); do package="$(jq -r ".[$index].package" "$FIRMWARE_PACKAGES_RESOLVED_FILE")"; version="$(jq -r ".[$index].version" "$FIRMWARE_PACKAGES_RESOLVED_FILE")"; source="$(jq -r ".[$index].source" "$FIRMWARE_PACKAGES_RESOLVED_FILE")"; safe="$(printf '%s_%s' "$package" "$index"|sed 's/[^A-Za-z0-9._-]/_/g')"; extract_root="$TMP_ROOT/firmware-package-$safe-extract"; normalized_root="$TMP_ROOT/firmware-package-$safe-normalized"; rm -rf "$extract_root" "$normalized_root"; mkdir -p "$extract_root" "$normalized_root"; dpkg-deb --extract "$source" "$extract_root"; if [[ -d "$extract_root/usr/lib/firmware" ]]; then firmware_root="$extract_root/usr/lib/firmware"; elif [[ -d "$extract_root/lib/firmware" ]]; then firmware_root="$extract_root/lib/firmware"; else die "Declared firmware package $package contains no firmware root"; fi; normalize_firmware_source_tree "$firmware_root" "$normalized_root"; merge_firmware_tree_fail_closed "$normalized_root" "$STAGED_FIRMWARE_DIR" "$package:$version"; done; }
extract_qcom_soc_firmware_package_tree() { extract_resolved_firmware_package_trees; }

validate_profile_board_data() {
  [[ "$FIRMWARE_BOARD_POLICY" != none ]] || { info "Profile declares firmware.board_data.policy=none; no replacement ATH11K board data is required."; return 0; }
  local raw="$STAGED_FIRMWARE_DIR/$FIRMWARE_BOARD_RAW_PATH" compressed="" raw_sha compressed_sha=""
  [[ -z "$FIRMWARE_BOARD_COMPRESSED_PATH" ]] || compressed="$STAGED_FIRMWARE_DIR/$FIRMWARE_BOARD_COMPRESSED_PATH"
  if [[ "$FIRMWARE_BOARD_POLICY" == optional && ! -e "$raw" && ( -z "$compressed" || ! -e "$compressed" ) ]]; then info "Optional board-data artifacts are not present; continuing."; return 0; fi
  [[ -f "$raw" && ! -L "$raw" && -s "$raw" ]] || die "Board-data raw file is absent, empty, or a symlink: $raw"
  if [[ -n "$compressed" ]]; then [[ -f "$compressed" && ! -L "$compressed" && -s "$compressed" ]] || die "Board-data compressed file invalid: $compressed"; zstd --test "$compressed" >/dev/null; cmp -s <(zstd -dc "$compressed") "$raw" || die "Compressed board-data content does not equal raw file"; fi
  raw_sha="$(sha256sum "$raw" | awk '{print tolower($1)}')"; [[ -z "$FIRMWARE_BOARD_RAW_SHA256" || "$raw_sha" == "$FIRMWARE_BOARD_RAW_SHA256" ]] || die "Board-data raw checksum mismatch"
  if [[ -n "$compressed" ]]; then compressed_sha="$(sha256sum "$compressed" | awk '{print tolower($1)}')"; [[ -z "$FIRMWARE_BOARD_COMPRESSED_SHA256" || "$compressed_sha" == "$FIRMWARE_BOARD_COMPRESSED_SHA256" ]] || die "Board-data compressed checksum mismatch"; fi
  [[ -z "$FIRMWARE_BOARD_MAGIC" ]] || grep -aFq "$FIRMWARE_BOARD_MAGIC" "$raw" || die "Board-data file lacks required magic string: $FIRMWARE_BOARD_MAGIC"
  if [[ -n "$FIRMWARE_BOARD_SUBSYSTEM" ]]; then local vendor="${FIRMWARE_BOARD_SUBSYSTEM%%:*}" device="${FIRMWARE_BOARD_SUBSYSTEM##*:}"; grep -aFq "subsystem-vendor=$vendor,subsystem-device=$device" "$raw" || die "Board-data file lacks required subsystem record: $FIRMWARE_BOARD_SUBSYSTEM"; fi
  { printf '%s  %s\n' "$raw_sha" "$FIRMWARE_BOARD_RAW_PATH"; [[ -z "$compressed_sha" ]] || printf '%s  %s\n' "$compressed_sha" "$FIRMWARE_BOARD_COMPRESSED_PATH"; } > "$FIRMWARE_PROVENANCE_DIR/board-data.sha256"
  ok "Validated profile-declared board data under policy=$FIRMWARE_BOARD_POLICY."
}
validate_hp_ath11k_board_data() { validate_profile_board_data; }
validate_profile_firmware_layout() { local probe path; : > "$FIRMWARE_PROVENANCE_DIR/required-firmware-paths.sha256"; for probe in "${PROFILE_FIRMWARE_PROBES[@]}"; do [[ -n "$probe" ]] || continue; validate_relative_firmware_probe "$probe"; path="$STAGED_FIRMWARE_DIR/$probe"; [[ -f "$path" && ! -L "$path" && -s "$path" ]] || die "Required profile firmware path invalid: $path"; printf '%s  %s\n' "$(sha256sum "$path"|awk '{print $1}')" "$probe" >> "$FIRMWARE_PROVENANCE_DIR/required-firmware-paths.sha256"; done; ok "Validated ${#PROFILE_FIRMWARE_PROBES[@]} profile-declared firmware paths."; }
validate_adreno_x145_firmware_layout() { validate_profile_firmware_layout; }
validate_all_profile_firmware_probes() { validate_profile_firmware_layout; }
write_staged_firmware_inventory() { : > "$FIRMWARE_STAGED_INVENTORY"; local path rel; while IFS= read -r -d '' path; do rel="${path#"$STAGED_FIRMWARE_DIR"/}"; printf '%s  %s\n' "$(sha256sum "$path"|awk '{print $1}')" "$rel" >> "$FIRMWARE_STAGED_INVENTORY"; done < <(find "$STAGED_FIRMWARE_DIR" -type f -print0 | LC_ALL=C sort -z); find "$STAGED_FIRMWARE_DIR" -type l -printf '%P\t%l\n' | LC_ALL=C sort > "$FIRMWARE_PROVENANCE_DIR/staged-firmware-symlinks.tsv"; }
qcom_network_argument() { case "${FIRMWARE_CONTAINER_NETWORK,,}" in host) printf '%s' '--network=host';; default|bridge) printf '';; skip) printf SKIP;; *) printf '%s' '--network=host';; esac; }
extract_qcom_firmware_isolated() {
  sync_repo "qcom-firmware-updater" "$QCOM_UPDATER_REPO_URL" "$QCOM_UPDATER_REF" "$QCOM_UPDATER_DIR"
  local work="$TMP_ROOT/qcom-extract"; rm -rf "$work"; mkdir -p "$work/input" "$work/out"; [[ "$FIRMWARE_MODE" != archive ]] || cp -a "$FIRMWARE_ARCHIVE" "$work/input/$(basename "$FIRMWARE_ARCHIVE")"
  local runner="$work/run-qcom-extract.sh"
  cat > "$runner" <<'QCOM_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
getent hosts deb.debian.org >/dev/null 2>&1 || exit 70
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl unzip msitools p7zip-full zstd rsync bash coreutils findutils file grep sed gawk
printf '#!/usr/bin/env bash\nexec "$@"\n' > /usr/local/bin/sudo
chmod 0755 /usr/local/bin/sudo
mkdir -p /out/lib/firmware /out/logs /work
cp -a /updater /work/qcom-firmware-updater
cd /work/qcom-firmware-updater
orig="$(cat ./qcom-firmware-updater.sh)"; orig="${orig%$'\n'}"; case "$orig" in *'main "$@"') orig="${orig%main \"\$@\"}" ;; esac
printf '%s\n' "$orig" > /work/qcom-functions.sh
cat >> /work/qcom-functions.sh <<'CAPTURE_EOF'
capture_main() {
  parse_args "$@"; check_deps
  if [[ -z "$DEVICE_PATH" ]]; then detect_device; else info "Using manual device path: $DEVICE_PATH"; fi
  FIRMWARE_DIR="$FIRMWARE_BASE/$DEVICE_PATH"; TMPDIR=$(mktemp -d /tmp/qcom-fw-capture.XXXXXX); local input_path=""
  if [[ -n "$INPUT_URL" ]]; then input_path="$TMPDIR/download.zip"; download_driver "$input_path"; else [[ -f "$INPUT_FILE" ]] || die "File not found: $INPUT_FILE"; input_path="$INPUT_FILE"; fi
  local extract_root fw_staging dest; extract_root=$(extract_exe "$input_path"); fw_staging=$(find_firmware "$extract_root"); dest="/out/lib/firmware/qcom/$DEVICE_PATH"; mkdir -p "$dest"; cp -a "$fw_staging"/. "$dest"/; chmod -R a+rX /out/lib/firmware || true
}
capture_main "$@"
CAPTURE_EOF
chmod 0755 /work/qcom-functions.sh
if [[ -n "${QCOM_URL:-}" ]]; then bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" --url "$QCOM_URL"; else input_file="$(find /input -maxdepth 1 -type f | sort | sed -n '1p')"; [[ -n "$input_file" ]] || exit 71; bash /work/qcom-functions.sh --device-path "$QCOM_DEVICE_PATH" "$input_file"; fi
QCOM_RUNNER
  chmod 0755 "$runner"
  local net_arg rc; net_arg="$(qcom_network_argument)"; [[ "$net_arg" != SKIP ]] || { FIRMWARE_MODE=skip; return 0; }
  local -a cmd=("$OCI_RUNTIME" run --rm --privileged); [[ -n "$net_arg" ]] && cmd+=("$net_arg"); cmd+=(-e "QCOM_URL=${FIRMWARE_URL:-}" -e "QCOM_DEVICE_PATH=$QCOM_DEVICE_PATH" -v "$QCOM_UPDATER_DIR:/updater:ro" -v "$work/input:/input:ro" -v "$work/out:/out" -v "$runner:/run-qcom-extract.sh:ro" debian:13 /bin/bash /run-qcom-extract.sh)
  set +e; "${cmd[@]}"; rc=$?; set -e; (( rc == 0 )) || die "Firmware extraction failed with status $rc"
  [[ -d "$work/out/lib/firmware" ]] || die "Isolated updater produced no firmware tree"; FIRMWARE_PRESTAGED="$work/out/lib/firmware"; FIRMWARE_MODE=prestaged
}
stage_firmware() {
  mkdir -p "$FIRMWARE_PROVENANCE_DIR"; rm -rf "$STAGED_FIRMWARE_DIR"; mkdir -p "$STAGED_FIRMWARE_DIR"; printf 'source\taction\trelative_path\tdetail\n' > "$FIRMWARE_MERGE_REPORT"
  local required_package_count; required_package_count="$(jq '[.[] | select(.required == true)] | length' "$FIRMWARE_PACKAGE_SPECS_FILE")"
  case "${FIRMWARE_MODE,,}" in skip) (( required_package_count == 0 && ${#PROFILE_FIRMWARE_PROBES[@]} == 0 )) && [[ "$FIRMWARE_BOARD_POLICY" != required ]] || die "FIRMWARE_MODE=skip incompatible with required firmware"; FIRMWARE_SOURCE=""; return;; archive|url) extract_qcom_firmware_isolated;; ask|auto|existing) die "Firmware mode must be resolved before execution: $FIRMWARE_MODE";; prestaged) :;; *) die "Unsupported firmware mode: $FIRMWARE_MODE";; esac
  extract_resolved_firmware_package_trees
  if [[ -n "$FIRMWARE_PRESTAGED" ]]; then local profile_normalized="$TMP_ROOT/profile-firmware-normalized"; normalize_firmware_source_tree "$FIRMWARE_PRESTAGED" "$profile_normalized"; merge_firmware_tree_fail_closed "$profile_normalized" "$STAGED_FIRMWARE_DIR" "profile:$PROFILE"; fi
  if ! find "$STAGED_FIRMWARE_DIR" -type f -print -quit | grep -q .; then (( required_package_count == 0 && ${#PROFILE_FIRMWARE_PROBES[@]} == 0 )) && [[ "$FIRMWARE_BOARD_POLICY" != required ]] && { FIRMWARE_SOURCE=""; return; }; die "Firmware configuration produced no staged files"; fi
  validate_profile_firmware_layout; validate_profile_board_data; write_staged_firmware_inventory; FIRMWARE_SOURCE="$STAGED_FIRMWARE_DIR"; FIRMWARE_PROBE_REL="$(printf '%s\n' "${PROFILE_FIRMWARE_PROBES[@]}" | sed '/^$/d' | sed -n '1p')"; [[ -n "$FIRMWARE_PROBE_REL" ]] || FIRMWARE_PROBE_REL="$(find "$FIRMWARE_SOURCE" -type f -printf '%P\n' | LC_ALL=C sort | sed -n '1p')"; write_resolved_profile
  ok "Staged firmware root: $FIRMWARE_SOURCE"; ok "Resolved firmware packages: $(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")"; ok "Staged firmware files: $(wc -l < "$FIRMWARE_STAGED_INVENTORY")"
}

peek_next_release_id() { local current=0; [[ -f "$BUILD_COUNTER_FILE" ]] && read -r current < "$BUILD_COUNTER_FILE" || true; [[ "$current" =~ ^[0-9]+$ ]] || current=0; printf 'r%04d' $((current + 1)); }
reserve_release_id() { local current=0; [[ -f "$BUILD_COUNTER_FILE" ]] && read -r current < "$BUILD_COUNTER_FILE" || true; [[ "$current" =~ ^[0-9]+$ ]] || current=0; current=$((current+1)); printf '%s\n' "$current" > "$BUILD_COUNTER_FILE"; printf 'r%04d' "$current"; }

print_plan() {
  local preview_id; preview_id="$(peek_next_release_id)"
  cat <<EOF_PLAN

Resolved v$SCRIPT_VERSION plan — MILESTONE: Reunion stable-release convergence
--------------------------------------------------------------------------
Work directory:             $WORKDIR
Profile:                    $PROFILE ($PROFILE_DISPLAY_NAME)
Artifact directory:         $ARTIFACT_DIR
Kernel release requested:   ${KERNEL_RELEASE_REQUESTED:-none}
Kernel release policy:      $KERNEL_RELEASE_POLICY
Kernel release selected:    $KERNEL_RELEASE
Kernel image source:        $KERNEL_IMAGE_DEB
Target OCI closure .debs:   ${#TARGET_KERNEL_DEBS[@]}
Reference-only .debs:       ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}
DTB:                        $DTB_FILE
Firmware mode:              $FIRMWARE_MODE
Firmware source:            ${FIRMWARE_SOURCE:-to be staged during execution}
Board-data policy:          $FIRMWARE_BOARD_POLICY
Legacy root overlay source: ${ROOT_SOURCE:-none}
Legacy root overlay target: /usr/lib/vanillaos-snapdragonx/root-source-overlay
Repository policy:          $REPO_POLICY
custom-image source:        $CUSTOM_IMAGE_REPO_URL @ $CUSTOM_IMAGE_REF
live-iso source:            $LIVE_ISO_REPO_URL @ $LIVE_ISO_REF
Target OCI base:            $CUSTOM_IMAGE_BASE
VSO native image:           $VSO_NATIVE_IMAGE
VSO native stack/instance:  $VSO_NATIVE_STACK / $VSO_NATIVE_INSTANCE
VSO source base contract:   $VSO_NATIVE_UPSTREAM_BASE
Target OCI reference:       $TARGET_IMAGE_REF
ABRoot image name:          $ABROOT_IMAGE_NAME
Installer delivery:         $DELIVERY_MODE
Installer storage guard:    $INSTALLER_STORAGE_GUARD_POLICY
ISO OCI layout path:        $ISO_IMAGE_LAYOUT_PATH
Logical registry host:      $LOCAL_REGISTRY_LOGICAL_HOST
Physical registry endpoint: $LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT
Push target OCI:            $PUSH_TARGET_IMAGE
OCI runtime:                $OCI_RUNTIME
Live ISO runtime:           $LIVE_ISO_RUNTIME
Live build image:           $LIVE_ISO_CONTAINER_IMAGE
Live ARM64 package policy:  $LIVE_ARM64_PACKAGE_POLICY
Live GDM timed-login delay: ${LIVE_GDM_TIMED_LOGIN_DELAY}s
Requested Vib version:      $VIB_VERSION
Vib recipe version:         $VIB_RECIPE_VERSION
FsGuard:                    removed by Reunion; no harness plugin stage
Expected release ID:        $preview_id

Stable-Reunion invariants:
  - gnome:latest is the published stable GNOME target base.
  - pico:latest remains the live/build substrate; VSO is not substituted for Pico.
  - vso-native / vso:latest / apx-vso-native is the installed-system operator contract.
  - Distrobox v2 coherence validation remains fail-closed while accepting valid opaque source-build version tokens.
  - Project-owned immutable payload is not installed beneath /opt, /usr/local, /root, or /var/root.
  - Kernel, DTB, firmware, GDM timing, storage guard, embedded OCI bridge, canonical Installer recipe, autostart convergence and digest binding remain project-owned and preserved.

Exact non-interactive execute command:
  sudo env WORKDIR=$(printf '%q' "$WORKDIR") PROFILE=$(printf '%q' "$PROFILE") \
    ARTIFACT_DIR=$(printf '%q' "$ARTIFACT_DIR") ROOT_SOURCE=$(printf '%q' "$ROOT_SOURCE") \
    KERNEL_DEB_DIR=$(printf '%q' "$KERNEL_DEB_DIR") EXPECTED_CUSTOM_KERNEL_RELEASE=$(printf '%q' "$KERNEL_RELEASE") \
    KERNEL_RELEASE_POLICY=require KERNEL_IMAGE_DEB_OVERRIDE=$(printf '%q' "$KERNEL_IMAGE_DEB") \
    FIRMWARE_MODE=$(printf '%q' "$FIRMWARE_MODE") FIRMWARE_PRESTAGED=$(printf '%q' "$FIRMWARE_PRESTAGED") \
    FIRMWARE_PACKAGE_OVERRIDES_JSON=$(printf '%q' "$FIRMWARE_PACKAGE_OVERRIDES_JSON") \
    REPO_POLICY=$(printf '%q' "$REPO_POLICY") CUSTOM_IMAGE_BASE=$(printf '%q' "$CUSTOM_IMAGE_BASE") \
    OCI_RUNTIME=$(printf '%q' "$OCI_RUNTIME") LIVE_ISO_RUNTIME=$(printf '%q' "$LIVE_ISO_RUNTIME") \
    LIVE_ISO_CONTAINER_IMAGE=$(printf '%q' "$LIVE_ISO_CONTAINER_IMAGE") LIVE_ARM64_PACKAGE_POLICY=$(printf '%q' "$LIVE_ARM64_PACKAGE_POLICY") \
    TARGET_IMAGE_REF=$(printf '%q' "$TARGET_IMAGE_REF") ABROOT_IMAGE_NAME=$(printf '%q' "$ABROOT_IMAGE_NAME") \
    $(printf '%q' "$SCRIPT_PATH") --execute --non-interactive
EOF_PLAN
}

prepare_custom_image_worktree() { rm -rf "$CUSTOM_PROJECT"; git -C "$CUSTOM_IMAGE_SOURCE" worktree add --detach "$CUSTOM_PROJECT" "$CUSTOM_SOURCE_COMMIT"; [[ -f "$CUSTOM_PROJECT/recipe.yml" ]] || die "Official custom-image worktree is incomplete."; ok "Clean custom-image worktree prepared at commit $CUSTOM_SOURCE_COMMIT."; }

# ---------------------------- Vib tooling --------------------------------
host_arch() { case "$(uname -m)" in aarch64|arm64) printf arm64;; x86_64|amd64) printf amd64;; *) die "Unsupported host architecture for Vib: $(uname -m)";; esac; }
normalize_version_tag() { [[ "$1" == v* ]] && printf '%s' "$1" || printf 'v%s' "$1"; }
version_ge() { local actual="$1" required="$2"; [[ -n "$actual" && -n "$required" ]] || return 1; [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | sed -n '1p')" == "$required" ]]; }
download_atomic() { local url="$1" destination="$2" partial="${2}.partial"; mkdir -p "$(dirname "$destination")"; rm -f "$partial"; curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 "$url" -o "$partial"; [[ -s "$partial" ]] || die "Downloaded file is empty: $url"; mv -f "$partial" "$destination"; }
vib_exec() { local vib_home="/home/root" vib_cache="$CACHE_DIR/vib-root"; [[ "$(id -u)" -ne 0 ]] || mkdir -p "$vib_home"; mkdir -p "$vib_cache"; env SUDO_UID=0 SUDO_GID=0 SUDO_USER=root HOME="$vib_home" XDG_CACHE_HOME="$vib_cache" "$VIB_BIN" "$@"; }
probe_vib_binary() { local output rc detected; set +e; output="$(vib_exec --version 2>&1)"; rc=$?; set -e; (( rc == 0 )) || { warn "Vib preflight failed: $VIB_BIN"; return 1; }; detected="$(printf '%s\n' "$output" | grep -Eo '[0-9]+(\.[0-9]+){2}' | sed -n '1p' || true)"; [[ -n "$detected" ]] || { warn "Unable to parse Vib semantic version: $output"; return 1; }; version_ge "$detected" "$VIB_RECIPE_VERSION" || { warn "Vib $detected is older than recipe $VIB_RECIPE_VERSION"; return 1; }; VIB_DETECTED_VERSION="$detected"; ok "Vib preflight passed: $output"; }
download_builder_local_vib() { local arch="$1" tag; tag="$(normalize_version_tag "$VIB_VERSION")"; VIB_BIN="$WORKDIR/tools/vib"; mkdir -p "$(dirname "$VIB_BIN")"; download_atomic "https://github.com/Vanilla-OS/Vib/releases/download/$tag/vib-$arch" "$VIB_BIN"; chmod 0755 "$VIB_BIN"; }
install_core_vib_plugins() { local arch="$1" tag archive extract_root source_dir plugin_dir; tag="$(normalize_version_tag "$VIB_DETECTED_VERSION")"; archive="$CACHE_DIR/vib-$tag-plugins-$arch.tar.gz"; extract_root="$TMP_ROOT/vib-core-plugins-extract"; source_dir="$extract_root/build/plugins"; plugin_dir="$CUSTOM_PROJECT/plugins"; [[ -s "$archive" ]] || download_atomic "https://github.com/Vanilla-OS/Vib/releases/download/$tag/plugins-$arch.tar.gz" "$archive"; rm -rf "$extract_root" "$plugin_dir"; mkdir -p "$extract_root" "$plugin_dir"; tar -xzf "$archive" -C "$extract_root"; [[ -d "$source_dir" ]] || die "Core plugin extraction did not produce $source_dir"; rsync -a "$source_dir/" "$plugin_dir/"; ok "Installed Vib core plugins from $tag; Reunion requires no external FsGuard plugin."; }
verify_vib_plugin_set() { local plugin_dir="$CUSTOM_PROJECT/plugins" count inventory="$TMP_ROOT/vib-plugin-inventory.txt"; find "$plugin_dir" -maxdepth 1 -type f -name '*.so' -printf '%f\t%s bytes\n' | LC_ALL=C sort > "$inventory"; count="$(wc -l < "$inventory" | tr -d '[:space:]')"; (( count > 0 )) || die "No Vib core plugins were installed."; sha256sum "$plugin_dir"/*.so > "$TMP_ROOT/vib-plugin-checksums.sha256"; ok "Validated $count project-local Vib core plugin(s); no FsGuard plugin present or required."; }
capture_vib_diagnostics() { local reason="$1" diag="$LOG_DIR/${SESSION_ID}-vib-diagnostics"; mkdir -p "$diag"; printf '%s\n' "$reason" > "$diag/FAILURE.txt"; printf '%s\n' "$VIB_BIN" > "$diag/vib-executable.path"; file "$VIB_BIN" > "$diag/vib-executable.file" 2>&1 || true; sha256sum "$VIB_BIN" > "$diag/vib-executable.sha256" 2>/dev/null || true; [[ ! -f "$CUSTOM_PROJECT/recipe.yml" ]] || cp -a "$CUSTOM_PROJECT/recipe.yml" "$diag/"; [[ ! -d "$CUSTOM_PROJECT/modules" ]] || cp -a "$CUSTOM_PROJECT/modules" "$diag/"; [[ ! -d "$CUSTOM_PROJECT/plugins" ]] || cp -a "$CUSTOM_PROJECT/plugins" "$diag/"; { printf 'SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"; printf 'VIB_DETECTED_VERSION=%q\n' "$VIB_DETECTED_VERSION"; printf 'REUNION_FSGUARD=absent\n'; } > "$diag/execution-context.txt"; warn "Vib diagnostic bundle retained at: $diag"; }
run_logged_vib() { local name="$1"; shift; local rc; CURRENT_LOG="$LOG_DIR/${SESSION_ID}-${name}.log"; mkdir -p "$LOG_DIR"; info "Log: $CURRENT_LOG"; set +e; vib_exec "$@" 2>&1 | tee "$CURRENT_LOG"; rc=${PIPESTATUS[0]}; set -e; if (( rc != 0 )); then capture_vib_diagnostics "Vib command failed: $*; exit status: $rc"; return "$rc"; fi; }
install_vib_and_plugins() { local arch; arch="$(host_arch)"; [[ -n "$VIB_BIN" ]] || VIB_BIN="$WORKDIR/tools/vib"; if [[ ! -x "$VIB_BIN" ]] && command_exists vib; then VIB_BIN="$(command -v vib)"; fi; [[ -x "$VIB_BIN" ]] || download_builder_local_vib "$arch"; probe_vib_binary || { download_builder_local_vib "$arch"; probe_vib_binary || die "Builder-local Vib failed validation."; }; install_core_vib_plugins "$arch"; verify_vib_plugin_set; ok "Vib executable: $VIB_BIN"; ok "Vib detected version: $VIB_DETECTED_VERSION"; }
# ------------------------ custom target OCI ------------------------------

generate_root_overlay_inventory() {
  : > "$ROOT_OVERLAY_INVENTORY"
  [[ -n "$ROOT_SOURCE" ]] || return 0
  [[ -d "$ROOT_SOURCE" ]] || die "Root overlay source is not a directory: $ROOT_SOURCE"

  while IFS= read -r -d '' file; do
    local rel hash
    rel="${file#"$ROOT_SOURCE"/}"
    hash="$(sha256sum "$file" | awk '{print $1}')"
    printf '%s  /usr/lib/vanillaos-snapdragonx/root-source-overlay/%s\n' "$hash" "$rel" >> "$ROOT_OVERLAY_INVENTORY"
  done < <(find "$ROOT_SOURCE" -type f -print0 | sort -z)
}

shell_array_literal() {
  local value out='('
  for value in "$@"; do
    printf -v out '%s %q' "$out" "$value"
  done
  printf '%s )' "$out"
}

prepare_custom_image_project() {
  [[ -e "$CUSTOM_PROJECT/.git" ]] || die "custom-image checkout is unavailable: $CUSTOM_PROJECT"
  [[ -f "$CUSTOM_PROJECT/modules/80-set-image-abroot-config.yml" ]] || \
    die "Official custom-image ABRoot module is missing."

  rm -rf \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/profiles/$PROFILE" \
    "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/firmware-provenance" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/vanillaos-snapdragonx"

  mkdir -p \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx" \
    "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/profiles/$PROFILE" \
    "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/firmware-provenance" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/vanillaos-snapdragonx" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/vanillaos-snapdragonx/root-source-overlay" \
    "$CUSTOM_PROJECT/includes.container/etc/systemd/system/multi-user.target.wants" \
    "$CUSTOM_PROJECT/modules"

  local deb class pkg role staged_name staged_count
  for deb in "${TARGET_KERNEL_DEBS[@]}"; do
    class="$(classify_kernel_deb_for_target "$deb")"
    pkg="$(package_field "$deb" Package)"
    role="$(kernel_deb_selection_role "$deb")"
    [[ -n "$role" && "$role" != "reference-only" ]] || \
      die "Kernel closure selected a package without a resolved role: $pkg ($deb)"

    staged_name="$(kernel_deb_canonical_name "$deb")"
    [[ ! -e "$CUSTOM_PROJECT/includes.container/deb-pkgs/$staged_name" ]] || \
      die "Canonical staged package name collision: $staged_name"
    cp -a "$deb" "$CUSTOM_PROJECT/includes.container/deb-pkgs/$staged_name"
    info "Staged kernel closure package: $pkg ($class/$role) -> $staged_name"
  done

  staged_count="$(find "$CUSTOM_PROJECT/includes.container/deb-pkgs" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d '[:space:]')"
  [[ "$staged_count" == "${#TARGET_KERNEL_DEBS[@]}" ]] || \
    die "Staged kernel closure count mismatch: expected=${#TARGET_KERNEL_DEBS[@]} actual=$staged_count"

  if [[ -n "$FIRMWARE_SOURCE" ]]; then
    rsync -aHAX "$FIRMWARE_SOURCE/" "$CUSTOM_PROJECT/includes.container/usr/lib/firmware/"
  fi
  cp -a "$DTB_FILE" "$CUSTOM_PROJECT/includes.container/boot/dtbs/$DTB_NAME"

  if [[ -n "$ROOT_SOURCE" ]]; then
    rsync -aHAX "$ROOT_SOURCE/" "$CUSTOM_PROJECT/includes.container/usr/lib/vanillaos-snapdragonx/root-source-overlay/"
    ROOT_PROBE_REL="$(find "$ROOT_SOURCE" -type f -printf '%P\n' | LC_ALL=C sort | sed -n '1p' || true)"
  else
    ROOT_PROBE_REL=""
  fi

  generate_root_overlay_inventory
  cp -a "$PROFILE_RESOLVED_JSON"     "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/profile.resolved.json"
  cp -a "$PROFILE_VALIDATION_REPORT"     "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/profile-validation.tsv"
  cp -a "$ROOT_OVERLAY_INVENTORY"     "$CUSTOM_PROJECT/includes.container/usr/lib/vanillaos-snapdragonx/root-overlay.sha256"
  if [[ -d "$FIRMWARE_PROVENANCE_DIR" ]]; then
    rsync -aHAX "$FIRMWARE_PROVENANCE_DIR/" \
      "$CUSTOM_PROJECT/includes.container/usr/share/vanillaos-snapdragonx/firmware-provenance/"
  fi

  # r5 intentionally does not embed the supplied .deb archive in the target.
  # kernel-package-selection.tsv, kernel-package-closure.json, the installed-package
  # receipt, and release SHA256SUMS are the authoritative package evidence.

  printf '%s' "$CUSTOM_IMAGE_BASE" > "$CUSTOM_PROJECT/includes.container/image-info/base-image-name"
  printf '%s' "$ABROOT_IMAGE_NAME" > "$CUSTOM_PROJECT/includes.container/image-info/image-name"

  cat > "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh" <<'INSTALL_DEBS_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

packages=(/deb-pkgs/*.deb)
((${#packages[@]} > 0)) || {
  echo "No local hardware .deb packages were included" >&2
  exit 1
}

command -v apt-get >/dev/null 2>&1 || {
  echo "apt-get is unavailable before the VanillaOS package layer was unlocked" >&2
  exit 1
}
command -v dpkg-deb >/dev/null 2>&1 || {
  echo "dpkg-deb is unavailable during the package-install stage" >&2
  exit 1
}
command -v dpkg-query >/dev/null 2>&1 || {
  echo "dpkg-query is unavailable during the package-install stage" >&2
  exit 1
}

apt-get update

# The target transaction contains the payload-selected kernel image/modules,
# release-bound auxiliary packages, a release-specific orchestrator when one is
# supplied, and local Depends/Pre-Depends needed by that closure. Reference-only
# packages are retained only in release-side selection/closure evidence, not in the target.
printf 'Installing selected local kernel package closure:\n'
printf '  %s\n' "${packages[@]}"
apt-get install -y "${packages[@]}"

# VanillaOS locks the package layer later in the recipe. Package-manager
# executables therefore cannot be assumed to exist in the finished image.
# Verify the transaction now, while dpkg-query is available, and persist an
# immutable receipt for post-build verification.
receipt_dir=/usr/lib/vanillaos-snapdragonx
receipt_tmp="$receipt_dir/target-installed-kernel-packages.tsv.tmp"
receipt="$receipt_dir/target-installed-kernel-packages.tsv"
receipt_checksum="$receipt.sha256"

mkdir -p "$receipt_dir"
printf 'package\trequested_version\tinstalled_version\tarchitecture\tstatus\tsource_deb\tsource_sha256\n' > "$receipt_tmp"

for package_file in "${packages[@]}"; do
  package_name="$(dpkg-deb -f "$package_file" Package)"
  requested_version="$(dpkg-deb -f "$package_file" Version)"
  requested_architecture="$(dpkg-deb -f "$package_file" Architecture)"
  installed_version="$(dpkg-query -W -f='${Version}' "$package_name")"
  installed_architecture="$(dpkg-query -W -f='${Architecture}' "$package_name")"
  installed_status="$(dpkg-query -W -f='${Status}' "$package_name")"
  source_sha256="$(sha256sum "$package_file" | awk '{print $1}')"

  [[ "$installed_status" == "install ok installed" ]] || {
    printf 'Package did not reach installed state: %s (%s)\n'       "$package_name" "$installed_status" >&2
    exit 1
  }
  [[ "$installed_version" == "$requested_version" ]] || {
    printf 'Installed version mismatch for %s: requested=%s installed=%s\n'       "$package_name" "$requested_version" "$installed_version" >&2
    exit 1
  }
  [[ "$installed_architecture" == "$requested_architecture" ]] || {
    printf 'Installed architecture mismatch for %s: requested=%s installed=%s\n'       "$package_name" "$requested_architecture" "$installed_architecture" >&2
    exit 1
  }

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n'     "$package_name"     "$requested_version"     "$installed_version"     "$installed_architecture"     "$installed_status"     "$(basename "$package_file")"     "$source_sha256"     >> "$receipt_tmp"
done

mv -f "$receipt_tmp" "$receipt"
(
  cd "$receipt_dir"
  sha256sum "$(basename "$receipt")" > "$(basename "$receipt_checksum")"
)

test -s "$receipt"
test -s "$receipt_checksum"
printf 'Recorded verified local-package receipt: %s\n' "$receipt"
cat "$receipt"
INSTALL_DEBS_EOF
  chmod 0755 "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh"

  local firmware_array initramfs_array installed_array cmdline_array
  firmware_array="$(shell_array_literal "${PROFILE_FIRMWARE_PROBES[@]}")"
  initramfs_array="$(shell_array_literal "${PROFILE_INITRAMFS_PROBES[@]}")"
  installed_array="$(shell_array_literal "${PROFILE_INSTALLED_PATH_PROBES[@]}")"
  cmdline_array="$(shell_array_literal "${PROFILE_KERNEL_CMDLINE_APPEND[@]}")"

  cat > "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/hardware-finalize" <<EOF_FINALIZE
#!/usr/bin/env bash
set -Eeuo pipefail
release=$(printf '%q' "$KERNEL_RELEASE")
dtb=$(printf '%q' "$DTB_NAME")
profile=$(printf '%q' "$PROFILE")
firmware_probes=$firmware_array
cmdline_append=$cmdline_array

test -s "/boot/vmlinuz-\$release"
test -d "/usr/lib/modules/\$release" || test -d "/lib/modules/\$release"
test -s "/boot/dtbs/\$dtb"

command -v depmod >/dev/null 2>&1 && depmod -a "\$release"
if [[ ! -e "/boot/initrd.img-\$release" ]]; then
  touch "/boot/initrd.img-\$release"
fi
ln -sfn "boot/vmlinuz-\$release" /vmlinuz
ln -sfn "boot/initrd.img-\$release" /initrd.img
printf '%s\n' "\$release" > /usr/lib/vanillaos-snapdragonx-kernel-release
printf '%s\n' "\$dtb" > /usr/lib/vanillaos-snapdragonx-dtb
printf '%s\n' "\$profile" > /usr/lib/vanillaos-snapdragonx-profile
printf '%s\n' "\${cmdline_append[@]}" > /usr/lib/vanillaos-snapdragonx-kernel-command-line
for probe in "\${firmware_probes[@]}"; do
  firmware_path="/usr/lib/firmware/\$probe"
  [[ -f "\$firmware_path" && ! -L "\$firmware_path" && -s "\$firmware_path" ]] || {
    echo "Missing, empty, or non-regular profile firmware probe: \$firmware_path" >&2
    exit 91
  }
done

test -s /usr/share/vanillaos-snapdragonx/firmware-provenance/staged-firmware.sha256
EOF_FINALIZE
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/hardware-finalize"

  cat > "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/verify-installed-boot" <<EOF_INSTALLED_VERIFY
#!/usr/bin/env bash
set -Eeuo pipefail

expected_profile=$(printf '%q' "$PROFILE")
expected_release=$(printf '%q' "$KERNEL_RELEASE")
expected_dtb=$(printf '%q' "$DTB_NAME")
firmware_probes=$firmware_array
initramfs_probes=$initramfs_array
installed_paths=$installed_array
cmdline_append=$cmdline_array

fail_verify() {
  local code="\$1"
  shift
  printf 'VANILLAOS_SNAPDRAGONX INSTALLED-BOOT VERIFY FAILED: %s\n' "\$*" >&2
  exit "\$code"
}

require_nonempty_file() {
  local path="\$1" label="\$2" code="\$3"
  [[ -r "\$path" ]] || fail_verify "\$code" "\$label is not readable: \$path"
  [[ -s "\$path" ]] || fail_verify "\$code" "\$label is empty: \$path"
}

require_directory() {
  local path="\$1" label="\$2" code="\$3"
  [[ -d "\$path" ]] || fail_verify "\$code" "\$label is missing: \$path"
}

read_required_marker() {
  local path="\$1" label="\$2" code="\$3" value
  require_nonempty_file "\$path" "\$label marker" "\$code"
  value="\$(cat "\$path")" || fail_verify "\$code" "Unable to read \$label marker: \$path"
  [[ -n "\$value" ]] || fail_verify "\$code" "\$label marker resolved empty: \$path"
  printf '%s' "\$value"
}

profile="\$(read_required_marker /usr/lib/vanillaos-snapdragonx-profile profile 101)"
release="\$(read_required_marker /usr/lib/vanillaos-snapdragonx-kernel-release kernel 102)"
dtb="\$(read_required_marker /usr/lib/vanillaos-snapdragonx-dtb DTB 103)"

[[ "\$profile" == "\$expected_profile" ]] || \
  fail_verify 104 "Profile mismatch: expected=\$expected_profile installed=\$profile"
[[ "\$release" == "\$expected_release" ]] || \
  fail_verify 105 "Kernel mismatch: expected=\$expected_release installed=\$release"
[[ "\$dtb" == "\$expected_dtb" ]] || \
  fail_verify 106 "DTB mismatch: expected=\$expected_dtb installed=\$dtb"

[[ -r /usr/lib/vanillaos-snapdragonx-kernel-command-line ]] || \
  fail_verify 107 "Kernel command-line marker is unreadable"

require_directory "/usr/lib/modules/\$release" "selected kernel module tree" 108
require_nonempty_file "/boot/init/vos-a/vmlinuz-\$release" "ABRoot A kernel" 109
require_nonempty_file "/boot/init/vos-a/initrd.img-\$release" "ABRoot A initramfs" 110
require_nonempty_file "/boot/init/vos-a/dtbs/\$dtb" "ABRoot A DTB" 111
require_nonempty_file "/boot/init/vos-b/dtbs/\$dtb" "ABRoot B DTB seed" 112

state=/boot/init/vos-a
cfg="\$state/abroot.cfg"
require_nonempty_file "\$cfg" "ABRoot A configuration" 113

grep -Fq "vmlinuz-\$release" "\$cfg" || \
  fail_verify 114 "ABRoot configuration does not reference selected kernel \$release"

dtb_line="devicetree (lvm/vos--root-init)/vos-a/dtbs/\$dtb"
initrd_line="initrd (lvm/vos--root-init)/vos-a/initrd.img-\$release"

[[ "\$(grep -Fxc "\$dtb_line" "\$cfg" || true)" == "1" ]] || \
  fail_verify 115 "ABRoot configuration must contain exactly one selected DTB directive"
[[ "\$(grep -Fxc "\$initrd_line" "\$cfg" || true)" == "1" ]] || \
  fail_verify 116 "ABRoot configuration must contain exactly one selected initramfs directive"

awk -v dtb="\$dtb_line" -v initrd="\$initrd_line" '
  index(\$0, dtb) { d=NR }
  index(\$0, initrd) { i=NR }
  END { exit(d > 0 && i > 0 && d < i ? 0 : 1) }
' "\$cfg" || fail_verify 117 "ABRoot DTB directive does not precede initrd"

mapfile -t configured_kernels < <(
  grep -oE 'vmlinuz-[^[:space:]]+' "\$cfg" | LC_ALL=C sort -u
)
[[ "\${#configured_kernels[@]}" -eq 1 ]] || \
  fail_verify 118 "ABRoot configuration references multiple kernel images: \${configured_kernels[*]:-none}"
[[ "\${configured_kernels[0]}" == "vmlinuz-\$release" ]] || \
  fail_verify 119 "ABRoot configuration references the wrong kernel: \${configured_kernels[0]}"

kernel_line="\$(grep -E '^[[:space:]]*linux[[:space:]]+' "\$cfg" | sed -n '1p')"
[[ -n "\$kernel_line" ]] || fail_verify 120 "ABRoot config lacks a linux command"
read -r -a kernel_tokens <<<"\$kernel_line"
for argument in "\${cmdline_append[@]}"; do
  [[ -n "\$argument" ]] || continue
  count=0
  for token in "\${kernel_tokens[@]}"; do
    [[ "\$token" == "\$argument" ]] && count=\$((count + 1))
  done
  [[ "\$count" -eq 1 ]] || \
    fail_verify 120 "ABRoot config contains required kernel argument \$argument \$count times; expected exactly one"
done

for probe in "\${firmware_probes[@]}"; do
  firmware_path="/usr/lib/firmware/\$probe"
  [[ -f "\$firmware_path" && ! -L "\$firmware_path" && -s "\$firmware_path" ]] || \
    fail_verify 121 "Installed firmware probe is missing, empty, or non-regular: \$firmware_path"
done

require_nonempty_file \
  /usr/share/vanillaos-snapdragonx/firmware-provenance/staged-firmware.sha256 \
  "staged firmware provenance" 132
[[ -x /usr/libexec/vanillaos-snapdragonx/record-boot-evidence ]] || \
  fail_verify 133 "Boot evidence recorder is absent or not executable"
[[ -x /usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics ]] || \
  fail_verify 134 "Hardware diagnostics collector is absent or not executable"

for path in "\${installed_paths[@]}"; do
  [[ -e "\$path" ]] || fail_verify 122 "Required installed path is missing: \$path"
done

[[ -L /root ]] || fail_verify 123 "/root was not converted to the expected /var-backed symlink"
root_link="\$(readlink /root)" || fail_verify 124 "Unable to read the /root symlink"
case "\$root_link" in
  var/root|/var/root) : ;;
  *) fail_verify 125 "Unexpected /root symlink target: \$root_link" ;;
esac

require_nonempty_file \
  /usr/lib/vanillaos-snapdragonx/relocated-var-payload.status \
  "relocated payload status" 126
if (( \${#initramfs_probes[@]} > 0 )); then
  command -v lsinitramfs >/dev/null 2>&1 || \
    fail_verify 128 "lsinitramfs is required for configured initramfs probes"
  listing="\$(mktemp)"
  trap 'rm -f "\$listing"' EXIT
  lsinitramfs "\$state/initrd.img-\$release" > "\$listing" || \
    fail_verify 129 "Unable to list the installed initramfs"
  for probe in "\${initramfs_probes[@]}"; do
    normalized="\${probe#/}"
    grep -Fq "\$normalized" "\$listing" || \
      fail_verify 130 "Installed initramfs lacks required probe: \$probe"
  done
fi

root_overlay_status="not-configured"
if [[ -s /usr/lib/vanillaos-snapdragonx/root-overlay.sha256 ]]; then
  checksum_output="\$(mktemp)"
  if ! sha256sum -c /usr/lib/vanillaos-snapdragonx/root-overlay.sha256 \
      > "\$checksum_output" 2>&1; then
    cat "\$checksum_output" >&2 || true
    rm -f "\$checksum_output"
    fail_verify 131 \
      "Immutable legacy root-source checksum validation failed"
  fi
  cat "\$checksum_output"
  rm -f "\$checksum_output"
  root_overlay_status="pass"
fi

mkdir -p /usr/lib/vanillaos-snapdragonx
{
  printf 'check\tstatus\tdetail\n'
  printf 'profile\tpass\t%s\n' "\$profile"
  printf 'kernel\tpass\t%s\n' "\$release"
  printf 'dtb\tpass\t%s\n' "\$dtb"
  printf 'abroot_a\tpass\t%s\n' "\$cfg"
  printf 'initramfs\tpass\t%s\n' "\$state/initrd.img-\$release"
  printf 'root_relocation\tpass\t%s\n' "\$root_link"
  printf 'root_source_overlay\t%s\t%s\n' "\$root_overlay_status" \
    /usr/lib/vanillaos-snapdragonx/root-overlay.sha256
  printf 'firmware_provenance\tpass\t%s\n' \
    /usr/share/vanillaos-snapdragonx/firmware-provenance/staged-firmware.sha256
  printf 'boot_evidence_collector\tpass\t%s\n' \
    /usr/libexec/vanillaos-snapdragonx/record-boot-evidence
  printf 'hardware_diagnostics\tpass\t%s\n' \
    /usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics
} > /usr/lib/vanillaos-snapdragonx/installed-boot-validation.tsv

printf 'VanillaOS-SnapdragonX installed-boot verification passed for profile %s.\n' "\$profile"
EOF_INSTALLED_VERIFY
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/verify-installed-boot"

  # Vanilla installations may not retain a conventional dmesg text file. This
  # oneshot records the boot's kernel journal, command line, Adreno messages,
  # firmware inventory, and DRM nodes into writable /var after each boot.
  cat > "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/record-boot-evidence" <<'BOOT_EVIDENCE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

out=/var/log/vanillaos-snapdragonx
mkdir -p "$out"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || date -u +%Y%m%d-%H%M%S)"
work="$out/.boot-$boot_id.tmp"
final="$out/boot-$boot_id"
rm -rf "$work"
mkdir -p "$work"

cat /proc/cmdline > "$work/proc-cmdline.txt"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k -b --no-pager > "$work/kernel-journal.txt" 2>&1 || true
else
  dmesg > "$work/kernel-journal.txt" 2>&1 || true
fi

grep -Ei 'adreno|gen71500|gmu|gpu|gpucc|msm_dpu|drm|iommu|smmu|cma|firmware' \
  "$work/kernel-journal.txt" > "$work/adreno-focused-kernel.txt" || true

find /usr/lib/firmware/qcom -maxdepth 4 \
  \( -name 'gen71500*' -o -name '*8380*' \) \
  -printf '%M\t%u:%g\t%s\t%p\t%l\n' 2>/dev/null | LC_ALL=C sort \
  > "$work/qcom-firmware-files.tsv" || true
sha256sum \
  /usr/lib/firmware/qcom/gen71500_sqe.fw \
  /usr/lib/firmware/qcom/gen71500_gmu.bin \
  /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn \
  > "$work/adreno-firmware.sha256" 2>&1 || true

ls -la /dev/dri > "$work/dev-dri.txt" 2>&1 || true
command -v glxinfo >/dev/null 2>&1 && glxinfo -B > "$work/glxinfo-B.txt" 2>&1 || true
command -v eglinfo >/dev/null 2>&1 && eglinfo -B > "$work/eglinfo-B.txt" 2>&1 || true

rm -rf "$final"
mv "$work" "$final"
ln -sfn "$(basename "$final")" "$out/current"
BOOT_EVIDENCE_EOF
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/record-boot-evidence"

  cat > "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics" <<'HW_COLLECT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

profile="$(jq -r '.vanillaos_snapdragonx_profile // empty' /etc/vanilla-installer/recipe.json 2>/dev/null || true)"
[[ -n "$profile" ]] || profile=unknown

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="vanillaos-snapdragonx-hardware-diagnostics-$stamp"
work="${TMPDIR:-/tmp}/$name"
archive="${1:-$PWD/$name.tar.gz}"
mkdir -p "$work"

/usr/libexec/vanillaos-snapdragonx/record-boot-evidence || true
cp -a /var/log/vanillaos-snapdragonx "$work/" 2>/dev/null || true
cp -a /usr/share/vanillaos-snapdragonx/firmware-provenance "$work/" 2>/dev/null || true
cp -a /usr/share/vanillaos-snapdragonx/profiles "$work/" 2>/dev/null || true
cp -a /usr/lib/vanillaos-snapdragonx-kernel-command-line "$work/" 2>/dev/null || true
cp -a /usr/lib/vanillaos-snapdragonx-kernel-release "$work/" 2>/dev/null || true
cp -a /usr/lib/vanillaos-snapdragonx-dtb "$work/" 2>/dev/null || true
cp -a /usr/lib/vanillaos-snapdragonx-profile "$work/" 2>/dev/null || true

find /sys/class/drm -maxdepth 3 -printf '%M\t%p\t%l\n' 2>/dev/null | LC_ALL=C sort \
  > "$work/sys-class-drm.tsv" || true
find /sys/kernel/debug/dri -maxdepth 4 -type f -print 2>/dev/null | LC_ALL=C sort \
  > "$work/debug-dri-files.txt" || true

mkdir -p "$(dirname "$archive")"
tar -C "$(dirname "$work")" -czf "$archive" "$(basename "$work")"
sha256sum "$archive"
printf 'Diagnostic archive: %s\n' "$archive"
HW_COLLECT_EOF
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics"

  cat > "$CUSTOM_PROJECT/includes.container/etc/systemd/system/vanillaos-snapdragonx-boot-evidence.service" <<'BOOT_SERVICE_EOF'
[Unit]
Description=Record VanillaOS-SnapdragonX Snapdragon X boot and GPU evidence
After=systemd-journald.service local-fs.target
Wants=systemd-journald.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/vanillaos-snapdragonx/record-boot-evidence
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BOOT_SERVICE_EOF
  ln -sfn ../vanillaos-snapdragonx-boot-evidence.service \
    "$CUSTOM_PROJECT/includes.container/etc/systemd/system/multi-user.target.wants/vanillaos-snapdragonx-boot-evidence.service"

  bash -n "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/hardware-finalize"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/verify-installed-boot"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/record-boot-evidence"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics"

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
  - /usr/libexec/vanillaos-snapdragonx/hardware-finalize
MODULE_HW_EOF

  cat > "$CUSTOM_PROJECT/recipe.yml" <<EOF_RECIPE
name: VanillaOS-SnapdragonX Desktop for $PROFILE
id: vanillaos-snapdragonx-$PROFILE
vibversion: $VIB_RECIPE_VERSION

stages:
  - id: build
    base: $CUSTOM_IMAGE_BASE
    addincludes: true
    singlelayer: false
    labels:
      maintainer: VanillaOS-SnapdragonX
      vanillaos-snapdragonx.profile: $PROFILE
      vanillaos-snapdragonx.profile-schema: "$PROFILE_SCHEMA_VERSION"
      vanillaos-snapdragonx.kernel: $KERNEL_RELEASE
      vanillaos-snapdragonx.dtb: $DTB_NAME
      vanillaos-snapdragonx.builder-version: "$SCRIPT_VERSION"
      vanillaos-snapdragonx.firmware-package-count: "$(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")"
      vanillaos-snapdragonx.firmware-lock-sha256: "$(sha256sum "$FIRMWARE_PACKAGE_LOCK_FILE" | awk '{print $1}')"
      vanillaos-snapdragonx.board-data-policy: "$FIRMWARE_BOARD_POLICY"
    args:
      DEBIAN_FRONTEND: noninteractive
    runs:
      commands:
        - echo 'APT::Install-Recommends "1";' > /etc/apt/apt.conf.d/01vanillaos-snapdragonx-recommends
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

      - name: cleanup2
        type: shell
        commands:
          - rm -rf /tmp/*
          - rm -rf /var/tmp/*
EOF_RECIPE

  cat > "$CUSTOM_PROJECT/VanillaOS-SnapdragonX-INPUTS.txt" <<EOF_INPUTS
Kernel packages discovered from:
  $ARTIFACT_DIR/kernel-debs/
  Compatibility fallback: $ARTIFACT_DIR/*.deb

Package handling:
  Supplied unique:  ${#KERNEL_DEBS[@]}
  Target installed: ${#TARGET_KERNEL_DEBS[@]} payload/dependency closure packages
  Live extracted:   ${#LIVE_KERNEL_DEBS[@]} image/module/auxiliary packages
  Target excluded:  ${#TARGET_EXCLUDED_KERNEL_DEBS[@]} reference-only packages
  Target archive:   none (retired in r5; redundant target-side historical payload)
  Selection record: release evidence kernel-package-selection.tsv
  Closure record:   kernel-package-closure.json in release evidence

Selected release:
  $KERNEL_RELEASE
Selected image package:
  $(package_field "$KERNEL_IMAGE_DEB" Package)=$(package_field "$KERNEL_IMAGE_DEB" Version)
  $KERNEL_IMAGE_DEB

Selected DTB:
  $DTB_FILE

Firmware source copied as paths relative to /usr/lib/firmware:
  ${FIRMWARE_SOURCE:-none}

Legacy root-source input (stored immutable; not installed beneath /root):
  ${ROOT_SOURCE:-none}

ABRoot image name:
  $ABROOT_IMAGE_NAME

Build/push reference:
  $TARGET_IMAGE_REF
EOF_INPUTS

  ok "Prepared official custom-image-derived Vib project: $CUSTOM_PROJECT"
}

inspect_stable_reunion_oci() {
  local role="$1" reference="$2" destination="$3"
  case "$reference" in
    ghcr.io/*|docker.io/*|quay.io/*)
      info "Resolving stable Reunion ARM64 OCI descriptor: role=$role reference=$reference"
      skopeo --override-arch arm64 inspect "docker://$reference" > "$destination" ||
        die "Unable to resolve ARM64 OCI descriptor for $role: $reference"
      jq -e '.Architecture == "arm64" or .Architecture == "aarch64"' "$destination" >/dev/null ||
        die "Resolved $role descriptor is not ARM64: $reference"
      local digest
      digest="$(jq -r '.Digest // empty' "$destination")"
      [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "Resolved $role descriptor lacks a canonical SHA-256 digest: $reference"
      ok "Resolved $role: $reference@$digest"
      ;;
    *)
      # Preserve the historical explicit local/custom-image override surface.
      # Stable upstream defaults always take the content-addressed path above;
      # a deliberate non-registry override is recorded but cannot honestly be
      # represented as a remote manifest digest by skopeo.
      warn "$role uses a non-registry override; remote moving-tag digest resolution is not applicable: $reference"
      jq -n --arg reference "$reference" \
        '{Name:$reference, Architecture:"override-unverified", Digest:null,
          ReunionResolution:"explicit-non-registry-override"}' > "$destination"
      ;;
  esac
}

resolve_stable_reunion_oci_provenance() {
  local live_inspect="$TMP_ROOT/live-builder-inspect.json"
  local vso_inspect="$TMP_ROOT/vso-native-inspect.json"

  inspect_stable_reunion_oci target-base "$CUSTOM_IMAGE_BASE" "$TARGET_BASE_INSPECT_JSON"
  inspect_stable_reunion_oci live-builder "$LIVE_ISO_CONTAINER_IMAGE" "$live_inspect"
  inspect_stable_reunion_oci vso-native "$VSO_NATIVE_IMAGE" "$vso_inspect"

  jq -n \
    --arg target_ref "$CUSTOM_IMAGE_BASE" \
    --arg target_digest "$(jq -r '.Digest // empty' "$TARGET_BASE_INSPECT_JSON")" \
    --arg target_arch "$(jq -r '.Architecture' "$TARGET_BASE_INSPECT_JSON")" \
    --arg live_ref "$LIVE_ISO_CONTAINER_IMAGE" \
    --arg live_digest "$(jq -r '.Digest // empty' "$live_inspect")" \
    --arg live_arch "$(jq -r '.Architecture' "$live_inspect")" \
    --arg vso_ref "$VSO_NATIVE_IMAGE" \
    --arg vso_digest "$(jq -r '.Digest // empty' "$vso_inspect")" \
    --arg vso_arch "$(jq -r '.Architecture' "$vso_inspect")" \
    --arg vso_base "$VSO_NATIVE_UPSTREAM_BASE" \
    '{schema:1, architecture:"arm64", resolved_at_utc:(now|todateiso8601),
      inputs:[
        {role:"target-base", requested_reference:$target_ref, resolved_digest:$target_digest, architecture:$target_arch, required_for_build:true},
        {role:"live-builder", requested_reference:$live_ref, resolved_digest:$live_digest, architecture:$live_arch, required_for_build:true},
        {role:"vso-native", requested_reference:$vso_ref, resolved_digest:$vso_digest, architecture:$vso_arch, required_for_build:false, upstream_base_contract:$vso_base}
      ]}' > "$UPSTREAM_OCI_PROVENANCE_JSON"

  jq -e '.inputs | length == 3 and all(.[];
      if (.requested_reference | test("^(ghcr\\.io|docker\\.io|quay\\.io)/"))
      then (.resolved_digest | test("^sha256:[0-9a-f]{64}$"))
      else (.resolved_digest == "") end)' \
    "$UPSTREAM_OCI_PROVENANCE_JSON" >/dev/null ||
    die "Stable Reunion OCI provenance manifest failed validation."

  # Refresh convergence evidence now that moving stable tags have concrete digests.
  write_reunion_convergence_manifest
}

validate_target_base_arm64() {
  resolve_stable_reunion_oci_provenance
}

build_target_oci() {
  validate_target_base_arm64
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
    info "The target OCI reference is local-only; v$SCRIPT_VERSION will embed and serve it from the ISO in iso-oci mode."
  fi
}

verify_target_oci() {
  local verify_script="$TMP_ROOT/verify-target-oci.sh"
  local expected_packages="$TMP_ROOT/target-installed-package-expectations.tsv"
  local actual_receipt="$TMP_ROOT/target-installed-kernel-packages.actual.tsv"
  local deb pkg version arch

  : > "$expected_packages"
  for deb in "${TARGET_KERNEL_DEBS[@]}"; do
    pkg="$(package_field "$deb" Package)"
    version="$(package_field "$deb" Version)"
    arch="$(package_field "$deb" Architecture)"
    printf '%s\t%s\t%s\n' "$pkg" "$version" "$arch" >> "$expected_packages"
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
expected_package_file="$6"
expected_profile="$7"

receipt=/usr/lib/vanillaos-snapdragonx/target-installed-kernel-packages.tsv
receipt_checksum=/usr/lib/vanillaos-snapdragonx/target-installed-kernel-packages.tsv.sha256

test -s "/boot/vmlinuz-$release"
test -d "/usr/lib/modules/$release" || test -d "/lib/modules/$release"
test -e "/boot/initrd.img-$release"
test "$(readlink -f /vmlinuz)" = "/boot/vmlinuz-$release"
test "$(readlink -f /initrd.img)" = "/boot/initrd.img-$release"
test -s "/boot/dtbs/$dtb"
grep -Fxq "$release" /usr/lib/vanillaos-snapdragonx-kernel-release
grep -Fxq "$dtb" /usr/lib/vanillaos-snapdragonx-dtb
grep -Fxq "$expected_profile" /usr/lib/vanillaos-snapdragonx-profile
test -f /usr/lib/vanillaos-snapdragonx-kernel-command-line
grep -Fq "$abroot_name" /usr/share/abroot/abroot.json

for storage_command in cryptsetup lsblk blkid; do
  command -v "$storage_command" >/dev/null 2>&1 || {
    echo "Target image lacks boot-storage command: $storage_command" >&2
    exit 1
  }
done
unlock_hook=/usr/share/init.d/090-abroot-unlock-var.sh
test -s "$unlock_hook"
grep -Fq '/dev/mapper/vos--var-var' "$unlock_hook"
grep -Fq '/dev/disk/by-partlabel/vos-var' "$unlock_hook"
grep -Fq '/dev/disk/by-label/vos-var' "$unlock_hook"

test -s /usr/share/vanillaos-snapdragonx/firmware-provenance/staged-firmware.sha256
test -x /usr/libexec/vanillaos-snapdragonx/record-boot-evidence
test -x /usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics
test -f /etc/systemd/system/vanillaos-snapdragonx-boot-evidence.service
test -L /etc/systemd/system/multi-user.target.wants/vanillaos-snapdragonx-boot-evidence.service

for core_firmware in \
  /usr/lib/firmware/qcom/gen71500_sqe.fw \
  /usr/lib/firmware/qcom/gen71500_gmu.bin \
  /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn; do
  test -f "$core_firmware"
  test ! -L "$core_firmware"
  test -s "$core_firmware"
done

# The official custom-image cleanup locks the package layer before final image verification.
# Do not require apt, dpkg, or dpkg-query in the finished immutable image.
# Protect the graphical desktop by checking the actual runtime executables.
test -x /usr/bin/gnome-shell
test -x /usr/bin/mutter
if [[ -x /usr/sbin/gdm3 ]]; then
  :
elif [[ -x /usr/sbin/gdm ]]; then
  :
else
  echo "GDM executable is absent from the target desktop image" >&2
  exit 1
fi
if [[ -x /usr/bin/NetworkManager ]]; then
  :
elif [[ -x /usr/sbin/NetworkManager ]]; then
  :
else
  echo "NetworkManager executable is absent from the target desktop image" >&2
  exit 1
fi

# Reunion userland coherence gate. A working Distrobox container by itself is
# not sufficient evidence: the installed target must contain the host-side
# VSO/APX/Distrobox generation expected by current Reunion.
test -x /usr/bin/vso || {
  echo "Reunion target lacks /usr/bin/vso" >&2
  exit 1
}
test -x /usr/bin/distrobox || {
  echo "Reunion target lacks canonical /usr/bin/distrobox" >&2
  exit 1
}
test -x /usr/bin/setup-vso-terminal || {
  echo "Reunion target lacks setup-vso-terminal" >&2
  exit 1
}

# APX 3.1.1 calls `distrobox --version` and treats the final whitespace-
# separated token as opaque. Do not impose a semantic-version requirement that
# upstream itself does not guarantee: Distrobox 2.0.0-rc.4 defaults Version to
# "dev" and its Makefile replaces that value only when build-time VERSION/Git
# metadata is available. Vib source staging can therefore legitimately produce
# `distrobox version dev`.
distrobox_version="$(/usr/bin/distrobox --version)" || {
  echo "Distrobox --version failed; APX 3.1.1+ requires this interface" >&2
  exit 1
}
case "$distrobox_version" in
  'distrobox version '?*) : ;;
  *)
    echo "Unexpected Distrobox version interface: $distrobox_version" >&2
    exit 1
    ;;
esac
distrobox_release="${distrobox_version##* }"
[[ -n "$distrobox_release" ]] || {
  echo "Distrobox --version returned an empty release token" >&2
  exit 1
}

# When upstream supplies a numeric release, retain the stronger r1 range checks.
# For source-build identifiers such as `dev` or a Git-derived opaque token,
# validate the modern Distrobox v2 CLI and the APX helper layout installed by
# current Vanilla core-image instead of rejecting a valid upstream build.
if [[ "$distrobox_release" =~ ^[0-9]+([.][0-9]+)*([-.][0-9A-Za-z.]+)*$ ]]; then
  distrobox_major="${distrobox_release%%.*}"
  [[ "$distrobox_major" =~ ^[0-9]+$ ]] || {
    echo "Unable to parse numeric Distrobox major version: $distrobox_release" >&2
    exit 1
  }
  (( distrobox_major >= 2 )) || {
    echo "Distrobox is older than the Reunion-compatible 2.x generation: $distrobox_release" >&2
    exit 1
  }
  if [[ "$distrobox_release" == 2.0.0-rc.* ]]; then
    distrobox_rc="${distrobox_release#2.0.0-rc.}"
    [[ "$distrobox_rc" =~ ^[0-9]+$ ]] && (( distrobox_rc >= 4 )) || {
      echo "Distrobox release candidate predates the required additional-flags fix: $distrobox_release" >&2
      exit 1
    }
  fi
else
  for distrobox_subcommand in create enter list rm; do
    /usr/bin/distrobox "$distrobox_subcommand" --help >/dev/null 2>&1 || {
      echo "Opaque Distrobox build token '$distrobox_release' lacks v2 subcommand: $distrobox_subcommand" >&2
      exit 1
    }
  done
fi

# Current Vanilla core-image installs these APX-facing helpers explicitly.
# Validate their resolved targets so an opaque source-build token cannot mask the
# historical /usr/local path skew or an incomplete Distrobox installation.
test -L /usr/share/apx/distrobox/distrobox-enter && \
  [[ "$(readlink -f /usr/share/apx/distrobox/distrobox-enter)" == /usr/bin/distrobox ]] || {
  echo "APX Distrobox enter helper does not resolve to /usr/bin/distrobox" >&2
  exit 1
}
for distrobox_helper in distrobox-export distrobox-host-exec distrobox-init; do
  test -L "/usr/share/apx/distrobox/$distrobox_helper" || {
    echo "APX Distrobox helper symlink is absent: $distrobox_helper" >&2
    exit 1
  }
  [[ "$(readlink -f "/usr/share/apx/distrobox/$distrobox_helper")" == "/usr/bin/$distrobox_helper" ]] || {
    echo "APX Distrobox helper resolves unexpectedly: $distrobox_helper" >&2
    exit 1
  }
done

# Current Reunion exposes the managed System Operator subsystem as `native`,
# not the transitional Pico-generation command surface.
/usr/bin/vso native --help >/dev/null 2>&1 || {
  echo "VSO does not expose the current Reunion native subsystem" >&2
  exit 1
}

vso_stack=/usr/share/vso/apx/stacks/vso-native.yaml
test -f "$vso_stack" && test ! -L "$vso_stack" || {
  echo "Reunion VSO native stack is absent or not a regular file" >&2
  exit 1
}
grep -Eq '^name:[[:space:]]*vso-native[[:space:]]*$' "$vso_stack"
grep -Eq '^base:[[:space:]]*ghcr\.io/vanilla-os/vso:latest[[:space:]]*$' "$vso_stack"
grep -Eq '^pkgmanager:[[:space:]]*apt[[:space:]]*$' "$vso_stack"
grep -Eq '^builtin:[[:space:]]*true[[:space:]]*$' "$vso_stack"

test ! -e /usr/share/vso/apx/stacks/vso-pico.yaml || {
  echo "Transitional vso-pico stack unexpectedly remains in the Reunion target" >&2
  exit 1
}
for hook in pre-init-hook init-hook; do
  test -f "/usr/share/vso/scripts/$hook" && test ! -L "/usr/share/vso/scripts/$hook" || {
    echo "Reunion VSO host hook placeholder is absent: $hook" >&2
    exit 1
  }
done

vso_service=/usr/lib/systemd/user/apx-vso-native.service
test -f "$vso_service" && test ! -L "$vso_service" || {
  echo "Reunion managed VSO user service is absent or not a regular file: $vso_service" >&2
  exit 1
}

printf 'REUNION-COHERENCE: distrobox=%s\n' "$distrobox_version"
printf 'REUNION-COHERENCE: vso-native=present\n'
printf 'REUNION-COHERENCE: vso-instance=apx-vso-native\n'
printf 'REUNION-COHERENCE: vso-hooks=pre-init-hook,init-hook\n'
printf 'REUNION-COHERENCE: distrobox-path=/usr/bin/distrobox\n'

# Validate the receipt written during the unlocked package-install stage.
test -s "$receipt"
test -s "$receipt_checksum"
(
  cd "$(dirname "$receipt")"
  sha256sum -c "$(basename "$receipt_checksum")"
)

header="$(sed -n '1p' "$receipt")"
expected_header=$'package\trequested_version\tinstalled_version\tarchitecture\tstatus\tsource_deb\tsource_sha256'
[[ "$header" == "$expected_header" ]] || {
  echo "Unexpected installed-package receipt header" >&2
  printf 'expected: %q\nactual:   %q\n' "$expected_header" "$header" >&2
  exit 1
}

expected_count="$(wc -l < "$expected_package_file" | tr -d '[:space:]')"
actual_count="$(awk 'NR > 1 { count++ } END { print count + 0 }' "$receipt")"
[[ "$actual_count" == "$expected_count" ]] || {
  echo "Installed-package receipt count mismatch: expected=$expected_count actual=$actual_count" >&2
  exit 1
}

while IFS=$'\t' read -r package requested_version architecture; do
  [[ -n "$package" ]] || continue

  awk -F '\t' \
    -v package="$package" \
    -v requested="$requested_version" \
    -v architecture="$architecture" '
      NR > 1 &&
      $1 == package &&
      $2 == requested &&
      $3 == requested &&
      $4 == architecture &&
      $5 == "install ok installed" {
        found=1
      }
      END { exit(found ? 0 : 1) }
    ' "$receipt" || {
      echo "Verified build-time package receipt is missing or mismatched: $package $requested_version $architecture" >&2
      exit 1
    }
done < "$expected_package_file"


if [[ -n "$firmware_probe" ]]; then
  test -s "/usr/lib/firmware/$firmware_probe" || test -s "/lib/firmware/$firmware_probe"
fi
if [[ -n "$root_probe" ]]; then
  test -e "/usr/lib/vanillaos-snapdragonx/root-source-overlay/$root_probe"
fi

if command -v dpkg-query >/dev/null 2>&1; then
  echo "Informational: dpkg-query remains available in this target image."
else
  echo "Informational: dpkg-query is absent after package-layer locking; persistent receipt validation was used."
fi
VERIFY_OCI_EOF
  chmod 0755 "$verify_script"

  run_logged "verify-target-oci" "$OCI_RUNTIME" run --rm \
    -v "$verify_script:/verify-target-oci.sh:ro" \
    -v "$expected_packages:/expected-target-packages.tsv:ro" \
    --entrypoint /bin/bash "$TARGET_IMAGE_REF" \
    /verify-target-oci.sh "$KERNEL_RELEASE" "$DTB_NAME" "$ABROOT_IMAGE_NAME" \
    "$FIRMWARE_PROBE_REL" "$ROOT_PROBE_REL" \
    /expected-target-packages.tsv "$PROFILE"

  # Export the exact receipt from the verified image into release evidence.
  "$OCI_RUNTIME" run --rm \
    --entrypoint /bin/cat \
    "$TARGET_IMAGE_REF" \
    /usr/lib/vanillaos-snapdragonx/target-installed-kernel-packages.tsv \
    > "$actual_receipt"
  [[ -s "$actual_receipt" ]] || die "Unable to export the target installed-package receipt."

  cp -a "$actual_receipt" "$RELEASE_DIR/target-installed-kernel-packages.tsv"
  cp -a "$expected_packages" "$RELEASE_DIR/target-installed-package-expectations.tsv"

  # Preserve the target's actual ABRoot configuration as evidence. Its
  # registry/name/tag fields describe future update lookup and must never be
  # confused with the ISO-local installation transport.
  "$OCI_RUNTIME" run --rm --entrypoint /bin/cat "$TARGET_IMAGE_REF"     /usr/share/abroot/abroot.json > "$TARGET_ABROOT_CONFIG_EVIDENCE"
  jq -e . "$TARGET_ABROOT_CONFIG_EVIDENCE" >/dev/null ||     die "Unable to export valid target ABRoot configuration evidence."
  cp -a "$TARGET_ABROOT_CONFIG_EVIDENCE" "$RELEASE_DIR/target-abroot.json"

  local verify_target_log="$LOG_DIR/${SESSION_ID}-verify-target-oci.log"
  grep '^REUNION-COHERENCE:' "$verify_target_log" > "$TARGET_USERLAND_COHERENCE_REPORT" ||     die "Target verification did not emit Reunion userland coherence evidence."
  [[ "$(wc -l < "$TARGET_USERLAND_COHERENCE_REPORT")" -ge 5 ]] ||     die "Target userland coherence report is incomplete."
  cp -a "$TARGET_USERLAND_COHERENCE_REPORT" "$RELEASE_DIR/target-userland-coherence.txt"
  [[ -s "$TARGET_BASE_INSPECT_JSON" ]] && cp -a "$TARGET_BASE_INSPECT_JSON" "$RELEASE_DIR/target-base-inspect.json"

  ok "Target OCI verification passed without requiring runtime package-manager tools."
}



# ---------------------- embedded target image ----------------------------

local_registry_repository() {
  printf '%s/%s' "$LOCAL_REGISTRY_NAMESPACE" "$PROFILE"
}

local_registry_logical_prefix() {
  printf '%s/%s/%s' \
    "$LOCAL_REGISTRY_LOGICAL_HOST" "$LOCAL_REGISTRY_NAMESPACE" "$PROFILE"
}

local_registry_physical_prefix() {
  printf '%s:%s/%s/%s' \
    "$LOCAL_REGISTRY_HOST" "$LOCAL_REGISTRY_PORT" \
    "$LOCAL_REGISTRY_NAMESPACE" "$PROFILE"
}

compose_local_install_image_ref() {
  local tag="$1"
  printf '%s:%s' "$(local_registry_logical_prefix)" "$tag"
}

validate_prometheus_storage_reference_compatibility() {
  # Albius currently derives a storage name with:
  #   strings.ReplaceAll(imageSource, "/", "-")
  # A port-bearing source retains two ':' characters after that operation and
  # is rejected by the containers-storage reference parser.
  local image_ref="$1"
  local derived="${image_ref//\//-}"

  [[ "$image_ref" != *"://"* ]] || \
    die "Installer image reference must not include a transport prefix: $image_ref"
  [[ "$derived" =~ ^[a-z0-9][a-z0-9._-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || \
    die "Installer image reference is incompatible with Albius storage naming: source=$image_ref derived=$derived"
}

local_image_transport_ref() {
  case "$OCI_RUNTIME" in
    podman) printf 'containers-storage:%s' "$TARGET_IMAGE_REF" ;;
    docker) printf 'docker-daemon:%s' "$TARGET_IMAGE_REF" ;;
    *) die "Unsupported OCI runtime for local image export: $OCI_RUNTIME" ;;
  esac
}

hash_tree_manifest() {
  local root="$1"
  (
    cd "$root"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

verify_exported_oci_storage_hook() {
  # Validate the hook from the exported OCI layout itself, not from the live
  # squashfs and not merely from the mutable source tag used before export.
  # Importing the layout under a temporary private tag makes the hook evidence
  # directly attributable to the manifest digest recorded in index.json.
  local verify_ref="localhost/vanillaos-snapdragonx/exported-oci-verify:${SESSION_ID}"
  local destination_ref=""

  case "$OCI_RUNTIME" in
    podman) destination_ref="containers-storage:$verify_ref" ;;
    docker) destination_ref="docker-daemon:$verify_ref" ;;
    *) die "Unsupported OCI runtime for exported-layout verification: $OCI_RUNTIME" ;;
  esac

  "$OCI_RUNTIME" image rm -f "$verify_ref" >/dev/null 2>&1 || true
  run_logged "import-exported-oci-for-storage-hook-verification" \
    skopeo copy "oci:$EMBEDDED_OCI_LAYOUT:$EMBEDDED_IMAGE_TAG" "$destination_ref"

  rm -f "$TARGET_STORAGE_HOOK_FILE" "$TARGET_STORAGE_HOOK_SHA256_FILE"
  if ! "$OCI_RUNTIME" run --rm \
      --entrypoint /bin/cat \
      "$verify_ref" \
      /usr/share/init.d/090-abroot-unlock-var.sh \
      > "$TARGET_STORAGE_HOOK_FILE"; then
    "$OCI_RUNTIME" image rm -f "$verify_ref" >/dev/null 2>&1 || true
    die "Unable to export the ABRoot /var unlock hook from the exported OCI layout."
  fi
  "$OCI_RUNTIME" image rm -f "$verify_ref" >/dev/null 2>&1 || true

  [[ -s "$TARGET_STORAGE_HOOK_FILE" ]] ||
    die "Exported OCI layout contains an empty ABRoot /var unlock hook."
  grep -Fq '/dev/mapper/vos--var-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Exported target hook lacks automatic LVM encrypted /var discovery."
  grep -Fq '/dev/disk/by-partlabel/vos-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Exported target hook lacks manual encrypted /var PARTLABEL discovery."
  grep -Fq '/dev/disk/by-label/vos-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Exported target hook lacks unencrypted /var filesystem-label discovery."

  (
    cd "$(dirname "$TARGET_STORAGE_HOOK_FILE")"
    sha256sum "$(basename "$TARGET_STORAGE_HOOK_FILE")"
  ) > "$TARGET_STORAGE_HOOK_SHA256_FILE"
}

export_target_oci_for_installer() {
  local source_ref descriptor digest_hex manifest_blob
  source_ref="$(local_image_transport_ref)"
  EMBEDDED_IMAGE_TAG="${EMBEDDED_IMAGE_TAG:-${BUILD_DATE}-${RELEASE_ID}}"
  LOCAL_INSTALL_IMAGE_REF="$(compose_local_install_image_ref "$EMBEDDED_IMAGE_TAG")"
  validate_prometheus_storage_reference_compatibility "$LOCAL_INSTALL_IMAGE_REF"

  rm -rf "$EMBEDDED_OCI_LAYOUT"
  mkdir -p "$EMBEDDED_OCI_LAYOUT"

  run_logged "export-target-oci-layout" \
    skopeo copy --all "$source_ref" "oci:$EMBEDDED_OCI_LAYOUT:$EMBEDDED_IMAGE_TAG"

  [[ -s "$EMBEDDED_OCI_LAYOUT/oci-layout" ]] || die "OCI layout marker was not exported."
  [[ -s "$EMBEDDED_OCI_LAYOUT/index.json" ]] || die "OCI layout index was not exported."

  descriptor="$(jq -c --arg tag "$EMBEDDED_IMAGE_TAG" '
    [.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $tag)]
    | if length == 1 then .[0] else empty end
  ' "$EMBEDDED_OCI_LAYOUT/index.json")"
  [[ -n "$descriptor" ]] || die "OCI layout index does not contain exactly one descriptor for tag $EMBEDDED_IMAGE_TAG"

  TARGET_IMAGE_MANIFEST_DIGEST="$(jq -r '.digest' <<<"$descriptor")"
  [[ "$TARGET_IMAGE_MANIFEST_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \
    die "Unexpected embedded OCI manifest digest: $TARGET_IMAGE_MANIFEST_DIGEST"
  digest_hex="${TARGET_IMAGE_MANIFEST_DIGEST#sha256:}"
  manifest_blob="$EMBEDDED_OCI_LAYOUT/blobs/sha256/$digest_hex"
  [[ -s "$manifest_blob" ]] || die "Embedded OCI manifest blob is missing: $manifest_blob"
  [[ "sha256:$(sha256sum "$manifest_blob" | awk '{print $1}')" == "$TARGET_IMAGE_MANIFEST_DIGEST" ]] || \
    die "Embedded OCI manifest blob digest mismatch."

  verify_exported_oci_storage_hook

  {
    printf 'path\tbytes\tsha256\n'
    while IFS= read -r -d '' file; do
      printf '%s\t%s\t%s\n' \
        "${file#"$EMBEDDED_OCI_LAYOUT"/}" \
        "$(stat -c %s "$file")" \
        "$(sha256sum "$file" | awk '{print $1}')"
    done < <(find "$EMBEDDED_OCI_LAYOUT" -type f -print0 | sort -z)
  } > "$EMBEDDED_OCI_INVENTORY"
  hash_tree_manifest "$EMBEDDED_OCI_LAYOUT" > "$EMBEDDED_OCI_TREE_HASH"

  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    INSTALLER_DEFAULT_IMAGE_REF="$LOCAL_INSTALL_IMAGE_REF"
  else
    INSTALLER_DEFAULT_IMAGE_REF="$REGISTRY_IMAGE_REF"
  fi

  local abroot_registry abroot_config_name abroot_tag
  abroot_registry="$(jq -r '.registry // empty' "$TARGET_ABROOT_CONFIG_EVIDENCE")"
  abroot_config_name="$(jq -r '.name // empty' "$TARGET_ABROOT_CONFIG_EVIDENCE")"
  abroot_tag="$(jq -r '.tag // empty' "$TARGET_ABROOT_CONFIG_EVIDENCE")"

  jq -n \
    --arg profile "$PROFILE" \
    --arg upstream_base "$CUSTOM_IMAGE_BASE" \
    --arg local_target "$TARGET_IMAGE_REF" \
    --arg tag "$EMBEDDED_IMAGE_TAG" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg layout "$ISO_IMAGE_LAYOUT_PATH" \
    --arg logical_ref "$LOCAL_INSTALL_IMAGE_REF" \
    --arg physical_ref "$(local_registry_physical_prefix):$EMBEDDED_IMAGE_TAG" \
    --arg installer_ref "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg delivery "$DELIVERY_MODE" \
    --arg abroot_identity "$ABROOT_IMAGE_NAME" \
    --arg abroot_registry "$abroot_registry" \
    --arg abroot_name "$abroot_config_name" \
    --arg abroot_tag "$abroot_tag" \
    --arg kernel "$KERNEL_RELEASE" \
    --arg dtb "$DTB_NAME" \
    '{schema:2, profile:$profile,
      upstream_base:$upstream_base,
      local_target_build_reference:$local_target,
      embedded_oci:{tag:$tag,manifest_digest:$digest,iso_layout_path:$layout},
      installer:{delivery_mode:$delivery,logical_reference:$logical_ref,
                 physical_loopback_reference:$physical_ref,
                 selected_reference:$installer_ref},
      abroot:{logical_identity:$abroot_identity,
              future_update_locator:{registry:$abroot_registry,name:$abroot_name,tag:$abroot_tag}},
      installation_provenance:(if $delivery == "iso-oci" then
        "verified ISO-embedded OCI layout served through loopback registry bridge"
        else "external registry delivery selected explicitly" end),
      kernel_release:$kernel, dtb:$dtb}' \
    > "$TMP_ROOT/embedded-target-image.json"

  [[ -s "$TARGET_STORAGE_HOOK_FILE" && -s "$TARGET_STORAGE_HOOK_SHA256_FILE" ]] ||
    die "Target storage-hook evidence was not produced before OCI export."
  local target_storage_hook_sha
  target_storage_hook_sha="$(awk 'NR == 1 {print $1}' "$TARGET_STORAGE_HOOK_SHA256_FILE")"
  [[ "$target_storage_hook_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "Target storage-hook SHA-256 evidence is malformed."
  [[ "$target_storage_hook_sha" == "$(sha256sum "$TARGET_STORAGE_HOOK_FILE" | awk '{print $1}')" ]] ||
    die "Target storage-hook SHA-256 evidence no longer matches the verified hook."

  jq -n \
    --arg profile "$PROFILE" \
    --arg target_image "$TARGET_IMAGE_REF" \
    --arg manifest_digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg hook_path "/usr/share/init.d/090-abroot-unlock-var.sh" \
    --arg hook_sha256 "$target_storage_hook_sha" \
    --arg verified_at "$(date -u --iso-8601=seconds)" \
    '{schema:1, profile:$profile, target_image:$target_image,
      manifest_digest:$manifest_digest, hook_path:$hook_path,
      hook_sha256:$hook_sha256, verified_at:$verified_at,
      verification_basis:[
        "exported OCI layout imported under an isolated verification tag",
        "hook exported from and content-validated in that imported layout",
        "hook digest bound to the exported OCI manifest digest",
        "final ISO must embed the identical OCI manifest digest"
      ]}' > "$TARGET_STORAGE_HOOK_EVIDENCE_JSON"

  ok "Exported verified target OCI layout: $TARGET_IMAGE_MANIFEST_DIGEST"
  ok "Installer image source: $INSTALLER_DEFAULT_IMAGE_REF"
}

# --------------------------- live ISO build ------------------------------

hash_directory_tree() {
  local root="$1"
  [[ -d "$root" ]] || die "Cannot hash absent directory tree: $root"
  (
    cd "$root"
    find . -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum
  )
}

read_terraform_value() {
  local file="$1" key="$2"
  sed -n -E "s/^[[:space:]]*${key}=[\"']?([^\"']+)[\"']?[[:space:]]*$/\\1/p" "$file" |
    sed -n '1p'
}

prepare_arm64_package_list_projection() {
  local conf="$1"
  local source_suffix source_dir derived_dir
  local protected_packages
  local expected_manifest="$TMP_ROOT/arm64-package-list-projection.expected.tsv"

  source_suffix="$(read_terraform_value "$conf" PACKAGE_LISTS_SUFFIX)"
  [[ -n "$source_suffix" ]] || die "Unable to read PACKAGE_LISTS_SUFFIX from $conf"

  source_dir="$LIVE_BUILD_DIR/etc/config/package-lists.$source_suffix"
  derived_dir="$LIVE_BUILD_DIR/etc/config/package-lists.$LIVE_ARM64_PACKAGE_LIST_SUFFIX"

  [[ -d "$source_dir" ]] || \
    die "Configured upstream live package-list directory is absent: $source_dir"
  [[ "$source_dir" != "$derived_dir" ]] || \
    die "Derived ARM64 package-list suffix must differ from upstream suffix: $source_suffix"

  LIVE_PACKAGE_LIST_SOURCE_SUFFIX="$source_suffix"
  LIVE_PACKAGE_LIST_SOURCE_DIR="$source_dir"
  LIVE_PACKAGE_LIST_DERIVED_DIR="$derived_dir"
  LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST="$TMP_ROOT/arm64-package-list-exclusions.tsv"
  LIVE_PACKAGE_LIST_PACKAGE_INVENTORY="$TMP_ROOT/arm64-package-list-packages.tsv"

  hash_directory_tree "$source_dir" \
    > "$TMP_ROOT/upstream-package-lists.original.before.sha256"

  protected_packages="gnome-shell,gnome-session,mutter,gdm3,xwayland,network-manager,vanilla-installer,efibootmgr,shim-signed"

  python3 - \
    "$source_dir" \
    "$derived_dir" \
    "$LIVE_ARM64_EXCLUDE_PACKAGES" \
    "$protected_packages" \
    "$LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST" \
    "$expected_manifest" \
    "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY" <<'PY_ARM64_PACKAGE_PROJECTION'
from __future__ import annotations

import os
import re
import shutil
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
derived = Path(sys.argv[2])
exclusion_text = sys.argv[3]
protected_text = sys.argv[4]
manifest = Path(sys.argv[5])
expected_manifest = Path(sys.argv[6])
package_inventory = Path(sys.argv[7])

package_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+.-]*$")
single_package_line_re = re.compile(
    r"^(?P<indent>\s*)(?P<pkg>[A-Za-z0-9][A-Za-z0-9+.-]*)(?P<tail>\s*(?:#.*)?)$"
)

exclusions = {
    item
    for item in re.split(r"[\s,]+", exclusion_text.strip())
    if item
}
protected = {
    item
    for item in re.split(r"[\s,]+", protected_text.strip())
    if item
}

if not exclusions:
    raise SystemExit("ARM64 package exclusion set is empty; refusing an undefined projection")

invalid = sorted(item for item in exclusions if not package_name_re.fullmatch(item))
if invalid:
    raise SystemExit(f"Invalid package name(s) in exclusion set: {', '.join(invalid)}")

intersection = sorted(exclusions & protected)
if intersection:
    raise SystemExit(
        "Protected graphical/installer package requested for exclusion: "
        + ", ".join(intersection)
    )

if derived.exists():
    shutil.rmtree(derived)
shutil.copytree(source, derived, symlinks=True)

removed: list[tuple[str, int, str, str]] = []
suspicious_unapproved: list[tuple[str, int, str]] = []
source_counts: dict[str, int] = {}
derived_counts: dict[str, int] = {}
derived_locations: dict[str, list[str]] = {}

def suspicious_x86_package(pkg: str) -> bool:
    return bool(
        re.search(r"(^|[-.])(amd64|i386)([-.]|$)", pkg)
        or pkg in {"intel-microcode", "iucode-tool"}
        or pkg.startswith("virtualbox-guest-")
    )

def exclusion_reason(pkg: str) -> str:
    if pkg.startswith("grub-efi-amd64"):
        return "AMD64-only GRUB EFI package; live-build must select the ARM64 bootloader"
    if pkg == "shim-helpers-amd64-signed":
        return "AMD64-only signed shim helper package"
    if pkg in {"intel-microcode", "amd64-microcode"}:
        return "x86 CPU microcode package unavailable for ARM64"
    if pkg == "iucode-tool":
        return "Intel/x86 microcode helper unavailable for ARM64"
    if pkg.startswith("virtualbox-guest-"):
        return "VirtualBox guest package unavailable in the configured ARM64 snapshot"
    return "explicitly approved ARM64 snapshot-incompatible package"

def count_token(counts: dict[str, int], pkg: str) -> None:
    counts[pkg] = counts.get(pkg, 0) + 1

for source_file in sorted(p for p in source.rglob("*") if p.is_file()):
    rel = source_file.relative_to(source)
    derived_file = derived / rel

    try:
        raw = source_file.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"Non-UTF-8 package-list file cannot be projected: {source_file}") from exc

    out_lines: list[str] = []
    for lineno, line_with_end in enumerate(raw.splitlines(keepends=True), start=1):
        line = line_with_end.rstrip("\r\n")
        newline = line_with_end[len(line):]
        match = single_package_line_re.fullmatch(line)
        if not match:
            out_lines.append(line_with_end)
            continue

        pkg = match.group("pkg")
        count_token(source_counts, pkg)

        if suspicious_x86_package(pkg) and pkg not in exclusions:
            suspicious_unapproved.append((str(rel), lineno, pkg))

        if pkg in exclusions:
            removed.append(
                (
                    str(rel),
                    lineno,
                    pkg,
                    exclusion_reason(pkg),
                )
            )
            continue

        count_token(derived_counts, pkg)
        derived_locations.setdefault(pkg, []).append(f"{rel}:{lineno}")
        out_lines.append(line + newline)

    derived_file.write_text("".join(out_lines), encoding="utf-8")
    shutil.copymode(source_file, derived_file, follow_symlinks=False)

if suspicious_unapproved:
    details = "\n".join(
        f"  {rel}:{lineno}: {pkg}"
        for rel, lineno, pkg in suspicious_unapproved
    )
    raise SystemExit(
        "Suspicious x86-specific package line is not in the explicit exclusion set:\n"
        + details
    )

# Verify that no protected graphical/installer token disappeared.
for pkg in sorted(protected):
    before = source_counts.get(pkg, 0)
    after = derived_counts.get(pkg, 0)
    if before != after:
        raise SystemExit(
            f"Protected package token count changed for {pkg}: before={before} after={after}"
        )

# Verify that every removed token is explicitly approved, and every approved
# token still present in the source has been removed from the projection.
removed_names = {row[2] for row in removed}
unapproved_removed = sorted(removed_names - exclusions)
if unapproved_removed:
    raise SystemExit("Unapproved package removal: " + ", ".join(unapproved_removed))

still_present = sorted(
    pkg for pkg in exclusions if derived_counts.get(pkg, 0) > 0
)
if still_present:
    raise SystemExit(
        "Excluded package remains in derived ARM64 package lists: "
        + ", ".join(still_present)
    )

manifest.parent.mkdir(parents=True, exist_ok=True)
with manifest.open("w", encoding="utf-8") as handle:
    handle.write("source_file\tline\tpackage\treason\n")
    for rel, lineno, pkg, reason in removed:
        handle.write(f"{rel}\t{lineno}\t{pkg}\t{reason}\n")

with expected_manifest.open("w", encoding="utf-8") as handle:
    handle.write("package\tpresent_in_upstream\tremoved_occurrences\n")
    for pkg in sorted(exclusions):
        handle.write(
            f"{pkg}\t{source_counts.get(pkg, 0)}\t"
            f"{sum(1 for row in removed if row[2] == pkg)}\n"
        )

with package_inventory.open("w", encoding="utf-8") as handle:
    handle.write("package\toccurrences\tsource_locations\n")
    for pkg in sorted(derived_counts):
        handle.write(
            f"{pkg}\t{derived_counts[pkg]}\t"
            f"{','.join(derived_locations.get(pkg, []))}\n"
        )

print(f"Created ARM64 package-list projection: {derived}")
print(f"Approved exclusions configured: {len(exclusions)}")
print(f"Package-list lines excluded: {len(removed)}")
for pkg in sorted(exclusions):
    print(
        f"  {pkg}: upstream={source_counts.get(pkg, 0)} "
        f"excluded={sum(1 for row in removed if row[2] == pkg)}"
    )
PY_ARM64_PACKAGE_PROJECTION

  [[ -d "$derived_dir" ]] || die "ARM64 package-list projection was not created."
  [[ -s "$LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST" ]] || \
    die "ARM64 package-list exclusion manifest was not created."
  [[ -s "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY" ]] || \
    die "ARM64 derived package inventory was not created."

  hash_directory_tree "$derived_dir" \
    > "$TMP_ROOT/arm64-package-lists.derived.before.sha256"

  # Select the derived package-list suffix. This changes only the active list
  # directory; it does not modify the canonical upstream list files.
  sed -i -E \
    "s/^PACKAGE_LISTS_SUFFIX=.*/PACKAGE_LISTS_SUFFIX=\"$LIVE_ARM64_PACKAGE_LIST_SUFFIX\"/" \
    "$conf"
  grep -Fqx "PACKAGE_LISTS_SUFFIX=\"$LIVE_ARM64_PACKAGE_LIST_SUFFIX\"" "$conf" || \
    die "Unable to select derived ARM64 package-list suffix."

  local excluded_count
  excluded_count="$(awk 'NR > 1 { count++ } END { print count + 0 }' \
    "$LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST")"

  ok "Upstream package-list tree retained: $source_dir"
  ok "Derived ARM64 package-list tree: $derived_dir"
  ok "Approved architecture exclusions applied: $excluded_count line(s)"
  info "Architecture exclusion manifest: $LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST"
  sed -n '1,120p' "$LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST"
}

preflight_arm64_package_candidates() {
  local conf="$1"
  local mirror suite preflight_dir runner packages_file rc
  mirror="$(read_terraform_value "$conf" MIRROR_URL)"
  suite="$(read_terraform_value "$conf" BASECODENAME)"

  [[ -n "$mirror" ]] || die "Unable to read MIRROR_URL for ARM64 package preflight."
  [[ -n "$suite" ]] || die "Unable to read BASECODENAME for ARM64 package preflight."
  [[ -s "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY" ]] || \
    die "Derived ARM64 package inventory is absent before candidate preflight."

  preflight_dir="$TMP_ROOT/arm64-package-candidate-preflight"
  runner="$preflight_dir/run-preflight.sh"
  packages_file="$preflight_dir/packages.txt"
  LIVE_PACKAGE_CANDIDATE_REPORT="$preflight_dir/package-candidates.tsv"

  rm -rf "$preflight_dir"
  mkdir -p "$preflight_dir"
  awk -F '\t' 'NR > 1 && $1 != "" { print $1 }' \
    "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY" |
    LC_ALL=C sort -u > "$packages_file"
  [[ -s "$packages_file" ]] || die "No package names were extracted for ARM64 candidate preflight."

  cat > "$runner" <<'ARM64_PACKAGE_PREFLIGHT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${MIRROR_URL:?}"
: "${BASECODENAME:?}"

arch="$(dpkg --print-architecture)"
[[ "$arch" == "arm64" ]] || {
  echo "Candidate preflight container architecture is $arch, expected arm64" >&2
  exit 40
}

rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
cat > /etc/apt/sources.list <<EOF_APT_SOURCE
deb [trusted=yes] $MIRROR_URL $BASECODENAME main contrib non-free non-free-firmware
EOF_APT_SOURCE

apt-get update \
  -o Acquire::Check-Valid-Until=false \
  -o Acquire::Retries=5 \
  -o Acquire::http::Timeout=100

report=/preflight/package-candidates.tsv
unavailable=/preflight/unavailable-packages.tsv
printf 'package\tcandidate\tkind\n' > "$report"
printf 'package\treason\n' > "$unavailable"

while IFS= read -r package; do
  [[ -n "$package" ]] || continue

  candidate="$(apt-cache madison "$package" | awk 'NR == 1 { print $3 }')"
  if [[ -n "$candidate" ]]; then
    printf '%s\t%s\trepository\n' "$package" "$candidate" >> "$report"
    continue
  fi

  if apt-cache showpkg "$package" |
       awk '
         /^Reverse Provides:/ { in_reverse=1; next }
         in_reverse && NF > 0 { found=1 }
         END { exit(found ? 0 : 1) }
       '; then
    printf '%s\tvirtual\tvirtual-package\n' "$package" >> "$report"
    continue
  fi

  printf '%s\tno repository candidate or virtual provider\n' "$package" >> "$unavailable"
done < /preflight/packages.txt

if [[ "$(wc -l < "$unavailable")" -gt 1 ]]; then
  echo "Unavailable direct ARM64 package names:" >&2
  tail -n +2 "$unavailable" >&2
  exit 41
fi

touch /preflight/candidate-preflight.ok
echo "All direct package-list names have an ARM64 repository candidate or virtual provider."
ARM64_PACKAGE_PREFLIGHT_EOF
  chmod 0755 "$runner"

  CURRENT_LOG="$LOG_DIR/${SESSION_ID}-arm64-package-candidate-preflight.log"
  info "Log: $CURRENT_LOG"
  info "Preflighting every derived package-list name against: $mirror $suite (arm64)"

  # Place the pipeline in an if-condition. Bash suppresses the ERR trap for
  # conditional commands, allowing us to capture the container's real status,
  # print the complete unavailable-package report, and then fail deliberately.
  if "$LIVE_ISO_RUNTIME" run --rm --network host \
       -e "MIRROR_URL=$mirror" \
       -e "BASECODENAME=$suite" \
       -v "$preflight_dir:/preflight" \
       "$LIVE_ISO_CONTAINER_IMAGE" \
       /bin/bash /preflight/run-preflight.sh \
       2>&1 | tee "$CURRENT_LOG"; then
    rc=0
  else
    rc=${PIPESTATUS[0]}
  fi

  if (( rc != 0 )); then
    if [[ -s "$preflight_dir/unavailable-packages.tsv" ]]; then
      fail "Complete direct-package candidate failure report:"
      while IFS=$'\t' read -r package reason; do
        [[ "$package" == "package" || -z "$package" ]] && continue
        local locations
        locations="$(
          awk -F '\t' -v pkg="$package" '
            NR > 1 && $1 == pkg { print $3; exit }
          ' "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY"
        )"
        fail "  $package — $reason — ${locations:-source location unknown}"
      done < "$preflight_dir/unavailable-packages.tsv"
    fi
    die "ARM64 package candidate preflight failed before live-build."
  fi

  [[ -f "$preflight_dir/candidate-preflight.ok" ]] || \
    die "ARM64 package candidate preflight returned success without its completion marker."
  [[ -s "$LIVE_PACKAGE_CANDIDATE_REPORT" ]] || \
    die "ARM64 package candidate report is missing."

  ok "Every derived direct package name has an ARM64 candidate or virtual provider."
  info "Candidate report: $LIVE_PACKAGE_CANDIDATE_REPORT"
}

verify_arm64_package_list_projection_after_build() {
  [[ -d "$LIVE_PACKAGE_LIST_SOURCE_DIR" ]] || \
    die "Original upstream package-list tree disappeared during build."
  [[ -d "$LIVE_PACKAGE_LIST_DERIVED_DIR" ]] || \
    die "Derived ARM64 package-list tree disappeared during build."

  hash_directory_tree "$LIVE_PACKAGE_LIST_SOURCE_DIR" \
    > "$TMP_ROOT/upstream-package-lists.original.after.sha256"
  hash_directory_tree "$LIVE_PACKAGE_LIST_DERIVED_DIR" \
    > "$TMP_ROOT/arm64-package-lists.derived.after.sha256"

  cmp -s \
    "$TMP_ROOT/upstream-package-lists.original.before.sha256" \
    "$TMP_ROOT/upstream-package-lists.original.after.sha256" || \
    die "Canonical upstream live package-list source files changed during build."

  cmp -s \
    "$TMP_ROOT/arm64-package-lists.derived.before.sha256" \
    "$TMP_ROOT/arm64-package-lists.derived.after.sha256" || \
    die "Derived ARM64 package-list files changed during build."

  local active_link="$LIVE_BUILD_DIR/tmp/arm64/config/package-lists"
  [[ -L "$active_link" ]] || \
    die "Live-build did not create the expected active package-list symlink: $active_link"

  local active_target
  active_target="$(readlink "$active_link")"
  [[ "$active_target" == "package-lists.$LIVE_ARM64_PACKAGE_LIST_SUFFIX" ]] || \
    die "Live-build selected unexpected package-list target: $active_target"

  ok "Canonical upstream and derived ARM64 package-list trees remained byte-identical during live-build."
  ok "Active live-build package-list target: $active_target"
}

normalize_live_arm64_package_policy() {
  case "${LIVE_ARM64_PACKAGE_POLICY,,}" in
    upstream|upstream-native|native) LIVE_ARM64_PACKAGE_POLICY="upstream-native" ;;
    legacy|legacy-projection|projection) LIVE_ARM64_PACKAGE_POLICY="legacy-projection" ;;
    *) die "Unsupported live ARM64 package policy: $LIVE_ARM64_PACKAGE_POLICY" ;;
  esac
}

validate_upstream_reunion_arm64_live_source() {
  local conf="$1" build="$2"
  local codename version source_suffix source_dir desktop_list pool_list
  codename="$(read_terraform_value "$conf" CODENAME)"
  version="$(read_terraform_value "$conf" VERSION)"
  source_suffix="$(read_terraform_value "$conf" PACKAGE_LISTS_SUFFIX)"

  [[ "$codename" == "reunion" ]] || \
    die "upstream-native policy requires current Reunion live source; CODENAME=$codename"
  [[ "$version" == "3" ]] || \
    die "upstream-native policy requires Vanilla OS 3 live source; VERSION=$version"
  [[ -n "$source_suffix" ]] || die "Unable to read upstream package-list suffix."

  source_dir="$LIVE_BUILD_DIR/etc/config/package-lists.$source_suffix"
  desktop_list="$source_dir/desktop.list.chroot_live"
  pool_list="$source_dir/pool.list.binary"
  [[ -f "$desktop_list" && -f "$pool_list" ]] || \
    die "Current Reunion package-list files are incomplete beneath $source_dir"

  # Prove that generic architecture ownership has actually moved upstream
  # before disabling the r4.1 projection. These predicates intentionally check
  # both the ARM64 selections and the guarded AMD64 alternatives.
  grep -Fq '#if ARCHITECTURES arm64' "$desktop_list" || \
    die "Upstream desktop list lacks ARM64 architecture conditionals."
  grep -Fq 'shim-helpers-arm64-signed' "$desktop_list" || \
    die "Upstream desktop list lacks ARM64 shim helpers."
  grep -Fq '#if ARCHITECTURES amd64' "$desktop_list" || \
    die "Upstream desktop list lacks guarded AMD64 conditionals."
  grep -Fq 'virtualbox-guest-utils' "$desktop_list" || \
    die "Expected guarded VirtualBox package is absent; source taxonomy changed and requires review."

  grep -Fq '#if ARCHITECTURES arm64' "$pool_list" || \
    die "Upstream binary pool lacks ARM64 architecture conditionals."
  for package in grub-efi-arm64 grub-efi-arm64-bin grub-efi-arm64-signed shim-helpers-arm64-signed; do
    grep -Fxq "$package" "$pool_list" || \
      die "Upstream ARM64 binary pool lacks expected package: $package"
  done
  grep -Fq '#if ARCHITECTURES amd64' "$pool_list" || \
    die "Upstream binary pool lacks guarded AMD64 conditionals."
  grep -Fxq 'grub-efi-amd64' "$pool_list" || \
    die "Expected guarded AMD64 GRUB package is absent; source taxonomy changed and requires review."

  # Current build.sh is architecture-aware. Refuse to patch it in canonical
  # mode; if upstream changes this contract, stop for review instead of
  # silently reintroducing an old workaround.
  grep -Fq 'live-image-$BUILD_ARCH.hybrid.iso' "$build" || \
    die "Current live-iso build.sh is not architecture-aware at the output path."
  grep -Fq 'build "$ARCH"' "$build" || \
    die "Current live-iso build.sh no longer exposes the expected ARCH selection path."

  LIVE_PACKAGE_LIST_SOURCE_SUFFIX="$source_suffix"
  LIVE_PACKAGE_LIST_SOURCE_DIR="$source_dir"
  LIVE_PACKAGE_LIST_DERIVED_DIR=""
  LIVE_PACKAGE_LIST_EXCLUSION_MANIFEST=""
  LIVE_PACKAGE_LIST_PACKAGE_INVENTORY=""
  LIVE_PACKAGE_CANDIDATE_REPORT=""

  hash_directory_tree "$source_dir" > "$TMP_ROOT/upstream-package-lists.original.before.sha256"
  {
    printf 'Vanilla OS 3 Reunion architecture-name audit\n'
    printf 'Target image: %s\n' "$CUSTOM_IMAGE_BASE"
    printf 'Live builder: %s\n' "$LIVE_ISO_CONTAINER_IMAGE"
    printf 'ARM64 package tokens verified in upstream package lists:\n'
    printf '  grub-efi-arm64\n  grub-efi-arm64-bin\n  grub-efi-arm64-signed\n  shim-helpers-arm64-signed\n'
    printf 'AMD64 alternatives verified as architecture-guarded, not projected into canonical ARM64 policy.\n'
    printf 'Kernel intake remains Debian-control/payload-semantic and independent of input filename.\n'
    printf 'Firmware package intake remains Debian-control metadata based and independent of input filename.\n'
  } > "$REUNION_ARCHITECTURE_NAME_AUDIT"
  ok "Current Reunion native ARM64 live-source contract validated."
  info "Upstream package-list suffix: $source_suffix"
}

verify_upstream_reunion_package_lists_after_build() {
  [[ -d "$LIVE_PACKAGE_LIST_SOURCE_DIR" ]] || \
    die "Canonical upstream package-list tree disappeared during live-build."
  hash_directory_tree "$LIVE_PACKAGE_LIST_SOURCE_DIR" \
    > "$TMP_ROOT/upstream-package-lists.original.after.sha256"
  cmp -s \
    "$TMP_ROOT/upstream-package-lists.original.before.sha256" \
    "$TMP_ROOT/upstream-package-lists.original.after.sha256" || \
    die "Canonical upstream live package-list source files changed during build."

  local active_link="$LIVE_BUILD_DIR/tmp/arm64/config/package-lists"
  [[ -L "$active_link" ]] || \
    die "Live-build did not create the expected active package-list symlink: $active_link"
  local active_target
  active_target="$(readlink "$active_link")"
  [[ "$active_target" == "package-lists.$LIVE_PACKAGE_LIST_SOURCE_SUFFIX" ]] || \
    die "Live-build selected unexpected package-list target: $active_target"

  ok "Canonical upstream architecture-aware package lists remained byte-identical during live-build."
  ok "Active live-build package-list target: $active_target"
}

prepare_arm64_live_worktree() {
  rm -rf "$LIVE_BUILD_DIR"
  git -C "$LIVE_ISO_SOURCE" worktree add --detach "$LIVE_BUILD_DIR" "$LIVE_SOURCE_COMMIT"

  local conf="$LIVE_BUILD_DIR/etc/terraform.conf"
  local build="$LIVE_BUILD_DIR/build.sh"
  [[ -f "$conf" && -f "$build" ]] || die "Official live-iso build inputs are missing."

  sed -i -E 's/^ARCH=.*/ARCH="arm64"/' "$conf"
  grep -q '^ARCH="arm64"$' "$conf" || die "Unable to select ARM64 in terraform.conf."

  normalize_live_arm64_package_policy
  case "$LIVE_ARM64_PACKAGE_POLICY" in
    upstream-native)
      validate_upstream_reunion_arm64_live_source "$conf" "$build"
      ;;
    legacy-projection)
      warn "Using legacy r4.1 ARM64 package projection by explicit policy."
      prepare_arm64_package_list_projection "$conf"
      preflight_arm64_package_candidates "$conf"

      # Historical compatibility only. Current Reunion build.sh is already
      # architecture-aware and therefore does not take this branch.
      if grep -Fq 'tmp/amd64/live-image-amd64.hybrid.iso' "$build"; then
        sed -i \
          's#tmp/amd64/live-image-amd64\.hybrid\.iso#tmp/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso#' \
          "$build"
      fi
      ;;
  esac

  local changed unexpected untracked unexpected_untracked allowed_tracked
  changed="$(git -C "$LIVE_BUILD_DIR" diff --name-only)"
  if [[ "$LIVE_ARM64_PACKAGE_POLICY" == "upstream-native" ]]; then
    allowed_tracked='^etc/terraform\.conf$'
  else
    allowed_tracked='^(build\.sh|etc/terraform\.conf)$'
  fi
  unexpected="$(printf '%s\n' "$changed" | grep -Ev "$allowed_tracked" || true)"
  [[ -z "$unexpected" ]] || \
    die "Refusing tracked live-iso source modifications outside the selected policy boundary: $unexpected"

  untracked="$(git -C "$LIVE_BUILD_DIR" ls-files --others --exclude-standard)"
  if [[ "$LIVE_ARM64_PACKAGE_POLICY" == "upstream-native" ]]; then
    [[ -z "$untracked" ]] || \
      die "Canonical upstream-native live build unexpectedly created pre-build untracked files: $untracked"
  else
    unexpected_untracked="$(printf '%s\n' "$untracked" | grep -Ev "^etc/config/package-lists\\.${LIVE_ARM64_PACKAGE_LIST_SUFFIX}/" || true)"
    [[ -z "$unexpected_untracked" ]] || \
      die "Refusing unexpected untracked live-iso build files: $unexpected_untracked"
  fi

  write_reunion_convergence_manifest
  ok "Upstream-derived ARM64 live-iso worktree prepared at commit $LIVE_SOURCE_COMMIT using policy=$LIVE_ARM64_PACKAGE_POLICY."
}

build_arm64_live_iso() {
  pushd "$LIVE_BUILD_DIR" >/dev/null
  CURRENT_LOG="$LOG_DIR/${SESSION_ID}-build-arm64-live-iso.log"
  info "Log: $CURRENT_LOG"

  "$LIVE_ISO_RUNTIME" run --rm --privileged --network host -i \
    -v /proc:/proc \
    -v "$LIVE_BUILD_DIR:/working_dir" \
    -w /working_dir \
    "$LIVE_ISO_CONTAINER_IMAGE" \
    /bin/bash -c 'apt-get update && apt-get install -y debootstrap && /bin/bash -s etc/terraform.conf' < build.sh \
    2>&1 | tee "$CURRENT_LOG"
  popd >/dev/null

  UPSTREAM_ISO="$(
    find "$LIVE_BUILD_DIR/builds/arm64" "$LIVE_BUILD_DIR/builds" \
      -type f -name '*.iso' -print 2>/dev/null |
      sort -u |
      tail -n1 || true
  )"
  [[ -n "$UPSTREAM_ISO" && -s "$UPSTREAM_ISO" ]] || \
    die "The upstream-derived ARM64 graphical ISO was not produced."

  case "$LIVE_ARM64_PACKAGE_POLICY" in
    upstream-native) verify_upstream_reunion_package_lists_after_build ;;
    legacy-projection) verify_arm64_package_list_projection_after_build ;;
    *) die "Internal live package policy drift after build: $LIVE_ARM64_PACKAGE_POLICY" ;;
  esac
  verify_arm64_graphical_iso
}

extract_iso_file() {
  local iso="$1" iso_path="$2" destination="$3"
  rm -f "$destination"
  xorriso -osirrox on -indev "$iso" -extract "$iso_path" "$destination" >/dev/null 2>&1
}

extract_required_squashfs_file() {
  # Extract one file that is required to exist in the live installer squashfs.
  # Do not use this helper for target-OCI content: the live squashfs and the
  # installed target image are separate artifacts with different responsibilities.
  local squash="$1" member="${2#/}" destination="$3" description="${4:-$2}"
  local stderr_file="${destination}.unsquashfs.stderr" detail=""

  rm -f "$destination" "$stderr_file"
  if ! unsquashfs -cat "$squash" "$member" > "$destination" 2> "$stderr_file"; then
    detail="$(tr '\n' ' ' < "$stderr_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    rm -f "$destination"
    die "Unable to extract required live-squashfs ${description} at /${member}${detail:+: $detail}"
  fi

  [[ -s "$destination" ]] ||
    die "Required live-squashfs ${description} is empty at /${member}"
  rm -f "$stderr_file"
}

validate_live_gdm_timed_login_settings() {
  case "$LIVE_GDM_TIMED_LOGIN_DELAY" in
    ''|*[!0-9]*)
      die "LIVE_GDM_TIMED_LOGIN_DELAY must be an integer from 1 through 60; got '$LIVE_GDM_TIMED_LOGIN_DELAY'"
      ;;
  esac
  (( 10#$LIVE_GDM_TIMED_LOGIN_DELAY >= 1 && 10#$LIVE_GDM_TIMED_LOGIN_DELAY <= 60 )) || \
    die "LIVE_GDM_TIMED_LOGIN_DELAY must be from 1 through 60 seconds; got '$LIVE_GDM_TIMED_LOGIN_DELAY'"
  [[ "$LIVE_GDM_TIMED_LOGIN_USER" == "vanilla" ]] || \
    die "Internal guard: live timed-login user unexpectedly changed from vanilla"
}

configure_live_gdm_timed_login() {
  # Live-squashfs only. Never apply this disposable live-user session policy to
  # the installed target OCI.
  local root="$1"
  local live_config="$root/$LIVE_GDM_LIVE_CONFIG_REL"
  local gdm_config="$root/$LIVE_GDM_DAEMON_CONFIG_REL"

  validate_live_gdm_timed_login_settings
  [[ -d "$root" ]] || die "Live squashfs root does not exist: $root"
  [[ -f "$gdm_config" && ! -L "$gdm_config" ]] || \
    die "Live filesystem lacks a regular Debian GDM configuration file: /$LIVE_GDM_DAEMON_CONFIG_REL"

  mkdir -p "$(dirname "$live_config")"
  cat > "$live_config" <<'LIVE_CONFIG_EOF'
# Managed by VanillaOS-SnapdragonX v8.5-r5.1.
# Keep Debian live-config responsible for the live user, but prevent its gdm3
# component from racing the explicit GDM timed-login policy below.
LIVE_CONFIG_NOCOMPONENTS="gdm3"
LIVE_CONFIG_EOF
  chmod 0644 "$live_config"

  python3 - "$gdm_config" "$LIVE_GDM_TIMED_LOGIN_USER" "$LIVE_GDM_TIMED_LOGIN_DELAY" <<'PY_GDM_TIMED_LOGIN'
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import sys
import tempfile

path = Path(sys.argv[1])
user = sys.argv[2]
delay = int(sys.argv[3], 10)
if delay < 1 or delay > 60:
    raise SystemExit(f"invalid timed-login delay: {delay}")

raw = path.read_text(encoding="utf-8")
lines = raw.splitlines(keepends=True)
section_re = re.compile(r"^\s*\[([^]]+)\]\s*(?:[#;].*)?$")
managed_keys = {
    "automaticloginenable", "automaticlogin", "timedloginenable",
    "timedlogin", "timedlogindelay",
}
sections: list[tuple[int, str]] = []
for idx, line in enumerate(lines):
    match = section_re.match(line.rstrip("\r\n"))
    if match:
        sections.append((idx, match.group(1).strip()))
daemon_sections = [idx for idx, name in sections if name.casefold() == "daemon"]
if len(daemon_sections) > 1:
    raise SystemExit("refusing GDM update: multiple [daemon] sections found")

newline = "\r\n" if "\r\n" in raw else "\n"
managed_block = [
    f"AutomaticLoginEnable=false{newline}",
    f"TimedLoginEnable=true{newline}",
    f"TimedLogin={user}{newline}",
    f"TimedLoginDelay={delay}{newline}",
]
if not daemon_sections:
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] = lines[-1] + newline
    if lines and lines[-1].strip():
        lines.append(newline)
    lines.extend([f"[daemon]{newline}", *managed_block])
else:
    start = daemon_sections[0]
    end = len(lines)
    for idx, _name in sections:
        if idx > start:
            end = idx
            break
    kept: list[str] = []
    assignment_re = re.compile(r"^\s*([A-Za-z][A-Za-z0-9]*)\s*=")
    for line in lines[start + 1 : end]:
        match = assignment_re.match(line)
        if match and match.group(1).casefold() in managed_keys:
            continue
        kept.append(line)
    while kept and kept[-1].strip() == "":
        kept.pop()
    if kept:
        kept.append(newline)
    lines = lines[: start + 1] + kept + managed_block + lines[end:]

result = "".join(lines)
st = path.stat()
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.v8.5-r5.1-", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
        handle.write(result)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, stat.S_IMODE(st.st_mode))
    try:
        os.chown(tmp_name, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp_name, path)
finally:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
PY_GDM_TIMED_LOGIN

  grep -Fqx 'LIVE_CONFIG_NOCOMPONENTS="gdm3"' "$live_config" || \
    die "Live-config GDM exclusion was not written correctly"
  grep -Fqx 'AutomaticLoginEnable=false' "$gdm_config" || \
    die "GDM immediate autologin was not explicitly disabled"
  grep -Fqx 'TimedLoginEnable=true' "$gdm_config" || \
    die "GDM timed login was not enabled"
  grep -Fqx "TimedLogin=$LIVE_GDM_TIMED_LOGIN_USER" "$gdm_config" || \
    die "GDM timed-login user does not match $LIVE_GDM_TIMED_LOGIN_USER"
  grep -Fqx "TimedLoginDelay=$LIVE_GDM_TIMED_LOGIN_DELAY" "$gdm_config" || \
    die "GDM timed-login delay does not match $LIVE_GDM_TIMED_LOGIN_DELAY"
  ok "Configured live-only GDM timed login for $LIVE_GDM_TIMED_LOGIN_USER after ${LIVE_GDM_TIMED_LOGIN_DELAY}s."
}

verify_live_gdm_timed_login_files() {
  local live_config="$1" gdm_config="$2"
  grep -Fqx 'LIVE_CONFIG_NOCOMPONENTS="gdm3"' "$live_config" || \
    die "Final live-config policy does not suppress the gdm3 component"

  python3 - "$gdm_config" "$LIVE_GDM_TIMED_LOGIN_USER" "$LIVE_GDM_TIMED_LOGIN_DELAY" <<'PY_VERIFY_GDM_TIMED_LOGIN'
from __future__ import annotations
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
expected_user = sys.argv[2]
expected_delay = sys.argv[3]
text = path.read_text(encoding="utf-8")
section_re = re.compile(r"^\s*\[([^]]+)\]\s*(?:[#;].*)?$")
assignment_re = re.compile(r"^\s*([A-Za-z][A-Za-z0-9]*)\s*=\s*(.*?)\s*$")
current = None
daemon_count = 0
values: dict[str, list[str]] = {}
for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line or line.startswith(("#", ";")):
        continue
    section = section_re.match(raw_line)
    if section:
        current = section.group(1).strip().casefold()
        if current == "daemon":
            daemon_count += 1
        continue
    if current != "daemon":
        continue
    assignment = assignment_re.match(raw_line)
    if assignment:
        key = assignment.group(1).casefold()
        values.setdefault(key, []).append(assignment.group(2).strip())
if daemon_count != 1:
    raise SystemExit(f"expected exactly one [daemon] section, found {daemon_count}")
expected = {
    "automaticloginenable": "false",
    "timedloginenable": "true",
    "timedlogin": expected_user,
    "timedlogindelay": expected_delay,
}
for key, wanted in expected.items():
    actual = values.get(key, [])
    if actual != [wanted]:
        raise SystemExit(f"unexpected {key}: expected {[wanted]!r}, got {actual!r}")
if values.get("automaticlogin"):
    raise SystemExit(f"stale AutomaticLogin assignment remains: {values['automaticlogin']!r}")
PY_VERIFY_GDM_TIMED_LOGIN
}

verify_final_live_gdm_timed_login() {
  local verify_dir="$TMP_ROOT/final-gdm-timed-login-verify"
  local final_squash="$verify_dir/filesystem.squashfs"
  local live_config="$verify_dir/vanillaos-snapdragonx.conf"
  local gdm_config="$verify_dir/daemon.conf"
  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"
  extract_iso_file "$FINAL_ISO" /live/filesystem.squashfs "$final_squash"
  [[ -s "$final_squash" ]] || die "Final ISO live filesystem.squashfs is missing for GDM verification"
  extract_required_squashfs_file "$final_squash" "$LIVE_GDM_LIVE_CONFIG_REL" "$live_config" "live-config GDM component exclusion"
  extract_required_squashfs_file "$final_squash" "$LIVE_GDM_DAEMON_CONFIG_REL" "$gdm_config" "GDM timed-login policy"
  verify_live_gdm_timed_login_files "$live_config" "$gdm_config"
  ok "Final ISO verified: live-config gdm3 autologin is suppressed and GDM timed login is ${LIVE_GDM_TIMED_LOGIN_DELAY}s."
}

verify_arm64_graphical_iso() {
  UPSTREAM_MANIFEST="$TMP_ROOT/upstream-filesystem.packages"
  UPSTREAM_REMOVE_MANIFEST="$TMP_ROOT/upstream-filesystem.packages-remove"
  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.packages "$UPSTREAM_MANIFEST"
  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.packages-remove "$UPSTREAM_REMOVE_MANIFEST"

  local required=(vanilla-installer gnome-shell gnome-session mutter gdm3 xwayland network-manager)
  local pkg
  for pkg in "${required[@]}"; do
    grep -Eq "^${pkg}([[:space:]]|$)" "$UPSTREAM_MANIFEST" || \
      die "ARM64 baseline ISO lacks required graphical package: $pkg"
  done

  local count
  count="$(wc -l < "$UPSTREAM_MANIFEST")"
  (( count >= MIN_GRAPHICAL_PACKAGE_COUNT )) || \
    die "ARM64 baseline ISO has only $count packages; minimum is $MIN_GRAPHICAL_PACKAGE_COUNT. Refusing to remaster an incomplete source."

  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.squashfs "$TMP_ROOT/upstream-filesystem.squashfs"
  local squash_bytes
  squash_bytes="$(stat -c %s "$TMP_ROOT/upstream-filesystem.squashfs")"

  sha256sum "$UPSTREAM_MANIFEST" > "$TMP_ROOT/upstream-manifest.sha256"
  sha256sum "$UPSTREAM_REMOVE_MANIFEST" > "$TMP_ROOT/upstream-remove-manifest.sha256"
  ok "Upstream-derived ARM64 graphical baseline accepted: $count packages, $squash_bytes-byte squashfs."
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

verify_live_grub_bindings() {
  # Verify that every menuentry selecting the exact custom kernel also selects
  # the exact custom initramfs and exactly one selected DTB before initrd.
  #
  # Print the number of validated live entries to stdout. Diagnostics go to
  # stderr so callers may safely capture the count.
  local file="$1"
  local release="$2"
  local dtb="$3"

  python3 - "$file" "$release" "$dtb" "$LIVE_KERNEL_CMDLINE_JSON" <<'VERIFY_GRUB_BINDINGS_PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
release = sys.argv[2]
dtb = sys.argv[3]
required_args = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
data = path.read_text(encoding="utf-8", errors="strict")

target_kernel = f"/live/vmlinuz-{release}"
target_initrd = f"/live/initrd.img-{release}"
target_dtb = f"/boot/dtbs/{dtb}"

entry_start = re.compile(r'menuentry\s+(["\'])(.*?)\1\s*\{', re.S)
linux_line = re.compile(
    r"(?m)^[ \t]*linux(?:efi)?[ \t]+(?P<kernel>[^\s;{}]+)(?P<rest>(?:[ \t]+.*)?)$"
)
initrd_line = re.compile(
    r"(?m)^[ \t]*initrd(?:efi)?[ \t]+(?P<initrd>[^\s;{}]+)(?:[ \t]+.*)?$"
)
dtb_line = re.compile(
    r"(?m)^[ \t]*devicetree[ \t]+(?P<dtb>[^\s;{}]+)(?:[ \t]+.*)?$"
)

def menuentries(blob: str):
    pos = 0
    while True:
        match = entry_start.search(blob, pos)
        if not match:
            return
        depth = 1
        index = match.end()
        quote = None
        escape = False
        while index < len(blob) and depth:
            char = blob[index]
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif quote:
                if char == quote:
                    quote = None
            elif char in ("'", '"'):
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            index += 1
        if depth:
            raise SystemExit(f"{path}: unbalanced menuentry braces")
        yield match.group(2), blob[match.start():index]
        pos = index

validated = 0
for title, block in menuentries(data):
    linux_matches = list(linux_line.finditer(block))
    selected_linux = [m for m in linux_matches if m.group("kernel") == target_kernel]
    if not selected_linux:
        continue

    if len(selected_linux) != 1:
        raise SystemExit(
            f"{path}: menuentry {title!r} has {len(selected_linux)} selected "
            f"kernel commands; expected exactly one"
        )

    linux_tokens = selected_linux[0].group("rest").strip().split()
    for argument in required_args:
        count = linux_tokens.count(argument)
        if count != 1:
            raise SystemExit(
                f"{path}: menuentry {title!r} contains required kernel "
                f"argument {argument!r} {count} times; expected exactly one"
            )

    initrd_matches = [
        m for m in initrd_line.finditer(block)
        if m.group("initrd") == target_initrd
    ]
    if len(initrd_matches) != 1:
        raise SystemExit(
            f"{path}: menuentry {title!r} has {len(initrd_matches)} selected "
            f"initrd commands; expected exactly one"
        )

    dtb_matches = [
        m for m in dtb_line.finditer(block)
        if m.group("dtb") == target_dtb
    ]
    if len(dtb_matches) != 1:
        raise SystemExit(
            f"{path}: menuentry {title!r} has {len(dtb_matches)} selected "
            f"DTB directives; expected exactly one"
        )

    if dtb_matches[0].start() > initrd_matches[0].start():
        raise SystemExit(
            f"{path}: menuentry {title!r} places devicetree after initrd"
        )

    validated += 1

if validated == 0:
    raise SystemExit(
        f"{path}: no menuentry selects the exact custom kernel {target_kernel}"
    )

print(validated)
VERIFY_GRUB_BINDINGS_PY
}

patch_live_grub_file() {
  # Patch one GRUB configuration in the extracted ISO tree.
  #
  # The official Reunion template uses:
  #   linux<TAB>KERNEL_LIVE APPEND_LIVE ---
  # A literal-space startswith() test therefore misses the command. Parse
  # complete menuentry blocks and accept all horizontal whitespace instead.
  local file="$1"
  local iso_root="$2"
  [[ -f "$file" ]] || return 0

  local relative="${file#"$iso_root"/}"
  local evidence_root="$TMP_ROOT/grub-patches"
  local original_copy="$evidence_root/original/$relative"
  local patched_copy="$evidence_root/patched/$relative"
  local diff_file="$evidence_root/diffs/$relative.diff"
  local temporary="$file.builder-patched.$$"
  local metadata="$file.builder-metadata.$$"
  local before_sha after_sha live_entries verified_entries rc

  mkdir -p \
    "$(dirname "$original_copy")" \
    "$(dirname "$patched_copy")" \
    "$(dirname "$diff_file")"
  cp -a "$file" "$original_copy"
  before_sha="$(sha256sum "$file" | awk '{print $1}')"

  set +e
  python3 - "$file" "$temporary" "$metadata" "$KERNEL_RELEASE" "$DTB_NAME" "$LIVE_KERNEL_CMDLINE_JSON" <<'PATCH_GRUB_PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
metadata = Path(sys.argv[3])
release = sys.argv[4]
dtb = sys.argv[5]
required_args = json.loads(Path(sys.argv[6]).read_text(encoding="utf-8"))

data = source.read_text(encoding="utf-8", errors="strict")
target_kernel = f"/live/vmlinuz-{release}"
target_initrd = f"/live/initrd.img-{release}"
target_dtb = f"/boot/dtbs/{dtb}"
marker = "VANILLAOS_SNAPDRAGONX_ARM64_DTB_MANAGED"
required_set = set(required_args)


def reconcile_linux_rest(rest: str) -> str:
    """Deduplicate required arguments and insert absent ones before `---`."""
    tokens = rest.strip().split()
    output = []
    seen_required = set()
    for token in tokens:
        if token in required_set:
            if token in seen_required:
                continue
            seen_required.add(token)
        output.append(token)

    try:
        insert_at = output.index("---")
    except ValueError:
        insert_at = len(output)

    for argument in required_args:
        if argument not in seen_required:
            output.insert(insert_at, argument)
            insert_at += 1
            seen_required.add(argument)

    return (" " + " ".join(output)) if output else ""


entry_start = re.compile(r'menuentry\s+(["\'])(.*?)\1\s*\{', re.S)
linux_line = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    r"(?P<command>linux(?:efi)?)(?P<separator>[ \t]+)"
    r"(?P<kernel>KERNEL_LIVE|LINUX_LIVE|(?:/live/)?vmlinuz-[^\s;{}]+)"
    r"(?P<rest>[^\r\n]*)$"
)
initrd_line = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    r"(?P<command>initrd(?:efi)?)(?P<separator>[ \t]+)"
    r"(?P<initrd>INITRD_LIVE|(?:/live/)?initrd\.img-[^\s;{}]+)"
    r"(?P<rest>[^\r\n]*)$"
)
managed_dtb = re.compile(
    rf"(?m)^[ \t]*(?:#[ \t]*{re.escape(marker)}[ \t]*\r?\n)?"
    r"[ \t]*devicetree[ \t]+/boot/dtbs/[^\s;{}]+"
    rf"(?:[ \t]+#[ \t]*{re.escape(marker)})?[ \t]*\r?\n?"
)

def find_entries(blob: str):
    entries = []
    pos = 0
    while True:
        match = entry_start.search(blob, pos)
        if not match:
            break
        depth = 1
        index = match.end()
        quote = None
        escape = False
        while index < len(blob) and depth:
            char = blob[index]
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif quote:
                if char == quote:
                    quote = None
            elif char in ("'", '"'):
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            index += 1
        if depth:
            raise SystemExit(f"{source}: unbalanced menuentry braces")
        entries.append((match.start(), index, match.group(2)))
        pos = index
    return entries

entries = find_entries(data)
patches = []

for start, end, title in entries:
    block = data[start:end]
    linux_match = linux_line.search(block)
    initrd_match = initrd_line.search(block)
    if not linux_match or not initrd_match:
        continue

    # This is a live entry only when both commands use known live placeholders
    # or concrete live kernel/initrd paths.
    kernel_token = linux_match.group("kernel")
    initrd_token = initrd_match.group("initrd")
    kernel_is_live = (
        kernel_token in {"KERNEL_LIVE", "LINUX_LIVE"}
        or "vmlinuz-" in kernel_token
    )
    initrd_is_live = (
        initrd_token == "INITRD_LIVE"
        or "initrd.img-" in initrd_token
    )
    if not (kernel_is_live and initrd_is_live):
        continue

    # Remove only a previously builder-managed /boot/dtbs directive. Preserve
    # unrelated GRUB commands and any non-builder device-tree handling.
    block = managed_dtb.sub("", block)

    linux_match = linux_line.search(block)
    initrd_match = initrd_line.search(block)
    if not linux_match or not initrd_match:
        raise SystemExit(
            f"{source}: live menuentry {title!r} became unparsable"
        )

    reconciled_rest = reconcile_linux_rest(linux_match.group("rest"))
    replacement_linux = (
        f"{linux_match.group('indent')}"
        f"{linux_match.group('command')}"
        f"{linux_match.group('separator')}"
        f"{target_kernel}"
        f"{reconciled_rest}"
    )
    block = (
        block[:linux_match.start()]
        + replacement_linux
        + block[linux_match.end():]
    )

    # Re-search after the kernel replacement because string offsets changed.
    initrd_match = initrd_line.search(block)
    if not initrd_match:
        raise SystemExit(
            f"{source}: live menuentry {title!r} lacks initrd after rewrite"
        )
    replacement_initrd = (
        f"{initrd_match.group('indent')}"
        f"# {marker}\n"
        f"{initrd_match.group('indent')}devicetree {target_dtb}\n"
        f"{initrd_match.group('indent')}"
        f"{initrd_match.group('command')}"
        f"{initrd_match.group('separator')}"
        f"{target_initrd}"
        f"{initrd_match.group('rest')}"
    )
    block = (
        block[:initrd_match.start()]
        + replacement_initrd
        + block[initrd_match.end():]
    )

    patches.append((start, end, block, title))

# Files with no live menuentries are valid auxiliary GRUB snippets and remain
# byte-identical. Files that contain a live kernel token but were not parsed are
# rejected rather than silently skipped.
if not patches:
    suspicious = bool(
        re.search(r"(?m)^[ \t]*linux(?:efi)?[ \t]+.*(?:KERNEL_LIVE|/live/vmlinuz-)", data)
        or re.search(r"(?m)^[ \t]*initrd(?:efi)?[ \t]+.*(?:INITRD_LIVE|/live/initrd\.img-)", data)
    )
    if suspicious:
        raise SystemExit(
            f"{source}: live boot commands were detected but no complete "
            "menuentry could be patched"
        )
    destination.write_text(data, encoding="utf-8")
    metadata.write_text("0\n", encoding="utf-8")
    raise SystemExit(0)

for start, end, block, _title in reversed(patches):
    data = data[:start] + block + data[end:]

# Internal validation before writing the patched file.
for _start, _end, _block, title in patches:
    pass

destination.write_text(data, encoding="utf-8")
metadata.write_text(f"{len(patches)}\n", encoding="utf-8")
PATCH_GRUB_PY
  rc=$?
  set -e

  if (( rc != 0 )); then
    rm -f "$temporary" "$metadata"
    die "Unable to patch GRUB file for custom kernel/DTB binding: $relative"
  fi

  live_entries="$(cat "$metadata")"
  rm -f "$metadata"
  [[ "$live_entries" =~ ^[0-9]+$ ]] || \
    die "Invalid GRUB patch metadata for $relative"

  if (( live_entries == 0 )); then
    rm -f "$temporary"
    printf '%s\t0\t0\t%s\t%s\n' \
      "$relative" "$before_sha" "$before_sha" "no live menuentries" \
      >> "$GRUB_PATCH_MANIFEST"
    return 0
  fi

  mv -f "$temporary" "$file"
  verified_entries="$(verify_live_grub_bindings "$file" "$KERNEL_RELEASE" "$DTB_NAME")"
  [[ "$verified_entries" == "$live_entries" ]] || \
    die "GRUB patch verification count mismatch for $relative: patched=$live_entries verified=$verified_entries"

  after_sha="$(sha256sum "$file" | awk '{print $1}')"
  cp -a "$file" "$patched_copy"
  diff -u "$original_copy" "$patched_copy" > "$diff_file" || true

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$relative" "$live_entries" "$verified_entries" \
    "$before_sha" "$after_sha" "$diff_file" \
    >> "$GRUB_PATCH_MANIFEST"

  ok "Patched $live_entries live GRUB menuentry/entries in $relative with selected DTB."
}



write_local_oci_registry_server() {
  local destination="$1"
  cat > "$destination" <<'PY_LOCAL_REGISTRY'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

parser = argparse.ArgumentParser()
parser.add_argument("--layout", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--repository", required=True)
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=5000)
args = parser.parse_args()

layout = Path(args.layout).resolve()
index = json.loads((layout / "index.json").read_text())
descriptors = {
    d.get("annotations", {}).get("org.opencontainers.image.ref.name"): d
    for d in index.get("manifests", [])
}
if args.tag not in descriptors:
    raise SystemExit(f"tag {args.tag!r} is absent from OCI layout")
tag_descriptor = descriptors[args.tag]

def blob_path(digest: str) -> Path:
    algorithm, encoded = digest.split(":", 1)
    if algorithm != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", encoded):
        raise ValueError("unsupported digest")
    return layout / "blobs" / algorithm / encoded

def descriptor_for_reference(reference: str):
    if reference == args.tag:
        return tag_descriptor
    if reference.startswith("sha256:"):
        path = blob_path(reference)
        if path.is_file():
            raw = path.read_bytes()
            media_type = "application/vnd.oci.image.manifest.v1+json"
            try:
                parsed = json.loads(raw)
                media_type = parsed.get("mediaType", media_type)
            except Exception:
                pass
            return {"digest": reference, "mediaType": media_type, "size": len(raw)}
    return None

class Handler(BaseHTTPRequestHandler):
    server_version = "VanillaOS-SnapdragonXOCIRegistry/1.2"

    def log_message(self, fmt, *values):
        rendered = fmt % values
        # containers/image commonly probes HTTPS before falling back to the
        # explicitly permitted plaintext HTTP endpoint.
        if "Bad request version" in rendered:
            return
        request_line = getattr(self, "requestline", "")
        if request_line and any(
            ord(ch) < 32 and ch not in "\t\r\n" for ch in request_line
        ):
            return
        print(f"registry: {self.address_string()} {rendered}", flush=True)

    def log_error(self, fmt, *values):
        rendered = fmt % values
        if "Bad request version" in rendered:
            return
        self.log_message(fmt, *values)

    def _send_file(self, path: Path, content_type: str, digest: str | None = None, head=False):
        if not path.is_file():
            self.send_error(404)
            return
        size = path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        if digest:
            self.send_header("Docker-Content-Digest", digest)
        self.end_headers()
        if not head:
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

    def _handle(self, head=False):
        path = unquote(self.path.split("?", 1)[0])
        if path in ("/v2", "/v2/"):
            self.send_response(200)
            self.send_header("Docker-Distribution-API-Version", "registry/2.0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        prefix = f"/v2/{args.repository}/"
        if not path.startswith(prefix):
            self.send_error(404)
            return
        suffix = path[len(prefix):]

        if suffix == "tags/list":
            body = json.dumps({"name": args.repository, "tags": [args.tag]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return

        if suffix.startswith("manifests/"):
            reference = suffix[len("manifests/"):]
            descriptor = descriptor_for_reference(reference)
            if descriptor is None:
                self.send_error(404)
                return
            digest = descriptor["digest"]
            self._send_file(blob_path(digest), descriptor.get("mediaType", "application/vnd.oci.image.manifest.v1+json"), digest, head)
            return

        if suffix.startswith("blobs/"):
            digest = suffix[len("blobs/"):]
            try:
                file_path = blob_path(digest)
            except ValueError:
                self.send_error(400)
                return
            self._send_file(file_path, "application/octet-stream", digest, head)
            return

        self.send_error(404)

    def do_GET(self):
        self._handle(False)

    def do_HEAD(self):
        self._handle(True)

ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
PY_LOCAL_REGISTRY
  chmod 0755 "$destination"
  python3 - "$destination" <<'PY_VALIDATE_REGISTRY_SERVER'
from pathlib import Path
import sys
compile(Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")
PY_VALIDATE_REGISTRY_SERVER
}

write_installer_storage_guard() {
  local root="$1"
  local guard="$root/usr/libexec/vanillaos-snapdragonx/storage-guard"
  local validator="$root/usr/libexec/vanillaos-snapdragonx/validate-installed-storage"
  local wrapper="$root/usr/libexec/vanillaos-snapdragonx/guarded-albius"
  local real_albius=""
  local candidate

  for candidate in /usr/bin/albius /usr/sbin/albius /bin/albius; do
    if [[ -x "$root$candidate" ]]; then
      real_albius="$candidate"
      break
    fi
  done
  [[ -n "$real_albius" ]] || \
    die "The live filesystem does not contain the real Albius executable."

  if [[ -e "$wrapper" ]] && ! grep -Fq \
      "VANILLAOS_SNAPDRAGONX_ALBIUS_STORAGE_GUARD" "$wrapper" 2>/dev/null; then
    die "Refusing to replace an unrelated executable at ${wrapper#"$root"}."
  fi

  mkdir -p "$(dirname "$guard")" "$(dirname "$wrapper")"

  cat > "$guard" <<'PY_STORAGE_GUARD'
#!/usr/bin/env python3
"""Validate and, when permitted, normalize Vanilla Installer storage recipes.

This program deliberately operates on the generated Albius recipe instead of
patching Vanilla Installer or Albius storage source. It is idempotent with an
upstream fix: a correct recipe is accepted without adding duplicate operations.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
from typing import Any

MARKER = "VANILLAOS_SNAPDRAGONX_STORAGE_GUARD_V1"
DEFAULT_EFFECTIVE_EVIDENCE = Path(
    "/tmp/vanillaos-snapdragonx-albius-install-recipe.json"
)
DEFAULT_GENERATED_EVIDENCE = Path(
    "/tmp/vanillaos-snapdragonx-albius-install-recipe.generated.json"
)
DEFAULT_REPORT = Path("/tmp/vanillaos-snapdragonx-storage-guard.json")
DEFAULT_VALIDATOR = "/usr/libexec/vanillaos-snapdragonx/validate-installed-storage"


class GuardError(RuntimeError):
    pass


def operation(step: dict[str, Any]) -> str:
    value = step.get("operation")
    return value if isinstance(value, str) else ""


def params(step: dict[str, Any]) -> list[Any]:
    value = step.get("params")
    return value if isinstance(value, list) else []


def norm_partnum(value: Any) -> str:
    if isinstance(value, bool):
        raise GuardError("partition number must not be boolean")
    if isinstance(value, float):
        if not value.is_integer():
            raise GuardError(f"non-integral partition number: {value!r}")
        return str(int(value))
    text = str(value).strip()
    if not text.isdigit() or int(text) < 1:
        raise GuardError(f"invalid partition number: {value!r}")
    return str(int(text))


def compose_partition(disk: str, partnum: Any) -> str:
    number = norm_partnum(partnum)
    suffix = "p" if disk and disk[-1].isdigit() else ""
    return f"{disk}{suffix}{number}"


def redact_recipe(document: dict[str, Any]) -> dict[str, Any]:
    redacted = copy.deepcopy(document)
    for step in redacted.get("setup", []):
        if not isinstance(step, dict):
            continue
        if operation(step) not in {"luks-format", "lvm-luks-format"}:
            continue
        values = params(step)
        if len(values) >= 3:
            values[2] = "<redacted-luks-passphrase>"
    return redacted


def atomic_json(path: Path, document: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def require_list(document: dict[str, Any], key: str) -> list[Any]:
    value = document.get(key)
    if not isinstance(value, list):
        raise GuardError(f"recipe field {key!r} must be a list")
    return value


def command_output(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as exc:
        raise GuardError(f"required storage utility is unavailable: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "unknown error").strip()
        raise GuardError(
            f"storage preflight command failed ({shlex.join(command)}): {detail}"
        ) from exc
    return completed.stdout.strip()


def iter_lsblk_nodes(nodes: list[Any]):
    for node in nodes:
        if not isinstance(node, dict):
            continue
        yield node
        children = node.get("children")
        if isinstance(children, list):
            yield from iter_lsblk_nodes(children)


def conflicting_partlabels(document: dict[str, Any], target: str) -> list[str]:
    target_real = os.path.realpath(target)
    conflicts: list[str] = []
    nodes = document.get("blockdevices")
    if not isinstance(nodes, list):
        raise GuardError("lsblk JSON lacks blockdevices array")
    for node in iter_lsblk_nodes(nodes):
        if node.get("type") != "part" or node.get("partlabel") != "vos-var":
            continue
        path = node.get("path")
        if not isinstance(path, str) or not path.startswith("/dev/"):
            raise GuardError("lsblk returned an unsafe device path for PARTLABEL vos-var")
        if os.path.realpath(path) != target_real:
            conflicts.append(path)
    return sorted(set(conflicts))


def preflight_manual_device(report: dict[str, Any]) -> dict[str, Any]:
    target = report.get("var_device")
    disk = report.get("var_disk")
    part_number = report.get("var_partition_number")
    if not isinstance(target, str) or not isinstance(disk, str):
        raise GuardError("manual storage report lacks target device identity")
    try:
        target_stat = os.stat(target)
    except OSError as exc:
        raise GuardError(f"manual /var partition is unavailable: {target}: {exc}") from exc
    if not stat.S_ISBLK(target_stat.st_mode):
        raise GuardError(f"manual /var target is not a block device: {target}")

    target_type = command_output(["lsblk", "-dn", "-o", "TYPE", target])
    if target_type != "part":
        raise GuardError(f"manual /var target is not a partition: {target} ({target_type})")

    parent_name = command_output(["lsblk", "-dn", "-o", "PKNAME", target])
    actual_disk = parent_name if parent_name.startswith("/dev/") else f"/dev/{parent_name}"
    if os.path.realpath(actual_disk) != os.path.realpath(disk):
        raise GuardError(
            f"manual /var recipe disk mismatch: recipe={disk}, actual={actual_disk}"
        )

    actual_part_number = norm_partnum(
        command_output(["lsblk", "-dn", "-o", "PARTN", target])
    )
    if actual_part_number != norm_partnum(part_number):
        raise GuardError(
            "manual /var partition-number mismatch: "
            f"recipe={part_number}, actual={actual_part_number}"
        )

    table_type = command_output(["lsblk", "-dn", "-o", "PTTYPE", disk]).lower()
    encrypted = report.get("encrypted") is True
    conflicts: list[str] = []
    if encrypted:
        if table_type != "gpt":
            raise GuardError(
                f"manual encrypted /var requires a GPT partition table for PARTLABEL discovery; "
                f"{disk} reports {table_type or 'unknown'}"
            )
        try:
            lsblk_document = json.loads(
                command_output(["lsblk", "--json", "-p", "-o", "PATH,TYPE,PARTLABEL"])
            )
        except json.JSONDecodeError as exc:
            raise GuardError(f"unable to parse lsblk JSON: {exc}") from exc
        conflicts = conflicting_partlabels(lsblk_document, target)
        if conflicts:
            raise GuardError(
                "existing GPT PARTLABEL vos-var is assigned to another partition: "
                + ", ".join(conflicts)
            )

    return {
        "status": "pass",
        "target": target,
        "disk": disk,
        "partition_number": actual_part_number,
        "partition_table": table_type,
        "existing_vos_var_conflicts": conflicts,
    }


def validate_root_lvm(setup: list[Any]) -> None:
    def matching(op: str, predicate) -> list[dict[str, Any]]:
        return [
            raw
            for raw in setup
            if isinstance(raw, dict) and operation(raw) == op and predicate(params(raw))
        ]

    vg = matching("vgcreate", lambda value: len(value) >= 1 and value[0] == "vos-root")
    init_lv = matching(
        "lvcreate",
        lambda value: len(value) >= 2 and value[0] == "init" and value[1] == "vos-root",
    )
    root_data = matching(
        "lvcreate",
        lambda value: len(value) >= 2 and value[0] == "root" and value[1] == "vos-root",
    )
    root_meta = matching(
        "lvcreate",
        lambda value: len(value) >= 2 and value[0] == "root-meta" and value[1] == "vos-root",
    )
    thin_pool = matching(
        "make-thin-pool",
        lambda value: len(value) >= 2
        and value[0] == "vos-root/root"
        and value[1] == "vos-root/root-meta",
    )
    root_a = matching(
        "lvcreate-thin",
        lambda value: len(value) >= 4
        and value[0] == "root-a"
        and value[1] == "vos-root"
        and value[3] == "root",
    )
    root_b = matching(
        "lvcreate-thin",
        lambda value: len(value) >= 4
        and value[0] == "root-b"
        and value[1] == "vos-root"
        and value[3] == "root",
    )
    checks = {
        "vos-root VG": vg,
        "vos-root/init LV": init_lv,
        "vos-root/root data LV": root_data,
        "vos-root/root-meta LV": root_meta,
        "vos-root/root thin pool": thin_pool,
        "vos-root/root-a thin LV": root_a,
        "vos-root/root-b thin LV": root_b,
    }
    invalid = [name for name, values in checks.items() if len(values) != 1]
    if invalid:
        raise GuardError(
            "ABRoot LVM topology is incomplete or ambiguous: " + ", ".join(invalid)
        )


def matching_partition_steps(
    setup: list[Any], var_partition: str, accepted_operations: set[str]
) -> list[tuple[int, dict[str, Any]]]:
    matches: list[tuple[int, dict[str, Any]]] = []
    for index, raw in enumerate(setup):
        if not isinstance(raw, dict) or operation(raw) not in accepted_operations:
            continue
        disk = raw.get("disk")
        values = params(raw)
        if not isinstance(disk, str) or not values:
            continue
        try:
            target = compose_partition(disk, values[0])
        except GuardError:
            continue
        if os.path.normpath(target) == os.path.normpath(var_partition):
            matches.append((index, raw))
    return matches


def validate_luks_passphrase(step: dict[str, Any]) -> None:
    values = params(step)
    if len(values) < 3 or not isinstance(values[2], str) or not values[2]:
        raise GuardError("encrypted /var operation lacks a nonempty LUKS passphrase")


def ensure_inner_label(
    step: dict[str, Any], label_index: int, policy: str, corrections: list[str]
) -> None:
    values = params(step)
    if len(values) > label_index and values[label_index] == "vos-var":
        return
    if policy != "repair":
        raise GuardError(
            "encrypted /var operation does not assign inner filesystem label vos-var"
        )
    while len(values) <= label_index:
        values.append("")
    values[label_index] = "vos-var"
    corrections.append("normalized encrypted /var inner filesystem label to vos-var")


def add_post_validation(
    document: dict[str, Any], validator: str, mode: str, var_device: str
) -> bool:
    post = require_list(document, "postInstallation")
    command = (
        f"{shlex.quote(validator)} --mode {shlex.quote(mode)} "
        f"--var-device {shlex.quote(var_device)}"
    )
    for raw in post:
        if not isinstance(raw, dict) or operation(raw) != "shell":
            continue
        for value in params(raw):
            if isinstance(value, str) and MARKER in value:
                return False
    post.append(
        {
            "chroot": False,
            "operation": "shell",
            "params": [f"{command} # {MARKER}"],
        }
    )
    return True


def analyze_and_normalize(
    document: dict[str, Any], policy: str, validator: str
) -> dict[str, Any]:
    setup = require_list(document, "setup")
    mountpoints = require_list(document, "mountpoints")
    require_list(document, "postInstallation")

    var_mounts = [
        item
        for item in mountpoints
        if isinstance(item, dict) and item.get("target") == "/var"
    ]
    if len(var_mounts) != 1:
        raise GuardError(
            f"expected exactly one /var mountpoint, found {len(var_mounts)}"
        )
    var_partition = var_mounts[0].get("partition")
    if not isinstance(var_partition, str) or not var_partition.startswith("/dev/"):
        raise GuardError(f"unsafe or missing /var device: {var_partition!r}")

    root_targets = [
        item.get("partition")
        for item in mountpoints
        if isinstance(item, dict) and item.get("target") == "/"
    ]
    if (
        len(root_targets) != 2
        or root_targets.count("/dev/vos-root/root-a") != 1
        or root_targets.count("/dev/vos-root/root-b") != 1
    ):
        raise GuardError(
            "recipe must expose exactly one ABRoot A mount and one ABRoot B mount"
        )

    validate_root_lvm(setup)

    corrections: list[str] = []
    topology: str
    encrypted: bool
    discovery_path: str
    var_disk: str | None = None
    var_partition_number: str | None = None

    automatic_paths = {"/dev/vos-var/var", "/dev/mapper/vos--var-var"}
    if os.path.normpath(var_partition) in automatic_paths:
        topology = "automatic-lvm"
        vg_steps = [
            raw
            for raw in setup
            if isinstance(raw, dict)
            and operation(raw) == "vgcreate"
            and params(raw)
            and params(raw)[0] == "vos-var"
        ]
        lv_steps = [
            raw
            for raw in setup
            if isinstance(raw, dict)
            and operation(raw) == "lvcreate"
            and len(params(raw)) >= 2
            and params(raw)[0] == "var"
            and params(raw)[1] == "vos-var"
        ]
        format_steps = [
            raw
            for raw in setup
            if isinstance(raw, dict)
            and operation(raw) in {"lvm-luks-format", "lvm-format"}
            and params(raw)
            and params(raw)[0] == "vos-var/var"
        ]
        if len(vg_steps) != 1 or len(lv_steps) != 1 or len(format_steps) != 1:
            raise GuardError(
                "automatic /var topology requires exactly one vos-var VG, var LV, and format operation"
            )
        encrypted = operation(format_steps[0]) == "lvm-luks-format"
        if encrypted:
            validate_luks_passphrase(format_steps[0])
            ensure_inner_label(format_steps[0], 3, policy, corrections)
            mode = "automatic-lvm-luks"
            discovery_path = "/dev/mapper/vos--var-var"
        else:
            values = params(format_steps[0])
            if len(values) < 3 or values[2] != "vos-var":
                raise GuardError("unencrypted automatic /var lacks filesystem label vos-var")
            mode = "automatic-lvm-plain"
            discovery_path = "/dev/disk/by-label/vos-var"
    else:
        topology = "manual-partition"
        candidates = matching_partition_steps(
            setup, var_partition, {"luks-format", "format", "setlabel"}
        )
        if len(candidates) != 1:
            raise GuardError(
                "manual /var must have exactly one matching luks-format, format, or setlabel operation"
            )
        format_index, format_step = candidates[0]
        format_operation = operation(format_step)
        disk = format_step.get("disk")
        values = params(format_step)
        if not isinstance(disk, str) or not values:
            raise GuardError("manual /var format operation is structurally invalid")
        part_number = norm_partnum(values[0])
        var_disk = disk
        var_partition_number = part_number
        encrypted = format_operation == "luks-format"

        if encrypted:
            validate_luks_passphrase(format_step)
            ensure_inner_label(format_step, 3, policy, corrections)
            other_vos_var: list[str] = []
            same_name_steps: list[tuple[int, dict[str, Any]]] = []
            for index, raw in enumerate(setup):
                if not isinstance(raw, dict) or operation(raw) != "namepart":
                    continue
                raw_values = params(raw)
                raw_disk = raw.get("disk")
                if len(raw_values) < 2 or not isinstance(raw_disk, str):
                    raise GuardError("malformed namepart operation in storage recipe")
                raw_number = norm_partnum(raw_values[0])
                same_target = raw_disk == disk and raw_number == part_number
                if raw_values[1] == "vos-var" and not same_target:
                    other_vos_var.append(compose_partition(raw_disk, raw_number))
                if same_target:
                    same_name_steps.append((index, raw))
            if other_vos_var:
                raise GuardError(
                    "PARTLABEL vos-var is assigned to another partition: "
                    + ", ".join(other_vos_var)
                )
            if len(same_name_steps) > 1:
                raise GuardError(
                    "manual /var contains multiple namepart operations for the same partition"
                )
            if same_name_steps:
                label_values = params(same_name_steps[0][1])
                if label_values[1] != "vos-var":
                    if policy != "repair":
                        raise GuardError(
                            "manual encrypted /var GPT partition name is not vos-var"
                        )
                    label_values[1] = "vos-var"
                    corrections.append(
                        "corrected manual encrypted /var GPT partition name to vos-var"
                    )
            else:
                if policy != "repair":
                    raise GuardError(
                        "manual encrypted /var lacks required GPT PARTLABEL vos-var"
                    )
                setup.insert(
                    format_index,
                    {
                        "disk": disk,
                        "operation": "namepart",
                        "params": [int(part_number), "vos-var"],
                    },
                )
                corrections.append(
                    "inserted idempotent namepart operation for manual encrypted /var"
                )
            mode = "manual-partition-luks"
            discovery_path = "/dev/disk/by-partlabel/vos-var"
        else:
            if format_operation == "format":
                if len(values) < 3 or values[2] != "vos-var":
                    raise GuardError("unencrypted manual /var lacks filesystem label vos-var")
            elif format_operation == "setlabel":
                if len(values) < 2 or values[1] != "vos-var":
                    raise GuardError("existing manual /var lacks filesystem label vos-var")
            mode = "manual-partition-plain"
            discovery_path = "/dev/disk/by-label/vos-var"

    validation_added = add_post_validation(document, validator, mode, var_partition)
    if validation_added:
        corrections.append("appended target storage validation post-install step")

    return {
        "marker": MARKER,
        "status": "pass",
        "policy": policy,
        "topology": topology,
        "root_lvm_topology": "vos-root validated",
        "encrypted": encrypted,
        "var_device": var_partition,
        "var_disk": var_disk,
        "var_partition_number": var_partition_number,
        "initramfs_discovery_path": discovery_path,
        "corrections": corrections,
        "effective_recipe_changed": bool(corrections),
    }


def process(args: argparse.Namespace) -> int:
    recipe_path = Path(args.recipe)
    try:
        if recipe_path.is_symlink():
            raise GuardError(f"refusing to replace symlinked Albius recipe: {recipe_path}")
        original_stat = recipe_path.stat()
        original_mode = stat.S_IMODE(original_stat.st_mode)
        document = json.loads(recipe_path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise GuardError("Albius recipe root must be a JSON object")

        atomic_json(Path(args.generated_evidence), redact_recipe(document))
        if args.policy == "off":
            report = {
                "marker": MARKER,
                "status": "disabled",
                "policy": "off",
                "warning": "storage recipe validation was explicitly disabled",
            }
        else:
            report = analyze_and_normalize(document, args.policy, args.validator)
            if report["topology"] == "manual-partition" and not args.skip_device_preflight:
                report["device_preflight"] = preflight_manual_device(report)
            else:
                report["device_preflight"] = {
                    "status": "not-required" if report["topology"] != "manual-partition" else "skipped"
                }
            atomic_json(recipe_path, document, mode=original_mode)
            os.chown(recipe_path, original_stat.st_uid, original_stat.st_gid)
        atomic_json(Path(args.effective_evidence), redact_recipe(document))
        atomic_json(Path(args.report), report)
        print(
            "Storage guard: "
            f"status={report['status']} policy={report['policy']} "
            f"topology={report.get('topology', 'not-validated')} "
            f"corrections={len(report.get('corrections', []))}"
        )
        return 0
    except (OSError, json.JSONDecodeError, GuardError, TypeError, ValueError) as exc:
        report = {
            "marker": MARKER,
            "status": "fail",
            "policy": args.policy,
            "error": str(exc),
        }
        try:
            atomic_json(Path(args.report), report)
        except OSError:
            pass
        print(f"Storage guard failure: {exc}", file=os.sys.stderr)
        return 78


def minimal_root_setup() -> list[dict[str, Any]]:
    return [
        {"disk": "/dev/nvme0n1", "operation": "vgcreate", "params": ["vos-root", ["/dev/nvme0n1p8"]]},
        {"disk": "/dev/nvme0n1", "operation": "lvcreate", "params": ["init", "vos-root", "linear", 1024]},
        {"disk": "/dev/nvme0n1", "operation": "lvcreate", "params": ["root-meta", "vos-root", "linear", 1024]},
        {"disk": "/dev/nvme0n1", "operation": "lvcreate", "params": ["root", "vos-root", "linear", 19456]},
        {"disk": "/dev/nvme0n1", "operation": "make-thin-pool", "params": ["vos-root/root", "vos-root/root-meta"]},
        {"disk": "/dev/nvme0n1", "operation": "lvcreate-thin", "params": ["root-a", "vos-root", 19456, "root"]},
        {"disk": "/dev/nvme0n1", "operation": "lvcreate-thin", "params": ["root-b", "vos-root", 19456, "root"]},
    ]


def minimal_recipe_manual(encrypted: bool, name: str | None = None) -> dict[str, Any]:
    op = "luks-format" if encrypted else "format"
    values: list[Any] = [9, "btrfs"]
    if encrypted:
        values.extend(["secret", "vos-var"])
    else:
        values.append("vos-var")
    setup: list[dict[str, Any]] = minimal_root_setup() + [
        {"disk": "/dev/nvme0n1", "operation": op, "params": values},
    ]
    if name is not None:
        format_index = next(index for index, step in enumerate(setup) if operation(step) == op)
        setup.insert(format_index, {"disk": "/dev/nvme0n1", "operation": "namepart", "params": [9, name]})
    return {
        "setup": setup,
        "mountpoints": [
            {"partition": "/dev/vos-root/root-a", "target": "/"},
            {"partition": "/dev/vos-root/root-b", "target": "/"},
            {"partition": "/dev/nvme0n1p9", "target": "/var"},
        ],
        "installation": {"method": "oci", "source": "example.invalid/image:tag"},
        "postInstallation": [],
    }


def minimal_recipe_auto(encrypted: bool = True) -> dict[str, Any]:
    op = "lvm-luks-format" if encrypted else "lvm-format"
    values: list[Any] = ["vos-var/var", "btrfs"]
    if encrypted:
        values.extend(["secret", "vos-var"])
    else:
        values.append("vos-var")
    return {
        "setup": minimal_root_setup() + [
            {"disk": "/dev/nvme0n1", "operation": "vgcreate", "params": ["vos-var", ["/dev/nvme0n1p4"]]},
            {"disk": "/dev/nvme0n1", "operation": "lvcreate", "params": ["var", "vos-var", "linear", "100%FREE"]},
            {"disk": "/dev/nvme0n1", "operation": op, "params": values},
        ],
        "mountpoints": [
            {"partition": "/dev/vos-root/root-a", "target": "/"},
            {"partition": "/dev/vos-root/root-b", "target": "/"},
            {"partition": "/dev/vos-var/var", "target": "/var"},
        ],
        "installation": {"method": "oci", "source": "example.invalid/image:tag"},
        "postInstallation": [],
    }


def expect_failure(document: dict[str, Any], policy: str, text: str) -> None:
    try:
        analyze_and_normalize(document, policy, DEFAULT_VALIDATOR)
    except GuardError as exc:
        if text not in str(exc):
            raise AssertionError(f"expected {text!r} in {exc!r}") from exc
    else:
        raise AssertionError(f"expected failure containing {text!r}")


def self_test() -> int:
    repaired = minimal_recipe_manual(True)
    result = analyze_and_normalize(repaired, "repair", DEFAULT_VALIDATOR)
    assert result["topology"] == "manual-partition"
    assert any(operation(step) == "namepart" for step in repaired["setup"])
    assert "<redacted-luks-passphrase>" in json.dumps(redact_recipe(repaired))
    assert "secret" not in json.dumps(redact_recipe(repaired))

    already_fixed = minimal_recipe_manual(True, "vos-var")
    result = analyze_and_normalize(already_fixed, "repair", DEFAULT_VALIDATOR)
    assert not any("inserted idempotent namepart" in item for item in result["corrections"])
    assert sum(operation(step) == "namepart" for step in already_fixed["setup"]) == 1

    strict_missing = minimal_recipe_manual(True)
    expect_failure(strict_missing, "strict", "lacks required GPT PARTLABEL")

    conflict = minimal_recipe_manual(True)
    conflict["setup"].insert(
        0,
        {"disk": "/dev/nvme0n1", "operation": "namepart", "params": [7, "vos-var"]},
    )
    expect_failure(conflict, "repair", "assigned to another partition")

    duplicate_var = minimal_recipe_manual(True)
    duplicate_var["mountpoints"].append(
        {"partition": "/dev/nvme0n1p10", "target": "/var"}
    )
    expect_failure(duplicate_var, "repair", "exactly one /var")

    automatic = minimal_recipe_auto(True)
    result = analyze_and_normalize(automatic, "repair", DEFAULT_VALIDATOR)
    assert result["topology"] == "automatic-lvm"
    assert not any(operation(step) == "namepart" for step in automatic["setup"])

    broken_auto = minimal_recipe_auto(True)
    broken_auto["setup"] = [
        step
        for step in broken_auto["setup"]
        if not (operation(step) == "vgcreate" and params(step)[0] == "vos-var")
    ]
    expect_failure(broken_auto, "repair", "requires exactly one vos-var VG")

    auto_missing_label = minimal_recipe_auto(True)
    auto_format = next(
        step for step in auto_missing_label["setup"] if operation(step) == "lvm-luks-format"
    )
    params(auto_format).pop()
    result = analyze_and_normalize(auto_missing_label, "repair", DEFAULT_VALIDATOR)
    assert params(auto_format)[3] == "vos-var"
    assert any("inner filesystem label" in item for item in result["corrections"])

    missing_secret = minimal_recipe_manual(True)
    manual_format = next(
        step for step in missing_secret["setup"] if operation(step) == "luks-format"
    )
    params(manual_format)[2] = ""
    expect_failure(missing_secret, "repair", "nonempty LUKS passphrase")

    plain = minimal_recipe_manual(False)
    result = analyze_and_normalize(plain, "repair", DEFAULT_VALIDATOR)
    assert result["encrypted"] is False
    assert result["initramfs_discovery_path"] == "/dev/disk/by-label/vos-var"

    labels = {
        "blockdevices": [
            {
                "path": "/dev/nvme0n1",
                "type": "disk",
                "children": [
                    {"path": "/dev/nvme0n1p9", "type": "part", "partlabel": None},
                    {"path": "/dev/nvme0n1p10", "type": "part", "partlabel": "vos-var"},
                ],
            }
        ]
    }
    assert conflicting_partlabels(labels, "/dev/nvme0n1p9") == ["/dev/nvme0n1p10"]

    print("Storage guard self-test: 11 scenarios passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--recipe")
    parser.add_argument("--policy", choices=("repair", "strict", "off"), default="repair")
    parser.add_argument("--report", default=str(DEFAULT_REPORT))
    parser.add_argument("--effective-evidence", default=str(DEFAULT_EFFECTIVE_EVIDENCE))
    parser.add_argument("--generated-evidence", default=str(DEFAULT_GENERATED_EVIDENCE))
    parser.add_argument("--validator", default=DEFAULT_VALIDATOR)
    parser.add_argument("--skip-device-preflight", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.self_test:
        return self_test()
    if not args.recipe:
        raise SystemExit("--recipe is required unless --self-test is used")
    return process(args)


if __name__ == "__main__":
    raise SystemExit(main())
PY_STORAGE_GUARD

  cat > "$validator" <<'SH_STORAGE_VALIDATOR'
#!/usr/bin/env bash
# VANILLAOS_SNAPDRAGONX_INSTALLED_STORAGE_VALIDATOR
set -Eeuo pipefail

mode=""
var_device=""
while (($#)); do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || exit 64; mode="$2"; shift 2 ;;
    --var-device) [[ $# -ge 2 ]] || exit 64; var_device="$2"; shift 2 ;;
    *) printf 'Unknown storage-validator argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[[ -n "$mode" && -n "$var_device" ]] || {
  echo "Storage validator requires --mode and --var-device." >&2
  exit 64
}

report=/tmp/vanillaos-snapdragonx-installed-storage-validation.txt
exec > >(tee "$report") 2>&1

fail_storage() {
  printf 'FAIL installed-storage: %s\n' "$*" >&2
  exit 79
}

real_device() {
  readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"
}

udevadm trigger --subsystem-match=block --action=change >/dev/null 2>&1 || true
udevadm settle --timeout=20 || fail_storage "udev did not settle"

printf 'Mode: %s\n' "$mode"
printf 'Recipe /var device: %s\n' "$var_device"

for required_command in lvs lsblk blkid udevadm; do
  command -v "$required_command" >/dev/null 2>&1 || \
    fail_storage "$required_command is unavailable"
done
for root_lv in init root root-a root-b; do
  lvs --noheadings "vos-root/$root_lv" >/dev/null 2>&1 || \
    fail_storage "required ABRoot LV is missing: vos-root/$root_lv"
done

case "$mode" in
  manual-partition-luks)
    command -v cryptsetup >/dev/null 2>&1 || fail_storage "cryptsetup is unavailable"
    [[ -b "$var_device" ]] || fail_storage "manual /var device is absent: $var_device"
    cryptsetup isLuks "$var_device" || fail_storage "$var_device is not a LUKS container"
    [[ "$(lsblk -dn -o PARTLABEL "$var_device" | xargs)" == "vos-var" ]] || \
      fail_storage "manual encrypted /var lacks GPT PARTLABEL vos-var"
    [[ -L /dev/disk/by-partlabel/vos-var ]] || \
      fail_storage "/dev/disk/by-partlabel/vos-var was not created"
    [[ "$(real_device /dev/disk/by-partlabel/vos-var)" == "$(real_device "$var_device")" ]] || \
      fail_storage "vos-var PARTLABEL resolves to the wrong partition"
    luks_uuid="$(blkid -s UUID -o value "$var_device" 2>/dev/null || true)"
    [[ -n "$luks_uuid" ]] || fail_storage "unable to read LUKS UUID for $var_device"
    mapper="/dev/mapper/luks-$luks_uuid"
    [[ -b "$mapper" ]] || fail_storage "installer did not leave encrypted /var open at $mapper"
    [[ "$(blkid -s LABEL -o value "$mapper" 2>/dev/null || true)" == "vos-var" ]] || \
      fail_storage "inner /var filesystem label is not vos-var"
    ;;
  automatic-lvm-luks)
    command -v cryptsetup >/dev/null 2>&1 || fail_storage "cryptsetup is unavailable"
    lvs --noheadings vos-var/var >/dev/null 2>&1 || \
      fail_storage "automatic vos-var/var LV is missing"
    [[ -b /dev/mapper/vos--var-var ]] || \
      fail_storage "/dev/mapper/vos--var-var is missing"
    cryptsetup isLuks /dev/mapper/vos--var-var || \
      fail_storage "vos-var/var is not a LUKS container"
    luks_uuid="$(blkid -s UUID -o value /dev/mapper/vos--var-var 2>/dev/null || true)"
    [[ -n "$luks_uuid" ]] || fail_storage "unable to read LUKS UUID for vos-var/var"
    mapper="/dev/mapper/luks-$luks_uuid"
    [[ -b "$mapper" ]] || fail_storage "installer did not leave encrypted /var open at $mapper"
    [[ "$(blkid -s LABEL -o value "$mapper" 2>/dev/null || true)" == "vos-var" ]] || \
      fail_storage "inner automatic /var filesystem label is not vos-var"
    ;;
  manual-partition-plain)
    [[ -b "$var_device" ]] || fail_storage "manual /var device is absent: $var_device"
    [[ "$(blkid -s LABEL -o value "$var_device" 2>/dev/null || true)" == "vos-var" ]] || \
      fail_storage "unencrypted manual /var lacks filesystem label vos-var"
    [[ -L /dev/disk/by-label/vos-var ]] || \
      fail_storage "/dev/disk/by-label/vos-var was not created"
    [[ "$(real_device /dev/disk/by-label/vos-var)" == "$(real_device "$var_device")" ]] || \
      fail_storage "vos-var filesystem label resolves to the wrong manual partition"
    ;;
  automatic-lvm-plain)
    lvs --noheadings vos-var/var >/dev/null 2>&1 || \
      fail_storage "automatic vos-var/var LV is missing"
    [[ -L /dev/disk/by-label/vos-var ]] || \
      fail_storage "/dev/disk/by-label/vos-var was not created"
    [[ "$(real_device /dev/disk/by-label/vos-var)" == "$(real_device /dev/vos-var/var)" ]] || \
      fail_storage "vos-var filesystem label resolves to the wrong logical volume"
    ;;
  *) fail_storage "unsupported validation mode: $mode" ;;
esac

printf 'PASS installed-storage: initramfs discovery metadata is valid for %s\n' "$mode"
SH_STORAGE_VALIDATOR

  cat > "$wrapper" <<EOF_ALBIUS_GUARD
#!/usr/bin/env bash
# VANILLAOS_SNAPDRAGONX_ALBIUS_STORAGE_GUARD
set -Eeuo pipefail
real_albius=$(printf '%q' "$real_albius")
guard=/usr/libexec/vanillaos-snapdragonx/storage-guard
validator=/usr/libexec/vanillaos-snapdragonx/validate-installed-storage
policy=$(printf '%q' "$INSTALLER_STORAGE_GUARD_POLICY")

[[ \$# -ge 1 ]] || {
  echo "The guarded Albius launcher requires a recipe path." >&2
  exit 64
}
recipe=\$1
[[ -s "\$recipe" ]] || {
  echo "The Albius recipe is absent or empty: \$recipe" >&2
  exit 66
}

"\$guard" \
  --recipe "\$recipe" \
  --policy "\$policy" \
  --validator "\$validator" \
  --generated-evidence /tmp/vanillaos-snapdragonx-albius-install-recipe.generated.json \
  --effective-evidence /tmp/vanillaos-snapdragonx-albius-install-recipe.json \
  --report /tmp/vanillaos-snapdragonx-storage-guard.json

recipe_real=\$(readlink -m -- "\$recipe")
cleanup_recipe=0
case "\$recipe_real" in
  /tmp/tmp*) cleanup_recipe=1 ;;
esac

set +e
"\$real_albius" "\$@"
rc=\$?
set -e

# Vanilla Installer uses NamedTemporaryFile under /tmp. Remove that raw recipe
# after Albius exits because it may contain the LUKS passphrase. Redacted
# generated/effective evidence and the guard report remain available.
if (( cleanup_recipe == 1 )); then
  rm -f -- "\$recipe_real"
fi
exit "\$rc"
EOF_ALBIUS_GUARD

  chmod 0755 "$guard" "$validator" "$wrapper"
  python3 -m py_compile "$guard"
  rm -rf "$(dirname "$guard")/__pycache__"
  python3 "$guard" --self-test
  bash -n "$validator" "$wrapper"

  grep -Fq "VANILLAOS_SNAPDRAGONX_STORAGE_GUARD_V1" "$guard" || \
    die "Generated storage guard lacks its version marker."
  grep -Fq "manual-partition-luks" "$validator" || \
    die "Generated storage validator lacks manual LUKS support."
  grep -Fq "preflight_manual_device" "$guard" || \
    die "Generated storage guard lacks physical manual-device preflight."
  grep -Fq "existing GPT PARTLABEL vos-var" "$guard" || \
    die "Generated storage guard lacks duplicate PARTLABEL rejection."
  grep -Fq "$real_albius" "$wrapper" || \
    die "Guarded Albius launcher does not reference the real executable."

  ok "Installed external Albius storage guard with policy: $INSTALLER_STORAGE_GUARD_POLICY"
}

patch_vanilla_installer_processor() {
  local root="$1"
  local processor progress
  local processor_original processor_patched processor_diff
  local progress_original progress_patched progress_diff

  processor="$(
    find "$root/usr" -type f \
      -path '*/vanilla_installer/utils/processor.py' \
      -print -quit 2>/dev/null || true
  )"
  progress="$(
    find "$root/usr" -type f \
      -path '*/vanilla_installer/views/progress.py' \
      -print -quit 2>/dev/null || true
  )"

  [[ -n "$processor" ]] || \
    die "Unable to locate Vanilla Installer processor.py in live filesystem."
  [[ -n "$progress" ]] || \
    die "Unable to locate Vanilla Installer progress.py in live filesystem."

  processor_original="$TMP_ROOT/installer-processor.original.py"
  processor_patched="$TMP_ROOT/installer-processor.patched.py"
  processor_diff="$TMP_ROOT/installer-processor.diff"
  progress_original="$TMP_ROOT/installer-progress.original.py"
  progress_patched="$TMP_ROOT/installer-progress.patched.py"
  progress_diff="$TMP_ROOT/installer-progress.diff"

  cp -a "$processor" "$processor_original"
  cp -a "$progress" "$progress_original"

  python3 - "$processor" "$progress" <<'PATCH_INSTALLER_COMPONENTS'
from pathlib import Path
import sys

processor_path = Path(sys.argv[1])
progress_path = Path(sys.argv[2])

data = processor_path.read_text(encoding="utf-8")
marker = "VANILLAOS_SNAPDRAGONX_V8_PROFILE_INSTALLER_PATCH"
if marker in data:
    raise SystemExit("processor already contains the v8 patch marker")

installation_anchor = '''        # Installation
        recipe.set_installation("oci", oci_image)
'''
installation_replacement = '''        # Installation
        # VANILLAOS_SNAPDRAGONX_V8_PROFILE_INSTALLER_PATCH
        abroot_image = sys_recipe.get("vanillaos_snapdragonx_abroot_image", oci_image)
        expected_image_digest = sys_recipe.get("vanillaos_snapdragonx_embedded_digest", "")
        recipe.set_installation("oci", oci_image)
'''
if installation_anchor not in data:
    raise SystemExit("unable to locate installer installation anchor")
data = data.replace(installation_anchor, installation_replacement, 1)

abimage_anchor = '''                oci_image,
            )
            file.write(abimage)
'''
abimage_replacement = '''                abroot_image,
            )
            file.write(abimage)
'''
if abimage_anchor not in data:
    raise SystemExit("unable to locate abimage image-name anchor")
data = data.replace(abimage_anchor, abimage_replacement, 1)

adapt_anchor = '''            # Adapt root A filesystem structure
'''
migration_step = r'''            # Preserve OCI payload before converting selected paths to
            # /var-backed symlinks.
            recipe.add_postinstall_step(
                "shell",
                [
                    *[f"mkdir -p /mnt/a/var/{path}" for path in _REL_VAR_LINKS],
                    *[
                        f"if [ -d /mnt/a/{path} ] && [ ! -L /mnt/a/{path} ]; "
                        f"then cp -a /mnt/a/{path}/. /mnt/a/var/{path}/; fi"
                        for path in _REL_VAR_LINKS
                    ],
                    "mkdir -p /mnt/a/usr/lib/vanillaos-snapdragonx",
                    "printf '%s\\n' 'complete' > /mnt/a/usr/lib/vanillaos-snapdragonx/relocated-var-payload.status",
                ],
            )

'''
if adapt_anchor not in data:
    raise SystemExit("unable to locate root-layout adaptation anchor")
data = data.replace(adapt_anchor, migration_step + adapt_anchor, 1)

generic_kernel_anchor = (
    "KERNEL_VERSION=$(ls -1 /mnt/a/usr/lib/modules | sed '1p;d')"
)
generic_kernel_replacement = (
    "KERNEL_VERSION=$(cat /mnt/a/usr/lib/vanillaos-snapdragonx-kernel-release)"
)
if generic_kernel_anchor not in data:
    raise SystemExit("unable to locate generic ABRoot kernel selection")
data = data.replace(generic_kernel_anchor, generic_kernel_replacement, 1)

overlay_anchor = '''            # Mount `/etc` as overlay
'''
profile_boot_step = r'''            # Replace the generic ABRoot entry with the deterministic
            # hardware-profile kernel and DTB binding.
            recipe.add_postinstall_step(
                "shell",
                [
                    " ".join(
                        f"""KERNEL_VERSION=$(cat /mnt/a/usr/lib/vanillaos-snapdragonx-kernel-release) && \
                        DTB_NAME=$(cat /mnt/a/usr/lib/vanillaos-snapdragonx-dtb) && \
                        PROFILE_NAME=$(cat /mnt/a/usr/lib/vanillaos-snapdragonx-profile) && \
                        KERNEL_CMDLINE=$(tr '\\n' ' ' < /mnt/a/usr/lib/vanillaos-snapdragonx-kernel-command-line) && \
                        ROOTA_UUID=$(lsblk -d -n -o UUID {root_a_part}) && \
                        test -n "$KERNEL_VERSION" && \
                        test -n "$DTB_NAME" && \
                        test -n "$PROFILE_NAME" && \
                        test -d "/mnt/a/usr/lib/modules/$KERNEL_VERSION" && \
                        test -s "/mnt/a/boot/vmlinuz-$KERNEL_VERSION" && \
                        test -s "/mnt/a/boot/dtbs/$DTB_NAME" && \
                        mkdir -p /mnt/a/boot/init/vos-a/dtbs /mnt/a/boot/init/vos-b/dtbs && \
                        cp -a "/mnt/a/boot/dtbs/$DTB_NAME" "/mnt/a/boot/init/vos-a/dtbs/$DTB_NAME" && \
                        cp -a "/mnt/a/boot/dtbs/$DTB_NAME" "/mnt/a/boot/init/vos-b/dtbs/$DTB_NAME" && \
                        printf '%s\\n' \
                          'insmod gzio' \
                          'insmod part_gpt' \
                          'insmod ext2' \
                          "linux (lvm/vos--root-init)/vos-a/vmlinuz-$KERNEL_VERSION root=UUID=$ROOTA_UUID quiet splash bgrt_disable \\$vt_handoff lsm=integrity $KERNEL_CMDLINE" \
                          "devicetree (lvm/vos--root-init)/vos-a/dtbs/$DTB_NAME" \
                          "initrd (lvm/vos--root-init)/vos-a/initrd.img-$KERNEL_VERSION" \
                          > /mnt/a/boot/init/vos-a/abroot.cfg""".split()
                    )
                ],
            )

'''
if overlay_anchor not in data:
    raise SystemExit("unable to locate installer boot-step insertion anchor")
data = data.replace(overlay_anchor, profile_boot_step + overlay_anchor, 1)

abimage_command_anchor = '''                    "IMAGE_DIGEST=$(cat /mnt/a/.oci_digest) \\
                    envsubst < /tmp/abimage.abr > /mnt/a/abimage.abr \\
                    '$IMAGE_DIGEST'".split()
'''
abimage_command_replacement = '''                    (
                        f"IMAGE_DIGEST=$(cat /mnt/a/.oci_digest) && "
                        f"( test -z '{expected_image_digest}' || test \\\"$IMAGE_DIGEST\\\" = '{expected_image_digest}' ) && "
                        f"envsubst < /tmp/abimage.abr > /mnt/a/abimage.abr '$IMAGE_DIGEST'"
                    ).split()
'''
if abimage_command_anchor not in data:
    raise SystemExit("unable to locate abimage digest command anchor")
data = data.replace(abimage_command_anchor, abimage_command_replacement, 1)

move_anchor = '''                "update-initramfs -c -k all",
                "mv /boot/config* /boot/initrd.img* /boot/System.map* /boot/vmlinuz* /boot/init/vos-a",
'''
move_replacement = '''                "update-initramfs -c -k all",
                "mv /boot/config* /boot/initrd.img* /boot/System.map* /boot/vmlinuz* /boot/init/vos-a",
                "/usr/libexec/vanillaos-snapdragonx/verify-installed-boot",
'''
if move_anchor not in data:
    raise SystemExit("unable to locate installed-initramfs validation anchor")
data = data.replace(move_anchor, move_replacement, 1)

recipe_anchor = '''        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps(recipe, default=vars))
            f.flush()
            f.close()

            # setting the file executable
            os.chmod(f.name, 0o755)

            return f.name
'''
recipe_replacement = '''        serialized_recipe = json.dumps(recipe, default=vars)

        # Keep deterministic recipe evidence without persisting the LUKS
        # passphrase. The effective redacted recipe is written by the external
        # storage guard immediately before Albius executes.
        evidence_recipe = json.loads(serialized_recipe)
        for setup_step in evidence_recipe.get("setup", []):
            if setup_step.get("operation") in ("luks-format", "lvm-luks-format"):
                setup_params = setup_step.get("params", [])
                if len(setup_params) >= 3:
                    setup_params[2] = "<redacted-luks-passphrase>"
        persistent_recipe = "/tmp/vanillaos-snapdragonx-albius-install-recipe.generated.json"
        with open(persistent_recipe, "w", encoding="utf-8") as evidence:
            evidence.write(json.dumps(evidence_recipe, indent=2, sort_keys=True))
            evidence.write("\\n")
            evidence.flush()
        os.chmod(persistent_recipe, 0o600)

        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(serialized_recipe)
            f.flush()
            f.close()

            # The generated recipe can contain a LUKS passphrase. It only
            # needs to be readable by its owner and by the root-run Albius
            # launcher; it must never be world-readable or executable.
            os.chmod(f.name, 0o600)

            return f.name
'''
if recipe_anchor not in data:
    raise SystemExit("unable to locate temporary Albius recipe anchor")
data = data.replace(recipe_anchor, recipe_replacement, 1)

processor_path.write_text(data, encoding="utf-8")

progress = progress_path.read_text(encoding="utf-8")
progress_marker = "VANILLAOS_SNAPDRAGONX_V8_ALBIUS_LOG_CAPTURE"
if progress_marker in progress:
    raise SystemExit("progress view already contains log capture patch")

spawn_anchor = '''        self.__terminal.spawn_async(
            Vte.PtyFlags.DEFAULT,
            ".",
            ["sh", "-c", f"sudo albius {recipe}"],
            [],
            GLib.SpawnFlags.DO_NOT_REAP_CHILD,
            None,
            None,
            -1,
            None,
            None,
        )
'''
spawn_replacement = '''        # VANILLAOS_SNAPDRAGONX_V8_ALBIUS_LOG_CAPTURE
        log_path = self.__window.recipe.get(
            "log_file", "/tmp/vanilla_installer.log"
        )
        command = (
            'log_path="$2"; '
            'install -d -m 0755 "$(dirname "$log_path")"; '
            'printf "%s\\\\n" "# Vanilla Installer Log" '
            '"Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$log_path"; '
            '/usr/libexec/vanillaos-snapdragonx/guarded-albius "$1" 2>&1 | tee -a "$log_path"'
        )
        self.__terminal.spawn_async(
            Vte.PtyFlags.DEFAULT,
            ".",
            [
                "sudo",
                "bash",
                "-o",
                "pipefail",
                "-c",
                command,
                "vanillaos-snapdragonx-albius",
                recipe,
                log_path,
            ],
            [],
            GLib.SpawnFlags.DO_NOT_REAP_CHILD,
            None,
            None,
            -1,
            None,
            None,
        )
'''
if spawn_anchor not in progress:
    raise SystemExit("unable to locate installer VTE Albius spawn anchor")
progress = progress.replace(spawn_anchor, spawn_replacement, 1)
progress_path.write_text(progress, encoding="utf-8")
PATCH_INSTALLER_COMPONENTS

  python3 -m py_compile "$processor" "$progress"

  cp -a "$processor" "$processor_patched"
  cp -a "$progress" "$progress_patched"
  diff -u "$processor_original" "$processor_patched" \
    > "$processor_diff" || true
  diff -u "$progress_original" "$progress_patched" \
    > "$progress_diff" || true

  {
    printf 'component\tpath\tbefore_sha256\tafter_sha256\tdiff\n'
    printf 'vanilla-installer-processor\t%s\t%s\t%s\t%s\n' \
      "${processor#"$root"}" \
      "$(sha256sum "$processor_original" | awk '{print $1}')" \
      "$(sha256sum "$processor_patched" | awk '{print $1}')" \
      "$processor_diff"
    printf 'vanilla-installer-progress-log-capture\t%s\t%s\t%s\t%s\n' \
      "${progress#"$root"}" \
      "$(sha256sum "$progress_original" | awk '{print $1}')" \
      "$(sha256sum "$progress_patched" | awk '{print $1}')" \
      "$progress_diff"
  } > "$INSTALLER_PATCH_MANIFEST"

  grep -Fq "relocated-var-payload.status" "$processor" || \
    die "Patched installer processor lacks payload-relocation evidence."
  grep -Fq "vanillaos-snapdragonx-albius-install-recipe.generated.json" "$processor" || \
    die "Patched installer processor lacks redacted generated-recipe evidence."
  grep -Fq "VANILLAOS_SNAPDRAGONX_V8_ALBIUS_LOG_CAPTURE" "$progress" || \
    die "Patched installer progress view lacks Albius log capture."
  grep -Fq "/usr/libexec/vanillaos-snapdragonx/guarded-albius" "$progress" || \
    die "Patched installer progress view bypasses the external storage guard."

  ok "Patched Vanilla Installer processor and VTE logging for profile installation."
}
install_profile_aware_installer_overlay() {
  local root="$1"
  local recipe_source="$root/etc/vanilla-installer/recipe.json"
  local profile_dir="$root/etc/vanilla-installer/profiles/$PROFILE"
  local recipe_target="$profile_dir/recipe.json"
  local wrapper="$root/usr/libexec/vanillaos-snapdragonx/installer-$PROFILE"
  local installer_dispatch="$root/usr/bin/vanilla-installer"
  local installer_real="$root/usr/libexec/vanilla-installer.real"
  local registry_server="$root/usr/libexec/vanillaos-snapdragonx/oci-registry.py"
  local registry_service_launcher="$root/usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE"
  local registry_unit_name="vanillaos-snapdragonx-oci-registry.service"
  local registry_unit="$root/etc/systemd/system/$registry_unit_name"
  local registry_wants="$root/etc/systemd/system/multi-user.target.wants/$registry_unit_name"
  local collector="$root/usr/libexec/vanillaos-snapdragonx/collect-installer-diagnostics"
  local upstream_autostart="$root/home/vanilla/.config/autostart/org.vanillaos.Installer.desktop"
  local fallback_autostart="$root/etc/xdg/autostart/vanillaos-snapdragonx-installer-$PROFILE.desktop"
  local autostart_evidence="$root/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/installer-autostart-path"
  local app="$root/usr/share/applications/vanillaos-snapdragonx-installer-$PROFILE.desktop"

  [[ -s "$recipe_source" ]] || \
    die "Live filesystem lacks Vanilla Installer recipe.json."

  mkdir -p "$profile_dir" "$root/usr/libexec/vanillaos-snapdragonx" \
    "$root/etc/xdg/autostart" "$root/usr/share/applications" \
    "$root/etc/containers/registries.conf.d" \
    "$root/etc/systemd/system/multi-user.target.wants" \
    "$root/usr/share/vanillaos-snapdragonx/profiles/$PROFILE"

  jq \
    --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    --arg abroot "$ABROOT_IMAGE_NAME" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg delivery "$DELIVERY_MODE" \
    --arg storage_guard_policy "$INSTALLER_STORAGE_GUARD_POLICY" \
    --arg allow_custom "$INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE" \
    '.images.default = $image
     | .images.nvidia = $image
     | .images.vm = $image
     | .vanillaos_snapdragonx_profile = $profile
     | .vanillaos_snapdragonx_abroot_image = $abroot
     | .vanillaos_snapdragonx_embedded_digest = $digest
     | .vanillaos_snapdragonx_delivery_mode = $delivery
     | .vanillaos_snapdragonx_storage_guard_policy = $storage_guard_policy
     | if $delivery == "iso-oci" then del(.steps["conn-check"]) else . end
     | if $allow_custom == "1" then . else del(.steps["image"]) end' \
    "$recipe_source" > "$recipe_target"

  # r1 canonical installer binding:
  # Preserve the exact upstream recipe for evidence, then make the generated
  # profile recipe canonical at /etc/vanilla-installer/recipe.json. The
  # Installer still honors VANILLA_CUSTOM_RECIPE, but current Gio single-instance
  # semantics make an environment-only selector insufficient: whichever launch
  # owns org.vanillaos.Installer first controls the process environment. Both
  # paths must therefore describe the same ISO-local target.
  cp -a "$recipe_source" "$profile_dir/recipe.upstream.json"
  cp -a "$recipe_target" "$recipe_source"
  cmp -s "$recipe_source" "$recipe_target" || \
    die "Canonical Vanilla Installer recipe diverges from the profile recipe."

  # Preserve the package-provided executable behind a private real entrypoint.
  # /usr/bin/vanilla-installer is replaced below with a dispatch shim so stock
  # desktop launchers, the installer session, and manual CLI use all traverse
  # the profile wrapper. In r3 that wrapper verifies a systemd-owned embedded
  # OCI bridge; it does not own or terminate the registry process itself.
  [[ -s "$installer_dispatch" ]] || \
    die "Live filesystem lacks /usr/bin/vanilla-installer before profile dispatch installation."
  cp -L --preserve=mode,ownership,timestamps "$installer_dispatch" "$installer_real"
  chmod 0755 "$installer_real"

  cp -a "$PROFILE_RESOLVED_JSON" \
    "$root/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/profile.resolved.json"
  cp -a "$TMP_ROOT/embedded-target-image.json" \
    "$root/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/embedded-target-image.json"

  write_local_oci_registry_server "$registry_server"

  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    grep -Eq '^vanilla:' "$root/etc/passwd" || \
      die "Live filesystem lacks the vanilla account required by the OCI bridge service."

    cat > "$registry_service_launcher" <<EOF_REGISTRY_SERVICE_HEADER
#!/usr/bin/env bash
# VANILLAOS_SNAPDRAGONX_OCI_REGISTRY_SERVICE_V1
set -Eeuo pipefail
profile=$(printf '%q' "$PROFILE")
layout_path=$(printf '%q' "$ISO_IMAGE_LAYOUT_PATH")
tag=$(printf '%q' "$EMBEDDED_IMAGE_TAG")
repository=$(printf '%q' "$LOCAL_REGISTRY_NAMESPACE/$PROFILE")
host=$(printf '%q' "$LOCAL_REGISTRY_HOST")
port=$(printf '%q' "$LOCAL_REGISTRY_PORT")
registry_log=/tmp/vanillaos-snapdragonx-local-registry.log
EOF_REGISTRY_SERVICE_HEADER

    cat >> "$registry_service_launcher" <<'EOF_REGISTRY_SERVICE_RUNTIME'
exec > >(tee -a "$registry_log") 2>&1
printf '\n=== VanillaOS-SnapdragonX OCI registry service: %s ===\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Profile: %s\n' "$profile"
printf 'Endpoint: http://%s:%s/%s\n' "$host" "$port" "$repository"

medium=""
for ((attempt=1; attempt<=600; attempt++)); do
  for candidate in /run/live/medium /cdrom /run/media/*/* /media/*/*; do
    [[ -d "$candidate" ]] || continue
    if [[ -s "$candidate/${layout_path#/}/oci-layout" && \
          -s "$candidate/${layout_path#/}/index.json" ]]; then
      medium="$candidate"
      break 2
    fi
  done
  sleep 0.1
done

[[ -n "$medium" ]] || {
  echo "Unable to locate embedded target OCI layout: $layout_path" >&2
  exit 70
}

layout="$medium/${layout_path#/}"
printf 'Embedded OCI medium: %s\n' "$medium"
printf 'Embedded OCI layout: %s\n' "$layout"
exec /usr/bin/python3 /usr/libexec/vanillaos-snapdragonx/oci-registry.py \
  --layout "$layout" --tag "$tag" --repository "$repository" \
  --host "$host" --port "$port"
EOF_REGISTRY_SERVICE_RUNTIME
    chmod 0755 "$registry_service_launcher"

    cat > "$registry_unit" <<EOF_REGISTRY_UNIT
[Unit]
Description=VanillaOS-SnapdragonX ISO-local OCI registry bridge
After=local-fs.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=vanilla
ExecStart=/usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE
Restart=always
RestartSec=1
KillMode=control-group
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_REGISTRY_UNIT
    ln -sfn "../$registry_unit_name" "$registry_wants"
  else
    rm -f "$registry_service_launcher" "$registry_unit" "$registry_wants"
  fi

  cat > "$wrapper" <<EOF_INSTALLER_WRAPPER_HEADER
#!/usr/bin/env bash
set -Eeuo pipefail
profile=$(printf '%q' "$PROFILE")
delivery=$(printf '%q' "$DELIVERY_MODE")
layout_path=$(printf '%q' "$ISO_IMAGE_LAYOUT_PATH")
tag=$(printf '%q' "$EMBEDDED_IMAGE_TAG")
repository=$(printf '%q' "$LOCAL_REGISTRY_NAMESPACE/$PROFILE")
logical_image=$(printf '%q' "$LOCAL_INSTALL_IMAGE_REF")
expected_digest=$(printf '%q' "$TARGET_IMAGE_MANIFEST_DIGEST")
host=$(printf '%q' "$LOCAL_REGISTRY_HOST")
port=$(printf '%q' "$LOCAL_REGISTRY_PORT")
recipe=$(printf '%q' "/etc/vanilla-installer/profiles/$PROFILE/recipe.json")
storage_guard_policy=$(printf '%q' "$INSTALLER_STORAGE_GUARD_POLICY")
registry_unit=vanillaos-snapdragonx-oci-registry.service
wrapper_log=/tmp/vanillaos-snapdragonx-installer-wrapper.log
EOF_INSTALLER_WRAPPER_HEADER

  cat >> "$wrapper" <<'EOF_INSTALLER_WRAPPER_RUNTIME'

exec > >(tee -a "$wrapper_log") 2>&1
printf '\n=== VanillaOS-SnapdragonX profile installer started: %s ===\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Profile: %s\n' "$profile"
printf 'Delivery: %s\n' "$delivery"
printf 'Storage guard policy: %s\n' "$storage_guard_policy"

# VANILLAOS_SNAPDRAGONX_REGISTRY_SERVICE_CLIENT_V1
# The registry is live-system infrastructure owned by systemd, not a child of
# this GUI launcher. Secondary Gio.Application launches may exit immediately;
# they must never tear down the bridge used by the primary Installer instance.
if [[ "$delivery" == "iso-oci" ]]; then
  if ! python3 - "$host" "$port" "$repository" "$tag" "$expected_digest" <<'PY_VERIFY_REGISTRY'
from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.request

host, port, repository, tag, expected_digest = sys.argv[1:]
base = f"http://{host}:{port}"
seen_manifests: set[str] = set()
seen_blob_headers: set[str] = set()

accept = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

def request(path: str, method: str = "GET"):
    req = urllib.request.Request(base + path, method=method)
    req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.headers, response.read()

for attempt in range(600):
    try:
        request("/v2/")
        break
    except Exception:
        if attempt == 599:
            raise SystemExit("local OCI registry bridge did not become ready")
        time.sleep(0.1)

def verify_digest(raw: bytes, expected: str, context: str) -> None:
    algorithm, encoded = expected.split(":", 1)
    if algorithm != "sha256":
        raise SystemExit(f"{context}: unsupported digest algorithm {algorithm}")
    actual = hashlib.sha256(raw).hexdigest()
    if actual != encoded:
        raise SystemExit(
            f"{context}: expected={expected} actual=sha256:{actual}"
        )

def verify_blob_header(descriptor: dict) -> None:
    digest = descriptor["digest"]
    if digest in seen_blob_headers:
        return
    headers, _raw = request(f"/v2/{repository}/blobs/{digest}", "HEAD")
    reported_digest = headers.get("Docker-Content-Digest")
    if reported_digest and reported_digest != digest:
        raise SystemExit(
            f"blob {digest}: registry reported digest {reported_digest}"
        )
    expected_size = descriptor.get("size")
    if expected_size is not None:
        reported_size = headers.get("Content-Length")
        if reported_size is None or int(reported_size) != int(expected_size):
            raise SystemExit(
                f"blob {digest}: expected size {expected_size}, "
                f"registry reported {reported_size}"
            )
    seen_blob_headers.add(digest)

def verify_manifest(reference: str, expected: str | None = None) -> str:
    headers, raw = request(f"/v2/{repository}/manifests/{reference}")
    digest = headers.get("Docker-Content-Digest")
    if not digest:
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    verify_digest(raw, digest, f"manifest {reference}")
    if expected and digest != expected:
        raise SystemExit(
            f"manifest {reference}: expected {expected}, received {digest}"
        )
    if digest in seen_manifests:
        return digest
    seen_manifests.add(digest)

    document = json.loads(raw)
    media_type = document.get("mediaType", headers.get_content_type())
    if "manifest.list" in media_type or media_type.endswith("image.index.v1+json"):
        descriptors = document.get("manifests", [])
        if not descriptors:
            raise SystemExit(f"manifest index {digest} has no child manifests")
        for descriptor in descriptors:
            child = descriptor["digest"]
            verify_manifest(child, child)
        return digest

    config = document.get("config")
    layers = document.get("layers", [])
    if not config or not layers:
        raise SystemExit(f"image manifest {digest} lacks config or layers")
    verify_blob_header(config)
    for descriptor in layers:
        verify_blob_header(descriptor)
    return digest

actual_digest = verify_manifest(tag, expected_digest)
summary = {
    "physical_endpoint": base,
    "repository": repository,
    "tag": tag,
    "expected_digest": expected_digest,
    "actual_digest": actual_digest,
    "manifests_verified": len(seen_manifests),
    "blob_headers_verified": len(seen_blob_headers),
    "verification_mode": "metadata-head",
}
with open(
    "/tmp/vanillaos-snapdragonx-local-registry-selftest.json", "w", encoding="utf-8"
) as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")

print(
    f"Local OCI bridge ready: manifests={len(seen_manifests)} "
    f"blob_headers={len(seen_blob_headers)} digest={actual_digest}"
)
PY_VERIFY_REGISTRY
  then
    echo "ISO-local OCI bridge readiness verification failed." >&2
    systemctl --no-pager --full status "$registry_unit" >&2 2>&1 || true
    journalctl -b -u "$registry_unit" -n 120 --no-pager >&2 2>&1 || true
    exit 70
  fi

  printf 'Installer logical image: %s\n' "$logical_image"
  printf 'Physical loopback endpoint: http://%s:%s/%s\n' \
    "$host" "$port" "$repository"
fi

export VANILLA_CUSTOM_RECIPE="$recipe"
EOF_INSTALLER_WRAPPER_RUNTIME

  if [[ "$INSTALLER_IGNORE_CPU" == "1" ]]; then
    printf 'export IGNORE_CPU=1\n' >> "$wrapper"
  fi

  cat >> "$wrapper" <<'EOF_INSTALLER_WRAPPER_END'

set +e
/usr/libexec/vanilla-installer.real "$@"
rc=$?
set -e
printf 'Vanilla Installer exited with status %s\n' "$rc"
exit "$rc"
EOF_INSTALLER_WRAPPER_END
  chmod 0755 "$wrapper"

  cat > "$installer_dispatch" <<EOF_INSTALLER_DISPATCH
#!/bin/sh
# VANILLAOS_SNAPDRAGONX_INSTALLER_DISPATCH_V2
# All live installer entrypoints must traverse the profile wrapper so the
# embedded OCI registry bridge is active before Vanilla Installer resolves its
# canonical ISO-local recipe.
exec /usr/libexec/vanillaos-snapdragonx/installer-$PROFILE "\$@"
EOF_INSTALLER_DISPATCH
  chmod 0755 "$installer_dispatch"

  cat > "$collector" <<'EOF_INSTALLER_COLLECTOR'
#!/usr/bin/env bash
set -Eeuo pipefail

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="vanillaos-snapdragonx-installer-diagnostics-$stamp"
work="/tmp/$name"
archive="/tmp/$name.tar.gz"
mkdir -p "$work"

copy_if_present() {
  local source="$1" destination="${2:-}"
  [[ -e "$source" ]] || return 0
  if [[ -n "$destination" ]]; then
    cp -a "$source" "$work/$destination"
  else
    cp -a "$source" "$work/"
  fi
}

copy_if_present /etc/vanilla/installer.log
copy_if_present /tmp/vanillaos-snapdragonx-installer-wrapper.log
copy_if_present /tmp/vanillaos-snapdragonx-local-registry.log
copy_if_present /tmp/vanillaos-snapdragonx-local-registry-selftest.json
copy_if_present /tmp/vanillaos-snapdragonx-albius-install-recipe.generated.json
copy_if_present /tmp/vanillaos-snapdragonx-albius-install-recipe.json
copy_if_present /etc/vanilla-installer/recipe.json installer-recipe-canonical.json
copy_if_present /etc/vanilla-installer/profiles/$profile/recipe.json installer-recipe-profile.json
copy_if_present /etc/vanilla-installer/profiles/$profile/recipe.upstream.json installer-recipe-upstream.json
copy_if_present /usr/bin/vanilla-installer installer-dispatch
copy_if_present /usr/libexec/vanillaos-snapdragonx/installer-$profile installer-wrapper
copy_if_present /tmp/vanillaos-snapdragonx-storage-guard.json
copy_if_present /tmp/vanillaos-snapdragonx-installed-storage-validation.txt
copy_if_present /etc/containers/registries.conf.d/90-vanillaos-snapdragonx-local.conf
copy_if_present /usr/share/vanillaos-snapdragonx profiles

find /etc/vanilla-installer/profiles -maxdepth 3 -type f \
  -print -exec cp --parents -a '{}' "$work" ';' 2>/dev/null || true

{
  echo "=== Mount state ==="
  findmnt /mnt/a || true
  findmnt /mnt/a/boot || true
  findmnt /mnt/a/boot/efi || true

  echo
  echo "=== Profile markers ==="
  for path in \
    /mnt/a/.oci_digest \
    /mnt/a/usr/lib/vanillaos-snapdragonx-profile \
    /mnt/a/usr/lib/vanillaos-snapdragonx-kernel-release \
    /mnt/a/usr/lib/vanillaos-snapdragonx-dtb \
    /mnt/a/usr/lib/vanillaos-snapdragonx-kernel-command-line \
    /mnt/a/usr/lib/vanillaos-snapdragonx/relocated-var-payload.status \
    /mnt/a/usr/lib/vanillaos-snapdragonx/installed-boot-validation.tsv
  do
    echo
    echo "--- $path"
    stat "$path" 2>&1 || true
    if [[ -f "$path" ]]; then
      cat "$path" 2>&1 || true
    fi
  done

  echo
  echo "=== Target storage topology ==="
  lsblk -e7 -o NAME,PATH,TYPE,FSTYPE,LABEL,PARTLABEL,UUID,PARTUUID,SIZE,MOUNTPOINTS 2>&1 || true
  pvs -a -o pv_name,pv_uuid,vg_name,pv_attr,pv_size,pv_free 2>&1 || true
  vgs -a -o vg_name,vg_uuid,vg_attr,vg_size,vg_free,lv_count,pv_count 2>&1 || true
  lvs -a -o vg_name,lv_name,lv_path,lv_attr,lv_active,segtype,devices 2>&1 || true
  find /dev/disk/by-partlabel /dev/disk/by-label -maxdepth 1 -type l \
    -printf '%p -> %l\n' 2>/dev/null | sort || true
  ls -la /dev/mapper 2>&1 || true

  echo
  echo "=== Relocated root payload ==="
  stat /mnt/a/root /mnt/a/var/root 2>&1 || true
  find /mnt/a/var/root -maxdepth 4 \
    -printf '%M %u:%g %s %p\n' 2>&1 | sort || true

  echo
  echo "=== Installed boot state ==="
  find /mnt/a/boot/init -maxdepth 5 \
    -printf '%M %u:%g %s %p\n' 2>&1 | sort || true
} > "$work/installed-target-state.txt" 2>&1

{
  echo "=== OCI registry service ==="
  systemctl --no-pager --full status vanillaos-snapdragonx-oci-registry.service 2>&1 || true
  echo
  ss -ltnp 'sport = :5000' 2>&1 || true
  echo
  pgrep -a -f 'vanillaos-snapdragonx-oci-registry|vanilla-installer' 2>&1 || true
  echo
  grep -RHE '^Exec=.*vanilla-installer' \
    /home/vanilla/.config/autostart /etc/xdg/autostart 2>/dev/null || true
} > "$work/registry-service-state.txt" 2>&1

journalctl -b -u vanillaos-snapdragonx-oci-registry.service --no-pager \
  > "$work/registry-service-journal.txt" 2>/dev/null || true
journalctl -b --no-pager > "$work/journal.txt" 2>/dev/null || true
tar -czf "$archive" -C /tmp "$name"
printf 'Diagnostic archive: %s\n' "$archive"
ls -lh "$archive"
sha256sum "$archive"
EOF_INSTALLER_COLLECTOR
  chmod 0755 "$collector"

  cat > "$root/etc/containers/registries.conf.d/90-vanillaos-snapdragonx-local.conf" <<EOF_REGISTRY_CONF
# Keep the image name given to Albius port-free. containers/image remaps this
# exact logical repository to the loopback-only physical bridge.
[[registry]]
prefix = "$(local_registry_logical_prefix)"
location = "$(local_registry_physical_prefix)"
insecure = true
blocked = false
EOF_REGISTRY_CONF

  cat > "$app" <<EOF_INSTALLER_DESKTOP
[Desktop Entry]
Type=Application
Name=Install $PROFILE_DISPLAY_NAME
Comment=Install the profile-specific offline VanillaOS target image
Exec=/usr/bin/vanilla-installer
Icon=org.vanillaos.Installer
Terminal=false
Categories=System;
EOF_INSTALLER_DESKTOP

  # Current live-iso:orchid copies org.vanillaos.Installer.desktop into
  # /etc/skel/.config/autostart before creating the vanilla live user. r1/r2
  # added a second global autostart with a different filename, so both launchers
  # ran. Converge on the upstream per-user autostart when present. Only create a
  # project fallback when an older/non-current live source does not provide it.
  rm -f "$fallback_autostart"
  if [[ "$INSTALLER_AUTOSTART" == "1" ]]; then
    if [[ -s "$upstream_autostart" ]]; then
      grep -Eq '^Exec=(/usr/bin/)?vanilla-installer([[:space:]]|$)' "$upstream_autostart" || \
        die "Upstream Installer autostart has an unexpected Exec contract."
      sed -i '/^Hidden=/d; /^X-GNOME-Autostart-enabled=/d' "$upstream_autostart"
      printf 'X-GNOME-Autostart-enabled=true\n' >> "$upstream_autostart"
      printf '%s\n' '/home/vanilla/.config/autostart/org.vanillaos.Installer.desktop' > "$autostart_evidence"
    else
      cp -a "$app" "$fallback_autostart"
      printf 'X-GNOME-Autostart-enabled=true\n' >> "$fallback_autostart"
      printf '%s\n' "/etc/xdg/autostart/vanillaos-snapdragonx-installer-$PROFILE.desktop" > "$autostart_evidence"
    fi
  else
    if [[ -s "$upstream_autostart" ]]; then
      sed -i '/^Hidden=/d; /^X-GNOME-Autostart-enabled=/d' "$upstream_autostart"
      printf 'Hidden=true\nX-GNOME-Autostart-enabled=false\n' >> "$upstream_autostart"
    fi
    printf '%s\n' 'disabled' > "$autostart_evidence"
  fi

  # Enforce a single automatic Installer launch path. Different XDG desktop
  # filenames are cumulative, so leaving both the upstream per-user entry and
  # the historical project-wide entry enabled recreates the r1/r2 race.
  local active_installer_autostarts=0 autostart_candidate
  for autostart_candidate in "$upstream_autostart" "$fallback_autostart"; do
    [[ -s "$autostart_candidate" ]] || continue
    grep -Eq '^Exec=.*vanilla-installer' "$autostart_candidate" || continue
    if grep -Eqi '^Hidden=(true|1|yes)$' "$autostart_candidate" || \
       grep -Eqi '^X-GNOME-Autostart-enabled=(false|0|no)$' "$autostart_candidate"; then
      continue
    fi
    ((active_installer_autostarts+=1))
  done
  if [[ "$INSTALLER_AUTOSTART" == "1" ]]; then
    (( active_installer_autostarts == 1 )) || \
      die "Expected exactly one enabled Installer autostart; found $active_installer_autostarts."
  else
    (( active_installer_autostarts == 0 )) || \
      die "Installer autostart is disabled by profile but an enabled launcher remains."
  fi

  bash -n "$wrapper"
  bash -n "$collector"
  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    bash -n "$registry_service_launcher"
  fi

  grep -Fqx "prefix = \"$(local_registry_logical_prefix)\"" \
    "$root/etc/containers/registries.conf.d/90-vanillaos-snapdragonx-local.conf" || \
    die "Generated registry remapping lacks its logical prefix."
  grep -Fqx "location = \"$(local_registry_physical_prefix)\"" \
    "$root/etc/containers/registries.conf.d/90-vanillaos-snapdragonx-local.conf" || \
    die "Generated registry remapping lacks its physical endpoint."
  validate_prometheus_storage_reference_compatibility \
    "$INSTALLER_DEFAULT_IMAGE_REF"

  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    '.images.default == $image and .vanillaos_snapdragonx_profile == $profile' \
    "$recipe_target" >/dev/null || \
    die "Generated profile-specific Vanilla Installer recipe failed validation."
  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    '.images.default == $image and .vanillaos_snapdragonx_profile == $profile' \
    "$recipe_source" >/dev/null || \
    die "Canonical Vanilla Installer recipe is not bound to the profile image."
  cmp -s "$recipe_source" "$recipe_target" || \
    die "Canonical and profile Vanilla Installer recipes differ after binding."
  grep -Fq 'VANILLAOS_SNAPDRAGONX_INSTALLER_DISPATCH_V2' "$installer_dispatch" || \
    die "Stock Vanilla Installer executable was not routed through the profile wrapper."
  [[ -x "$installer_real" && -s "$installer_real" ]] || \
    die "Private real Vanilla Installer executable is absent or non-executable."
  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    [[ -x "$registry_service_launcher" && -s "$registry_unit" && -L "$registry_wants" ]] || \
      die "ISO-local OCI registry systemd service was not installed/enabled."
    grep -Fq 'VANILLAOS_SNAPDRAGONX_OCI_REGISTRY_SERVICE_V1' "$registry_service_launcher" || \
      die "OCI registry service launcher lacks its ownership marker."
    grep -Fq "ExecStart=/usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE" "$registry_unit" || \
      die "OCI registry systemd service targets the wrong profile launcher."
    grep -Fq 'VANILLAOS_SNAPDRAGONX_REGISTRY_SERVICE_CLIENT_V1' "$wrapper" || \
      die "Installer wrapper does not consume the systemd-owned OCI bridge."
    ! grep -Fq 'cleanup_registry' "$wrapper" || \
      die "Installer wrapper still owns/terminates the OCI registry lifecycle."
  fi

  write_installer_storage_guard "$root"
  patch_vanilla_installer_processor "$root"

  {
    printf 'canonical-installer-recipe\t%s\tnot-applicable\t%s\tgenerated-profile-binding\n' \
      "/etc/vanilla-installer/recipe.json" \
      "$(sha256sum "$recipe_source" | awk '{print $1}')"
    printf 'profile-installer-recipe\t%s\tnot-applicable\t%s\tgenerated-profile-binding\n' \
      "/etc/vanilla-installer/profiles/$PROFILE/recipe.json" \
      "$(sha256sum "$recipe_target" | awk '{print $1}')"
    printf 'installer-dispatch\t%s\tnot-applicable\t%s\tgenerated-profile-binding\n' \
      "/usr/bin/vanilla-installer" \
      "$(sha256sum "$installer_dispatch" | awk '{print $1}')"
    printf 'installer-real-entrypoint\t%s\tnot-applicable\t%s\tupstream-preserved\n' \
      "/usr/libexec/vanilla-installer.real" \
      "$(sha256sum "$installer_real" | awk '{print $1}')"
    if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
      printf 'local-oci-registry-service-launcher\t%s\tnot-applicable\t%s\tgenerated-supervised-bridge\n' \
        "/usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE" \
        "$(sha256sum "$registry_service_launcher" | awk '{print $1}')"
      printf 'local-oci-registry-systemd-unit\t%s\tnot-applicable\t%s\tgenerated-supervised-bridge\n' \
        "/etc/systemd/system/$registry_unit_name" \
        "$(sha256sum "$registry_unit" | awk '{print $1}')"
    fi
    printf 'installer-autostart-contract\t%s\tnot-applicable\t%s\tsingle-launch-path\n' \
      "/usr/share/vanillaos-snapdragonx/profiles/$PROFILE/installer-autostart-path" \
      "$(sha256sum "$autostart_evidence" | awk '{print $1}')"
    printf 'external-storage-guard\t%s\tnot-applicable\t%s\tgenerated\n' \
      "/usr/libexec/vanillaos-snapdragonx/storage-guard" \
      "$(sha256sum "$root/usr/libexec/vanillaos-snapdragonx/storage-guard" | awk '{print $1}')"
    printf 'external-storage-validator\t%s\tnot-applicable\t%s\tgenerated\n' \
      "/usr/libexec/vanillaos-snapdragonx/validate-installed-storage" \
      "$(sha256sum "$root/usr/libexec/vanillaos-snapdragonx/validate-installed-storage" | awk '{print $1}')"
    printf 'guarded-albius-launcher\t%s\tnot-applicable\t%s\tgenerated\n' \
      "/usr/libexec/vanillaos-snapdragonx/guarded-albius" \
      "$(sha256sum "$root/usr/libexec/vanillaos-snapdragonx/guarded-albius" | awk '{print $1}')"
  } >> "$INSTALLER_PATCH_MANIFEST"

  jq -n \
    --arg profile "$PROFILE" \
    --arg release "$KERNEL_RELEASE" \
    --arg dtb "$DTB_NAME" \
    --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg cfg "/boot/init/vos-a/abroot.cfg" \
    --arg storage_guard_policy "$INSTALLER_STORAGE_GUARD_POLICY" \
    --arg registry_endpoint "$LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT" \
    --argjson cmdline "$(cat "$LIVE_KERNEL_CMDLINE_JSON")" \
    '{profile:$profile,kernel_release:$release,dtb:$dtb,
      installer_image:$image,manifest_digest:$digest,
      abroot_a_config:$cfg,
      kernel_command_line_append:$cmdline,
      installer_log:"/etc/vanilla/installer.log",
      generated_recipe:"/tmp/vanillaos-snapdragonx-albius-install-recipe.generated.json",
      persistent_recipe:"/tmp/vanillaos-snapdragonx-albius-install-recipe.json",
      storage_guard_report:"/tmp/vanillaos-snapdragonx-storage-guard.json",
      storage_validation_report:"/tmp/vanillaos-snapdragonx-installed-storage-validation.txt",
      storage_guard_policy:$storage_guard_policy,
      local_oci_registry_service:"vanillaos-snapdragonx-oci-registry.service",
      local_oci_registry_endpoint:$registry_endpoint,
      diagnostics_collector:"/usr/libexec/vanillaos-snapdragonx/collect-installer-diagnostics",
      installed_hardware_collector:"/usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics",
      installed_boot_evidence:"/var/log/vanillaos-snapdragonx/current",
      required_markers:[
        "/usr/lib/vanillaos-snapdragonx-profile",
        "/usr/lib/vanillaos-snapdragonx-kernel-release",
        "/usr/lib/vanillaos-snapdragonx-dtb",
        "/usr/lib/vanillaos-snapdragonx/relocated-var-payload.status"
      ]}' > "$INSTALLED_BOOT_EXPECTED_JSON"

  ok "Installed profile-aware Vanilla Installer overlay for $PROFILE."
}
remaster_boot_hardware_only() {
  local iso_tree="$TMP_ROOT/iso-tree"
  local squash_root="$TMP_ROOT/squash-root"
  local original_squash="$TMP_ROOT/original-filesystem.squashfs"
  local new_squash="$TMP_ROOT/new-filesystem.squashfs"
  local compression

  rm -rf "$iso_tree" "$squash_root"
  mkdir -p "$iso_tree" "$squash_root"

  info "Extracting accepted ARM64 baseline ISO tree."
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

  # Embed installer-side profile metadata and patch the installer before the
  # live squashfs is rebuilt. This does not alter package manifests.
  install_profile_aware_installer_overlay "$squash_root"
  configure_live_gdm_timed_login "$squash_root"

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
      echo 'Neither update-initramfs nor dracut exists inside the ARM64 baseline live filesystem.' >&2
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

  # Embed the verified OCI image layout outside the squashfs so it can be read
  # directly from the mounted installation medium without consuming live RAM.
  local embedded_dest="$iso_tree/${ISO_IMAGE_LAYOUT_PATH#/}"
  rm -rf "$embedded_dest"
  mkdir -p "$embedded_dest"
  rsync -aHAX "$EMBEDDED_OCI_LAYOUT/" "$embedded_dest/"
  cp -a "$TMP_ROOT/embedded-target-image.json" "$embedded_dest/VANILLAOS_SNAPDRAGONX-IMAGE.json"
  cp -a "$PROFILE_RESOLVED_JSON" "$embedded_dest/profile.resolved.json"

  # Preserve both official package manifests byte-for-byte. The custom live
  # kernel is a boot payload overlay, not a package-list or APT transaction.
  cp -a "$UPSTREAM_MANIFEST" "$iso_tree/live/filesystem.packages"
  cp -a "$UPSTREAM_REMOVE_MANIFEST" "$iso_tree/live/filesystem.packages-remove"

  GRUB_PATCH_MANIFEST="$TMP_ROOT/grub-patch-manifest.tsv"
  printf 'grub_file\tlive_entries\tverified_entries\tbefore_sha256\tafter_sha256\tdiff_file\n' \
    > "$GRUB_PATCH_MANIFEST"

  while IFS= read -r -d '' cfg; do
    patch_live_grub_file "$cfg" "$iso_tree"
  done < <(
    find -L "$iso_tree/boot/grub" "$iso_tree/EFI" -type f \
      \( -name '*.cfg' -o -name 'grub.cfg' -o -name 'loopback.cfg' \) \
      -print0 2>/dev/null
  )

  local grub_live_entries
  grub_live_entries="$(
    awk -F '\t' 'NR > 1 { total += $2 } END { print total + 0 }' \
      "$GRUB_PATCH_MANIFEST"
  )"
  (( grub_live_entries > 0 )) ||     die "No live GRUB menuentries were patched in the extracted ISO tree."

  awk -F '\t' '
    NR > 1 && $1 == "boot/grub/grub.cfg" && $2 > 0 { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$GRUB_PATCH_MANIFEST" ||     die "Primary boot/grub/grub.cfg was not patched with a live kernel/DTB binding."

  {
    printf 'Required profile kernel arguments:\n'
    printf '  %s\n' "${PROFILE_KERNEL_CMDLINE_APPEND[@]}"
    printf '\nPatched live linux commands:\n'
    while IFS= read -r -d '' cfg; do
      printf '\n--- %s\n' "${cfg#"$iso_tree"/}"
      grep -E \
        "^[[:space:]]*linux(efi)?[[:space:]]+/live/vmlinuz-${KERNEL_RELEASE//./\\.}([[:space:]]|$)" \
        "$cfg" || true
    done < <(
      find -L "$iso_tree/boot/grub" "$iso_tree/EFI" -type f \
        \( -name '*.cfg' -o -name 'grub.cfg' -o -name 'loopback.cfg' \) \
        -print0 2>/dev/null
    )
  } > "$LIVE_KERNEL_CMDLINE_EVIDENCE"

  ok "Validated $grub_live_entries live GRUB menuentry binding(s), DTB, and deduplicated kernel arguments before ISO creation."

  rm -f "$new_squash"
  mksquashfs "$squash_root" "$new_squash" -noappend -comp "$compression" >/dev/null

  # xorriso extraction preserves the upstream squashfs mode (normally 0444).
  # A plain mv to that path can invoke GNU mv's terminal overwrite prompt even
  # under an otherwise non-interactive build. Remove the extracted destination
  # first so replacement is deterministic and Stage 12 never waits for input.
  rm -f -- "$iso_tree/live/filesystem.squashfs"
  mv -- "$new_squash" "$iso_tree/live/filesystem.squashfs"

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
    -iso-level 3 \
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
  cmp -s "$UPSTREAM_MANIFEST" "$final_manifest" || die "Final filesystem.packages differs from accepted ARM64 baseline."
  cmp -s "$UPSTREAM_REMOVE_MANIFEST" "$final_remove" || die "Final filesystem.packages-remove differs from accepted ARM64 baseline."

  extract_iso_file "$FINAL_ISO" "/live/vmlinuz-$KERNEL_RELEASE" "$verify_dir/vmlinuz"
  extract_iso_file "$FINAL_ISO" "/live/initrd.img-$KERNEL_RELEASE" "$verify_dir/initrd"
  extract_iso_file "$FINAL_ISO" "/boot/dtbs/$DTB_NAME" "$verify_dir/$DTB_NAME"
  [[ -s "$verify_dir/vmlinuz" ]] || die "Final ISO lacks the nonempty custom kernel."
  [[ -s "$verify_dir/initrd" ]] || die "Final ISO lacks the nonempty custom initramfs."
  [[ -s "$verify_dir/$DTB_NAME" ]] || die "Final ISO lacks the selected DTB."

  extract_iso_file "$FINAL_ISO" /boot/grub/grub.cfg "$verify_dir/grub.cfg"
  [[ -s "$verify_dir/grub.cfg" ]] || die "Final ISO lacks nonempty /boot/grub/grub.cfg."

  local final_grub_entries
  final_grub_entries="$(
    verify_live_grub_bindings "$verify_dir/grub.cfg" "$KERNEL_RELEASE" "$DTB_NAME"
  )"
  (( final_grub_entries > 0 )) ||     die "Final GRUB config contains no validated custom kernel/initrd/DTB menuentry."

  grep -Fq "/live/vmlinuz-$KERNEL_RELEASE" "$verify_dir/grub.cfg" ||     die "Final GRUB config does not select the custom kernel."
  grep -Eq "^[[:space:]]*devicetree[[:space:]]+/boot/dtbs/${DTB_NAME//./\.}([[:space:]]|$)"     "$verify_dir/grub.cfg" ||     die "Final GRUB config lacks the selected DTB directive."

  cp -a "$verify_dir/grub.cfg" "$RELEASE_DIR/final-grub.cfg"
  ok "Final GRUB binding verification passed for $final_grub_entries live menuentry/entries."

  extract_iso_file "$FINAL_ISO" /live/filesystem.squashfs "$final_squash"
  unsquashfs -ll "$final_squash" > "$squash_listing"
  grep -Eq "(usr/)?lib/modules/${KERNEL_RELEASE}/" "$squash_listing" || die "Final squashfs lacks custom modules."
  grep -Fq "boot/dtbs/$DTB_NAME" "$squash_listing" || die "Final squashfs lacks selected DTB."
  local firmware_probe
  for firmware_probe in "${PROFILE_FIRMWARE_PROBES[@]}"; do
    [[ -n "$firmware_probe" ]] || continue
    grep -Fq "usr/lib/firmware/$firmware_probe" "$squash_listing" || \
      die "Final squashfs lacks required firmware probe: $firmware_probe"
  done

  # Do not search the live installer squashfs for the installed target's
  # ABRoot unlock hook. The hook was validated in the target OCI before export;
  # below, the final ISO is required to carry that exact OCI manifest digest.
  [[ -s "$TARGET_STORAGE_HOOK_FILE" && -s "$TARGET_STORAGE_HOOK_SHA256_FILE" &&
     -s "$TARGET_STORAGE_HOOK_EVIDENCE_JSON" ]] ||
    die "Target storage-hook verification evidence is incomplete."
  grep -Fq '/dev/mapper/vos--var-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Recorded target hook lacks automatic LVM encrypted /var discovery."
  grep -Fq '/dev/disk/by-partlabel/vos-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Recorded target hook lacks manual encrypted /var PARTLABEL discovery."
  grep -Fq '/dev/disk/by-label/vos-var' "$TARGET_STORAGE_HOOK_FILE" ||
    die "Recorded target hook lacks unencrypted /var filesystem-label discovery."

  # Verify the embedded OCI layout and exact manifest digest.
  local embedded_verify="$verify_dir/embedded-oci"
  mkdir -p "$embedded_verify"
  extract_iso_file "$FINAL_ISO" "$ISO_IMAGE_LAYOUT_PATH/oci-layout" "$embedded_verify/oci-layout"
  extract_iso_file "$FINAL_ISO" "$ISO_IMAGE_LAYOUT_PATH/index.json" "$embedded_verify/index.json"
  [[ -s "$embedded_verify/oci-layout" && -s "$embedded_verify/index.json" ]] || \
    die "Final ISO lacks the embedded OCI layout metadata."

  local embedded_descriptor embedded_digest embedded_hex
  embedded_descriptor="$(jq -c --arg tag "$EMBEDDED_IMAGE_TAG" '
    [.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $tag)]
    | if length == 1 then .[0] else empty end
  ' "$embedded_verify/index.json")"
  [[ -n "$embedded_descriptor" ]] || die "Final ISO OCI index lacks tag $EMBEDDED_IMAGE_TAG"
  embedded_digest="$(jq -r '.digest' <<<"$embedded_descriptor")"
  [[ "$embedded_digest" == "$TARGET_IMAGE_MANIFEST_DIGEST" ]] || \
    die "Final ISO embedded manifest digest differs from verified target digest."
  embedded_hex="${embedded_digest#sha256:}"
  extract_iso_file "$FINAL_ISO" \
    "$ISO_IMAGE_LAYOUT_PATH/blobs/sha256/$embedded_hex" \
    "$embedded_verify/manifest.blob"
  [[ "sha256:$(sha256sum "$embedded_verify/manifest.blob" | awk '{print $1}')" == "$embedded_digest" ]] || \
    die "Final ISO embedded OCI manifest blob failed digest validation."

  local evidence_manifest_digest evidence_hook_sha recorded_hook_sha
  evidence_manifest_digest="$(jq -r '.manifest_digest // empty' "$TARGET_STORAGE_HOOK_EVIDENCE_JSON")"
  evidence_hook_sha="$(jq -r '.hook_sha256 // empty' "$TARGET_STORAGE_HOOK_EVIDENCE_JSON")"
  recorded_hook_sha="$(sha256sum "$TARGET_STORAGE_HOOK_FILE" | awk '{print $1}')"
  [[ "$evidence_manifest_digest" == "$embedded_digest" ]] ||
    die "Target storage-hook evidence is bound to a different OCI manifest digest."
  [[ "$evidence_hook_sha" == "$recorded_hook_sha" ]] ||
    die "Target storage-hook evidence SHA-256 differs from the recorded verified hook."
  ok "Verified target storage hook through embedded OCI manifest identity: $embedded_digest"

  # Verify the profile-specific recipe and installer patch inside squashfs.
  extract_required_squashfs_file "$final_squash" \
    "etc/vanilla-installer/profiles/$PROFILE/recipe.json" \
    "$verify_dir/installer-recipe.json" \
    "profile installer recipe"
  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    '.images.default == $image' "$verify_dir/installer-recipe.json" >/dev/null || \
    die "Final ISO installer recipe does not default to the resolved profile image."
  extract_required_squashfs_file "$final_squash" \
    "etc/vanilla-installer/recipe.json" \
    "$verify_dir/installer-recipe-canonical.json" \
    "canonical installer recipe"
  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    '.images.default == $image and .vanillaos_snapdragonx_profile == $profile' \
    "$verify_dir/installer-recipe-canonical.json" >/dev/null || \
    die "Final ISO canonical installer recipe is not bound to the embedded/profile image."
  cmp -s "$verify_dir/installer-recipe.json" "$verify_dir/installer-recipe-canonical.json" || \
    die "Final ISO canonical and profile installer recipes differ."
  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    ! grep -Fq 'ghcr.io/vanilla-os/gnome:latest' "$verify_dir/installer-recipe-canonical.json" || \
      die "Final ISO canonical recipe still exposes the stock gnome:latest default in iso-oci mode."
  fi
  extract_required_squashfs_file "$final_squash" \
    "usr/bin/vanilla-installer" \
    "$verify_dir/installer-dispatch" \
    "canonical Vanilla Installer dispatch"
  grep -Fq 'VANILLAOS_SNAPDRAGONX_INSTALLER_DISPATCH_V2' "$verify_dir/installer-dispatch" || \
    die "Final ISO /usr/bin/vanilla-installer does not dispatch through the profile wrapper."
  grep -Fq "/usr/libexec/vanillaos-snapdragonx/installer-$PROFILE" "$verify_dir/installer-dispatch" || \
    die "Final ISO installer dispatch targets the wrong profile wrapper."
  extract_required_squashfs_file "$final_squash" \
    "usr/libexec/vanilla-installer.real" \
    "$verify_dir/installer-real" \
    "private real Vanilla Installer entrypoint"
  [[ -s "$verify_dir/installer-real" ]] || \
    die "Final ISO private real Vanilla Installer entrypoint is empty."
  extract_required_squashfs_file "$final_squash" \
    "usr/libexec/vanillaos-snapdragonx/installer-$PROFILE" \
    "$verify_dir/installer-wrapper" \
    "profile installer wrapper"
  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    extract_required_squashfs_file "$final_squash" \
      "usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE" \
      "$verify_dir/registry-service-launcher" \
      "OCI registry service launcher"
    extract_required_squashfs_file "$final_squash" \
      "etc/systemd/system/vanillaos-snapdragonx-oci-registry.service" \
      "$verify_dir/registry-service.unit" \
      "OCI registry systemd unit"
    grep -Fq 'VANILLAOS_SNAPDRAGONX_OCI_REGISTRY_SERVICE_V1' \
      "$verify_dir/registry-service-launcher" || \
      die "Final ISO OCI registry service launcher lacks its ownership marker."
    grep -Fq "ExecStart=/usr/libexec/vanillaos-snapdragonx/oci-registry-service-$PROFILE" \
      "$verify_dir/registry-service.unit" || \
      die "Final ISO OCI registry unit targets the wrong profile launcher."
    grep -Fq 'Restart=always' "$verify_dir/registry-service.unit" || \
      die "Final ISO OCI registry unit is not configured for supervised restart."
    # r4-inherited correction: reuse the complete squashfs listing captured above instead of
    # piping a second unsquashfs process into grep -q. With global pipefail,
    # grep -q may exit as soon as it finds the match, causing unsquashfs to
    # receive SIGPIPE and the otherwise-successful pipeline to be reported as
    # failed. Verify both the enablement path and its exact relative symlink
    # target from the already-materialized listing.
    grep -Fq \
      "etc/systemd/system/multi-user.target.wants/vanillaos-snapdragonx-oci-registry.service -> ../vanillaos-snapdragonx-oci-registry.service" \
      "$squash_listing" || \
      die "Final ISO OCI registry service is not enabled in multi-user.target."
    grep -Fq 'VANILLAOS_SNAPDRAGONX_REGISTRY_SERVICE_CLIENT_V1' \
      "$verify_dir/installer-wrapper" || \
      die "Final ISO Installer wrapper does not consume the supervised registry service."
    ! grep -Fq 'cleanup_registry' "$verify_dir/installer-wrapper" || \
      die "Final ISO Installer wrapper still owns the OCI registry process lifecycle."
    bash -n "$verify_dir/registry-service-launcher"
  fi

  extract_required_squashfs_file "$final_squash" \
    "usr/share/vanillaos-snapdragonx/profiles/$PROFILE/installer-autostart-path" \
    "$verify_dir/installer-autostart-path" \
    "Installer autostart contract marker"
  local final_autostart_path final_active_autostarts=0 final_autostart_candidate
  final_autostart_path="$(tr -d '\r\n' < "$verify_dir/installer-autostart-path")"
  for final_autostart_candidate in \
    "home/vanilla/.config/autostart/org.vanillaos.Installer.desktop" \
    "etc/xdg/autostart/vanillaos-snapdragonx-installer-$PROFILE.desktop"
  do
    local final_candidate_file="$verify_dir/autostart-$(basename "$final_autostart_candidate")"
    rm -f "$final_candidate_file"
    if unsquashfs -cat "$final_squash" "$final_autostart_candidate" \
        > "$final_candidate_file" 2>/dev/null; then
      if grep -Eq '^Exec=.*vanilla-installer' "$final_candidate_file" && \
         ! grep -Eqi '^Hidden=(true|1|yes)$' "$final_candidate_file" && \
         ! grep -Eqi '^X-GNOME-Autostart-enabled=(false|0|no)$' "$final_candidate_file"; then
        ((final_active_autostarts+=1))
      fi
    fi
  done
  if [[ "$INSTALLER_AUTOSTART" == "1" ]]; then
    (( final_active_autostarts == 1 )) || \
      die "Final ISO does not contain exactly one enabled Installer autostart."
    case "$final_autostart_path" in
      /home/vanilla/.config/autostart/org.vanillaos.Installer.desktop|\
      /etc/xdg/autostart/vanillaos-snapdragonx-installer-$PROFILE.desktop) : ;;
      *) die "Final ISO autostart marker names an unexpected path: $final_autostart_path" ;;
    esac
  else
    (( final_active_autostarts == 0 )) || \
      die "Final ISO contains an enabled Installer autostart despite profile policy."
    [[ "$final_autostart_path" == "disabled" ]] || \
      die "Final ISO autostart marker does not report disabled."
  fi

  extract_required_squashfs_file "$final_squash" \
    "usr/libexec/vanillaos-snapdragonx/storage-guard" \
    "$verify_dir/storage-guard" \
    "external storage guard"
  extract_required_squashfs_file "$final_squash" \
    "usr/libexec/vanillaos-snapdragonx/validate-installed-storage" \
    "$verify_dir/storage-validator" \
    "installed-storage validator"
  extract_required_squashfs_file "$final_squash" \
    "usr/libexec/vanillaos-snapdragonx/guarded-albius" \
    "$verify_dir/albius-wrapper" \
    "Albius guard launcher"
  grep -Fq "VANILLA_CUSTOM_RECIPE" "$verify_dir/installer-wrapper" || \
    die "Final ISO lacks the profile installer wrapper."
  grep -Fq "/usr/libexec/vanilla-installer.real" "$verify_dir/installer-wrapper" || \
    die "Final ISO profile wrapper does not invoke the private real Installer entrypoint."
  if [[ "$DELIVERY_MODE" == "iso-oci" ]]; then
    grep -Fq '"verification_mode": "metadata-head"' "$verify_dir/installer-wrapper" || \
      die "Final ISO profile wrapper lacks the bounded registry metadata probe."
    ! grep -Fq 'server_pid=' "$verify_dir/installer-wrapper" || \
      die "Final ISO profile wrapper still tracks a private registry PID."
  fi
  grep -Fq "VANILLAOS_SNAPDRAGONX_STORAGE_GUARD_V1" "$verify_dir/storage-guard" || \
    die "Final ISO lacks the external storage guard."
  grep -Fq "manual-partition-luks" "$verify_dir/storage-validator" || \
    die "Final ISO storage validator lacks manual LUKS support."
  grep -Fq "preflight_manual_device" "$verify_dir/storage-guard" || \
    die "Final ISO storage guard lacks physical manual-device preflight."
  grep -Fq "existing GPT PARTLABEL vos-var" "$verify_dir/storage-guard" || \
    die "Final ISO storage guard lacks duplicate PARTLABEL rejection."
  grep -Fq "VANILLAOS_SNAPDRAGONX_ALBIUS_STORAGE_GUARD" "$verify_dir/albius-wrapper" || \
    die "Final ISO Albius launcher does not enforce the storage guard."
  python3 "$verify_dir/storage-guard" --self-test >/dev/null || \
    die "Final ISO storage guard failed its synthetic regression suite."
  bash -n "$verify_dir/installer-dispatch" "$verify_dir/installer-wrapper" \
    "$verify_dir/storage-validator" "$verify_dir/albius-wrapper"
  extract_required_squashfs_file "$final_squash" \
    "usr/share/vanillaos-snapdragonx/profiles/$PROFILE/profile.resolved.json" \
    "$verify_dir/profile.resolved.json" \
    "resolved installer hardware profile"
  jq -e --arg profile "$PROFILE" '.profile == $profile' \
    "$verify_dir/profile.resolved.json" >/dev/null || \
    die "Final ISO embedded installer profile does not match $PROFILE."

  local el_torito="$verify_dir/el-torito.txt"
  xorriso -indev "$FINAL_ISO" -report_el_torito as_mkisofs > "$el_torito" 2>&1
  grep -Fq -- "-e '/boot/grub/efi.img'" "$el_torito" || die "Final ISO lacks the expected ARM64 El Torito EFI image."

  verify_final_live_gdm_timed_login

  sha256sum "$FINAL_ISO" > "$FINAL_ISO.sha256"
  cp -a "$TMP_ROOT/upstream-package-lists.original.before.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-package-lists.original.after.sha256" "$RELEASE_DIR/"
  if [[ "$LIVE_ARM64_PACKAGE_POLICY" == "legacy-projection" ]]; then
    cp -a "$TMP_ROOT/arm64-package-lists.derived.before.sha256" "$RELEASE_DIR/"
    cp -a "$TMP_ROOT/arm64-package-lists.derived.after.sha256" "$RELEASE_DIR/"
    cp -a "$TMP_ROOT/arm64-package-list-exclusions.tsv" "$RELEASE_DIR/"
    cp -a "$TMP_ROOT/arm64-package-list-projection.expected.tsv" "$RELEASE_DIR/"
    cp -a "$TMP_ROOT/arm64-package-list-packages.tsv" "$RELEASE_DIR/"
    [[ -n "$LIVE_PACKAGE_CANDIDATE_REPORT" && -f "$LIVE_PACKAGE_CANDIDATE_REPORT" ]] &&       cp -a "$LIVE_PACKAGE_CANDIDATE_REPORT" "$RELEASE_DIR/"
  fi
  [[ -n "$SOURCE_PROVENANCE_MANIFEST" && -f "$SOURCE_PROVENANCE_MANIFEST" ]] &&     cp -a "$SOURCE_PROVENANCE_MANIFEST" "$RELEASE_DIR/"
  [[ -n "$REUNION_CONVERGENCE_MANIFEST" && -f "$REUNION_CONVERGENCE_MANIFEST" ]] &&     cp -a "$REUNION_CONVERGENCE_MANIFEST" "$RELEASE_DIR/"
  [[ -s "$UPSTREAM_OCI_PROVENANCE_JSON" ]] && cp -a "$UPSTREAM_OCI_PROVENANCE_JSON" "$RELEASE_DIR/upstream-oci-provenance.json"
  [[ -s "$TMP_ROOT/live-builder-inspect.json" ]] && cp -a "$TMP_ROOT/live-builder-inspect.json" "$RELEASE_DIR/live-builder-inspect.json"
  [[ -s "$TMP_ROOT/vso-native-inspect.json" ]] && cp -a "$TMP_ROOT/vso-native-inspect.json" "$RELEASE_DIR/vso-native-inspect.json"
  [[ -s "$REUNION_ARCHITECTURE_NAME_AUDIT" ]] && cp -a "$REUNION_ARCHITECTURE_NAME_AUDIT" "$RELEASE_DIR/reunion-architecture-name-audit.txt"
  cp -a "$TMP_ROOT/upstream-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-remove-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/debian-package-inventory.tsv" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/kernel-package-selection.tsv" "$RELEASE_DIR/"
  cp -a "$KERNEL_PACKAGE_CLOSURE_JSON" "$RELEASE_DIR/kernel-package-closure.json"
  cp -a "$PROFILE_RESOLVED_JSON" "$RELEASE_DIR/profile.resolved.json"
  cp -a "$PROFILE_VALIDATION_REPORT" "$RELEASE_DIR/profile-validation.tsv"
  cp -a "$LIVE_KERNEL_CMDLINE_JSON" "$RELEASE_DIR/live-kernel-command-line.json"
  cp -a "$LIVE_KERNEL_CMDLINE_EVIDENCE" "$RELEASE_DIR/live-kernel-command-line-evidence.txt"
  cp -a "$ROOT_OVERLAY_INVENTORY" "$RELEASE_DIR/root-overlay-inventory.sha256"
  if [[ -d "$FIRMWARE_PROVENANCE_DIR" ]]; then
    mkdir -p "$RELEASE_DIR/firmware-provenance"
    cp -a "$FIRMWARE_PROVENANCE_DIR/." "$RELEASE_DIR/firmware-provenance/"
  fi
  cp -a "$SCRIPT_PATH" "$RELEASE_DIR/$SCRIPT_NAME"
  cp -a "$EMBEDDED_OCI_INVENTORY" "$RELEASE_DIR/embedded-image-inventory.tsv"
  cp -a "$EMBEDDED_OCI_TREE_HASH" "$RELEASE_DIR/target-image-layout.sha256"
  cp -a "$TMP_ROOT/embedded-target-image.json" "$RELEASE_DIR/"
  cp -a "$TARGET_STORAGE_HOOK_FILE" "$RELEASE_DIR/target-090-abroot-unlock-var.sh"
  cp -a "$TARGET_STORAGE_HOOK_SHA256_FILE" "$RELEASE_DIR/target-090-abroot-unlock-var.sh.sha256"
  cp -a "$TARGET_STORAGE_HOOK_EVIDENCE_JSON" "$RELEASE_DIR/target-storage-hook-evidence.json"
  cp -a "$INSTALLED_BOOT_EXPECTED_JSON" "$RELEASE_DIR/installed-boot-expected.json"
  [[ -f "$INSTALLER_PATCH_MANIFEST" ]] && cp -a "$INSTALLER_PATCH_MANIFEST" "$RELEASE_DIR/"
  [[ -f "$TMP_ROOT/installer-processor.diff" ]] && cp -a "$TMP_ROOT/installer-processor.diff" "$RELEASE_DIR/"
  [[ -f "$TMP_ROOT/installer-progress.diff" ]] && cp -a "$TMP_ROOT/installer-progress.diff" "$RELEASE_DIR/"
  [[ -n "$GRUB_PATCH_MANIFEST" && -f "$GRUB_PATCH_MANIFEST" ]] &&     cp -a "$GRUB_PATCH_MANIFEST" "$RELEASE_DIR/"
  if [[ -d "$TMP_ROOT/grub-patches" ]]; then
    mkdir -p "$RELEASE_DIR/grub-patches"
    cp -a "$TMP_ROOT/grub-patches/." "$RELEASE_DIR/grub-patches/"
  fi
  mkdir -p "$RELEASE_DIR/deb-listings"
  cp -a "$TMP_ROOT/deb-listings/." "$RELEASE_DIR/deb-listings/"
  [[ -f "$TMP_ROOT/vib-plugin-inventory.txt" ]] && cp -a "$TMP_ROOT/vib-plugin-inventory.txt" "$RELEASE_DIR/"
  [[ -f "$TMP_ROOT/vib-plugin-checksums.sha256" ]] && cp -a "$TMP_ROOT/vib-plugin-checksums.sha256" "$RELEASE_DIR/"
  printf '%s\n' "$CUSTOM_SOURCE_COMMIT" > "$RELEASE_DIR/custom-image-source.commit"
  printf '%s\n' "$LIVE_SOURCE_COMMIT" > "$RELEASE_DIR/live-iso-source.commit"

  cat > "$RELEASE_DIR/CUSTOM-TARGET-IMAGE.txt" <<EOF_TARGET
Custom VanillaOS target image
==============================
Build reference:          $TARGET_IMAGE_REF
Manifest digest:          $TARGET_IMAGE_MANIFEST_DIGEST
Storage hook evidence:    target-storage-hook-evidence.json
ABRoot image name:        $ABROOT_IMAGE_NAME
Upstream base image:      $CUSTOM_IMAGE_BASE
Upstream base digest:     $(jq -r '.inputs[] | select(.role == "target-base") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")
Local target build ref:   $TARGET_IMAGE_REF
ABRoot logical identity:  $ABROOT_IMAGE_NAME
ABRoot future locator:    $(jq -r '[(.registry // ""),(.name // ""),(.tag // "")] | join(" / ")' "$TARGET_ABROOT_CONFIG_EVIDENCE")
Installation provenance:  $(jq -r '.installation_provenance' "$TMP_ROOT/embedded-target-image.json")
Profile:                  $PROFILE
Profile display name:     $PROFILE_DISPLAY_NAME
Kernel:                   $KERNEL_RELEASE
Kernel image package:     $(package_field "$KERNEL_IMAGE_DEB" Package)=$(package_field "$KERNEL_IMAGE_DEB" Version)
Kernel image source:      $KERNEL_IMAGE_DEB
Kernel closure record:    kernel-package-closure.json
DTB:                      $DTB_NAME
Kernel command additions: ${PROFILE_KERNEL_CMDLINE_APPEND[*]:-none}
Firmware package lock:   firmware-provenance/firmware-package-lock.json
Firmware packages:       $(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")
Firmware required paths: ${PROFILE_FIRMWARE_PROBES[*]:-none}
Board-data policy:       $FIRMWARE_BOARD_POLICY
Hardware diagnostics:    /usr/libexec/vanillaos-snapdragonx/collect-hardware-diagnostics
Boot evidence:           /var/log/vanillaos-snapdragonx/current
Installer delivery:       $DELIVERY_MODE
Storage guard policy:     $INSTALLER_STORAGE_GUARD_POLICY
Manual encrypted /var:    /dev/disk/by-partlabel/vos-var
Automatic encrypted /var: /dev/mapper/vos--var-var
Storage guard report:     /tmp/vanillaos-snapdragonx-storage-guard.json
Storage validation report: /tmp/vanillaos-snapdragonx-installed-storage-validation.txt
Installer image source:   $INSTALLER_DEFAULT_IMAGE_REF
Physical bridge endpoint: http://$(local_registry_physical_prefix)
Installer transcript:     /etc/vanilla/installer.log
Persistent Albius recipe: /tmp/vanillaos-snapdragonx-albius-install-recipe.json
Root payload policy:      no project archive under /root; ABRoot /root symlink topology retained
ISO OCI layout:           $ISO_IMAGE_LAYOUT_PATH
Registry fallback:        ${REGISTRY_IMAGE_REF:-none}
Built:                    $(date -u --iso-8601=seconds)

In iso-oci mode a supervised live-system service owns the loopback registry bridge
serving the embedded OCI image layout. No external image registry is required.
EOF_TARGET

  cat > "$RELEASE_DIR/BUILD-MANIFEST.txt" <<EOF_MANIFEST
VanillaOS-SnapdragonX ARM64 build
Version:                     $SCRIPT_VERSION
Release ID:                  $RELEASE_ID
Profile:                     $PROFILE
Profile display name:        $PROFILE_DISPLAY_NAME
Profile source:              $PROFILE_FILE_SOURCE
Profile normalized:          $PROFILE_FILE_RESOLVED
Profile resolved record:     profile.resolved.json
Kernel package directory:    $KERNEL_DEB_DIR
Kernel release:              $KERNEL_RELEASE
Kernel image package:        $(package_field "$KERNEL_IMAGE_DEB" Package)=$(package_field "$KERNEL_IMAGE_DEB" Version)
Kernel image source:         $KERNEL_IMAGE_DEB
Kernel closure record:       kernel-package-closure.json
Supplied unique .debs:       ${#KERNEL_DEBS[@]}
Target-installed closure:    ${#TARGET_KERNEL_DEBS[@]}
Target-excluded .debs:       ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}
Target package archive:      retired in r5; release evidence only
Installed package receipt:   /usr/lib/vanillaos-snapdragonx/target-installed-kernel-packages.tsv
Runtime dpkg-query required: no
Live extraction closure:     ${#LIVE_KERNEL_DEBS[@]}
DTB:                         $DTB_NAME
GRUB binding evidence:       grub-patch-manifest.tsv and final-grub.cfg
Firmware source:             ${FIRMWARE_SOURCE:-none}
Firmware package lock:       firmware-provenance/firmware-package-lock.json
Firmware package count:      $(jq 'length' "$FIRMWARE_PACKAGES_RESOLVED_FILE")
Firmware required paths:     ${PROFILE_FIRMWARE_PROBES[*]:-none}
Firmware board-data policy:  $FIRMWARE_BOARD_POLICY
Kernel command additions:    ${PROFILE_KERNEL_CMDLINE_APPEND[*]:-none}
Firmware provenance:         firmware-provenance/
Legacy root-source input:    ${ROOT_SOURCE:-none} (immutable /usr/lib reference payload)
Target OCI:                  $TARGET_IMAGE_REF
Target OCI manifest digest:  $TARGET_IMAGE_MANIFEST_DIGEST
Target storage hook evidence: target-storage-hook-evidence.json
ABRoot image name:           $ABROOT_IMAGE_NAME
Installer delivery mode:     $DELIVERY_MODE
Installer storage guard:     $INSTALLER_STORAGE_GUARD_POLICY
Manual LUKS discovery path:  /dev/disk/by-partlabel/vos-var
Automatic LUKS discovery:    /dev/mapper/vos--var-var
Installer default image:     $INSTALLER_DEFAULT_IMAGE_REF
Embedded OCI layout path:    $ISO_IMAGE_LAYOUT_PATH
Embedded OCI tag:            $EMBEDDED_IMAGE_TAG
Logical registry reference:  $LOCAL_INSTALL_IMAGE_REF
Physical registry bridge:      $LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT
Registry fallback:           ${REGISTRY_IMAGE_REF:-none}
Target OCI base:             $CUSTOM_IMAGE_BASE
Target base digest:          $(jq -r '.inputs[] | select(.role == "target-base") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")
Live builder image:          $LIVE_ISO_CONTAINER_IMAGE
Live builder digest:         $(jq -r '.inputs[] | select(.role == "live-builder") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")
VSO native image:            $VSO_NATIVE_IMAGE
VSO native digest:           $(jq -r '.inputs[] | select(.role == "vso-native") | .resolved_digest' "$UPSTREAM_OCI_PROVENANCE_JSON")
VSO managed instance:        $VSO_NATIVE_INSTANCE
VSO upstream base contract:  $VSO_NATIVE_UPSTREAM_BASE
Vib version:                 $VIB_DETECTED_VERSION
FsGuard:                     absent by stable Reunion design
custom-image source ref:     $CUSTOM_IMAGE_REF
custom-image source commit:  $CUSTOM_SOURCE_COMMIT
custom-image commit date:    $(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE")
live-iso source ref:         $LIVE_ISO_REF
live-iso source commit:      $LIVE_SOURCE_COMMIT
live-iso commit date:        $(repo_commit_iso_date "$LIVE_ISO_SOURCE")
Source provenance record:    source-provenance.tsv
Reunion convergence record:  reunion-convergence.tsv
Upstream package-list suffix:$LIVE_PACKAGE_LIST_SOURCE_SUFFIX
Live ARM64 package policy:   $LIVE_ARM64_PACKAGE_POLICY
Legacy package-list suffix:  $LIVE_ARM64_PACKAGE_LIST_SUFFIX
Legacy exclusions:           $LIVE_ARM64_EXCLUDE_PACKAGES
ARM64 candidate report:      $([[ "$LIVE_ARM64_PACKAGE_POLICY" == "legacy-projection" ]] && printf package-candidates.tsv || printf not-applicable-upstream-native)
Live GDM timed-login delay:  ${LIVE_GDM_TIMED_LOGIN_DELAY}s
Target userland coherence:   target-userland-coherence.txt
Target ABRoot evidence:      target-abroot.json
Target base inspect:         target-base-inspect.json
ARM64 baseline ISO:          $UPSTREAM_ISO
Final ISO:                   $FINAL_ISO
Live package manifests:      byte-identical to accepted ARM64 baseline
Built:                       $(date -u --iso-8601=seconds)
EOF_MANIFEST

  local scope_record
  scope_record="$SCRIPT_DIR/VanillaOS-ARM64-v8.0.0-Scope-and-Acceptance.md"
  [[ -f "$scope_record" ]] && cp -a "$scope_record" "$RELEASE_DIR/"

  (
    cd "$RELEASE_DIR"
    find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
  )

  ok "Final ISO: $FINAL_ISO"
  ok "Target OCI: $TARGET_IMAGE_REF"
  ok "Embedded target digest: $TARGET_IMAGE_MANIFEST_DIGEST"
  ok "Installer default image: $INSTALLER_DEFAULT_IMAGE_REF"
  ok "Both live package manifests remained byte-identical."
}

# Fail closed if artifact generation ever omits a main-stage internal driver.
# This is intentionally pure Bash and runs before profile discovery or any host
# mutation so a structurally incomplete harness cannot enter Stage 1.
validate_internal_stage_driver_contract() {
  local fn
  local -a required=(
    preparse_profile_args
    recompute_paths
    require_root
    setup_directories
    load_hardware_profile
    parse_args
    normalize_live_arm64_package_policy
    validate_live_gdm_timed_login_settings
    write_resolved_profile
    setup_logging
    stage
    configure_repository_interactively
    print_builder_banner
    choose_repo_policy
    install_host_dependencies_safely
    check_free_space
    report_repository_plan_state
    sync_required_repositories
    configure_build_inputs_interactively
    resolve_firmware_packages
    discover_kernel_and_dtb_inputs
    print_plan
    confirm_or_abort
    reserve_release_id
    stage_firmware
    prepare_custom_image_worktree
    install_vib_and_plugins
    prepare_custom_image_project
    build_target_oci
    export_target_oci_for_installer
    prepare_arm64_live_worktree
    build_arm64_live_iso
    remaster_boot_hardware_only
    verify_final_release
  )

  for fn in "${required[@]}"; do
    if ! declare -F "$fn" >/dev/null; then
      printf 'FAIL Internal harness function contract is incomplete: %s is undefined.\n' "$fn" >&2
      return 127
    fi
  done
}

# ------------------------------- main -----------------------------------

main() {
  validate_internal_stage_driver_contract
  preparse_profile_args "$@"
  recompute_paths
  require_root
  setup_directories
  load_hardware_profile

  # Re-run the authoritative parser after profile loading so command-line
  # values override both the manifest and environment-derived defaults.
  parse_args "$@"
  recompute_paths
  setup_directories
  normalize_live_arm64_package_policy
  validate_live_gdm_timed_login_settings
  write_resolved_profile

  [[ "$INTERACTIVE_MODE" != "auto" ]] || {
    if [[ -t 0 && -t 1 ]]; then INTERACTIVE_MODE=1; else INTERACTIVE_MODE=0; fi
  }

  setup_logging

  stage "1/13 Selecting the official Git source policy"
  configure_repository_interactively

  stage "2/13 Checking host dependencies without changing initramfs implementation"
  install_host_dependencies_safely
  check_free_space

  stage "3/13 Applying and verifying the official Git source action"
  if (( PLAN_ONLY == 1 )); then
    report_repository_plan_state
  else
    sync_required_repositories
  fi

  stage "4/13 Resolving interactive build inputs and validating hardware artifacts"
  configure_build_inputs_interactively
  resolve_firmware_packages
  discover_kernel_and_dtb_inputs
  # Refresh resolved profile evidence with the deterministic discovered values.
  KERNEL_IMAGE_DEB_OVERRIDE="$KERNEL_IMAGE_DEB"
  DTB_FILE_OVERRIDE="$DTB_FILE"
  DTB_INSTALLED_NAME_OVERRIDE="$DTB_NAME"
  write_resolved_profile
  print_plan
  if (( PLAN_ONLY == 1 )); then
    ok "Plan mode complete. No repository checkout, firmware staging, OCI export, container build, or ISO build was performed."
    exit 0
  fi

  (( SOURCES_SYNCHRONIZED == 1 )) ||     die "Internal guard: execute mode reached confirmation without synchronized official sources."
  confirm_or_abort

  RELEASE_ID="$(reserve_release_id)"
  RELEASE_DIR="$RELEASES_DIR/${BUILD_DATE}-${RELEASE_ID}-${PROFILE}"
  FINAL_ISO="$RELEASE_DIR/VanillaOS-SnapdragonX-Reunion-arm64-${BUILD_DATE}-${RELEASE_ID}-${PROFILE}.iso"
  mkdir -p "$RELEASE_DIR"

  stage "5/13 Staging Qualcomm firmware without modifying the build host"
  stage_firmware

  stage "6/13 Preparing a clean custom-image worktree and resolving Vib/plugins"
  prepare_custom_image_worktree
  install_vib_and_plugins

  stage "7/13 Preparing the official custom-image-derived hardware recipe"
  prepare_custom_image_project

  stage "8/13 Building and verifying the Reunion gnome-derived target OCI"
  build_target_oci

  stage "9/13 Exporting the verified target OCI for installer delivery"
  export_target_oci_for_installer

  stage "10/13 Preparing and building an upstream-derived graphical ARM64 live ISO"
  prepare_arm64_live_worktree
  build_arm64_live_iso

  stage "11/13 Remastering boot hardware and profile-aware installer delivery"
  remaster_boot_hardware_only

  stage "12/13 Verifying package closure, embedded OCI, installer, and release artifacts"
  verify_final_release

  stage "13/13 Complete"
  cat "$RELEASE_DIR/BUILD-MANIFEST.txt"
}

# Permit the harness to be sourced by deterministic shell tests without
# launching a build. Direct execution retains the normal behavior.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
