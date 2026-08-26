#!/usr/bin/env bash
# Conception VanillaOS ARM64 Builder
# Version 8.0.3
#
# Architecture:
#   - The installed system is a Vib custom OCI image layered on
#     ghcr.io/vanilla-os/desktop:dev.
#   - The graphical installer ISO is built from a clean official live-iso
#     checkout using the proven Pico workflow.
#   - Upstream package-list source files remain byte-identical. A derived ARM64
#     projection removes only explicitly approved snapshot-incompatible x86
#     support packages; GNOME and installer package closure is preserved.
#   - The live filesystem remaster includes boot-critical hardware content plus
#     the profile-aware offline installer delivery overlay. Upstream package
#     manifests remain byte-identical to the accepted ARM64 baseline.
#
# v8.0.3 corrections after the first successful offline OCI installation
# transfer and the subsequent installed-system verification failure:
#   - Preserves image-provided content below /home, /mnt, /root, and /srv before
#     Vanilla Installer relocates those paths to /var. The stock processor
#     deleted the OCI /root payload before creating /root -> var/root, causing
#     root-overlay checksum entries to report FAILED open or read.
#   - Adds explicit installed-root migration evidence and verifies the resulting
#     /root symlink, custom package archive, user-supplied root overlay, kernel,
#     DTB, firmware, and ABRoot binding with named failure diagnostics.
#   - Makes /etc/vanilla/installer.log a real Albius transcript. The installer
#     VTE now runs Albius through root-owned bash/tee with pipefail, preserving
#     the visible console output and the actual Albius exit status.
#   - Persists the generated Albius recipe at
#     /tmp/conception-albius-install-recipe.json for deterministic diagnosis.
#   - Generates a live-system diagnostic collector at
#     /usr/local/sbin/conception-collect-installer-diagnostics.
#   - Rebuilds the profile launcher generator without the unquoted-heredoc
#     expansion defect from v8.0.1 and without the duplicated runtime body that
#     was present in the superseded v8.0.2 draft.
#   - Preserves v8.0.1 logical-to-physical registry remapping, complete OCI
#     manifest/blob self-test, hardware-profile support, and all v7 live-boot
#     kernel, firmware, DTB, graphical, and GRUB safeguards.
#
# v8.0.1 corrections after the first offline-installer field test:
#   - Separates the logical image name consumed by Albius from the physical
#     loopback endpoint. The installer now uses a port-free logical reference
#     under oci.conception.invalid, remapped by containers/image to
#     127.0.0.1:<port>.
#   - Avoids an Albius/Prometheus storage-name defect. Prometheus replaces '/'
#     but not ':' when creating its containers-storage destination name; a
#     source containing both ':<port>' and ':<tag>' therefore becomes invalid
#     after manifest discovery and before any layer blobs are requested.
#   - Keeps the bridge on loopback plaintext HTTP with an explicit insecure
#     registry rule. HTTPS ClientHello probes are expected fallback behavior and
#     are suppressed from the local bridge log.
#   - Adds a complete local bridge self-test that validates the tag manifest,
#     nested OCI indexes, config, layers, sizes, and SHA-256 digests before
#     Vanilla Installer is launched.
#   - Records both logical and physical registry references in release evidence.
#
# v8.0.0 installed-image architecture:
#   - Freezes v7.0.13 as the proven bootable live-environment milestone and
#     extends it without modifying the frozen milestone artifact.
#   - Loads hardware-specific kernel, DTB, firmware, overlay, image, installer,
#     and validation settings from a declarative JSON hardware profile. CLI and
#     environment values override the profile; ambiguous discovery fails closed.
#   - Exports the verified custom target image to an OCI image layout and embeds
#     that layout on the installation ISO beneath /target-images/<profile>/.
#   - Provides an offline loopback registry bridge over the embedded OCI layout,
#     allowing the unmodified Albius OCI pull path to consume the ISO-local image
#     without external network or registry access.
#   - Installs a profile-specific Vanilla Installer recipe and autostart wrapper.
#     The embedded hardware image is the default; IGNORE_CPU=1 is applied by the
#     wrapper and the custom-image screen remains available as an override.
#   - Patches the live installer processor so installed ABRoot state uses the
#     explicit conception kernel/DTB/profile markers rather than module-directory
#     sort order, copies the selected DTB into the A/B init-volume layout, writes
#     a DTB-aware A-state abroot.cfg, and validates installed boot artifacts.
#   - Preserves the v7.0.13 graphical closure, source provenance, ARM64 package
#     candidate preflight, Vib/FsGuard, target receipt, and live GRUB safeguards.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_VERSION="8.0.3"
SCRIPT_NAME="$(basename "$0")"

# Record whether profile-resolvable values were explicitly supplied through the
# environment. The profile loader may replace ordinary defaults, but never an
# explicit environment value. Full CLI parsing occurs after profile loading and
# therefore has the highest precedence.
ENV_PROFILE_SET="${PROFILE+x}"
ENV_ARTIFACT_DIR_SET="${ARTIFACT_DIR+x}"
ENV_KERNEL_DEB_DIR_SET="${KERNEL_DEB_DIR+x}"
ENV_ROOT_SOURCE_SET="${ROOT_SOURCE+x}"
ENV_DTB_FILE_SET="${DTB_FILE_OVERRIDE+x}"
ENV_DTB_NAME_SET="${DTB_INSTALLED_NAME_OVERRIDE+x}"
ENV_FIRMWARE_SOURCE_SET="${FIRMWARE_SOURCE_OVERRIDE+x}"
ENV_KERNEL_RELEASE_SET="${EXPECTED_CUSTOM_KERNEL_RELEASE+x}"
ENV_CUSTOM_IMAGE_BASE_SET="${CUSTOM_IMAGE_BASE+x}"
ENV_TARGET_IMAGE_SET="${TARGET_IMAGE_REF+x}"
ENV_TARGET_REPOSITORY_SET="${TARGET_IMAGE_REPOSITORY+x}"
ENV_ABROOT_IMAGE_SET="${ABROOT_IMAGE_NAME+x}"
ENV_DELIVERY_MODE_SET="${DELIVERY_MODE+x}"
ENV_REGISTRY_IMAGE_SET="${REGISTRY_IMAGE_REF+x}"
ENV_ISO_LAYOUT_PATH_SET="${ISO_IMAGE_LAYOUT_PATH+x}"
ENV_MIN_FREE_GIB_SET="${MIN_FREE_GIB+x}"

# ----------------------------- defaults ---------------------------------

WORKDIR="${WORKDIR:-$HOME/src/vanilla-arm64-build-system}"
PROFILE="${PROFILE:-hp-omnibook-5}"
PROFILE_FILE="${PROFILE_FILE:-}"
PROFILE_SCHEMA_VERSION="${PROFILE_SCHEMA_VERSION:-1}"
PROFILE_DISPLAY_NAME="${PROFILE_DISPLAY_NAME:-}"
PROFILE_ARCHITECTURE="${PROFILE_ARCHITECTURE:-arm64}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
KERNEL_DEB_DIR="${KERNEL_DEB_DIR:-}"
ROOT_SOURCE="${ROOT_SOURCE:-}"
DTB_FILE_OVERRIDE="${DTB_FILE_OVERRIDE:-}"
DTB_INSTALLED_NAME_OVERRIDE="${DTB_INSTALLED_NAME_OVERRIDE:-}"
FIRMWARE_SOURCE_OVERRIDE="${FIRMWARE_SOURCE_OVERRIDE:-}"
EXPECTED_CUSTOM_KERNEL_RELEASE="${EXPECTED_CUSTOM_KERNEL_RELEASE:-}"

CUSTOM_IMAGE_REPO_URL="${CUSTOM_IMAGE_REPO_URL:-https://github.com/Vanilla-OS/custom-image.git}"
CUSTOM_IMAGE_REF="${CUSTOM_IMAGE_REF:-main}"
CUSTOM_IMAGE_BASE="${CUSTOM_IMAGE_BASE:-ghcr.io/vanilla-os/desktop:dev}"

LIVE_ISO_REPO_URL="${LIVE_ISO_REPO_URL:-https://github.com/Vanilla-OS/live-iso.git}"
LIVE_ISO_REF="${LIVE_ISO_REF:-orchid}"
SOURCE_STALE_WARN_DAYS="${SOURCE_STALE_WARN_DAYS:-180}"
LIVE_ISO_CONTAINER_IMAGE="${LIVE_ISO_CONTAINER_IMAGE:-ghcr.io/vanilla-os/pico:dev}"
LIVE_ISO_RUNTIME="${LIVE_ISO_RUNTIME:-docker}"

# The current orchid installer list is shared with AMD64. These exact x86,
# AMD64 EFI, and unavailable VirtualBox entries are incompatible with the
# configured ARM64 snapshot. The value is intentionally
# explicit and environment-overridable; broad "remove every unavailable
# package" behavior is prohibited.
LIVE_ARM64_PACKAGE_LIST_SUFFIX="${LIVE_ARM64_PACKAGE_LIST_SUFFIX:-vanilla-installer-arm64}"
LIVE_ARM64_EXCLUDE_PACKAGES="${LIVE_ARM64_EXCLUDE_PACKAGES:-grub-efi-amd64,grub-efi-amd64-bin,grub-efi-amd64-signed,shim-helpers-amd64-signed,intel-microcode,amd64-microcode,iucode-tool,virtualbox-guest-utils,virtualbox-guest-x11}"

QCOM_UPDATER_REPO_URL="${QCOM_UPDATER_REPO_URL:-https://github.com/alejandroqh/qcom-firmware-updater.git}"
QCOM_UPDATER_REF="${QCOM_UPDATER_REF:-main}"
QCOM_DEVICE_PATH_DEFAULT="${QCOM_DEVICE_PATH_DEFAULT:-x1p42100/hp/omnibook-5}"
QCOM_DEVICE_PATH="${QCOM_DEVICE_PATH:-$QCOM_DEVICE_PATH_DEFAULT}"

OCI_RUNTIME="${OCI_RUNTIME:-podman}"
OCI_BUILD_NETWORK="${OCI_BUILD_NETWORK:-host}"
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
LOCAL_REGISTRY_LOGICAL_HOST="${LOCAL_REGISTRY_LOGICAL_HOST:-oci.conception.invalid}"
LOCAL_REGISTRY_NAMESPACE="${LOCAL_REGISTRY_NAMESPACE:-conception}"
INSTALLER_AUTOSTART="${INSTALLER_AUTOSTART:-1}"
INSTALLER_IGNORE_CPU="${INSTALLER_IGNORE_CPU:-1}"
INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE="${INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE:-1}"

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

# Discovered inputs.
declare -a KERNEL_DEBS=()
declare -a TARGET_KERNEL_DEBS=()
declare -a TARGET_EXCLUDED_KERNEL_DEBS=()
declare -a LIVE_KERNEL_DEBS=()
declare -a DTB_CANDIDATES=()
declare -a PROFILE_FIRMWARE_PROBES=()
declare -a PROFILE_INITRAMFS_PROBES=()
declare -a PROFILE_INSTALLED_PATH_PROBES=()
declare -a PROFILE_KERNEL_CMDLINE_APPEND=()
KERNEL_RELEASE=""
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
  --profile NAME                  Hardware profile identifier.
  --profile-file PATH             Hardware-profile JSON manifest.
  --artifact-dir PATH             Profile artifact directory.
  --kernel-deb-dir PATH           Kernel Debian-package directory.
  --kernel-release RELEASE        Expected exact custom kernel release.
  --dtb-file PATH                 Exact DTB source file.
  --dtb-name NAME                 Installed DTB filename.
  --root-source PATH              Directory copied into target OCI /root.
  --firmware-dir PATH             Existing firmware tree; paths relative to
                                  /usr/lib/firmware.
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
                                  oci.conception.invalid
  --live-ref REF                  live-iso branch, tag, or commit.
  --custom-image-ref REF          custom-image branch, tag, or commit.
  --push-target-image             Push target OCI after local verification.
  -h, --help                      Show this help.

Source-reference strategy:
  custom-image Git checkout: main branch
  live-iso Git checkout:     orchid branch
  target OCI base:           ghcr.io/vanilla-os/desktop:dev
  live build container:      ghcr.io/vanilla-os/pico:dev

  These repositories do not share one universal dev branch. Git branches are
  refreshed and exact commit SHAs are recorded. Vib and plugins use release
  tags. core-image and desktop-image source trees are not build inputs in this
  v7 container-base architecture.

Vib toolchain defaults:
  VIB_VERSION=1.1.0
  FSGUARD_PLUGIN_REPO=Vanilla-OS/vib-fsguard
  FSGUARD_PLUGIN_VERSION=auto     Select newest release containing the exact
                                  fsguard-<host-arch>.so asset.
  GITHUB_TOKEN=<optional>         Raise GitHub API rate limits.

ARM64 live-ISO package projection:
  LIVE_ARM64_PACKAGE_LIST_SUFFIX=vanilla-installer-arm64
  LIVE_ARM64_EXCLUDE_PACKAGES=grub-efi-amd64,grub-efi-amd64-bin,
      grub-efi-amd64-signed,shim-helpers-amd64-signed,intel-microcode,
      amd64-microcode,iucode-tool,virtualbox-guest-utils,virtualbox-guest-x11

  The canonical upstream package-lists.vanilla-installer tree is never edited.
  Only exact package lines named above are omitted from the derived ARM64 tree.
  Every remaining direct package name is candidate-checked against the selected
  ARM64 snapshot before the expensive live-build starts.

Hardware profile lookup order:
  --profile-file PATH
  WORKDIR/profiles/$PROFILE/profile.json
  WORKDIR/profiles/$PROFILE.json
  synthesized compatibility profile when neither file exists

Profile precedence:
  CLI option > environment variable > profile manifest > deterministic discovery

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

preparse_profile_args() {
  # Resolve only values required to locate the profile before applying it. The
  # complete parser runs later and retains authoritative CLI precedence.
  local -a args=("$@")
  local i=0
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --workdir)
        (( i + 1 < ${#args[@]} )) || die "--workdir requires a path"
        WORKDIR="$(normalize_path_input "${args[$((i+1))]}")"
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
      --workdir) [[ $# -ge 2 ]] || die "--workdir requires a path"; WORKDIR="$(normalize_path_input "$2")"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile requires a value"; PROFILE="$2"; PROFILE_SELECTOR_EXPLICIT=1; shift 2 ;;
      --profile-file) [[ $# -ge 2 ]] || die "--profile-file requires a path"; PROFILE_FILE="$(normalize_path_input "$2")"; shift 2 ;;
      --artifact-dir) [[ $# -ge 2 ]] || die "--artifact-dir requires a path"; ARTIFACT_DIR="$(normalize_path_input "$2")"; shift 2 ;;
      --kernel-deb-dir) [[ $# -ge 2 ]] || die "--kernel-deb-dir requires a path"; KERNEL_DEB_DIR="$(normalize_path_input "$2")"; shift 2 ;;
      --kernel-release) [[ $# -ge 2 ]] || die "--kernel-release requires a value"; EXPECTED_CUSTOM_KERNEL_RELEASE="$2"; shift 2 ;;
      --dtb-file) [[ $# -ge 2 ]] || die "--dtb-file requires a path"; DTB_FILE_OVERRIDE="$(normalize_path_input "$2")"; shift 2 ;;
      --dtb-name) [[ $# -ge 2 ]] || die "--dtb-name requires a value"; DTB_INSTALLED_NAME_OVERRIDE="$2"; shift 2 ;;
      --root-source) [[ $# -ge 2 ]] || die "--root-source requires a path"; ROOT_SOURCE="$(normalize_path_input "$2")"; shift 2 ;;
      --firmware-dir) [[ $# -ge 2 ]] || die "--firmware-dir requires a path"; FIRMWARE_SOURCE_OVERRIDE="$(normalize_path_input "$2")"; FIRMWARE_MODE="prestaged"; shift 2 ;;
      --repo-policy) [[ $# -ge 2 ]] || die "--repo-policy requires a value"; REPO_POLICY="$2"; shift 2 ;;
      --target-image) [[ $# -ge 2 ]] || die "--target-image requires a value"; TARGET_IMAGE_REF="$2"; shift 2 ;;
      --abroot-image) [[ $# -ge 2 ]] || die "--abroot-image requires a value"; ABROOT_IMAGE_NAME="$2"; shift 2 ;;
      --delivery-mode) [[ $# -ge 2 ]] || die "--delivery-mode requires iso-oci or registry"; DELIVERY_MODE="$2"; shift 2 ;;
      --registry-image) [[ $# -ge 2 ]] || die "--registry-image requires a value"; REGISTRY_IMAGE_REF="$2"; shift 2 ;;
      --iso-image-path) [[ $# -ge 2 ]] || die "--iso-image-path requires a value"; ISO_IMAGE_LAYOUT_PATH="$2"; shift 2 ;;
      --local-registry-port) [[ $# -ge 2 ]] || die "--local-registry-port requires a value"; LOCAL_REGISTRY_PORT="$2"; shift 2 ;;
      --local-registry-logical-host) [[ $# -ge 2 ]] || die "--local-registry-logical-host requires a value"; LOCAL_REGISTRY_LOGICAL_HOST="$2"; shift 2 ;;
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
  KERNEL_DEB_DIR="${KERNEL_DEB_DIR:-$ARTIFACT_DIR/kernel-debs}"
  TARGET_IMAGE_REPOSITORY="${TARGET_IMAGE_REPOSITORY:-localhost/conception/vanilla-desktop-${PROFILE}}"
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
  TMP_ROOT="$TMP_DIR/v8.0.3-${SESSION_ID}"
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

synthesize_compatibility_profile() {
  PROFILE_FILE_RESOLVED="$TMP_ROOT/profile.synthesized.json"
  jq -n \
    --arg profile "$PROFILE" \
    --arg display "$PROFILE" \
    --arg artifacts "$ARTIFACT_DIR" \
    --arg kernel_dir "$KERNEL_DEB_DIR" \
    --arg kernel_release "$EXPECTED_CUSTOM_KERNEL_RELEASE" \
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
    '{
      schema_version: 1,
      profile: $profile,
      display_name: $display,
      architecture: "arm64",
      artifacts: {
        directory: $artifacts,
        root_overlay: (if $root == "" then null else $root end)
      },
      kernel: {
        deb_directory: $kernel_dir,
        expected_release: (if $kernel_release == "" then null else $kernel_release end),
        allow_single_release_discovery: true,
        command_line_append: []
      },
      dtb: {
        source: (if $dtb == "" then null else $dtb end),
        installed_name: (if $dtb_name == "" then null else $dtb_name end)
      },
      firmware: {
        mode: (if $firmware == "" then "ask" else "prestaged" end),
        source: (if $firmware == "" then null else $firmware end),
        device_path: $qcom,
        probes: [],
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
        allow_custom_image_override: true
      },
      validation: {
        installed_paths: [],
        minimum_free_gib: $min_free
      }
    }' > "$PROFILE_FILE_RESOLVED"
  warn "No profile manifest was found. A compatibility profile was synthesized: $PROFILE_FILE_RESOLVED"
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

  schema_version="$(jq -r '.schema_version // empty' "$PROFILE_FILE_RESOLVED")"
  [[ "$schema_version" == "$PROFILE_SCHEMA_VERSION" ]] || \
    die "Unsupported hardware-profile schema version '$schema_version'; expected $PROFILE_SCHEMA_VERSION"

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
    die "v8.0.0 supports ARM64 profiles only; profile requested $PROFILE_ARCHITECTURE"

  if [[ -z "$ENV_ARTIFACT_DIR_SET" ]]; then
    value="$(jq -r '.artifacts.directory // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || ARTIFACT_DIR="$(resolve_profile_path "$value")"
  fi
  if [[ -z "$ENV_KERNEL_DEB_DIR_SET" ]]; then
    value="$(jq -r '.kernel.deb_directory // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || KERNEL_DEB_DIR="$(resolve_profile_path "$value")"
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

  if [[ -z "$ENV_MIN_FREE_GIB_SET" ]]; then
    value="$(jq -r '.validation.minimum_free_gib // empty' "$PROFILE_FILE_RESOLVED")"
    [[ -z "$value" ]] || MIN_FREE_GIB="$value"
  fi

  mapfile -t PROFILE_FIRMWARE_PROBES < <(jq -r '.firmware.probes[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_INITRAMFS_PROBES < <(jq -r '.firmware.initramfs_probes[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_INSTALLED_PATH_PROBES < <(jq -r '.validation.installed_paths[]? // empty' "$PROFILE_FILE_RESOLVED")
  mapfile -t PROFILE_KERNEL_CMDLINE_APPEND < <(jq -r '.kernel.command_line_append[]? // empty' "$PROFILE_FILE_RESOLVED")

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

  ok "Loaded hardware profile: $PROFILE_DISPLAY_NAME ($PROFILE)"
  info "Profile manifest: $PROFILE_FILE_RESOLVED"
}

write_resolved_profile() {
  local firmware_json initramfs_json installed_json cmdline_json
  firmware_json="$(printf '%s\n' "${PROFILE_FIRMWARE_PROBES[@]}" | jq -Rsc 'split("\\n") | map(select(length > 0))')"
  initramfs_json="$(printf '%s\n' "${PROFILE_INITRAMFS_PROBES[@]}" | jq -Rsc 'split("\\n") | map(select(length > 0))')"
  installed_json="$(printf '%s\n' "${PROFILE_INSTALLED_PATH_PROBES[@]}" | jq -Rsc 'split("\\n") | map(select(length > 0))')"
  cmdline_json="$(printf '%s\n' "${PROFILE_KERNEL_CMDLINE_APPEND[@]}" | jq -Rsc 'split("\\n") | map(select(length > 0))')"

  jq -n \
    --argjson schema "$PROFILE_SCHEMA_VERSION" \
    --arg profile "$PROFILE" \
    --arg display "$PROFILE_DISPLAY_NAME" \
    --arg architecture "$PROFILE_ARCHITECTURE" \
    --arg source_profile "$PROFILE_FILE_RESOLVED" \
    --arg artifact_dir "$ARTIFACT_DIR" \
    --arg kernel_dir "$KERNEL_DEB_DIR" \
    --arg kernel_release "$EXPECTED_CUSTOM_KERNEL_RELEASE" \
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
    --arg registry "$REGISTRY_IMAGE_REF" \
    --argjson autostart "$INSTALLER_AUTOSTART" \
    --argjson ignore_cpu "$INSTALLER_IGNORE_CPU" \
    --argjson allow_custom "$INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE" \
    --argjson min_free "$MIN_FREE_GIB" \
    --argjson firmware_probes "$firmware_json" \
    --argjson initramfs_probes "$initramfs_json" \
    --argjson installed_paths "$installed_json" \
    --argjson cmdline "$cmdline_json" \
    '{
      schema_version: $schema,
      profile: $profile,
      display_name: $display,
      architecture: $architecture,
      source_profile: $source_profile,
      resolved: {
        artifact_directory: $artifact_dir,
        kernel_deb_directory: $kernel_dir,
        expected_kernel_release: (if $kernel_release == "" then null else $kernel_release end),
        dtb_source: (if $dtb_source == "" then null else $dtb_source end),
        dtb_installed_name: (if $dtb_name == "" then null else $dtb_name end),
        root_overlay: (if $root_source == "" then null else $root_source end),
        firmware_mode: $firmware_mode,
        firmware_source: (if $firmware_source == "" then null else $firmware_source end),
        firmware_device_path: $device_path,
        firmware_probes: $firmware_probes,
        initramfs_probes: $initramfs_probes,
        kernel_command_line_append: $cmdline,
        target_base: $base,
        target_image: $target_ref,
        abroot_image: $abroot,
        iso_layout_path: $iso_path,
        delivery_mode: $delivery,
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
    printf 'dtb_source\t%s\t%s\n' "$([[ -n "$DTB_FILE_OVERRIDE" ]] && printf resolved || printf discovery)" "${DTB_FILE_OVERRIDE:-deterministic discovery}"
    printf 'delivery_mode\tpass\t%s\n' "$DELIVERY_MODE"
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
Profile:          $PROFILE ($PROFILE_DISPLAY_NAME)
Profile file:     $PROFILE_FILE_RESOLVED
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
    find "$KERNEL_DEB_DIR" "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null |
      sort -u
  )
  ((${#KERNEL_DEBS[@]} > 0)) || die "No .deb files found in $KERNEL_DEB_DIR or $ARTIFACT_DIR."

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

  DTB_NAME="${DTB_INSTALLED_NAME_OVERRIDE:-$(basename "$DTB_FILE")}"
  [[ "$DTB_NAME" != */* && -n "$DTB_NAME" ]] || die "Installed DTB name must be a basename: $DTB_NAME"
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

repo_ref_kind() {
  local path="$1" ref="$2"
  if git -C "$path" show-ref --verify --quiet "refs/heads/$ref" ||
     git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    printf 'branch'
  elif git -C "$path" show-ref --verify --quiet "refs/tags/$ref"; then
    printf 'tag'
  elif git -C "$path" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    printf 'commit'
  else
    printf 'unresolved'
  fi
}

repo_commit_iso_date() {
  local path="$1"
  git -C "$path" show -s --format=%cI HEAD 2>/dev/null || printf 'unknown'
}

repo_commit_age_days() {
  local path="$1"
  local commit_epoch now_epoch
  commit_epoch="$(git -C "$path" show -s --format=%ct HEAD 2>/dev/null || true)"
  [[ "$commit_epoch" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  now_epoch="$(date -u +%s)"
  printf '%s' "$(( (now_epoch - commit_epoch) / 86400 ))"
}

repo_exact_tags() {
  local path="$1"
  local tags
  tags="$(git -C "$path" tag --points-at HEAD 2>/dev/null | LC_ALL=C sort | paste -sd, - || true)"
  printf '%s' "${tags:-none}"
}

write_source_provenance_manifest() {
  SOURCE_PROVENANCE_MANIFEST="$TMP_ROOT/source-provenance.tsv"
  {
    printf 'role\trepository\trequested_ref\tref_kind\tcommit\tcommit_date_utc\tage_days\texact_tags\tcheckout\tbuild_use\n'
    printf 'custom-image\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$CUSTOM_IMAGE_REPO_URL" "$CUSTOM_IMAGE_REF" \
      "$(repo_ref_kind "$CUSTOM_IMAGE_SOURCE" "$CUSTOM_IMAGE_REF")" \
      "$CUSTOM_SOURCE_COMMIT" "$(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE")" \
      "$(repo_commit_age_days "$CUSTOM_IMAGE_SOURCE")" \
      "$(repo_exact_tags "$CUSTOM_IMAGE_SOURCE")" "$CUSTOM_IMAGE_SOURCE" \
      "template for generated custom target recipe"
    printf 'live-iso\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$LIVE_ISO_REPO_URL" "$LIVE_ISO_REF" \
      "$(repo_ref_kind "$LIVE_ISO_SOURCE" "$LIVE_ISO_REF")" \
      "$LIVE_SOURCE_COMMIT" "$(repo_commit_iso_date "$LIVE_ISO_SOURCE")" \
      "$(repo_commit_age_days "$LIVE_ISO_SOURCE")" \
      "$(repo_exact_tags "$LIVE_ISO_SOURCE")" "$LIVE_ISO_SOURCE" \
      "installer ISO source"
  } > "$SOURCE_PROVENANCE_MANIFEST"
}

report_source_provenance() {
  local custom_age live_age
  custom_age="$(repo_commit_age_days "$CUSTOM_IMAGE_SOURCE")"
  live_age="$(repo_commit_age_days "$LIVE_ISO_SOURCE")"

  info "Source-reference strategy:"
  info "  custom-image: ref=$CUSTOM_IMAGE_REF kind=$(repo_ref_kind "$CUSTOM_IMAGE_SOURCE" "$CUSTOM_IMAGE_REF") commit=$(git -C "$CUSTOM_IMAGE_SOURCE" rev-parse --short HEAD) date=$(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE") age=${custom_age}d tags=$(repo_exact_tags "$CUSTOM_IMAGE_SOURCE")"
  info "  live-iso:     ref=$LIVE_ISO_REF kind=$(repo_ref_kind "$LIVE_ISO_SOURCE" "$LIVE_ISO_REF") commit=$(git -C "$LIVE_ISO_SOURCE" rev-parse --short HEAD) date=$(repo_commit_iso_date "$LIVE_ISO_SOURCE") age=${live_age}d tags=$(repo_exact_tags "$LIVE_ISO_SOURCE")"
  info "  target base:  $CUSTOM_IMAGE_BASE"
  info "  live builder: $LIVE_ISO_CONTAINER_IMAGE"

  if [[ "$live_age" =~ ^[0-9]+$ ]] && (( live_age > SOURCE_STALE_WARN_DAYS )); then
    warn "live-iso is older than ${SOURCE_STALE_WARN_DAYS} days. This is the refreshed upstream '$LIVE_ISO_REF' state, not a failed Git update."
  fi
  if [[ "$custom_age" =~ ^[0-9]+$ ]] && (( custom_age > SOURCE_STALE_WARN_DAYS )); then
    warn "custom-image is older than ${SOURCE_STALE_WARN_DAYS} days."
  fi
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
  write_source_provenance_manifest
  report_source_provenance
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
custom-image commit date:   $(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE")
live-iso source:            $LIVE_ISO_REPO_URL @ $LIVE_ISO_REF
live-iso checkout:          $(source_checkout_summary "$LIVE_ISO_SOURCE")
live-iso commit date:       $(repo_commit_iso_date "$LIVE_ISO_SOURCE")
core-image source role:     not cloned; consumed through published OCI lineage
desktop-image source role:  not cloned; target uses $CUSTOM_IMAGE_BASE
qcom updater checkout:      $(source_checkout_summary "$QCOM_UPDATER_DIR")
Target OCI base:            $CUSTOM_IMAGE_BASE
Target OCI reference:       $TARGET_IMAGE_REF
ABRoot image name:          $ABROOT_IMAGE_NAME
Installer delivery:        $DELIVERY_MODE
ISO OCI layout path:       $ISO_IMAGE_LAYOUT_PATH
Logical registry host:      $LOCAL_REGISTRY_LOGICAL_HOST
Physical registry endpoint: $LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT
Registry fallback:         ${REGISTRY_IMAGE_REF:-none}
Profile manifest:          $PROFILE_FILE_RESOLVED
Kernel package directory:  $KERNEL_DEB_DIR
Push target OCI:            $PUSH_TARGET_IMAGE
Pico image:                 $LIVE_ISO_CONTAINER_IMAGE
ARM64 package-list suffix:  $LIVE_ARM64_PACKAGE_LIST_SUFFIX
ARM64 package exclusions:   $LIVE_ARM64_EXCLUDE_PACKAGES
Requested Vib version:      $VIB_VERSION
FsGuard plugin request:     $FSGUARD_PLUGIN_REPO @ $FSGUARD_PLUGIN_VERSION
Expected release ID:        $preview_id
Minimum graphical packages: $MIN_GRAPHICAL_PACKAGE_COUNT

Safety invariants:
  - No host initramfs implementation is installed or replaced.
  - dpkg-deb archive listings complete before any grep validation.
  - Only named boot packages or packages with regular kernel/module objects
    enter target or live package transactions.
  - Package registration is attested during the unlocked build stage; the final
    immutable target is not expected to retain apt, dpkg, or dpkg-query.
  - /lib/modules/<release>/build and source symlinks never qualify as modules.
  - Optional tools, headers, development, and metadata .debs are reference-only.
  - Official live package-list source files remain byte-identical.
  - The derived ARM64 list may omit only explicitly approved x86 support
    packages; no GNOME, installer, shim-signed, or efibootmgr package may be removed.
  - Every remaining direct package name is candidate-checked against the exact
    ARM64 snapshot before the expensive live-build begins.
  - The upstream-derived ARM64 graphical manifest is accepted before remastering.
  - Final filesystem.packages and filesystem.packages-remove are byte-identical
    to the accepted ARM64 baseline ISO.
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
    "$TMP_ROOT/target-installed-kernel-packages.actual.tsv" \
    "$TMP_ROOT/target-installed-package-expectations.tsv" \
    "$SOURCE_PROVENANCE_MANIFEST" \
    "$LIVE_PACKAGE_LIST_PACKAGE_INVENTORY" \
    "$LIVE_PACKAGE_CANDIDATE_REPORT" \
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

generate_root_overlay_inventory() {
  : > "$ROOT_OVERLAY_INVENTORY"
  [[ -n "$ROOT_SOURCE" ]] || return 0
  [[ -d "$ROOT_SOURCE" ]] || die "Root overlay source is not a directory: $ROOT_SOURCE"

  while IFS= read -r -d '' file; do
    local rel hash
    rel="${file#"$ROOT_SOURCE"/}"
    hash="$(sha256sum "$file" | awk '{print $1}')"
    printf '%s  /root/%s\n' "$hash" "$rel" >> "$ROOT_OVERLAY_INVENTORY"
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
    "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/root" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/includes.container/usr/share/conception/profiles/$PROFILE" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/conception"

  mkdir -p \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/root/custom-kernel-packages" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/root" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/includes.container/usr/local/sbin" \
    "$CUSTOM_PROJECT/includes.container/usr/share/conception/profiles/$PROFILE" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/conception" \
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

  generate_root_overlay_inventory
  cp -a "$PROFILE_RESOLVED_JSON"     "$CUSTOM_PROJECT/includes.container/usr/share/conception/profiles/$PROFILE/profile.resolved.json"
  cp -a "$PROFILE_VALIDATION_REPORT"     "$CUSTOM_PROJECT/includes.container/usr/share/conception/profiles/$PROFILE/profile-validation.tsv"
  cp -a "$ROOT_OVERLAY_INVENTORY"     "$CUSTOM_PROJECT/includes.container/usr/lib/conception/root-overlay.sha256"

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

# Only the boot-critical image/module closure is staged here. Optional headers,
# tools, development packages, and metadata are archived under
# /root/custom-kernel-packages and never enter this APT transaction.
printf 'Installing selected boot-critical local packages:\n'
printf '  %s\n' "${packages[@]}"
apt-get install -y "${packages[@]}"

# VanillaOS locks the package layer later in the recipe. Package-manager
# executables therefore cannot be assumed to exist in the finished image.
# Verify the transaction now, while dpkg-query is available, and persist an
# immutable receipt for post-build verification.
receipt_dir=/usr/lib/conception
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

  cat > "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-hardware-finalize" <<EOF_FINALIZE
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
printf '%s\n' "\$release" > /usr/lib/conception-kernel-release
printf '%s\n' "\$dtb" > /usr/lib/conception-dtb
printf '%s\n' "\$profile" > /usr/lib/conception-profile
printf '%s\n' "\${cmdline_append[@]}" > /usr/lib/conception-kernel-command-line
for probe in "\${firmware_probes[@]}"; do
  [[ -e "/usr/lib/firmware/\$probe" || -e "/lib/firmware/\$probe" ]] || {
    echo "Missing profile firmware probe: \$probe" >&2
    exit 91
  }
done
EOF_FINALIZE
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-hardware-finalize"

  cat > "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-verify-installed-boot" <<EOF_INSTALLED_VERIFY
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
  printf 'CONCEPTION INSTALLED-BOOT VERIFY FAILED: %s\n' "\$*" >&2
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

profile="\$(read_required_marker /usr/lib/conception-profile profile 101)"
release="\$(read_required_marker /usr/lib/conception-kernel-release kernel 102)"
dtb="\$(read_required_marker /usr/lib/conception-dtb DTB 103)"

[[ "\$profile" == "\$expected_profile" ]] || \
  fail_verify 104 "Profile mismatch: expected=\$expected_profile installed=\$profile"
[[ "\$release" == "\$expected_release" ]] || \
  fail_verify 105 "Kernel mismatch: expected=\$expected_release installed=\$release"
[[ "\$dtb" == "\$expected_dtb" ]] || \
  fail_verify 106 "DTB mismatch: expected=\$expected_dtb installed=\$dtb"

[[ -r /usr/lib/conception-kernel-command-line ]] || \
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

for argument in "\${cmdline_append[@]}"; do
  [[ -n "\$argument" ]] || continue
  grep -Fq -- "\$argument" "\$cfg" || \
    fail_verify 120 "ABRoot config lacks required kernel argument: \$argument"
done

for probe in "\${firmware_probes[@]}"; do
  [[ -e "/usr/lib/firmware/\$probe" || -e "/lib/firmware/\$probe" ]] || \
    fail_verify 121 "Installed firmware probe is missing: \$probe"
done

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
  /usr/lib/conception/relocated-var-payload.status \
  "relocated payload status" 126
require_nonempty_file \
  /root/custom-kernel-packages/PACKAGE-SELECTION.tsv \
  "preserved custom-kernel package selection archive" 127

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
if [[ -s /usr/lib/conception/root-overlay.sha256 ]]; then
  checksum_output="\$(mktemp)"
  if ! sha256sum -c /usr/lib/conception/root-overlay.sha256 \
      > "\$checksum_output" 2>&1; then
    cat "\$checksum_output" >&2 || true
    rm -f "\$checksum_output"
    fail_verify 131 \
      "Root overlay checksum validation failed after Vanilla /root relocation"
  fi
  cat "\$checksum_output"
  rm -f "\$checksum_output"
  root_overlay_status="pass"
fi

mkdir -p /usr/lib/conception
{
  printf 'check\tstatus\tdetail\n'
  printf 'profile\tpass\t%s\n' "\$profile"
  printf 'kernel\tpass\t%s\n' "\$release"
  printf 'dtb\tpass\t%s\n' "\$dtb"
  printf 'abroot_a\tpass\t%s\n' "\$cfg"
  printf 'initramfs\tpass\t%s\n' "\$state/initrd.img-\$release"
  printf 'root_relocation\tpass\t%s\n' "\$root_link"
  printf 'root_overlay\t%s\t%s\n' "\$root_overlay_status" \
    /usr/lib/conception/root-overlay.sha256
  printf 'package_archive\tpass\t%s\n' \
    /root/custom-kernel-packages/PACKAGE-SELECTION.tsv
} > /usr/lib/conception/installed-boot-validation.tsv

printf 'Conception installed-boot verification passed for profile %s.\n' "\$profile"
EOF_INSTALLED_VERIFY
  chmod 0755 "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-verify-installed-boot"

  bash -n "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-hardware-finalize"
  bash -n "$CUSTOM_PROJECT/includes.container/usr/local/sbin/conception-verify-installed-boot"

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
      conception.profile-schema: "$PROFILE_SCHEMA_VERSION"
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
    info "The target OCI reference is local-only; v8 will embed and serve it from the ISO in iso-oci mode."
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
expected_archive_count="$6"
expected_package_file="$7"
expected_profile="$8"

receipt=/usr/lib/conception/target-installed-kernel-packages.tsv
receipt_checksum=/usr/lib/conception/target-installed-kernel-packages.tsv.sha256

test -s "/boot/vmlinuz-$release"
test -d "/usr/lib/modules/$release" || test -d "/lib/modules/$release"
test -e "/boot/initrd.img-$release"
test "$(readlink -f /vmlinuz)" = "/boot/vmlinuz-$release"
test "$(readlink -f /initrd.img)" = "/boot/initrd.img-$release"
test -s "/boot/dtbs/$dtb"
grep -Fxq "$release" /usr/lib/conception-kernel-release
grep -Fxq "$dtb" /usr/lib/conception-dtb
grep -Fxq "$expected_profile" /usr/lib/conception-profile
test -f /usr/lib/conception-kernel-command-line
grep -Fq "$abroot_name" /usr/share/abroot/abroot.json

# The official custom-image cleanup locks the package layer before FsGuard.
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

test -s /root/custom-kernel-packages/PACKAGE-SELECTION.tsv
test -s /root/custom-kernel-packages/README.txt
actual_archive_count="$(
  find /root/custom-kernel-packages -maxdepth 1 -type f -name '*.deb' |
    wc -l |
    tr -d '[:space:]'
)"
[[ "$actual_archive_count" == "$expected_archive_count" ]] || {
  echo "Archived package count mismatch: expected=$expected_archive_count actual=$actual_archive_count" >&2
  exit 1
}

if [[ -n "$firmware_probe" ]]; then
  test -s "/usr/lib/firmware/$firmware_probe" || test -s "/lib/firmware/$firmware_probe"
fi
if [[ -n "$root_probe" ]]; then
  test -e "/root/$root_probe"
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
    "$FIRMWARE_PROBE_REL" "$ROOT_PROBE_REL" "${#KERNEL_DEBS[@]}" \
    /expected-target-packages.tsv "$PROFILE"

  # Export the exact receipt from the verified image into release evidence.
  "$OCI_RUNTIME" run --rm \
    --entrypoint /bin/cat \
    "$TARGET_IMAGE_REF" \
    /usr/lib/conception/target-installed-kernel-packages.tsv \
    > "$actual_receipt"
  [[ -s "$actual_receipt" ]] || die "Unable to export the target installed-package receipt."

  cp -a "$actual_receipt" "$RELEASE_DIR/target-installed-kernel-packages.tsv"
  cp -a "$expected_packages" "$RELEASE_DIR/target-installed-package-expectations.tsv"

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

  jq -n \
    --arg profile "$PROFILE" \
    --arg tag "$EMBEDDED_IMAGE_TAG" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg layout "$ISO_IMAGE_LAYOUT_PATH" \
    --arg local_ref "$LOCAL_INSTALL_IMAGE_REF" \
    --arg physical_ref "$(local_registry_physical_prefix):$EMBEDDED_IMAGE_TAG" \
    --arg installer_ref "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg delivery "$DELIVERY_MODE" \
    --arg kernel "$KERNEL_RELEASE" \
    --arg dtb "$DTB_NAME" \
    '{profile:$profile, tag:$tag, manifest_digest:$digest, iso_layout_path:$layout,
      local_registry_reference:$local_ref,
      physical_registry_reference:$physical_ref,
      installer_reference:$installer_ref,
      delivery_mode:$delivery, kernel_release:$kernel, dtb:$dtb}' \
    > "$TMP_ROOT/embedded-target-image.json"

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

prepare_arm64_live_worktree() {
  rm -rf "$LIVE_BUILD_DIR"
  git -C "$LIVE_ISO_SOURCE" worktree add --detach "$LIVE_BUILD_DIR" "$LIVE_SOURCE_COMMIT"

  local conf="$LIVE_BUILD_DIR/etc/terraform.conf"
  local build="$LIVE_BUILD_DIR/build.sh"
  [[ -f "$conf" && -f "$build" ]] || die "Official live-iso build inputs are missing."

  sed -i -E 's/^ARCH=.*/ARCH="arm64"/' "$conf"
  grep -q '^ARCH="arm64"$' "$conf" || die "Unable to select ARM64 in terraform.conf."

  prepare_arm64_package_list_projection "$conf"
  preflight_arm64_package_candidates "$conf"

  # The official orchid build script still hard-codes the final AMD64 output
  # source path. This replacement happens after lb build and cannot alter the
  # package closure or live filesystem content.
  if grep -Fq 'tmp/amd64/live-image-amd64.hybrid.iso' "$build"; then
    sed -i \
      's#tmp/amd64/live-image-amd64\.hybrid\.iso#tmp/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso#' \
      "$build"
  fi

  local changed unexpected untracked unexpected_untracked
  changed="$(git -C "$LIVE_BUILD_DIR" diff --name-only)"
  unexpected="$(
    printf '%s\n' "$changed" |
      grep -Ev '^(build\.sh|etc/terraform\.conf)$' || true
  )"
  [[ -z "$unexpected" ]] || \
    die "Refusing tracked live-iso source modifications outside build.sh and terraform.conf: $unexpected"

  untracked="$(git -C "$LIVE_BUILD_DIR" ls-files --others --exclude-standard)"
  unexpected_untracked="$(
    printf '%s\n' "$untracked" |
      grep -Ev "^etc/config/package-lists\\.${LIVE_ARM64_PACKAGE_LIST_SUFFIX}/" || true
  )"
  [[ -z "$unexpected_untracked" ]] || \
    die "Refusing unexpected untracked live-iso build files: $unexpected_untracked"

  ok "Upstream-derived ARM64 live-iso worktree prepared at commit $LIVE_SOURCE_COMMIT."
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
    /bin/bash -s etc/terraform.conf < build.sh \
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

  verify_arm64_package_list_projection_after_build
  verify_arm64_graphical_iso
}


extract_iso_file() {
  local iso="$1" iso_path="$2" destination="$3"
  rm -f "$destination"
  xorriso -osirrox on -indev "$iso" -extract "$iso_path" "$destination" >/dev/null 2>&1
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

  python3 - "$file" "$release" "$dtb" <<'VERIFY_GRUB_BINDINGS_PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
release = sys.argv[2]
dtb = sys.argv[3]
data = path.read_text(encoding="utf-8", errors="strict")

target_kernel = f"/live/vmlinuz-{release}"
target_initrd = f"/live/initrd.img-{release}"
target_dtb = f"/boot/dtbs/{dtb}"

entry_start = re.compile(r'menuentry\s+(["\'])(.*?)\1\s*\{', re.S)
linux_line = re.compile(
    r"(?m)^[ \t]*linux(?:efi)?[ \t]+(?P<kernel>[^\s;{}]+)(?:[ \t]+.*)?$"
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
  # The official orchid template uses:
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
  python3 - "$file" "$temporary" "$metadata" "$KERNEL_RELEASE" "$DTB_NAME" <<'PATCH_GRUB_PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
metadata = Path(sys.argv[3])
release = sys.argv[4]
dtb = sys.argv[5]

data = source.read_text(encoding="utf-8", errors="strict")
target_kernel = f"/live/vmlinuz-{release}"
target_initrd = f"/live/initrd.img-{release}"
target_dtb = f"/boot/dtbs/{dtb}"
marker = "CONCEPTION_ARM64_DTB_MANAGED"

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

    replacement_linux = (
        f"{linux_match.group('indent')}"
        f"{linux_match.group('command')}"
        f"{linux_match.group('separator')}"
        f"{target_kernel}"
        f"{linux_match.group('rest')}"
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
    server_version = "ConceptionOCIRegistry/1.1"

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
marker = "CONCEPTION_V8_PROFILE_INSTALLER_PATCH"
if marker in data:
    raise SystemExit("processor already contains the v8 patch marker")

installation_anchor = '''        # Installation
        recipe.set_installation("oci", oci_image)
'''
installation_replacement = '''        # Installation
        # CONCEPTION_V8_PROFILE_INSTALLER_PATCH
        abroot_image = sys_recipe.get("conception_abroot_image", oci_image)
        expected_image_digest = sys_recipe.get("conception_embedded_digest", "")
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
                    "mkdir -p /mnt/a/usr/lib/conception",
                    "printf '%s\\n' 'complete' > /mnt/a/usr/lib/conception/relocated-var-payload.status",
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
    "KERNEL_VERSION=$(cat /mnt/a/usr/lib/conception-kernel-release)"
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
                        f"""KERNEL_VERSION=$(cat /mnt/a/usr/lib/conception-kernel-release) && \
                        DTB_NAME=$(cat /mnt/a/usr/lib/conception-dtb) && \
                        PROFILE_NAME=$(cat /mnt/a/usr/lib/conception-profile) && \
                        KERNEL_CMDLINE=$(tr '\\n' ' ' < /mnt/a/usr/lib/conception-kernel-command-line) && \
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
                "/usr/local/sbin/conception-verify-installed-boot",
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
        persistent_recipe = "/tmp/conception-albius-install-recipe.json"
        with open(persistent_recipe, "w", encoding="utf-8") as evidence:
            evidence.write(serialized_recipe)
            evidence.write("\\n")
            evidence.flush()
        os.chmod(persistent_recipe, 0o600)

        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(serialized_recipe)
            f.flush()
            f.close()

            # setting the file executable
            os.chmod(f.name, 0o755)

            return f.name
'''
if recipe_anchor not in data:
    raise SystemExit("unable to locate temporary Albius recipe anchor")
data = data.replace(recipe_anchor, recipe_replacement, 1)

processor_path.write_text(data, encoding="utf-8")

progress = progress_path.read_text(encoding="utf-8")
progress_marker = "CONCEPTION_V8_ALBIUS_LOG_CAPTURE"
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
spawn_replacement = '''        # CONCEPTION_V8_ALBIUS_LOG_CAPTURE
        log_path = self.__window.recipe.get(
            "log_file", "/tmp/vanilla_installer.log"
        )
        command = (
            'log_path="$2"; '
            'install -d -m 0755 "$(dirname "$log_path")"; '
            'printf "%s\\\\n" "# Vanilla Installer Log" '
            '"Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$log_path"; '
            'albius "$1" 2>&1 | tee -a "$log_path"'
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
                "conception-albius",
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
  grep -Fq "conception-albius-install-recipe.json" "$processor" || \
    die "Patched installer processor lacks persistent recipe evidence."
  grep -Fq "CONCEPTION_V8_ALBIUS_LOG_CAPTURE" "$progress" || \
    die "Patched installer progress view lacks Albius log capture."

  ok "Patched Vanilla Installer processor and VTE logging for profile installation."
}
install_profile_aware_installer_overlay() {
  local root="$1"
  local recipe_source="$root/etc/vanilla-installer/recipe.json"
  local profile_dir="$root/etc/vanilla-installer/profiles/$PROFILE"
  local recipe_target="$profile_dir/recipe.json"
  local wrapper="$root/usr/local/libexec/conception-installer-$PROFILE"
  local registry_server="$root/usr/local/libexec/conception-oci-registry.py"
  local collector="$root/usr/local/sbin/conception-collect-installer-diagnostics"
  local desktop="$root/etc/xdg/autostart/conception-installer-$PROFILE.desktop"
  local app="$root/usr/share/applications/conception-installer-$PROFILE.desktop"

  [[ -s "$recipe_source" ]] || \
    die "Live filesystem lacks Vanilla Installer recipe.json."

  mkdir -p "$profile_dir" "$root/usr/local/libexec" \
    "$root/usr/local/sbin" \
    "$root/etc/xdg/autostart" "$root/usr/share/applications" \
    "$root/etc/containers/registries.conf.d" \
    "$root/usr/share/conception/profiles/$PROFILE"

  jq \
    --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    --arg abroot "$ABROOT_IMAGE_NAME" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg delivery "$DELIVERY_MODE" \
    --arg allow_custom "$INSTALLER_ALLOW_CUSTOM_IMAGE_OVERRIDE" \
    '.images.default = $image
     | .images.nvidia = $image
     | .images.vm = $image
     | .conception_profile = $profile
     | .conception_abroot_image = $abroot
     | .conception_embedded_digest = $digest
     | .conception_delivery_mode = $delivery
     | if $delivery == "iso-oci" then del(.steps["conn-check"]) else . end
     | if $allow_custom == "1" then . else del(.steps["image"]) end' \
    "$recipe_source" > "$recipe_target"

  cp -a "$PROFILE_RESOLVED_JSON" \
    "$root/usr/share/conception/profiles/$PROFILE/profile.resolved.json"
  cp -a "$TMP_ROOT/embedded-target-image.json" \
    "$root/usr/share/conception/profiles/$PROFILE/embedded-target-image.json"

  write_local_oci_registry_server "$registry_server"

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
server_pid=""
wrapper_log=/tmp/conception-installer-wrapper.log
EOF_INSTALLER_WRAPPER_HEADER

  cat >> "$wrapper" <<'EOF_INSTALLER_WRAPPER_RUNTIME'

exec > >(tee -a "$wrapper_log") 2>&1
printf '\n=== Conception profile installer started: %s ===\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Profile: %s\n' "$profile"
printf 'Delivery: %s\n' "$delivery"

cleanup_registry() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_registry EXIT INT TERM

if [[ "$delivery" == "iso-oci" ]]; then
  medium=""
  for candidate in /run/live/medium /cdrom /run/media/*/* /media/*/*; do
    [[ -d "$candidate" ]] || continue
    if [[ -s "$candidate/${layout_path#/}/oci-layout" ]]; then
      medium="$candidate"
      break
    fi
  done

  [[ -n "$medium" ]] || {
    echo "Unable to locate embedded target OCI layout: $layout_path" >&2
    exit 70
  }

  layout="$medium/${layout_path#/}"
  python3 /usr/local/libexec/conception-oci-registry.py \
    --layout "$layout" --tag "$tag" --repository "$repository" \
    --host "$host" --port "$port" \
    > /tmp/conception-local-registry.log 2>&1 &
  server_pid=$!

  python3 - "$host" "$port" "$repository" "$tag" "$expected_digest" <<'PY_VERIFY_REGISTRY'
from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.request

host, port, repository, tag, expected_digest = sys.argv[1:]
base = f"http://{host}:{port}"
seen_manifests: set[str] = set()
seen_blobs: set[str] = set()

accept = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

def request(path: str):
    req = urllib.request.Request(base + path, method="GET")
    req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.headers, response.read()

for attempt in range(100):
    try:
        request("/v2/")
        break
    except Exception:
        if attempt == 99:
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

def fetch_blob(descriptor: dict) -> None:
    digest = descriptor["digest"]
    if digest in seen_blobs:
        return
    _headers, raw = request(f"/v2/{repository}/blobs/{digest}")
    verify_digest(raw, digest, f"blob {digest}")
    expected_size = descriptor.get("size")
    if expected_size is not None and len(raw) != expected_size:
        raise SystemExit(
            f"blob {digest}: expected size {expected_size}, received {len(raw)}"
        )
    seen_blobs.add(digest)

def fetch_manifest(reference: str, expected: str | None = None) -> str:
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
            fetch_manifest(child, child)
        return digest

    config = document.get("config")
    layers = document.get("layers", [])
    if not config or not layers:
        raise SystemExit(f"image manifest {digest} lacks config or layers")
    fetch_blob(config)
    for descriptor in layers:
        fetch_blob(descriptor)
    return digest

actual_digest = fetch_manifest(tag, expected_digest)
summary = {
    "physical_endpoint": base,
    "repository": repository,
    "tag": tag,
    "expected_digest": expected_digest,
    "actual_digest": actual_digest,
    "manifests_verified": len(seen_manifests),
    "blobs_verified": len(seen_blobs),
}
with open(
    "/tmp/conception-local-registry-selftest.json", "w", encoding="utf-8"
) as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")

print(
    f"Local OCI bridge verified: manifests={len(seen_manifests)} "
    f"blobs={len(seen_blobs)} digest={actual_digest}"
)
PY_VERIFY_REGISTRY

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
vanilla-installer "$@"
rc=$?
set -e
printf 'Vanilla Installer exited with status %s\n' "$rc"
exit "$rc"
EOF_INSTALLER_WRAPPER_END
  chmod 0755 "$wrapper"

  cat > "$collector" <<'EOF_INSTALLER_COLLECTOR'
#!/usr/bin/env bash
set -Eeuo pipefail

stamp="$(date -u +%Y%m%d-%H%M%S)"
name="conception-installer-diagnostics-$stamp"
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
copy_if_present /tmp/conception-installer-wrapper.log
copy_if_present /tmp/conception-local-registry.log
copy_if_present /tmp/conception-local-registry-selftest.json
copy_if_present /tmp/conception-albius-install-recipe.json
copy_if_present /etc/containers/registries.conf.d/90-conception-local.conf
copy_if_present /usr/share/conception profiles

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
    /mnt/a/usr/lib/conception-profile \
    /mnt/a/usr/lib/conception-kernel-release \
    /mnt/a/usr/lib/conception-dtb \
    /mnt/a/usr/lib/conception-kernel-command-line \
    /mnt/a/usr/lib/conception/relocated-var-payload.status \
    /mnt/a/usr/lib/conception/installed-boot-validation.tsv
  do
    echo
    echo "--- $path"
    stat "$path" 2>&1 || true
    if [[ -f "$path" ]]; then
      cat "$path" 2>&1 || true
    fi
  done

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

journalctl -b --no-pager > "$work/journal.txt" 2>/dev/null || true
tar -czf "$archive" -C /tmp "$name"
printf 'Diagnostic archive: %s\n' "$archive"
ls -lh "$archive"
sha256sum "$archive"
EOF_INSTALLER_COLLECTOR
  chmod 0755 "$collector"

  cat > "$root/etc/containers/registries.conf.d/90-conception-local.conf" <<EOF_REGISTRY_CONF
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
Exec=/usr/local/libexec/conception-installer-$PROFILE
Icon=org.vanillaos.Installer
Terminal=false
Categories=System;
EOF_INSTALLER_DESKTOP

  cp -a "$app" "$desktop"
  if [[ "$INSTALLER_AUTOSTART" != "1" ]]; then
    printf 'X-GNOME-Autostart-enabled=false\n' >> "$desktop"
  else
    printf 'X-GNOME-Autostart-enabled=true\n' >> "$desktop"
  fi

  bash -n "$wrapper"
  bash -n "$collector"

  grep -Fqx "prefix = \"$(local_registry_logical_prefix)\"" \
    "$root/etc/containers/registries.conf.d/90-conception-local.conf" || \
    die "Generated registry remapping lacks its logical prefix."
  grep -Fqx "location = \"$(local_registry_physical_prefix)\"" \
    "$root/etc/containers/registries.conf.d/90-conception-local.conf" || \
    die "Generated registry remapping lacks its physical endpoint."
  validate_prometheus_storage_reference_compatibility \
    "$INSTALLER_DEFAULT_IMAGE_REF"

  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg profile "$PROFILE" \
    '.images.default == $image and .conception_profile == $profile' \
    "$recipe_target" >/dev/null || \
    die "Generated profile-specific Vanilla Installer recipe failed validation."

  patch_vanilla_installer_processor "$root"

  jq -n \
    --arg profile "$PROFILE" \
    --arg release "$KERNEL_RELEASE" \
    --arg dtb "$DTB_NAME" \
    --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    --arg digest "$TARGET_IMAGE_MANIFEST_DIGEST" \
    --arg cfg "/boot/init/vos-a/abroot.cfg" \
    '{profile:$profile,kernel_release:$release,dtb:$dtb,
      installer_image:$image,manifest_digest:$digest,
      abroot_a_config:$cfg,
      installer_log:"/etc/vanilla/installer.log",
      persistent_recipe:"/tmp/conception-albius-install-recipe.json",
      diagnostics_collector:"/usr/local/sbin/conception-collect-installer-diagnostics",
      required_markers:[
        "/usr/lib/conception-profile",
        "/usr/lib/conception-kernel-release",
        "/usr/lib/conception-dtb",
        "/usr/lib/conception/relocated-var-payload.status"
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
  cp -a "$TMP_ROOT/embedded-target-image.json" "$embedded_dest/CONCEPTION-IMAGE.json"
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

  ok "Validated $grub_live_entries live GRUB menuentry binding(s) before ISO creation."

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
  if [[ -n "$FIRMWARE_PROBE_REL" ]]; then
    grep -Fq "usr/lib/firmware/$FIRMWARE_PROBE_REL" "$squash_listing" || \
      die "Final squashfs lacks firmware probe: $FIRMWARE_PROBE_REL"
  fi

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

  # Verify the profile-specific recipe and installer patch inside squashfs.
  unsquashfs -cat "$final_squash" \
    "etc/vanilla-installer/profiles/$PROFILE/recipe.json" \
    > "$verify_dir/installer-recipe.json"
  jq -e --arg image "$INSTALLER_DEFAULT_IMAGE_REF" \
    '.images.default == $image' "$verify_dir/installer-recipe.json" >/dev/null || \
    die "Final ISO installer recipe does not default to the resolved profile image."
  unsquashfs -cat "$final_squash" \
    "usr/local/libexec/conception-installer-$PROFILE" \
    > "$verify_dir/installer-wrapper"
  grep -Fq "VANILLA_CUSTOM_RECIPE" "$verify_dir/installer-wrapper" || \
    die "Final ISO lacks the profile installer wrapper."
  unsquashfs -cat "$final_squash" \
    "usr/share/conception/profiles/$PROFILE/profile.resolved.json" \
    > "$verify_dir/profile.resolved.json"
  jq -e --arg profile "$PROFILE" '.profile == $profile' \
    "$verify_dir/profile.resolved.json" >/dev/null || \
    die "Final ISO embedded installer profile does not match $PROFILE."

  local el_torito="$verify_dir/el-torito.txt"
  xorriso -indev "$FINAL_ISO" -report_el_torito as_mkisofs > "$el_torito" 2>&1
  grep -Fq -- "-e '/boot/grub/efi.img'" "$el_torito" || die "Final ISO lacks the expected ARM64 El Torito EFI image."

  sha256sum "$FINAL_ISO" > "$FINAL_ISO.sha256"
  cp -a "$TMP_ROOT/upstream-package-lists.original.before.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-package-lists.original.after.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/arm64-package-lists.derived.before.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/arm64-package-lists.derived.after.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/arm64-package-list-exclusions.tsv" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/arm64-package-list-projection.expected.tsv" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/arm64-package-list-packages.tsv" "$RELEASE_DIR/"
  [[ -n "$LIVE_PACKAGE_CANDIDATE_REPORT" && -f "$LIVE_PACKAGE_CANDIDATE_REPORT" ]] &&     cp -a "$LIVE_PACKAGE_CANDIDATE_REPORT" "$RELEASE_DIR/"
  [[ -n "$SOURCE_PROVENANCE_MANIFEST" && -f "$SOURCE_PROVENANCE_MANIFEST" ]] &&     cp -a "$SOURCE_PROVENANCE_MANIFEST" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-remove-manifest.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/debian-package-inventory.tsv" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/kernel-package-selection.tsv" "$RELEASE_DIR/"
  cp -a "$PROFILE_RESOLVED_JSON" "$RELEASE_DIR/profile.resolved.json"
  cp -a "$PROFILE_VALIDATION_REPORT" "$RELEASE_DIR/profile-validation.tsv"
  cp -a "$ROOT_OVERLAY_INVENTORY" "$RELEASE_DIR/root-overlay-inventory.sha256"
  cp -a "$EMBEDDED_OCI_INVENTORY" "$RELEASE_DIR/embedded-image-inventory.tsv"
  cp -a "$EMBEDDED_OCI_TREE_HASH" "$RELEASE_DIR/target-image-layout.sha256"
  cp -a "$TMP_ROOT/embedded-target-image.json" "$RELEASE_DIR/"
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
  [[ -n "$FSGUARD_PLUGIN_RELEASE_METADATA" && -f "$FSGUARD_PLUGIN_RELEASE_METADATA" ]] && \
    cp -a "$FSGUARD_PLUGIN_RELEASE_METADATA" "$RELEASE_DIR/"
  printf '%s\n' "$CUSTOM_SOURCE_COMMIT" > "$RELEASE_DIR/custom-image-source.commit"
  printf '%s\n' "$LIVE_SOURCE_COMMIT" > "$RELEASE_DIR/live-iso-source.commit"

  cat > "$RELEASE_DIR/CUSTOM-TARGET-IMAGE.txt" <<EOF_TARGET
Custom VanillaOS target image
==============================
Build reference:          $TARGET_IMAGE_REF
Manifest digest:          $TARGET_IMAGE_MANIFEST_DIGEST
ABRoot image name:        $ABROOT_IMAGE_NAME
Base image:               $CUSTOM_IMAGE_BASE
Profile:                  $PROFILE
Profile display name:     $PROFILE_DISPLAY_NAME
Kernel:                   $KERNEL_RELEASE
DTB:                      $DTB_NAME
Installer delivery:       $DELIVERY_MODE
Installer image source:   $INSTALLER_DEFAULT_IMAGE_REF
Physical bridge endpoint: http://$(local_registry_physical_prefix)
Installer transcript:     /etc/vanilla/installer.log
Persistent Albius recipe: /tmp/conception-albius-install-recipe.json
Root payload migration:   OCI /home,/mnt,/root,/srv -> installed /var paths
ISO OCI layout:           $ISO_IMAGE_LAYOUT_PATH
Registry fallback:        ${REGISTRY_IMAGE_REF:-none}
Built:                    $(date -u --iso-8601=seconds)

In iso-oci mode the installer wrapper starts a loopback-only registry bridge
serving the embedded OCI image layout. No external image registry is required.
EOF_TARGET

  cat > "$RELEASE_DIR/BUILD-MANIFEST.txt" <<EOF_MANIFEST
Conception VanillaOS ARM64 build
Version:                     $SCRIPT_VERSION
Release ID:                  $RELEASE_ID
Profile:                     $PROFILE
Profile display name:        $PROFILE_DISPLAY_NAME
Profile source:              $PROFILE_FILE_RESOLVED
Profile resolved record:     profile.resolved.json
Kernel package directory:    $KERNEL_DEB_DIR
Kernel release:              $KERNEL_RELEASE
Supplied kernel .debs:       ${#KERNEL_DEBS[@]}
Target-installed .debs:      ${#TARGET_KERNEL_DEBS[@]}
Target-excluded .debs:       ${#TARGET_EXCLUDED_KERNEL_DEBS[@]}
Target archive location:     /root/custom-kernel-packages
Installed package receipt:   /usr/lib/conception/target-installed-kernel-packages.tsv
Runtime dpkg-query required: no
Live boot .debs:             ${#LIVE_KERNEL_DEBS[@]}
DTB:                         $DTB_NAME
GRUB binding evidence:       grub-patch-manifest.tsv and final-grub.cfg
Firmware source:             ${FIRMWARE_SOURCE:-none}
Target /root source:         ${ROOT_SOURCE:-none}
Target OCI:                  $TARGET_IMAGE_REF
Target OCI manifest digest:  $TARGET_IMAGE_MANIFEST_DIGEST
ABRoot image name:           $ABROOT_IMAGE_NAME
Installer delivery mode:     $DELIVERY_MODE
Installer default image:     $INSTALLER_DEFAULT_IMAGE_REF
Embedded OCI layout path:    $ISO_IMAGE_LAYOUT_PATH
Embedded OCI tag:            $EMBEDDED_IMAGE_TAG
Logical registry reference:  $LOCAL_INSTALL_IMAGE_REF
Physical registry bridge:      $LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT
Registry fallback:           ${REGISTRY_IMAGE_REF:-none}
Target OCI base:             $CUSTOM_IMAGE_BASE
Vib version:                 $VIB_DETECTED_VERSION
FsGuard plugin:              $FSGUARD_PLUGIN_REPO @ $FSGUARD_PLUGIN_RESOLVED_TAG
custom-image source ref:     $CUSTOM_IMAGE_REF
custom-image source commit:  $CUSTOM_SOURCE_COMMIT
custom-image commit date:    $(repo_commit_iso_date "$CUSTOM_IMAGE_SOURCE")
live-iso source ref:         $LIVE_ISO_REF
live-iso source commit:      $LIVE_SOURCE_COMMIT
live-iso commit date:        $(repo_commit_iso_date "$LIVE_ISO_SOURCE")
Source provenance record:    source-provenance.tsv
Upstream package-list suffix:$LIVE_PACKAGE_LIST_SOURCE_SUFFIX
ARM64 package-list suffix:   $LIVE_ARM64_PACKAGE_LIST_SUFFIX
ARM64 exclusions:            $LIVE_ARM64_EXCLUDE_PACKAGES
ARM64 candidate report:      package-candidates.tsv
ARM64 baseline ISO:          $UPSTREAM_ISO
Final ISO:                   $FINAL_ISO
Live package manifests:      byte-identical to accepted ARM64 baseline
Built:                       $(date -u --iso-8601=seconds)
EOF_MANIFEST

  local scope_record
  scope_record="$(dirname "$(readlink -f "$0")")/VanillaOS-ARM64-v8.0.0-Scope-and-Acceptance.md"
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

# ------------------------------- main -----------------------------------

main() {
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
  discover_kernel_and_dtb_inputs
  # Refresh resolved profile evidence with the deterministic discovered values.
  EXPECTED_CUSTOM_KERNEL_RELEASE="$KERNEL_RELEASE"
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
  FINAL_ISO="$RELEASE_DIR/Conception-VanillaOS-Orchid-arm64-${BUILD_DATE}-${RELEASE_ID}-${PROFILE}.iso"
  mkdir -p "$RELEASE_DIR"

  stage "5/13 Staging Qualcomm firmware without modifying the build host"
  stage_firmware

  stage "6/13 Preparing a clean custom-image worktree and resolving Vib/plugins"
  prepare_custom_image_worktree
  install_vib_and_plugins

  stage "7/13 Preparing the official custom-image-derived hardware recipe"
  prepare_custom_image_project

  stage "8/13 Building and verifying the desktop:dev-derived target OCI"
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

main "$@"
