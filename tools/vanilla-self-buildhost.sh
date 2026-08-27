#!/usr/bin/env bash
#
# vanilla-arm64-self-buildhost.sh
#
# Unified lifecycle manager for the Vanilla OS Reunion self-hosted build
# environment used by the VanillaOS Snapdragon X ARM64 build harness.
#
# This revision replaces the former create/bootstrap, enter, and destroy helper
# scripts with one coherent executable and adds the nested-storage/FUSE
# performance redesign.
#
# Primary runtime interface:
#   ./vanilla-arm64-self-buildhost.sh --create
#   ./vanilla-arm64-self-buildhost.sh --enter
#   ./vanilla-arm64-self-buildhost.sh --delete
#
# Intended invocation context:
#   Run from an APX/VSO-managed parent shell on the installed Vanilla OS host.
#   The parent must provide distrobox-host-exec.
#
# Builder architecture:
#   Vanilla OS ARM64 host
#       -> distrobox-host-exec
#       -> PolKit-compatible Distrobox root adapter
#       -> rootful ghcr.io/vanilla-os/pico:latest Distrobox
#          --unshare-all
#          --privileged
#          host-native bind -> /var/lib/containers/storage
#          host-native bind -> /var/tmp
#       -> nested rootful Podman / Buildah
#          overlay storage driver
#          kernel-native OverlayFS REQUIRED
#          fuse-overlayfs NOT ACCEPTED
#          cgroupfs
#          cgroups disabled
#          inherited builder namespaces
#
# The storage and cgroup settings are BUILD-HOST ONLY. They are not incorporated
# into generated Vanilla OS images or installed targets.
#
# Destructive semantics:
#   --delete removes both the rootful Distrobox and this script's dedicated,
#   marker-protected external build storage. It will not recursively delete an
#   unmarked or mismatched path.
#
# Version: 2.0.2
#

set -Eeuo pipefail

readonly SCRIPT_VERSION="2.0.2"
readonly CONFIGURATION_VERSION="2.0.0"
readonly STORAGE_LAYOUT_VERSION="2"

# Single-source-of-truth lifecycle definition.  These are intentionally not
# command-line options: create, enter, and delete must always address exactly
# the same builder topology.
readonly BOX_NAME="vanilla-arm64-builder-root"
readonly BOX_IMAGE="ghcr.io/vanilla-os/pico:latest"
readonly DBX_ADAPTER="$HOME/.local/bin/dbx-pkexec"
readonly STATE_ROOT="$HOME/.local/share/vanilla-arm64-self-buildhost"
readonly STATE_DIR="$STATE_ROOT/$BOX_NAME"
readonly HOST_GRAPHROOT="$STATE_DIR/containers-storage"
readonly HOST_VAR_TMP="$STATE_DIR/var-tmp"
readonly STORAGE_MARKER="$STATE_DIR/.vanilla-arm64-self-buildhost-storage"
readonly READY_MARKER="$STATE_DIR/.vanilla-arm64-self-buildhost-ready"

readonly CONTAINER_GRAPHROOT="/var/lib/containers/storage"
readonly CONTAINER_VAR_TMP="/var/tmp"

ACTION=""
INNER_SCRIPT=""
HOST_GRAPHROOT_FSTYPE=""
HOST_VAR_TMP_FSTYPE=""
INSPECTED_FSTYPE=""

usage() {
    cat <<EOF
Usage:
  $(basename "$0") --create
  $(basename "$0") --enter
  $(basename "$0") --delete

Actions:
  --create   Create, configure, and acceptance-test the optimized ARM64 builder.
             Refuses to overwrite an existing builder; use --delete first.

  --enter    Validate the builder identity/topology and enter it interactively.

  --delete   Remove the rootful Distrobox and its dedicated external build
             storage. External storage is deleted only when its ownership
             marker exactly matches this builder definition.

  -h, --help Show this help.

Fixed builder definition:
  Name:       $BOX_NAME
  Image:      $BOX_IMAGE
  State:      $STATE_DIR
  Graphroot:  $HOST_GRAPHROOT -> $CONTAINER_GRAPHROOT
  Build tmp:  $HOST_VAR_TMP -> $CONTAINER_VAR_TMP

The script must be run from an APX/VSO parent shell that provides
'distrobox-host-exec'.
EOF
}

log()  { printf '==> %s\n' "$*"; }
ok()   { printf 'OK  %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$INNER_SCRIPT" ]]; then
        rm -f -- "$INNER_SCRIPT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

parse_args() {
    (($# == 1)) || {
        usage >&2
        die "Specify exactly one lifecycle action: --create, --enter, or --delete."
    }

    case "$1" in
        --create)
            ACTION="create"
            ;;
        --enter)
            ACTION="enter"
            ;;
        --delete)
            ACTION="delete"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac
}

require_parent_environment() {
    command -v distrobox-host-exec >/dev/null 2>&1 ||
        die "distrobox-host-exec is required. Run this from an APX/VSO parent shell."
    command -v bash >/dev/null 2>&1 || die "bash is required."
    command -v mktemp >/dev/null 2>&1 || die "mktemp is required."

    log "Validating Vanilla host command surface."
    distrobox-host-exec sh -lc '
        command -v distrobox >/dev/null 2>&1 &&
        command -v podman >/dev/null 2>&1 &&
        command -v pkexec >/dev/null 2>&1 &&
        command -v findmnt >/dev/null 2>&1 &&
        command -v df >/dev/null 2>&1 &&
        command -v stat >/dev/null 2>&1
    ' || die "Host must provide distrobox, podman, pkexec, findmnt, df, and stat."

    local host_arch
    host_arch="$(distrobox-host-exec uname -m 2>/dev/null || true)"
    case "$host_arch" in
        aarch64|arm64)
            ok "Host architecture is ARM64 (${host_arch})."
            ;;
        *)
            die "Expected an ARM64 Vanilla OS host; detected '${host_arch:-unknown}'."
            ;;
    esac
}

install_dbx_adapter() {
    log "Installing/refreshing the Distrobox PolKit compatibility adapter."
    mkdir -p -- "$(dirname "$DBX_ADAPTER")"

    cat >"$DBX_ADAPTER" <<'EOF_ADAPTER'
#!/bin/sh
set -eu

# Distrobox validates its configured sudo program with "<program> -v".
# Vanilla OS intentionally does not provide sudo on the immutable host, so
# translate that validation into a harmless PolKit authorization request.
if [ "${1:-}" = "-v" ] && [ "$#" -eq 1 ]; then
    exec /usr/bin/pkexec /usr/bin/true
fi

# Execute the requested host-side privileged command through PolKit.
exec /usr/bin/pkexec "$@"
EOF_ADAPTER

    chmod 0755 "$DBX_ADAPTER"

    distrobox-host-exec test -x "$DBX_ADAPTER" ||
        die "The host cannot execute $DBX_ADAPTER. The parent HOME must be host-shared."
}

dbx_host() {
    distrobox-host-exec env \
        DBX_SUDO_PROGRAM="$DBX_ADAPTER" \
        distrobox "$@"
}

host_root_exec() {
    # Reuse the same PolKit adapter for direct host-side operations that may
    # encounter root-owned files created by the rootful nested engine.
    distrobox-host-exec "$DBX_ADAPTER" "$@"
}

box_exists() {
    # distrobox-list emits a pipe-delimited table; match the NAME field exactly.
    dbx_host list --root --no-color 2>/dev/null | awk -F '|' -v wanted="$BOX_NAME" '
        NR > 1 {
            name=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

validate_state_path_safety() {
    [[ -n "$STATE_ROOT" && -n "$STATE_DIR" ]] || die "Internal state path is empty."
    [[ "$STATE_ROOT" != "/" && "$STATE_DIR" != "/" ]] ||
        die "Refusing unsafe state path '/'."
    [[ "$STATE_DIR" != "$HOME" && "$STATE_DIR" != "$STATE_ROOT" ]] ||
        die "Refusing unsafe state directory: $STATE_DIR"
    [[ "$STATE_DIR" == "$STATE_ROOT/"* ]] ||
        die "State directory escaped the configured state root."
    [[ ! -L "$STATE_DIR" ]] ||
        die "Refusing symlinked state directory: $STATE_DIR"
}

state_marker_matches() {
    [[ -f "$STORAGE_MARKER" && ! -L "$STORAGE_MARKER" ]] || return 1

    grep -Fqx "marker_format=1" "$STORAGE_MARKER" &&
    grep -Fqx "box_name=$BOX_NAME" "$STORAGE_MARKER" &&
    grep -Fqx "storage_layout_version=$STORAGE_LAYOUT_VERSION" "$STORAGE_MARKER" &&
    grep -Fqx "state_dir=$STATE_DIR" "$STORAGE_MARKER" &&
    grep -Fqx "host_graphroot=$HOST_GRAPHROOT" "$STORAGE_MARKER" &&
    grep -Fqx "host_var_tmp=$HOST_VAR_TMP" "$STORAGE_MARKER"
}

ready_marker_matches() {
    [[ -f "$READY_MARKER" && ! -L "$READY_MARKER" ]] || return 1

    grep -Fqx "marker_format=1" "$READY_MARKER" &&
    grep -Fqx "acceptance_status=passed" "$READY_MARKER" &&
    grep -Fqx "box_name=$BOX_NAME" "$READY_MARKER" &&
    grep -Fqx "configuration_version=$CONFIGURATION_VERSION" "$READY_MARKER" &&
    grep -Fqx "storage_layout_version=$STORAGE_LAYOUT_VERSION" "$READY_MARKER"
}

write_ready_marker() {
    cat >"$READY_MARKER" <<EOF_READY
VanillaOS ARM64 self-buildhost acceptance state
marker_format=1
acceptance_status=passed
acceptance_script_version=$SCRIPT_VERSION
box_name=$BOX_NAME
configuration_version=$CONFIGURATION_VERSION
storage_layout_version=$STORAGE_LAYOUT_VERSION
EOF_READY
    chmod 0600 "$READY_MARKER"
}

remove_marked_state_dir() {
    validate_state_path_safety

    [[ -e "$STATE_DIR" ]] || return 0

    state_marker_matches ||
        die "Refusing to delete unmarked or mismatched external state: $STATE_DIR"

    log "Removing marker-validated external build storage."
    host_root_exec /usr/bin/rm -rf -- "$STATE_DIR"
    [[ ! -e "$STATE_DIR" ]] || die "External state directory still exists after deletion."
    ok "External build storage removed."
}

write_storage_marker() {
    cat >"$STORAGE_MARKER" <<EOF_MARKER
VanillaOS ARM64 self-buildhost external storage
marker_format=1
script_version=$SCRIPT_VERSION
box_name=$BOX_NAME
builder_image=$BOX_IMAGE
storage_layout_version=$STORAGE_LAYOUT_VERSION
state_dir=$STATE_DIR
host_graphroot=$HOST_GRAPHROOT
host_var_tmp=$HOST_VAR_TMP
container_graphroot=$CONTAINER_GRAPHROOT
container_var_tmp=$CONTAINER_VAR_TMP
EOF_MARKER
    chmod 0600 "$STORAGE_MARKER"
}

inspect_backing_filesystem() {
    local path="$1"
    local label="$2"
    local fstype source options free_kb

    fstype="$(distrobox-host-exec findmnt -T "$path" -n -o FSTYPE 2>/dev/null || true)"
    source="$(distrobox-host-exec findmnt -T "$path" -n -o SOURCE 2>/dev/null || true)"
    options="$(distrobox-host-exec findmnt -T "$path" -n -o OPTIONS 2>/dev/null || true)"
    free_kb="$(distrobox-host-exec df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}' || true)"

    [[ -n "$fstype" ]] || die "Could not determine backing filesystem for $label: $path"

    log "$label backing: filesystem=$fstype source=${source:-unknown} free_kib=${free_kb:-unknown}"

    # Kernel OverlayFS must not itself be layered on top of these known-bad or
    # unsuitable storage classes.  Btrfs is intentionally not rejected here:
    # current containers/storage probes actual native-overlay support and the
    # acceptance test below is authoritative.
    case "$fstype" in
        overlay|aufs|ecryptfs|nfs|nfs4|cifs|smb3|9p|sshfs|fuse|fuse.*)
            die "$label is on unsupported backing filesystem '$fstype'. Native nested OverlayFS is required."
            ;;
    esac

    if [[ "$options" == *",ro,"* || "$options" == ro,* || "$options" == *,ro || "$options" == "ro" ]]; then
        die "$label backing filesystem is read-only."
    fi

    INSPECTED_FSTYPE="$fstype"
}

prepare_external_storage() {
    validate_state_path_safety

    if [[ -e "$STATE_DIR" ]]; then
        if state_marker_matches; then
            warn "Found orphaned marker-owned state from a prior builder attempt."
            warn "Because --create is a fresh lifecycle transition, the orphaned store will be reset."
            remove_marked_state_dir
        elif [[ -d "$STATE_DIR" ]] && [[ -z "$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            rmdir -- "$STATE_DIR" || true
        else
            die "State path already exists but is not owned by this builder: $STATE_DIR"
        fi
    fi

    log "Creating dedicated host-native build storage."
    mkdir -p -- "$HOST_GRAPHROOT" "$HOST_VAR_TMP"
    chmod 0700 "$STATE_DIR"

    # The nested engine is rootful and Distrobox root maps to real host root.
    # Give its graphroot the same ownership semantics as a conventional
    # /var/lib/containers/storage, while keeping /var/tmp sticky/world-writable.
    host_root_exec /usr/bin/chown 0:0 -- "$HOST_GRAPHROOT" "$HOST_VAR_TMP"
    host_root_exec /usr/bin/chmod 0700 -- "$HOST_GRAPHROOT"
    host_root_exec /usr/bin/chmod 1777 -- "$HOST_VAR_TMP"

    write_storage_marker

    inspect_backing_filesystem "$HOST_GRAPHROOT" "Container graphroot"
    HOST_GRAPHROOT_FSTYPE="$INSPECTED_FSTYPE"
    inspect_backing_filesystem "$HOST_VAR_TMP" "Build temporary storage"
    HOST_VAR_TMP_FSTYPE="$INSPECTED_FSTYPE"

    # Record the resolved backing types after successful host-side validation.
    cat >>"$STORAGE_MARKER" <<EOF_FSTYPE
host_graphroot_fstype=$HOST_GRAPHROOT_FSTYPE
host_var_tmp_fstype=$HOST_VAR_TMP_FSTYPE
EOF_FSTYPE

    ok "Dedicated external build storage prepared."
}

make_inner_script() {
    mkdir -p -- "$HOME/.cache"
    INNER_SCRIPT="$(mktemp "$HOME/.cache/vanilla-arm64-self-buildhost-inner.XXXXXX.sh")"
    chmod 0700 "$INNER_SCRIPT"
}

create_outer_distrobox() {
    log "Creating optimized rootful Pico Distrobox '$BOX_NAME'."
    log "A GUI PolKit authentication prompt is expected."

    dbx_host create \
        --root \
        --name "$BOX_NAME" \
        --image "$BOX_IMAGE" \
        --pull \
        --unshare-all \
        --volume "$HOST_GRAPHROOT:$CONTAINER_GRAPHROOT:rw" \
        --volume "$HOST_VAR_TMP:$CONTAINER_VAR_TMP:rw" \
        --additional-flags "--privileged" \
        --yes || return 1

    log "Initializing '$BOX_NAME'."
    log "On first initialization Distrobox may require creation of a container-user password."
    dbx_host enter \
        --root \
        --name "$BOX_NAME" \
        -- true || return 1
}

configure_inner_builder() {
    make_inner_script

    cat >"$INNER_SCRIPT" <<'EOF_INNER'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '  -> %s\n' "$*"; }
ok()  { printf '  OK %s\n' "$*"; }
die() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

: "${SELF_BUILDHOST_VERSION:?missing SELF_BUILDHOST_VERSION}"
: "${SELF_BUILDHOST_IMAGE:?missing SELF_BUILDHOST_IMAGE}"
: "${SELF_BUILDHOST_STORAGE_LAYOUT:?missing SELF_BUILDHOST_STORAGE_LAYOUT}"
: "${SELF_BUILDHOST_HOST_GRAPHROOT_FSTYPE:?missing SELF_BUILDHOST_HOST_GRAPHROOT_FSTYPE}"
: "${SELF_BUILDHOST_HOST_VAR_TMP_FSTYPE:?missing SELF_BUILDHOST_HOST_VAR_TMP_FSTYPE}"

log "Acquiring container sudo authorization."
sudo -v

# Host-side command/package closure used by the accepted VanillaOS Snapdragon X
# harness, plus Buildah for direct acceptance testing of the writable RUN-mount
# build shape.
PACKAGES=(
    apt
    build-essential
    buildah
    ca-certificates
    coreutils
    curl
    dpkg
    file
    findutils
    gawk
    git
    grep
    jq
    podman
    python3
    rsync
    sed
    skopeo
    squashfs-tools
    tar
    util-linux
    xorriso
    zstd
)

log "Updating Pico/Sid package metadata."
sudo env DEBIAN_FRONTEND=noninteractive apt update

log "Installing build-host dependency closure."
sudo env DEBIAN_FRONTEND=noninteractive apt install -y "${PACKAGES[@]}"

# Distrobox upstream recommends subordinate ranges for Podman-in-Distrobox.
# Preserve the prior idempotent configuration even though the accepted nested
# engine is rootful.
if ! sudo grep -qE "^${USER}:10000:55537$" /etc/subuid 2>/dev/null; then
    log "Adding subordinate UID range 10000-65536 for ${USER}."
    sudo usermod --add-subuids 10000-65536 "$USER"
fi

if ! sudo grep -qE "^${USER}:10000:55537$" /etc/subgid 2>/dev/null; then
    log "Adding subordinate GID range 10000-65536 for ${USER}."
    sudo usermod --add-subgids 10000-65536 "$USER"
fi

log "Installing validated nested-Podman namespace/cgroup configuration."
CONF_TMP="$(mktemp)"
cat >"$CONF_TMP" <<'EOF_CONF'
[containers]
netns="host"
userns="host"
ipcns="host"
utsns="host"
cgroups="disabled"
log_driver="k8s-file"

[engine]
cgroup_manager="cgroupfs"
events_logger="file"
EOF_CONF
sudo install -D -m 0644 "$CONF_TMP" /etc/containers/containers.conf
rm -f "$CONF_TMP"

log "Installing deterministic native-overlay storage configuration."
STORAGE_TMP="$(mktemp)"
cat >"$STORAGE_TMP" <<'EOF_STORAGE'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mountopt = "nodev"
EOF_STORAGE
sudo install -D -m 0644 "$STORAGE_TMP" /etc/containers/storage.conf
rm -f "$STORAGE_TMP"

# Deliberately do not configure overlay.mount_program.  containers/storage may
# auto-select fuse-overlayfs when native OverlayFS is unavailable; the
# acceptance phase detects that condition and fails closed.
if sudo grep -Eq '^[[:space:]]*mount_program[[:space:]]*=' /etc/containers/storage.conf; then
    die "storage.conf unexpectedly configures a mount_program."
fi

MARKER_TMP="$(mktemp)"
cat >"$MARKER_TMP" <<EOF_MARKER
VanillaOS ARM64 self-buildhost
configuration_version=${SELF_BUILDHOST_VERSION}
storage_layout_version=${SELF_BUILDHOST_STORAGE_LAYOUT}
builder_base=${SELF_BUILDHOST_IMAGE}
outer_mode=rootful
outer_unshare_all=true
outer_privileged=true
outer_graphroot_bind=true
outer_var_tmp_bind=true
host_graphroot_fstype=${SELF_BUILDHOST_HOST_GRAPHROOT_FSTYPE}
host_var_tmp_fstype=${SELF_BUILDHOST_HOST_VAR_TMP_FSTYPE}
inner_podman_cgroup_manager=cgroupfs
inner_podman_cgroups=disabled
inner_storage_driver=overlay
inner_storage_graphroot=/var/lib/containers/storage
inner_storage_native_overlay_required=true
inner_storage_fuse_allowed=false
EOF_MARKER
sudo install -D -m 0644 "$MARKER_TMP" /etc/vanilla-arm64-self-buildhost.conf
rm -f "$MARKER_TMP"

for cmd in podman buildah skopeo xorriso unsquashfs findmnt mountpoint jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not available after installation."
done

ok "Builder packages, namespace/cgroup configuration, and native-overlay policy installed."
EOF_INNER

    log "Applying builder configuration from the parent shell."
    log "The container-user sudo password may be requested once."

    if ! dbx_host enter \
        --root \
        --name "$BOX_NAME" \
        -- env \
            SELF_BUILDHOST_VERSION="$CONFIGURATION_VERSION" \
            SELF_BUILDHOST_IMAGE="$BOX_IMAGE" \
            SELF_BUILDHOST_STORAGE_LAYOUT="$STORAGE_LAYOUT_VERSION" \
            SELF_BUILDHOST_HOST_GRAPHROOT_FSTYPE="$HOST_GRAPHROOT_FSTYPE" \
            SELF_BUILDHOST_HOST_VAR_TMP_FSTYPE="$HOST_VAR_TMP_FSTYPE" \
            bash "$INNER_SCRIPT"; then
        return 1
    fi
}

run_acceptance_tests() {
    cat >"$INNER_SCRIPT" <<'EOF_TEST'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '  -> %s\n' "$*"; }
ok()  { printf '  OK %s\n' "$*"; }
die() { printf '  FAIL %s\n' "$*" >&2; exit 1; }

: "${EXPECTED_CONFIGURATION_VERSION:?missing EXPECTED_CONFIGURATION_VERSION}"
: "${EXPECTED_STORAGE_LAYOUT:?missing EXPECTED_STORAGE_LAYOUT}"
: "${EXPECTED_HOST_GRAPHROOT:?missing EXPECTED_HOST_GRAPHROOT}"
: "${EXPECTED_HOST_VAR_TMP:?missing EXPECTED_HOST_VAR_TMP}"

sudo -v

log "Validating builder identity marker."
grep -Fqx "configuration_version=${EXPECTED_CONFIGURATION_VERSION}" /etc/vanilla-arm64-self-buildhost.conf ||
    die "Builder configuration marker version mismatch."
grep -Fqx "storage_layout_version=${EXPECTED_STORAGE_LAYOUT}" /etc/vanilla-arm64-self-buildhost.conf ||
    die "Builder storage-layout marker mismatch."

log "Validating direct host-backed mount topology."
mountpoint -q /var/lib/containers/storage ||
    die "/var/lib/containers/storage is not an independent mountpoint."
mountpoint -q /var/tmp ||
    die "/var/tmp is not an independent mountpoint."

GRAPH_BIND_ID="$(stat -Lc '%d:%i' /var/lib/containers/storage)"
GRAPH_SOURCE_ID="$(stat -Lc '%d:%i' "$EXPECTED_HOST_GRAPHROOT")"
[[ "$GRAPH_BIND_ID" == "$GRAPH_SOURCE_ID" ]] ||
    die "Container graphroot does not resolve to the expected host-backed directory."

TMP_BIND_ID="$(stat -Lc '%d:%i' /var/tmp)"
TMP_SOURCE_ID="$(stat -Lc '%d:%i' "$EXPECTED_HOST_VAR_TMP")"
[[ "$TMP_BIND_ID" == "$TMP_SOURCE_ID" ]] ||
    die "Container /var/tmp does not resolve to the expected host-backed directory."

log "Checking Podman runtime and storage identity."
ROOTLESS="$(sudo podman info --format '{{.Host.Security.Rootless}}')"
CGROUP_MANAGER="$(sudo podman info --format '{{.Host.CgroupManager}}')"
[[ "$ROOTLESS" == "false" ]] || die "Inner Podman unexpectedly reports rootless=true."
[[ "$CGROUP_MANAGER" == "cgroupfs" ]] ||
    die "Expected cgroupManager=cgroupfs; got '$CGROUP_MANAGER'."

INFO_JSON="$(sudo podman info --format json)"
DRIVER="$(jq -r '.store.graphDriverName // empty' <<<"$INFO_JSON")"
GRAPHROOT="$(jq -r '.store.graphRoot // empty' <<<"$INFO_JSON")"
CONFIG_FILE="$(jq -r '.store.configFile // empty' <<<"$INFO_JSON")"
BACKING_FS="$(jq -r '.store.graphStatus["Backing Filesystem"] // empty' <<<"$INFO_JSON")"
NATIVE_DIFF="$(jq -r '.store.graphStatus["Native Overlay Diff"] // empty' <<<"$INFO_JSON")"
GRAPH_OPTIONS_TEXT="$(jq -r '(.store.graphOptions // {}) | tostring' <<<"$INFO_JSON")"

[[ "$DRIVER" == "overlay" ]] || die "Expected graphDriverName=overlay; got '$DRIVER'."
[[ "$GRAPHROOT" == "/var/lib/containers/storage" ]] ||
    die "Expected graphRoot=/var/lib/containers/storage; got '$GRAPHROOT'."
[[ "$CONFIG_FILE" == "/etc/containers/storage.conf" ]] ||
    die "Expected storage config /etc/containers/storage.conf; got '${CONFIG_FILE:-unknown}'."
[[ "$NATIVE_DIFF" == "true" ]] ||
    die "Native Overlay Diff is not true (value='${NATIVE_DIFF:-missing}', backing='${BACKING_FS:-unknown}')."

if grep -Eqi 'fuse[-.]?overlayfs|mount_program' <<<"$GRAPH_OPTIONS_TEXT"; then
    die "Podman graph options indicate a userspace/FUSE overlay mount program: $GRAPH_OPTIONS_TEXT"
fi

# containers/storage uses overlay/.has-mount-program as a cached capability/state
# marker.  The marker's PRESENCE does not mean that a userspace mount program is
# active: SupportsNativeOverlay() records either "true" or "false".  Only
# "true" indicates that this store requires/has used a mount program.
MOUNT_PROGRAM_MARKER="/var/lib/containers/storage/overlay/.has-mount-program"
if sudo test -e "$MOUNT_PROGRAM_MARKER"; then
    MOUNT_PROGRAM_STATE="$(sudo cat "$MOUNT_PROGRAM_MARKER" 2>/dev/null | tr -d '[:space:]')"
    case "$MOUNT_PROGRAM_STATE" in
        false)
            ok "containers/storage mount-program marker records false (native overlay store)."
            ;;
        true)
            die "containers/storage mount-program marker records true; optimized mode forbids FUSE fallback."
            ;;
        *)
            die "Unexpected containers/storage mount-program marker value: '${MOUNT_PROGRAM_STATE:-empty}'."
            ;;
    esac
else
    ok "No containers/storage mount-program marker is present; runtime native-overlay checks passed."
fi

ok "Storage identity: driver=$DRIVER backing=${BACKING_FS:-unknown} native_overlay_diff=$NATIVE_DIFF"

log "Pulling ARM64 Alpine self-test image."
sudo podman pull docker.io/library/alpine:latest >/dev/null

log "Testing image inspection."
sudo podman image inspect docker.io/library/alpine:latest >/dev/null

log "Testing ordinary nested container execution."
sudo podman run --rm docker.io/library/alpine:latest true

log "Testing privileged nested container execution."
sudo podman run --rm --privileged docker.io/library/alpine:latest true

TEST_DIR="$(mktemp -d)"
TEST_IMAGE="localhost/vanilla-arm64-buildhost-selftest:latest"
BUILDAH_CTR=""
cleanup_test() {
    if [[ -n "$BUILDAH_CTR" ]]; then
        sudo buildah rm "$BUILDAH_CTR" >/dev/null 2>&1 || true
    fi
    sudo podman image rm -f "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_DIR"
}
trap cleanup_test EXIT

cat >"$TEST_DIR/Containerfile" <<'EOF_CONTAINERFILE'
FROM docker.io/library/alpine:latest
RUN echo nested-podman-build-ok >/build-test
EOF_CONTAINERFILE

log "Testing nested Podman build."
sudo podman build --no-cache --rm -t "$TEST_IMAGE" "$TEST_DIR" >/dev/null

RESULT="$(sudo podman run --rm "$TEST_IMAGE" cat /build-test)"
[[ "$RESULT" == "nested-podman-build-ok" ]] ||
    die "Nested Podman build/run self-test returned unexpected output: $RESULT"

log "Testing writable Buildah run --mount bind shape."
BUILDAH_CTR="$(sudo buildah from docker.io/library/alpine:latest)"
# Buildah RUN --mount bind mounts intentionally use ephemeral RUN-mount
# semantics: writes are valid during the command but are discarded when that
# command finishes.  Validate writability and read-after-write inside the same
# Buildah invocation; do not require the probe file to propagate back to the
# source directory after buildah run exits.
sudo buildah run \
    --mount "type=bind,src=$TEST_DIR,dst=/build-context,rw" \
    "$BUILDAH_CTR" -- \
    sh -ec 'printf "%s\n" writable-run-mount-ok > /build-context/buildah-rw-probe; grep -Fxq writable-run-mount-ok /build-context/buildah-rw-probe; rm -f /build-context/buildah-rw-probe'
sudo buildah rm "$BUILDAH_CTR" >/dev/null
BUILDAH_CTR=""

log "Testing Buildah against the same deterministic storage configuration."
sudo buildah info >/dev/null

ok "Native-overlay storage and nested Podman/Buildah acceptance tests all passed."
EOF_TEST
    chmod 0700 "$INNER_SCRIPT"

    log "Running optimized nested-storage and Podman/Buildah acceptance tests."

    if ! dbx_host enter \
        --root \
        --name "$BOX_NAME" \
        -- env \
            EXPECTED_CONFIGURATION_VERSION="$CONFIGURATION_VERSION" \
            EXPECTED_STORAGE_LAYOUT="$STORAGE_LAYOUT_VERSION" \
            EXPECTED_HOST_GRAPHROOT="$HOST_GRAPHROOT" \
            EXPECTED_HOST_VAR_TMP="$HOST_VAR_TMP" \
            bash "$INNER_SCRIPT"; then
        return 1
    fi
}

verify_enter_topology() {
    log "Validating builder identity before interactive entry."

    dbx_host enter \
        --root \
        --name "$BOX_NAME" \
        --no-tty \
        -- env \
            EXPECTED_CONFIGURATION_VERSION="$CONFIGURATION_VERSION" \
            EXPECTED_STORAGE_LAYOUT="$STORAGE_LAYOUT_VERSION" \
            EXPECTED_HOST_GRAPHROOT="$HOST_GRAPHROOT" \
            EXPECTED_HOST_VAR_TMP="$HOST_VAR_TMP" \
            bash -lc '
                set -eu
                grep -Fqx "configuration_version=${EXPECTED_CONFIGURATION_VERSION}" /etc/vanilla-arm64-self-buildhost.conf
                grep -Fqx "storage_layout_version=${EXPECTED_STORAGE_LAYOUT}" /etc/vanilla-arm64-self-buildhost.conf
                mountpoint -q /var/lib/containers/storage
                mountpoint -q /var/tmp
                [ "$(stat -Lc "%d:%i" /var/lib/containers/storage)" = "$(stat -Lc "%d:%i" "$EXPECTED_HOST_GRAPHROOT")" ]
                [ "$(stat -Lc "%d:%i" /var/tmp)" = "$(stat -Lc "%d:%i" "$EXPECTED_HOST_VAR_TMP")" ]
            '
}

action_create() {
    if box_exists; then
        die "Builder '$BOX_NAME' already exists. Use --delete before --create; implicit replacement is intentionally disabled."
    fi

    prepare_external_storage

    if ! create_outer_distrobox; then
        warn "Distrobox creation/initialization failed. State is retained for diagnosis."
        die "Run --delete before retrying --create."
    fi

    if ! configure_inner_builder; then
        warn "Builder configuration failed. The partially configured builder is retained for diagnosis."
        die "Run --delete before retrying --create."
    fi

    if ! run_acceptance_tests; then
        warn "Builder failed optimized-storage acceptance. It is NOT considered ready."
        warn "Review the first FAIL line above for the authoritative cause."
        die "Inspect the failure, then run --delete before retrying --create."
    fi

    write_ready_marker
    ok "Acceptance-complete readiness marker written."
    ok "Vanilla OS ARM64 self-buildhost '$BOX_NAME' is ready."
    cat <<EOF

Validated builder definition:
  Script:                $SCRIPT_VERSION
  Name:                  $BOX_NAME
  Image:                 $BOX_IMAGE
  Mode:                  rootful, --unshare-all, outer --privileged
  Podman:                cgroupfs, cgroups disabled, inherited namespaces
  Storage driver:        overlay, kernel-native required
  FUSE fallback:         forbidden / acceptance-tested
  Host graphroot:        $HOST_GRAPHROOT
  Container graphroot:   $CONTAINER_GRAPHROOT
  Direct build temp:     $HOST_VAR_TMP -> $CONTAINER_VAR_TMP

Enter it with:
  $(basename "$0") --enter

Delete it completely with:
  $(basename "$0") --delete

EOF
}

action_enter() {
    box_exists || die "Builder '$BOX_NAME' does not exist. Create it with --create."
    state_marker_matches ||
        die "Builder external-storage ownership marker is missing or mismatched. Refusing entry."
    ready_marker_matches ||
        die "Builder has not completed acceptance successfully. Refusing entry; use --delete followed by --create."

    if ! verify_enter_topology; then
        die "Builder topology/version validation failed. Refusing entry; recreate with --delete followed by --create."
    fi

    ok "Builder identity and direct-storage topology validated."
    log "Entering '$BOX_NAME'."

    exec distrobox-host-exec env \
        DBX_SUDO_PROGRAM="$DBX_ADAPTER" \
        distrobox enter --root "$BOX_NAME"
}

action_delete() {
    validate_state_path_safety

    local had_box=0
    local had_state=0

    # Validate external ownership before changing either half of the lifecycle.
    # This prevents a mismatched/unmarked state path from producing a partial
    # delete in which the Distrobox is gone but protected external state remains.
    if [[ -e "$STATE_DIR" ]]; then
        state_marker_matches ||
            die "Refusing delete: external state exists but its ownership marker is missing or mismatched: $STATE_DIR"
    fi

    if box_exists; then
        had_box=1
        log "Removing rootful Distrobox '$BOX_NAME'."
        dbx_host rm --root -f "$BOX_NAME"
        ok "Distrobox removed."
    else
        log "No rootful Distrobox named '$BOX_NAME' is present."
    fi

    if [[ -e "$STATE_DIR" ]]; then
        had_state=1
        remove_marked_state_dir
    else
        log "No external build-storage state is present."
    fi

    if (( had_box || had_state )); then
        ok "Vanilla OS ARM64 self-buildhost lifecycle state deleted."
    else
        ok "Nothing to delete. Builder is already absent."
    fi
}

main() {
    parse_args "$@"
    require_parent_environment
    install_dbx_adapter

    case "$ACTION" in
        create) action_create ;;
        enter)  action_enter ;;
        delete) action_delete ;;
        *) die "Internal error: unresolved action '$ACTION'." ;;
    esac
}

main "$@"
