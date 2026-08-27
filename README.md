# Vanilla OS Snapdragon X ISO Builder

Build profile-aware **Vanilla OS 3 (Reunion)** installer media for Qualcomm Snapdragon X ARM64 systems.

This build harness wraps the official Vanilla OS vib-based image and live-ISO build tooling for Snapdragon X target devices, keeping the official release ARM64 image composition owned by upstream Vanilla OS. 

This build harness allows addition of hardware-specific artifacts that aren't yet supplied by the upstream installer path: 
- kernel packages 
- DTB selection 
- Qualcomm firmware
- boot integration

Additionally, this build harness includes installation-time storage validation and deterministic offline delivery of the custom target image.

The current accepted baseline is **v8.5-r5.2**, the Reunion stable-release convergence revision. It has completed the full cycle of:

**Vanilla OS on Snapdragon X → self-hosted build environment → installer ISO → live boot → installation → installed Vanilla OS system → reboot and runtime validation.**

Included in this repository is a tools/ directory, containing the script necessary to generate a complete custom Distrobox environment that is capable of running the harness on a VanillaOS ARM64 build host.

These efforts are an independent community project and not an official Vanilla OS effort or directly connected to upstream work by Canonical/Ubuntu Concept x1e projects.

---

## What the builder does

`build-vanilla-snapdragon-x.sh` orchestrates a complete ARM64 installer build while preserving the major upstream Vanilla OS boundaries.

At a high level it:

- synchronizes the official Vanilla OS `custom-image` and `live-iso` sources;
- builds a Snapdragon-aware target OCI image derived from the stable Vanilla OS GNOME image;
- installs the supplied kernel package closure and required Qualcomm firmware;
- binds the selected kernel, DTB, firmware, and boot arguments to a hardware profile;
- verifies the installed-target boot and storage contracts before release;
- builds an upstream-derived ARM64 Vanilla OS live ISO;
- adds only the hardware-specific live boot payload and installer integration needed for the target profile;
- OPTIONALLY embeds the verified target OCI image into the ISO for OFFLINE installation without OCI image hosting;
- provides a supervised loopback OCI registry bridge for Vanilla Installer;
- preserves deterministic provenance and validation evidence alongside the finished ISO.

The normal VanillaOS 3.0 Reunion path uses:

- `ghcr.io/vanilla-os/gnome:latest` as the target image base;
- `ghcr.io/vanilla-os/pico:latest` as the live/build container;
- the upstream `live-iso:orchid` ARM64 package-selection logic;
- Vib 1.1.x;
- Podman by default;
- the Reunion VSO/Apx/Distrobox stack, including the managed `apx-vso-native` subsystem.

Generic ARM64 support is intentionally left to upstream Vanilla OS wherever possible. This project concentrates on Snapdragon X hardware enablement and deterministic installer delivery.

---

## Device support model

The builder is designed around **hardware profiles**, not a single laptop vendor or model.

A profile describes the hardware-specific build inputs and validation requirements for a Snapdragon X target, including such things as:

- architecture;
- kernel release and package selection;
- device-tree blob;
- required firmware paths;
- board-data policy where necessary;
- kernel command-line additions;
- installer behavior and delivery policy.

Current development has been validated on real Snapdragon X hardware, but those systems are test targets rather than architectural defaults. 

Future revisions are intended to offer runtime target device selection and profile selection - so additional Snapdragon X1E, X1P, and related systems can be supported without changing the generic build architecture.

The harness already supports an explicit profile manifest:

```text
--profile NAME
--profile-file PATH
```

Profile lookup order is:

```text
--profile-file PATH
WORKDIR/profiles/$PROFILE/profile.json
WORKDIR/profiles/$PROFILE.json
synthesized compatibility profile when neither file exists
```

Configuration precedence is:

```text
CLI option > environment variable > profile manifest > deterministic discovery
```

---

## Required build artifacts

The Git repository contains the build harness and the self-buildhost tooling. A completely reproducible device build still requires the hardware artifacts appropriate to the selected target.

The preferred layout is:

```text
artifacts/<profile>/
├── firmware-debs/
│   ├── <firmware-package>.deb
│   └── <firmware-package>.deb.sha256
├── kernel-debs/
│   ├── <kernel-image-or-related-package>.deb
│   ├── <kernel-modules-or-related-package>.deb
│   └── <optional-local-dependency>.deb
├── dtb/
│   └── <device>.dtb
└── firmware/
    └── ...                       # overlay relative to /usr/lib/firmware
```

The builder does **not** depend on a particular kernel package filename or Debian `Package:` naming convention. It examines package metadata, payload ownership, kernel release identity, and local dependency relationships to determine the target package closure.

Signed kernel packages will allow for secure boot enablement. Existing test targets have been unsigned, with secure boot disabled for these devices.

Firmware packages should be accompanied by SHA-256 provenance. The harness records the resolved firmware package set, staged firmware inventory, target-image digest, upstream OCI digests, source Git commits, installer patches, and final release checksums.

At present, the externally maintained **kernel and device-specific firmware artifacts** are the main pieces that must be supplied by the builder, in addition to a fresh clone of this repository.

---

## Basic use

Clone the repository and place the required hardware artifacts beneath the selected profile:

```bash
git clone https://github.com/JeremiahCornelius/Vanilla-OS-Snapdragon-X-ISO-Builder.git
cd Vanilla-OS-Snapdragon-X-ISO-Builder
```

Review all available builder options:

```bash
./build-vanilla-snapdragon-x.sh --help
```

A plan run resolves the profile, source policy, package inputs, firmware, kernel, DTB, and final execution arguments without performing the image build:

```bash
sudo ./build-vanilla-snapdragon-x.sh --plan
```

For an interactive build:

```bash
sudo ./build-vanilla-snapdragon-x.sh --execute
```

Interactive mode is the normal operator workflow. The harness validates repositories and build inputs before asking for final confirmation.

For a fully preconfigured build, the same settings can be supplied through a profile, environment variables, or command-line options and used with:

```bash
sudo ./build-vanilla-snapdragon-x.sh --execute --non-interactive --yes
```

The builder is intentionally fail-closed around ambiguous kernel selection, missing firmware provenance, unexpected source changes, invalid storage topology, target-image digest mismatches, and incomplete installer state.

Build output is written beneath the repository work tree by default:

```text
output/
├── logs/
└── releases/
```

Each successful release includes the final ISO, SHA-256 checksums, source and OCI provenance, hardware-profile resolution, package closure evidence, firmware inventory, installer evidence, boot expectations, and copies of the harness needed to identify the exact build.

---

## Building from Vanilla OS (aarch64) build host

The repository includes:

```text
tools/vanilla-self-buildhost.sh
```

This utility creates and manages a dedicated **self-hosted ARM64 build environment on Vanilla OS**. It is intended to be run from an Apx/VSO-managed parent shell that provides `distrobox-host-exec`.

The lifecycle is:

```bash
tools/vanilla-self-buildhost.sh --create
tools/vanilla-self-buildhost.sh --enter
tools/vanilla-self-buildhost.sh --delete
```

`--create` constructs and acceptance-tests a rootful Pico-based Distrobox with nested Podman/Buildah and host-backed native OverlayFS storage. The tool refuses FUSE-overlay fallback in its optimized build path and verifies the complete nested container/storage topology before marking the environment ready.

`--enter` validates that the expected builder identity and storage topology are still present before entering the environment.

`--delete` removes the Distrobox and its dedicated marker-protected external build storage.

Once inside the accepted self-buildhost, clone or access this repository and run the same builder commands shown above.

This configuration has demonstrated the intended self-hosting cycle: an installed Vanilla OS Snapdragon X system can build a new Vanilla OS Snapdragon X installer ISO from the repository plus the required kernel, DTB, and firmware artifacts.

---

## Installer architecture

The installed system is not reconstructed by a collection of post-install shell fixes.

The builder produces a verified custom target OCI image and embeds that image into the installation ISO. Vanilla Installer consumes the profile-bound image through an ISO-local OCI Distribution v2 bridge on loopback. The installer recipe, target manifest digest, ABRoot configuration, selected kernel/DTB, firmware provenance, and storage expectations are checked as part of the release process.

Important design properties include:

- offline target-image delivery from the ISO;
- exact target OCI manifest-digest binding;
- deterministic kernel and DTB selection;
- preservation of upstream Vanilla OS package composition where possible;
- profile-aware storage validation, including encrypted `/var`;
- exactly one live Installer autostart path;
- systemd ownership of the ISO-local registry bridge;
- live-only GDM timed login;
- no requirement for runtime package-manager tooling in the immutable installed image.

---

## Current status

**Accepted baseline: `v8.5-r5.2`**

The accepted Reunion-convergence baseline has successfully demonstrated:

- ARM64 self-hosted ISO construction on an installed Vanilla OS Snapdragon X system;
- complete target OCI and live-ISO build;
- boot of the generated installer media on Snapdragon X hardware;
- successful Vanilla Installer completion;
- installed Vanilla OS 3.0 graphical boot under GNOME/Wayland;
- accelerated Qualcomm Adreno graphics;
- custom Snapdragon kernel and DTB operation;
- persistent installed storage across reboot;
- VSO/Apx/Distrobox operation;
- the managed `apx-vso-native` subsystem;
- reboot-survival of the installed system.

The project remains under active development. Hardware compatibility depends on the quality and completeness of the kernel, DTB, firmware, and profile supplied for a particular Snapdragon X system.

---

## Project direction

The immediate goal is to make Snapdragon X installation increasingly **profile-driven and device-selectable** while continuing to delegate generic ARM64 and Vanilla OS behavior upstream.

Areas expected to evolve include:

- additional Snapdragon X hardware profiles;
- easier target-device selection;
- stronger publication and retrieval of kernel/firmware artifact provenance;
- reduction of compatibility code as upstream Vanilla OS and Debian/testing absorb more ARM64/Snapdragon functionality;
- continued convergence with current Vanilla OS image, Installer, VSO, Apx, and Distrobox contracts.

A central design objective is that a successfully installed system should require no ephemeral repair procedure to become the system the installer was intended to produce.

---

## Credits

This project exists because of substantial upstream and community work.

### Vanilla OS

[Vanilla OS](https://vanillaos.org/) and the [Vanilla-OS GitHub organization](https://github.com/Vanilla-OS) provide the operating system architecture and the principal upstream components used here, including ABRoot, Apx, Vib, Vanilla Installer, the official custom-image scaffold, OCI desktop images, Pico image, and live-ISO tooling.

This builder is an adaptation of those upstream mechanisms for Snapdragon X hardware; it is not a forked replacement for the Vanilla OS distribution.

### Ubuntu Concept — Snapdragon X Elite

Canonical's experimental [Ubuntu Concept Snapdragon X Elite](https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800) effort and its [X1E package archive](https://launchpad.net/~ubuntu-concept/+archive/ubuntu/x1e) have provided essential ARM64/Qualcomm enablement work, package integration, device support knowledge, and a practical reference for bringing Linux desktop systems up on Snapdragon X laptops.

The Ubuntu Concept project has been particularly important in advancing the `linux-qcom-x1e` hardware-support path and in demonstrating broad Snapdragon X laptop compatibility beyond any single vendor.

### Jens Glathe / `jglathe`

Special credit goes to **Jens Glathe (`jglathe`)** for his continuing Snapdragon laptop kernel and device-enablement work.

His extensive and ongoing fork,[`linux_ms_dev_kit`](https://github.com/jglathe/linux_ms_dev_kit) repository maintains a Linux kernel source tree for Snapdragon 8cx Gen 3 and Snapdragon X-based laptops, publishes tested kernel package sets, carries device-specific enablement work, and builds on the Ubuntu Concept X1E kernel configuration and ecosystem.

The custom `*-jg-*-qcom-x1e` kernel packages used during development and acceptance of this project derive from that work. Jens Glathe and contributor's kernel maintenance, testing, DTB work, install-media experimentation, and public documentation have been an important foundation for making our current Snapdragon X target systems practical.