#!/usr/bin/env bash
# Conception VanillaOS ARM64 Builder
# Version 7.0.0
#
# Architectural model:
#   1. Build the installed target as a Vib custom OCI image based on
#      ghcr.io/vanilla-os/desktop:dev.
#   2. Build the graphical installer ISO from a pristine official live-iso
#      checkout using the proven Pico invocation.
#   3. Do not add, remove, or replace the upstream live graphical package lists.
#   4. After the upstream ISO is complete, remaster only its boot-critical
#      hardware payload: kernel, modules, initramfs, DTB, firmware, and GRUB.
#
# This is intentionally not a continuation of the v6 package-list approach.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_VERSION="7.0.0"
SCRIPT_NAME="$(basename "$0")"

WORKDIR="${WORKDIR:-$HOME/src/vanilla-arm64-build-system}"
PROFILE="${PROFILE:-hp-omnibook-5}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$WORKDIR/artifacts/$PROFILE}"

CUSTOM_IMAGE_REPO_URL="${CUSTOM_IMAGE_REPO_URL:-https://github.com/Vanilla-OS/custom-image.git}"
CUSTOM_IMAGE_REF="${CUSTOM_IMAGE_REF:-main}"
CUSTOM_IMAGE_BASE="${CUSTOM_IMAGE_BASE:-ghcr.io/vanilla-os/desktop:dev}"

LIVE_ISO_REPO_URL="${LIVE_ISO_REPO_URL:-https://github.com/Vanilla-OS/live-iso.git}"
LIVE_ISO_REF="${LIVE_ISO_REF:-orchid}"
LIVE_ISO_CONTAINER_IMAGE="${LIVE_ISO_CONTAINER_IMAGE:-ghcr.io/vanilla-os/pico:dev}"
LIVE_ISO_RUNTIME="${LIVE_ISO_RUNTIME:-docker}"

OCI_RUNTIME="${OCI_RUNTIME:-podman}"
TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-localhost/conception/vanilla-desktop-${PROFILE}:$(date -u +%Y%m%d)}"
PUSH_TARGET_IMAGE="${PUSH_TARGET_IMAGE:-0}"

VIB_VERSION="${VIB_VERSION:-latest}"
VIB_BIN="${VIB_BIN:-$WORKDIR/tools/vib}"
VIB_PLUGIN_DIR="${VIB_PLUGIN_DIR:-$WORKDIR/tools/vib-plugins}"

BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%d-%H%M%S)}"
OUTPUT_DIR="$WORKDIR/output"
RELEASE_DIR="$OUTPUT_DIR/releases/${BUILD_ID}-${PROFILE}"
LOG_DIR="$OUTPUT_DIR/logs"
TMP_ROOT="$WORKDIR/tmp/v7-${BUILD_ID}"
SOURCES_DIR="$WORKDIR/sources"
CUSTOM_PROJECT="$SOURCES_DIR/custom-image-${PROFILE}"
LIVE_ISO_DIR="$SOURCES_DIR/live-iso-v7"
UPSTREAM_ISO=""
FINAL_ISO="$RELEASE_DIR/Conception-VanillaOS-Orchid-arm64-${BUILD_ID}-${PROFILE}.iso"

PLAN_ONLY=0
KEEP_TMP=0

CURRENT_STAGE="initialization"
CURRENT_LOG=""

usage() {
  cat <<EOF
Usage:
  sudo $SCRIPT_NAME [--plan] [--execute] [--keep-tmp]

Environment variables:
  WORKDIR              Build-system root. Default: $WORKDIR
  PROFILE              Hardware profile. Default: $PROFILE
  ARTIFACT_DIR         Input directory. Default: $ARTIFACT_DIR
  TARGET_IMAGE_REF     Custom target OCI reference.
                       Default: $TARGET_IMAGE_REF
  PUSH_TARGET_IMAGE    1 to push TARGET_IMAGE_REF after local build.
  LIVE_ISO_REF         Exact live-iso branch, tag, or commit. Default: $LIVE_ISO_REF
  CUSTOM_IMAGE_REF     custom-image branch, tag, or commit. Default: $CUSTOM_IMAGE_REF
  OCI_RUNTIME          podman or docker. Default: $OCI_RUNTIME
  LIVE_ISO_RUNTIME     Runtime used for Pico. Default: $LIVE_ISO_RUNTIME

Required artifact layout:
  $ARTIFACT_DIR/
  ├── kernel-debs/
  │   ├── linux-image-<release>_*.deb
  │   └── linux-modules-<release>_*.deb
  ├── dtb/
  │   └── x1p42100-hp-omnibook-5.dtb
  ├── firmware/
  │   └── qcom/...                    # paths relative to /usr/lib/firmware
  └── root/                           # optional; copied into /root in target OCI
      └── ...

Compatibility discovery:
  Kernel .deb files placed directly in $ARTIFACT_DIR are also detected.
  A .dtb placed directly in $ARTIFACT_DIR is also detected.
  Existing firmware trees under firmware/, qcom/, or usr/lib/firmware/ are detected.

Examples:
  sudo $SCRIPT_NAME --plan
  sudo TARGET_IMAGE_REF=ghcr.io/example/conception-omnibook5:dev \
       PUSH_TARGET_IMAGE=1 $SCRIPT_NAME --execute
EOF
}

log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
ok()   { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }

stage() {
  CURRENT_STAGE="$1"
  printf '\n[%s]\n' "$CURRENT_STAGE"
}

on_error() {
  local rc=$?
  fail "Unexpected failure during: $CURRENT_STAGE"
  fail "Line: ${BASH_LINENO[0]:-unknown}; exit status: $rc"
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    fail "Last 80 log lines: $CURRENT_LOG"
    tail -n 80 "$CURRENT_LOG" >&2 || true
  fi
  exit "$rc"
}
trap on_error ERR

cleanup() {
  if (( KEEP_TMP == 0 )); then
    rm -rf "$TMP_ROOT" 2>/dev/null || true
  else
    warn "Temporary work retained: $TMP_ROOT"
  fi
}
trap cleanup EXIT

run_logged() {
  local name="$1"; shift
  CURRENT_LOG="$LOG_DIR/${BUILD_ID}-${name}.log"
  mkdir -p "$LOG_DIR"
  info "Log: $CURRENT_LOG"
  "$@" 2>&1 | tee "$CURRENT_LOG"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root so chroot, mounts, package installation, and ISO remastering are deterministic."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

install_host_dependencies() {
  local required=(
    git curl ca-certificates jq rsync findutils coreutils grep sed gawk
    dpkg-deb xorriso unsquashfs mksquashfs cpio gzip zstd sha256sum
    mount umount chroot depmod update-initramfs
  )
  local missing=()
  local cmd
  for cmd in "${required[@]}"; do
    require_cmd "$cmd" || missing+=("$cmd")
  done

  require_cmd "$OCI_RUNTIME" || missing+=("$OCI_RUNTIME")
  require_cmd "$LIVE_ISO_RUNTIME" || missing+=("$LIVE_ISO_RUNTIME")

  if ((${#missing[@]} == 0)); then
    ok "Required host commands are available."
    return
  fi

  require_cmd apt || die "Missing commands: ${missing[*]}; apt is not available for installation."
  info "Installing required host packages with apt."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    git curl ca-certificates jq rsync findutils coreutils grep sed gawk \
    dpkg-dev xorriso squashfs-tools cpio gzip zstd kmod initramfs-tools \
    util-linux podman docker.io
}

fresh_checkout() {
  local url="$1" ref="$2" dst="$3"
  rm -rf "$dst"
  git clone --filter=blob:none "$url" "$dst"
  git -C "$dst" fetch --tags --force origin
  git -C "$dst" checkout --detach "$ref" 2>/dev/null || {
    git -C "$dst" fetch origin "$ref"
    git -C "$dst" checkout --detach FETCH_HEAD
  }
  git -C "$dst" reset --hard
  git -C "$dst" clean -ffdqx
}

discover_inputs() {
  KERNEL_DEBS=()
  DTB_FILE=""
  FIRMWARE_SOURCE=""
  ROOT_SOURCE=""

  local candidates=()
  candidates+=("$ARTIFACT_DIR"/kernel-debs/*.deb)
  candidates+=("$ARTIFACT_DIR"/*.deb)
  local f
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && KERNEL_DEBS+=("$f")
  done
  ((${#KERNEL_DEBS[@]} > 0)) || die "No kernel-related .deb files found under $ARTIFACT_DIR/kernel-debs or $ARTIFACT_DIR."

  local dtbs=("$ARTIFACT_DIR"/dtb/*.dtb "$ARTIFACT_DIR"/*.dtb)
  for f in "${dtbs[@]}"; do
    [[ -f "$f" ]] || continue
    [[ -z "$DTB_FILE" ]] || die "Multiple DTB files found; retain exactly one selected target DTB."
    DTB_FILE="$f"
  done
  [[ -n "$DTB_FILE" ]] || die "No DTB found under $ARTIFACT_DIR/dtb or $ARTIFACT_DIR."

  if [[ -d "$ARTIFACT_DIR/firmware" ]]; then
    FIRMWARE_SOURCE="$ARTIFACT_DIR/firmware"
  elif [[ -d "$ARTIFACT_DIR/usr/lib/firmware" ]]; then
    FIRMWARE_SOURCE="$ARTIFACT_DIR/usr/lib/firmware"
  elif [[ -d "$ARTIFACT_DIR/qcom" ]]; then
    FIRMWARE_SOURCE="$ARTIFACT_DIR"
  else
    die "No firmware source found. Use $ARTIFACT_DIR/firmware with paths relative to /usr/lib/firmware."
  fi

  [[ -d "$ARTIFACT_DIR/root" ]] && ROOT_SOURCE="$ARTIFACT_DIR/root"

  local releases=()
  local deb path rel
  for deb in "${KERNEL_DEBS[@]}"; do
    while IFS= read -r path; do
      case "$path" in
        ./boot/vmlinuz-*) rel="${path#./boot/vmlinuz-}"; releases+=("$rel") ;;
        ./lib/modules/*/*) rel="${path#./lib/modules/}"; rel="${rel%%/*}"; releases+=("$rel") ;;
        ./usr/lib/modules/*/*) rel="${path#./usr/lib/modules/}"; rel="${rel%%/*}"; releases+=("$rel") ;;
      esac
    done < <(dpkg-deb -c "$deb" | awk '{print $NF}')
  done

  mapfile -t UNIQUE_RELEASES < <(printf '%s\n' "${releases[@]}" | sed '/^$/d' | sort -u)
  ((${#UNIQUE_RELEASES[@]} == 1)) || {
    printf 'Detected releases:\n%s\n' "$(printf '  %s\n' "${UNIQUE_RELEASES[@]:-none}")" >&2
    die "Kernel packages must resolve to exactly one release."
  }
  KERNEL_RELEASE="${UNIQUE_RELEASES[0]}"
  DTB_NAME="$(basename "$DTB_FILE")"

  local image_count=0 module_count=0
  for deb in "${KERNEL_DEBS[@]}"; do
    dpkg-deb -c "$deb" | awk '{print $NF}' | grep -qE "^\./boot/vmlinuz-${KERNEL_RELEASE}$" && image_count=$((image_count+1)) || true
    dpkg-deb -c "$deb" | awk '{print $NF}' | grep -qE "^\./(usr/)?lib/modules/${KERNEL_RELEASE}/" && module_count=$((module_count+1)) || true
  done
  (( image_count > 0 )) || die "No package contains /boot/vmlinuz-$KERNEL_RELEASE."
  (( module_count > 0 )) || die "No package contains a module tree for $KERNEL_RELEASE."

  ok "Kernel release: $KERNEL_RELEASE"
  ok "DTB: $DTB_NAME"
  ok "Firmware source: $FIRMWARE_SOURCE"
  [[ -n "$ROOT_SOURCE" ]] && ok "Optional /root overlay: $ROOT_SOURCE" || info "No optional /root overlay supplied."
}

print_plan() {
  cat <<EOF

Resolved v7.0.0 plan
--------------------
Work directory:        $WORKDIR
Profile:               $PROFILE
Artifact directory:    $ARTIFACT_DIR
Kernel release:        $KERNEL_RELEASE
Kernel packages:       ${#KERNEL_DEBS[@]}
DTB:                   $DTB_FILE
Firmware source:       $FIRMWARE_SOURCE
/root source:          ${ROOT_SOURCE:-none}
Target OCI base:       $CUSTOM_IMAGE_BASE
Target OCI reference:  $TARGET_IMAGE_REF
Custom-image ref:      $CUSTOM_IMAGE_REF
Live-iso ref:          $LIVE_ISO_REF
Pico image:            $LIVE_ISO_CONTAINER_IMAGE
Final ISO:             $FINAL_ISO

Architectural guards:
  - No live-iso GNOME, Mutter, GDM, NetworkManager, or installer lists are created.
  - The custom target OCI is built independently with Vib.
  - The upstream live ISO is built first from a pristine checkout.
  - Its graphical package manifest is hashed before remastering.
  - Only kernel/modules/initramfs/DTB/firmware/GRUB are changed.
  - The final graphical package manifest must be byte-identical.

Exact execute command:
  sudo WORKDIR='$WORKDIR' PROFILE='$PROFILE' ARTIFACT_DIR='$ARTIFACT_DIR' \
TARGET_IMAGE_REF='$TARGET_IMAGE_REF' LIVE_ISO_REF='$LIVE_ISO_REF' \
'$0' --execute
EOF
}

install_vib() {
  mkdir -p "$(dirname "$VIB_BIN")" "$VIB_PLUGIN_DIR"
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == "arm64" || "$arch" == "amd64" ]] || die "Unsupported Vib host architecture: $arch"

  local base="https://github.com/Vanilla-OS/Vib/releases"
  local release_base
  if [[ "$VIB_VERSION" == "latest" ]]; then
    release_base="$base/latest/download"
  else
    release_base="$base/download/$VIB_VERSION"
  fi

  if [[ ! -x "$VIB_BIN" ]]; then
    info "Downloading Vib $VIB_VERSION for $arch."
    curl -fL "$release_base/vib-$arch" -o "$VIB_BIN"
    chmod 0755 "$VIB_BIN"
  fi

  # Install the official Vib plugin bundle. The custom-image template's
  # fsguard stage depends on these plugins, and Vib searches this global path.
  if [[ ! -d /usr/share/vib/plugins || -z "$(find /usr/share/vib/plugins -type f -print -quit 2>/dev/null)" ]]; then
    local plugin_archive="$TMP_ROOT/plugins-$arch.tar.gz"
    info "Downloading official Vib plugin bundle for $arch."
    curl -fL "$release_base/plugins-$arch.tar.gz" -o "$plugin_archive"
    mkdir -p /usr/share/vib/plugins
    tar -xzf "$plugin_archive" -C /usr/share/vib/plugins --strip-components=2
  fi

  ok "Vib executable: $VIB_BIN"
  ok "Vib plugins: /usr/share/vib/plugins"
}

prepare_custom_image_project() {
  fresh_checkout "$CUSTOM_IMAGE_REPO_URL" "$CUSTOM_IMAGE_REF" "$CUSTOM_PROJECT"

  rm -rf "$CUSTOM_PROJECT/includes.container/deb-pkgs"
  mkdir -p \
    "$CUSTOM_PROJECT/includes.container/deb-pkgs" \
    "$CUSTOM_PROJECT/includes.container/usr/lib/firmware" \
    "$CUSTOM_PROJECT/includes.container/boot/dtbs" \
    "$CUSTOM_PROJECT/includes.container/root" \
    "$CUSTOM_PROJECT/includes.container/image-info" \
    "$CUSTOM_PROJECT/modules"

  local deb
  for deb in "${KERNEL_DEBS[@]}"; do
    cp -a "$deb" "$CUSTOM_PROJECT/includes.container/deb-pkgs/"
  done
  rsync -aHAX "$FIRMWARE_SOURCE/" "$CUSTOM_PROJECT/includes.container/usr/lib/firmware/"
  cp -a "$DTB_FILE" "$CUSTOM_PROJECT/includes.container/boot/dtbs/$DTB_NAME"
  if [[ -n "$ROOT_SOURCE" ]]; then
    rsync -aHAX "$ROOT_SOURCE/" "$CUSTOM_PROJECT/includes.container/root/"
  fi

  printf '%s' "$CUSTOM_IMAGE_BASE" > "$CUSTOM_PROJECT/includes.container/image-info/base-image-name"
  printf '%s' "${TARGET_IMAGE_REF#*/}" > "$CUSTOM_PROJECT/includes.container/image-info/image-name"

  cat > "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh" <<'EOF_INSTALL'
#!/bin/bash
set -Eeuo pipefail
shopt -s nullglob
packages=(/deb-pkgs/*.deb)
((${#packages[@]} > 0)) || { echo "No local .deb packages found" >&2; exit 1; }
apt-get update
for package in "${packages[@]}"; do
  echo "Installing local hardware package: $package"
  apt-get install -y "$package"
done
EOF_INSTALL
  chmod 0755 "$CUSTOM_PROJECT/includes.container/deb-pkgs/install-debs.sh"

  cat > "$CUSTOM_PROJECT/modules/50-install-hardware-debs.yml" <<'EOF_MOD_DEBS'
name: install-hardware-debs
type: shell
commands:
  - bash /deb-pkgs/install-debs.sh
  - rm -rf /deb-pkgs
EOF_MOD_DEBS

  cat > "$CUSTOM_PROJECT/modules/60-select-hardware-kernel.yml" <<EOF_MOD_HW
name: select-hardware-kernel
type: shell
commands:
  - test -s /boot/vmlinuz-${KERNEL_RELEASE}
  - test -d /usr/lib/modules/${KERNEL_RELEASE} || test -d /lib/modules/${KERNEL_RELEASE}
  - test -s /boot/dtbs/${DTB_NAME}
  - ln -sfn boot/vmlinuz-${KERNEL_RELEASE} /vmlinuz
  - ln -sfn boot/initrd.img-${KERNEL_RELEASE} /initrd.img
  - printf '%s\n' '${KERNEL_RELEASE}' > /usr/lib/conception-kernel-release
  - printf '%s\n' '${DTB_NAME}' > /usr/lib/conception-dtb
  - depmod -a '${KERNEL_RELEASE}'
  - test -e /usr/lib/firmware/qcom || test -e /lib/firmware/qcom
EOF_MOD_HW

  cat > "$CUSTOM_PROJECT/recipe.yml" <<EOF_RECIPE
name: Conception VanillaOS Desktop for ${PROFILE}
id: conception-${PROFILE}
vibversion: 1.0.7

stages:
  - id: build
    base: ${CUSTOM_IMAGE_BASE}
    addincludes: true
    singlelayer: false
    labels:
      maintainer: Conception
      conception.profile: ${PROFILE}
      conception.kernel: ${KERNEL_RELEASE}
      conception.dtb: ${DTB_NAME}
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

      # Hardware is installed and validated before cleanup and FsGuard.
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
Kernel package source:
  $ARTIFACT_DIR/kernel-debs/
  Compatibility fallback: $ARTIFACT_DIR/*.deb

Firmware source:
  $ARTIFACT_DIR/firmware/
  Paths are relative to /usr/lib/firmware.
  Compatibility fallbacks:
    $ARTIFACT_DIR/usr/lib/firmware/
    $ARTIFACT_DIR/qcom/

DTB source:
  $ARTIFACT_DIR/dtb/*.dtb
  Compatibility fallback: $ARTIFACT_DIR/*.dtb

Desired target /root files:
  $ARTIFACT_DIR/root/
  Everything below this directory is copied to /root in the custom OCI.
EOF_INPUTS

  ok "Prepared Vib project: $CUSTOM_PROJECT"
}

build_custom_image() {
  pushd "$CUSTOM_PROJECT" >/dev/null
  run_logged "vib-generate-containerfile" "$VIB_BIN" build recipe.yml
  [[ -s Containerfile ]] || die "Vib did not generate Containerfile."

  run_logged "build-target-oci" "$OCI_RUNTIME" build \
    --pull=always \
    --tag "$TARGET_IMAGE_REF" \
    --file Containerfile \
    .

  "$OCI_RUNTIME" image inspect "$TARGET_IMAGE_REF" >/dev/null
  popd >/dev/null

  if [[ "$PUSH_TARGET_IMAGE" == "1" ]]; then
    run_logged "push-target-oci" "$OCI_RUNTIME" push "$TARGET_IMAGE_REF"
  elif [[ "$TARGET_IMAGE_REF" == localhost/* ]]; then
    warn "TARGET_IMAGE_REF is local-only. The graphical installer cannot pull it from another environment."
    warn "Set a reachable registry reference and PUSH_TARGET_IMAGE=1 before installation."
  fi

  mkdir -p "$RELEASE_DIR"
  cat > "$RELEASE_DIR/CUSTOM-TARGET-IMAGE.txt" <<EOF_TARGET
Custom VanillaOS target image
==============================
Reference: $TARGET_IMAGE_REF
Base:      $CUSTOM_IMAGE_BASE
Profile:   $PROFILE
Kernel:    $KERNEL_RELEASE
DTB:       $DTB_NAME
Built:     $(date -u --iso-8601=seconds)

Graphical installer entry:
  $TARGET_IMAGE_REF

Important:
  The installer must be able to resolve and pull this reference.
  A localhost reference is not reachable from the live installer unless the
  image is loaded into the same container store, which is not assumed here.
EOF_TARGET
}

prepare_live_iso_checkout() {
  fresh_checkout "$LIVE_ISO_REPO_URL" "$LIVE_ISO_REF" "$LIVE_ISO_DIR"

  local conf="$LIVE_ISO_DIR/etc/terraform.conf"
  [[ -f "$conf" ]] || die "Official live-iso terraform.conf not found."

  # Architecture is a build selector, not a package-closure customization.
  sed -i -E 's/^ARCH=.*/ARCH="arm64"/' "$conf"
  grep -q '^ARCH="arm64"$' "$conf" || die "Unable to select ARM64 in terraform.conf."

  # Preserve every upstream package list byte-for-byte and record their hash.
  (
    cd "$LIVE_ISO_DIR"
    find etc/config -type f \( -path '*/package-lists*/*' -o -name '*.list.chroot' -o -name '*.list.binary' \) \
      -print0 | sort -z | xargs -0 sha256sum
  ) > "$TMP_ROOT/upstream-package-lists.sha256"

  # Upstream orchid build.sh currently contains an amd64-only final mv source.
  # Correct only the output filename selector. This occurs after lb build and
  # cannot alter the live filesystem package closure.
  local build="$LIVE_ISO_DIR/build.sh"
  if grep -Fq 'tmp/amd64/live-image-amd64.hybrid.iso' "$build"; then
    sed -i 's#tmp/amd64/live-image-amd64\.hybrid\.iso#tmp/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso#' "$build"
  fi

  # Explicitly refuse legacy v6 package-list injections.
  if grep -RqsE 'zz-conception-installer-runtime|gnome-shell|mutter|gdm3|network-manager' \
      "$LIVE_ISO_DIR/etc/config/package-lists."* 2>/dev/null; then
    die "Refusing altered live package closure: Conception/manual graphical package entries found."
  fi
}

build_pristine_live_iso() {
  pushd "$LIVE_ISO_DIR" >/dev/null
  CURRENT_LOG="$LOG_DIR/${BUILD_ID}-build-pristine-live-iso.log"
  mkdir -p "$LOG_DIR"
  info "Log: $CURRENT_LOG"

  "$LIVE_ISO_RUNTIME" run --rm --privileged --network host -i \
    -v /proc:/proc \
    -v "$LIVE_ISO_DIR:/working_dir" \
    -w /working_dir \
    "$LIVE_ISO_CONTAINER_IMAGE" \
    /bin/bash -s etc/terraform.conf < build.sh \
    2>&1 | tee "$CURRENT_LOG"

  UPSTREAM_ISO="$(find "$LIVE_ISO_DIR/builds/arm64" "$LIVE_ISO_DIR/builds" \
    -type f -name '*.iso' -print 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "$UPSTREAM_ISO" && -s "$UPSTREAM_ISO" ]] || die "Pristine upstream ARM64 ISO was not produced."
  popd >/dev/null

  verify_pristine_graphical_manifest
}

extract_iso_file() {
  local iso="$1" iso_path="$2" destination="$3"
  rm -f "$destination"
  xorriso -osirrox on -indev "$iso" -extract "$iso_path" "$destination" >/dev/null 2>&1
}

verify_pristine_graphical_manifest() {
  mkdir -p "$TMP_ROOT"
  UPSTREAM_MANIFEST="$TMP_ROOT/upstream-filesystem.packages"
  extract_iso_file "$UPSTREAM_ISO" /live/filesystem.packages "$UPSTREAM_MANIFEST"

  local required=(vanilla-installer gnome-shell gnome-session mutter gdm3 xwayland network-manager)
  local p
  for p in "${required[@]}"; do
    grep -Eq "^${p}([[:space:]]|$)" "$UPSTREAM_MANIFEST" || \
      die "Pristine upstream ISO is not the known-good graphical closure: missing $p."
  done

  local count
  count="$(wc -l < "$UPSTREAM_MANIFEST")"
  (( count >= 1000 )) || die "Pristine upstream ISO has only $count packages; refusing to remaster an incomplete source."
  sha256sum "$UPSTREAM_MANIFEST" > "$TMP_ROOT/upstream-manifest.sha256"
  ok "Pristine upstream graphical package manifest accepted: $count entries."
}

mount_chroot_fs() {
  local root="$1"
  mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/dev/pts"
  mount --bind /dev "$root/dev"
  mount --bind /dev/pts "$root/dev/pts"
  mount -t proc proc "$root/proc"
  mount -t sysfs sys "$root/sys"
}

umount_chroot_fs() {
  local root="$1"
  umount -lf "$root/dev/pts" 2>/dev/null || true
  umount -lf "$root/dev" 2>/dev/null || true
  umount -lf "$root/proc" 2>/dev/null || true
  umount -lf "$root/sys" 2>/dev/null || true
}

patch_grub_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  sed -i -E \
    -e "s#(/live/)?vmlinuz-[^[:space:]'\"]+#/live/vmlinuz-${KERNEL_RELEASE}#g" \
    -e "s#(/live/)?initrd\.img-[^[:space:]'\"]+#/live/initrd.img-${KERNEL_RELEASE}#g" \
    "$file"

  python3 - "$file" "$DTB_NAME" <<'PY_GRUB'
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
PY_GRUB
}

remaster_boot_hardware_only() {
  local iso_tree="$TMP_ROOT/iso-tree"
  local squash_root="$TMP_ROOT/squash-root"
  local original_squash="$TMP_ROOT/original-filesystem.squashfs"
  local new_squash="$TMP_ROOT/filesystem.squashfs"
  local compression

  rm -rf "$iso_tree" "$squash_root"
  mkdir -p "$iso_tree" "$squash_root"

  info "Extracting pristine upstream ISO."
  xorriso -osirrox on -indev "$UPSTREAM_ISO" -extract / "$iso_tree" >/dev/null 2>&1

  cp -a "$iso_tree/live/filesystem.squashfs" "$original_squash"
  compression="$(unsquashfs -s "$original_squash" | awk -F': ' '/Compression/{print $2; exit}')"
  [[ -n "$compression" ]] || compression="xz"

  unsquashfs -d "$squash_root" "$original_squash" >/dev/null

  # Extract local package payloads without invoking APT and without changing the
  # upstream graphical package closure. These are boot-critical live-media
  # payloads, not target-OCI package transactions.
  local deb
  for deb in "${KERNEL_DEBS[@]}"; do
    dpkg-deb -x "$deb" "$squash_root"
  done

  mkdir -p "$squash_root/usr/lib/firmware" "$squash_root/boot/dtbs"
  rsync -aHAX "$FIRMWARE_SOURCE/" "$squash_root/usr/lib/firmware/"
  cp -a "$DTB_FILE" "$squash_root/boot/dtbs/$DTB_NAME"

  [[ -s "$squash_root/boot/vmlinuz-$KERNEL_RELEASE" ]] || \
    die "Remastered squashfs lacks /boot/vmlinuz-$KERNEL_RELEASE."
  [[ -d "$squash_root/usr/lib/modules/$KERNEL_RELEASE" || -d "$squash_root/lib/modules/$KERNEL_RELEASE" ]] || \
    die "Remastered squashfs lacks module tree for $KERNEL_RELEASE."

  # Generate a live initramfs inside the native ARM64 rootfs. The graphical
  # package set is not modified; only boot artifacts are generated.
  mount_chroot_fs "$squash_root"
  trap 'umount_chroot_fs "'"$squash_root"'"' RETURN
  chroot "$squash_root" /bin/bash -Eeuo pipefail -c "
    depmod -a '$KERNEL_RELEASE'
    rm -f '/boot/initrd.img-$KERNEL_RELEASE'
    update-initramfs -c -k '$KERNEL_RELEASE'
    test -s '/boot/initrd.img-$KERNEL_RELEASE'
  "
  umount_chroot_fs "$squash_root"
  trap - RETURN

  # Update only live boot payload files.
  rm -f "$iso_tree/live"/vmlinuz-* "$iso_tree/live"/initrd.img-*
  cp -a "$squash_root/boot/vmlinuz-$KERNEL_RELEASE" "$iso_tree/live/vmlinuz-$KERNEL_RELEASE"
  cp -a "$squash_root/boot/initrd.img-$KERNEL_RELEASE" "$iso_tree/live/initrd.img-$KERNEL_RELEASE"
  mkdir -p "$iso_tree/boot/dtbs"
  cp -a "$DTB_FILE" "$iso_tree/boot/dtbs/$DTB_NAME"

  # Preserve the upstream package manifest exactly. Kernel payload extraction is
  # intentionally not represented as an APT change in the live environment.
  cp -a "$UPSTREAM_MANIFEST" "$iso_tree/live/filesystem.packages"

  find "$iso_tree/boot/grub" "$iso_tree/EFI" -type f \
    \( -name '*.cfg' -o -name 'grub.cfg' -o -name 'loopback.cfg' \) -print0 2>/dev/null |
    while IFS= read -r -d '' cfg; do
      patch_grub_file "$cfg"
    done

  rm -f "$new_squash"
  mksquashfs "$squash_root" "$new_squash" -noappend -comp "$compression" >/dev/null
  mv "$new_squash" "$iso_tree/live/filesystem.squashfs"

  # Recreate checksums after the boot-only changes.
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

verify_final_release() {
  local final_manifest="$TMP_ROOT/final-filesystem.packages"
  local extracted="$TMP_ROOT/verify"
  rm -rf "$extracted"
  mkdir -p "$extracted"

  extract_iso_file "$FINAL_ISO" /live/filesystem.packages "$final_manifest"
  cmp -s "$UPSTREAM_MANIFEST" "$final_manifest" || \
    die "Final ISO graphical package manifest differs from pristine upstream manifest."

  extract_iso_file "$FINAL_ISO" "/live/vmlinuz-$KERNEL_RELEASE" "$extracted/vmlinuz"
  extract_iso_file "$FINAL_ISO" "/live/initrd.img-$KERNEL_RELEASE" "$extracted/initrd"
  extract_iso_file "$FINAL_ISO" "/boot/dtbs/$DTB_NAME" "$extracted/$DTB_NAME"

  [[ -s "$extracted/vmlinuz" ]] || die "Final ISO lacks nonempty custom kernel."
  [[ -s "$extracted/initrd" ]] || die "Final ISO lacks nonempty custom initramfs."
  [[ -s "$extracted/$DTB_NAME" ]] || die "Final ISO lacks selected DTB."

  local grub="$extracted/grub.cfg"
  extract_iso_file "$FINAL_ISO" /boot/grub/grub.cfg "$grub"
  grep -Fq "/live/vmlinuz-$KERNEL_RELEASE" "$grub" || die "Final GRUB config does not select custom kernel."
  grep -Fq "devicetree /boot/dtbs/$DTB_NAME" "$grub" || die "Final GRUB config lacks DTB directive."

  sha256sum "$FINAL_ISO" > "$FINAL_ISO.sha256"
  cp -a "$TMP_ROOT/upstream-package-lists.sha256" "$RELEASE_DIR/"
  cp -a "$TMP_ROOT/upstream-manifest.sha256" "$RELEASE_DIR/"
  git -C "$CUSTOM_PROJECT" rev-parse HEAD > "$RELEASE_DIR/custom-image-source.commit"
  git -C "$LIVE_ISO_DIR" rev-parse HEAD > "$RELEASE_DIR/live-iso-source.commit"

  cat > "$RELEASE_DIR/BUILD-MANIFEST.txt" <<EOF_MANIFEST
Conception VanillaOS ARM64 build
Version:            $SCRIPT_VERSION
Build ID:           $BUILD_ID
Profile:            $PROFILE
Kernel release:     $KERNEL_RELEASE
DTB:                $DTB_NAME
Target OCI:         $TARGET_IMAGE_REF
Target OCI base:    $CUSTOM_IMAGE_BASE
Pristine ISO:       $UPSTREAM_ISO
Final ISO:          $FINAL_ISO
Live package set:   byte-identical before and after remaster
Built:              $(date -u --iso-8601=seconds)
EOF_MANIFEST

  ok "Final ISO: $FINAL_ISO"
  ok "Target OCI: $TARGET_IMAGE_REF"
  ok "Live graphical package manifest remained byte-identical."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --plan|--dry-run) PLAN_ONLY=1 ;;
      --execute) PLAN_ONLY=0 ;;
      --keep-tmp) KEEP_TMP=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  require_root
  mkdir -p "$WORKDIR" "$OUTPUT_DIR" "$LOG_DIR" "$TMP_ROOT" "$SOURCES_DIR"

  stage "1/10 Checking host dependencies"
  install_host_dependencies

  stage "2/10 Discovering kernel, DTB, firmware, and /root inputs"
  discover_inputs
  print_plan
  (( PLAN_ONLY == 0 )) || exit 0

  stage "3/10 Installing Vib tooling"
  install_vib

  stage "4/10 Preparing official custom-image-derived Vib project"
  prepare_custom_image_project

  stage "5/10 Building custom target OCI from desktop:dev"
  build_custom_image

  stage "6/10 Preparing pristine official live-iso checkout"
  prepare_live_iso_checkout

  stage "7/10 Building pristine graphical ARM64 ISO with Pico"
  build_pristine_live_iso

  stage "8/10 Remastering only boot-critical hardware payload"
  remaster_boot_hardware_only

  stage "9/10 Verifying package-closure preservation and boot artifacts"
  verify_final_release

  stage "10/10 Complete"
  cat "$RELEASE_DIR/BUILD-MANIFEST.txt"
}

main "$@"
