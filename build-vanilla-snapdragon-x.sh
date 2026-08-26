#!/usr/bin/env bash
# build-vanilla-arm64-release-v2.3.2.sh
#
# Constructive Vanilla ARM64 Release Builder
# Version: 2.3.2
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

SCRIPT_VERSION="2.3.2"
SCRIPT_NAME="$(basename "$0")"

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
  printf '\n%s[Stage %s of %s]%s %s\n' "$C_BOLD" "$n" "$total" "$C_RESET" "$msg" >&2
}

hr() { printf '%s\n' '==================================================================' >&2; }

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
  printf '  sudo apt install -y git curl ca-certificates gawk coreutils findutils tar python3 podman docker.io xorriso genisoimage jq file rsync squashfs-tools gnupg zstd\n\n' >&2
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
  $path" "2" \
    "1|Continue using the existing checkout|No network activity." \
    "2|Refresh from Git (git pull)|Retrieve the latest commits from the configured branch." \
    "3|Re-clone repository|Delete the local checkout and perform a fresh clone." \
    "4|Open an interactive shell here|Make manual changes, then exit the shell to resume." \
    "5|Skip this repository|Continue with remaining repositories." \
    "6|Quit the builder|Exit immediately."
}

sync_repo() {
  local name="$1" url="$2" branch="$3" path="$4"
  mkdir -p "$(dirname "$path")"

  if [[ -d "$path/.git" ]]; then
    local choice
    choice="$(repo_action "$name" "$path")"
    case "$choice" in
      1) ok "Using existing checkout for $name." ;;
      2)
        info "Refreshing $name."
        git -C "$path" fetch --all --prune
        git -C "$path" checkout "$branch"
        git -C "$path" pull --ff-only
        ;;
      3)
        warn "Re-cloning $name."
        rm -rf "$path"
        git clone -b "$branch" "$url" "$path"
        ;;
      4) open_shell "$path"; sync_repo "$name" "$url" "$branch" "$path" ;;
      5) warn "Skipping $name."; return 0 ;;
      6) exit 0 ;;
    esac
  else
    info "Cloning $name from $url branch $branch."
    git clone -b "$branch" "$url" "$path"
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
        cp -a "$QCOM_ARCHIVE" "$work/input/driver$(basename "$QCOM_ARCHIVE" | sed 's/.*\(\.zip\|\.exe\)$/\1/I')"
      fi

      # This container deliberately acts as the disposable "host".
      # If the updater writes to /lib/firmware, it writes inside the container.
      # We then copy the resulting firmware tree out of the mounted /out path
      # where possible. This may need future updater-specific refinement.
      local run_script="$work/run-qcom-extract.sh"
      cat >"$run_script" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
apt update
apt install -y curl ca-certificates unzip p7zip-full zstd rsync bash coreutils findutils
mkdir -p /out/lib/firmware /work
cp -a /updater /work/qcom-firmware-updater
cd /work/qcom-firmware-updater

echo "Running qcom-firmware-updater in disposable container."
echo "No firmware will be installed on the build host."

if [[ -n "${QCOM_URL:-}" ]]; then
  bash ./qcom-firmware-updater.sh --url "$QCOM_URL" "$QCOM_DEVICE_PATH" || true
elif compgen -G "/input/*" >/dev/null; then
  # Updater CLI may change. Try the local archive path first, then open a shell-like diagnostic if it fails.
  local_file="$(find /input -maxdepth 1 -type f | head -n1)"
  bash ./qcom-firmware-updater.sh "$local_file" "$QCOM_DEVICE_PATH" || true
fi

# Capture any firmware that was installed inside the disposable container.
if [[ -d /lib/firmware ]]; then
  rsync -a /lib/firmware/ /out/lib/firmware/
fi
EOS
      chmod +x "$run_script"

      podman run --rm --privileged \
        -e QCOM_URL="${QCOM_URL:-}" \
        -e QCOM_DEVICE_PATH="$QCOM_DEVICE_PATH" \
        -v "$updater_dir:/updater:ro" \
        -v "$work/input:/input:ro" \
        -v "$work/out:/out" \
        -v "$run_script:/run-qcom-extract.sh:ro" \
        debian:13 \
        /bin/bash /run-qcom-extract.sh || warn "Containerized qcom extraction returned non-zero."

      if [[ -d "$work/out/lib/firmware" ]]; then
        rsync -a "$work/out/lib/firmware"/ "$STAGED_QCOM_DIR"/
      fi

      if ! find "$STAGED_QCOM_DIR" -type f | grep -q .; then
        warn "No Qualcomm firmware files were captured."
        warn "Open the temporary directory to inspect updater behavior if needed: $work"
        local c
        c="$(menu "Qualcomm Firmware Capture Empty" "1" \
          "1|Continue without staged Qualcomm firmware|Build will proceed, but target may lack required firmware." \
          "2|Open shell to inspect extraction workspace|Inspect files, copy staged firmware manually, then resume." \
          "3|Abort build|Stop immediately.")"
        case "$c" in
          1) ;;
          2) open_shell "$work"; rsync -a "$work/out/lib/firmware"/ "$STAGED_QCOM_DIR"/ 2>/dev/null || true ;;
          3) die "Qualcomm firmware staging failed." ;;
        esac
      fi
      ;;
  esac
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
    mkdir -p "$live/etc/config/includes.chroot/opt/vendor-kernel" \
             "$live/etc/config/includes.chroot/boot/dtbs" \
             "$live/etc/config/includes.binary/boot/dtbs" \
             "$live/etc/config/includes.chroot/root"
    for f in "${KERNEL_DEBS[@]:-}"; do cp -a "$f" "$live/etc/config/includes.chroot/opt/vendor-kernel/"; done
    for f in "${DTB_FILES[@]:-}"; do
      cp -a "$f" "$live/etc/config/includes.chroot/boot/dtbs/"
      cp -a "$f" "$live/etc/config/includes.binary/boot/dtbs/"
    done
    if [[ -d "$ROOT_OVERLAY_DIR" ]]; then
      rsync -a "$ROOT_OVERLAY_DIR"/ "$live/etc/config/includes.chroot/root"/
    fi
    if [[ -d "$STAGED_QCOM_DIR" ]] && find "$STAGED_QCOM_DIR" -type f | grep -q .; then
      mkdir -p "$live/etc/config/includes.chroot/lib/firmware"
      rsync -a "$STAGED_QCOM_DIR"/ "$live/etc/config/includes.chroot/lib/firmware"/
    fi

    mkdir -p "$live/etc/config/hooks/live"
    cat >"$live/etc/config/hooks/live/010-custom-arm64-kernel.chroot" <<'EOF'
#!/bin/sh
set -eu
if ls /opt/vendor-kernel/*.deb >/dev/null 2>&1; then
  dpkg -i /opt/vendor-kernel/*.deb || apt -f install -y
fi
mkdir -p /boot/dtbs
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -c -k all || update-initramfs -u -k all || true
fi
if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
fi
EOF
    chmod +x "$live/etc/config/hooks/live/010-custom-arm64-kernel.chroot"

    # Generated GRUB fragment; actual inclusion depends on live-iso layout.
    if [[ -n "${PRIMARY_DTB:-}" ]]; then
      mkdir -p "$live/etc/config/includes.binary/boot/grub"
      local dtb_name
      dtb_name="$(basename "$PRIMARY_DTB")"
      {
        printf '# Generated by %s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '# Review live-iso GRUB inclusion rules. This fragment demonstrates required DTB loading.\n'
        printf 'menuentry "Vanilla OS ARM64 - Custom DTB (%s)" {\n' "$dtb_name"
        printf '    linux /live/vmlinuz boot=live components quiet splash\n'
        printf '    initrd /live/initrd.img\n'
        printf '    devicetree /boot/dtbs/%s\n' "$dtb_name"
        printf '}\n'
      } >"$live/etc/config/includes.binary/boot/grub/custom-dtb.cfg"
    fi
  fi
}

# ------------------------------- build --------------------------------

build_images() {
  local core="$SOURCES_DIR/core-image"
  local desktop="$SOURCES_DIR/desktop-image"
  if [[ -d "$core" ]]; then
    info "Building core image with Vib."
    (cd "$core" && vib build recipe.yml)
    (cd "$core" && podman image build -t "local/vanilla-core:$PROFILE-$BUILD_DATE" .)
  fi
  if [[ -d "$desktop" ]]; then
    info "Building desktop image with Vib."
    (cd "$desktop" && vib build recipe.yml)
    (cd "$desktop" && podman image build -t "local/vanilla-desktop:$PROFILE-$BUILD_DATE" .)
  fi
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
  [[ -d "$live" ]] || die "live-iso source missing."
  patch_live_conf
  info "Building live ISO."
  (cd "$live" && docker run --privileged -i -v /proc:/proc \
    -v "$PWD":/working_dir \
    -w /working_dir \
    ghcr.io/vanilla-os/pico:main \
    /bin/bash -s etc/terraform.conf < build.sh)
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

EOF

stage 1 11 "Checking host dependencies."
check_dependencies

stage 2 11 "Refreshing source repositories."
sync_repo "pico-image" "$PICO_REPO_URL" "$PICO_BRANCH" "$SOURCES_DIR/pico-image"
sync_repo "core-image" "$CORE_REPO_URL" "$CORE_BRANCH" "$SOURCES_DIR/core-image"
sync_repo "desktop-image" "$DESKTOP_REPO_URL" "$DESKTOP_BRANCH" "$SOURCES_DIR/desktop-image"
sync_repo "live-iso" "$LIVE_REPO_URL" "$LIVE_BRANCH" "$SOURCES_DIR/live-iso"

stage 3 11 "Validating local kernel and DTB artifacts."
validate_artifacts

stage 4 11 "Configuring Qualcomm firmware staging."
configure_qcom_firmware

stage 5 11 "Staging Qualcomm firmware without modifying build host."
stage_qcom_firmware

stage 6 11 "Preparing build summary."
release_id="$(next_release_id)"
release_dir_preview="$RELEASES_DIR/${BUILD_DATE}-${release_id}-${PROFILE}"
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
