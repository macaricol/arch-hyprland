# Arch Linux + Hyprland (Caelestia) installer

Unattended-ish installer for a UEFI machine: Btrfs root with `@`/`@home`
subvolumes, RAM-sized swap with working hibernation, GRUB, Hyprland with the
[Caelestia](https://github.com/caelestia-dots/shell) shell and dots, GPU
drivers (64- and 32-bit), Steam, and a handful of AUR packages. Tuned for Portuguese locale/keyboard by default — see `config.sh`.

## Quick start

Boot the official Arch ISO, connect to the network, and run:

    curl -fsSL https://raw.githubusercontent.com/macaricol/arch-hyprland/main/bootstrap.sh | bash

Answer four prompts (hostname, root password, username, user password),
pick the drive from an arrow-key menu, type `YES`, and walk away. The
machine reboots into a one-time tty autologin that runs the desktop setup,
then reboots again into SDDM; pick the Hyprland session and log in. Two
reboots in total, and one password prompt after the first.

Hyprland needs working GPU acceleration. In a VM, enable 3D acceleration
(VirtualBox: VMSVGA + "Enable 3D Acceleration"; QEMU: virtio-gpu with
`gl=on`), or the session may not start.

To install from a different branch: `curl ... | BRANCH=clauding bash`.

**This erases the selected drive.** Test in a VM first.

### No-typing USB

`tools/build-autoinstall-iso.sh` adds an "Automated Install" entry to an
official ISO's boot menu that runs the command above by itself:

    sudo pacman -S --needed xorriso squashfs-tools
    sudo tools/build-autoinstall-iso.sh

Run with no arguments it asks whether to fetch the current official ISO or
use one you already have. `--download` skips the question for scripted use,
and an explicit path still works as before:

    sudo tools/build-autoinstall-iso.sh --download my-autoinstall.iso
    sudo tools/build-autoinstall-iso.sh archlinux-x86_64.iso archlinux-autoinstall.iso

Downloads land in the current directory under their dated release name, are
checked against the mirror's `sha256sums.txt` and GPG-verified against the
pacman keyring, and are reused instead of re-fetched on later runs. The
mirror is `ISO_MIRROR` in `config.sh`.

## How it fits together

    bootstrap.sh          fetches the repo tarball to /tmp, runs setup.sh install
    setup.sh <phase>      single entry point; loads config + lib, runs one phase
    config.sh             every tunable value: locale, disk, package lists, theme
    lib/ui.sh             messages, step counter, run() spinner + setup.log
    lib/prompt.sh         validated input, passwords, confirm, arrow-key menu
    lib/system.sh         checks, CPU/GPU detection, pacman/AUR/service helpers
    phases/install.sh     live ISO: partition, format, pacstrap, hand off to chroot
    phases/chroot.sh      locale, accounts, sudo, hibernation, GRUB, first-login hook
    phases/post.sh        first login: multilib, drivers, SDDM, Samba, Steam, AUR, Caelestia

The installer directory travels with the install: `/tmp/arch-setup` on the
ISO → `/root/arch-setup` in the chroot → `~/.arch-setup` for the post
phase, which deletes it once it succeeds, leaving only `~/arch-setup.log`.
If the post phase fails, the copy stays so it can be re-run with
`bash ~/.arch-setup/setup.sh post`.

Every command that goes through `run()` is logged there, with its full
output shown on the terminal only if it fails. `VERBOSE=1 setup.sh <phase>`
streams everything live instead.

## Running phases by hand

From a local checkout, phases can be run directly — useful for re-applying
the desktop setup or iterating on it:

    ./setup.sh post        # as your user; idempotent (--needed everywhere)

Running from a checkout never deletes it; only the staged `~/.arch-setup`
copy cleans itself up.

## Configuration

Everything lives in `config.sh`: timezone, keymaps, locales, mirror
countries, EFI size, Btrfs mount options, the package lists (`BASE_`,
`DESKTOP_`, `EXTRA_`, `GAMING_`, `AUR_PACKAGES`, per-vendor `GPU_PACKAGES_*`),
the surround-upmix settings (`UPMIX_*`), the Caelestia components and
Hyprland variables (`CAELESTIA_*`, `HYPR_VARS`), the SDDM theme and
wallpaper, and the Samba workgroup.

### Customising the desktop afterwards

Caelestia owns `~/.config/hypr/` and overwrites it on `caelestia update`, so
don't edit it. Personal changes go in the two files it never touches, both
seeded by the installer:

- `~/.config/caelestia/hypr-vars.lua` — default apps, keybinds, borders,
  blur... (every key is in the dots' `hypr/variables.lua`)
- `~/.config/caelestia/hypr-user.lua` — any other Hyprland config: monitor
  layout, extra binds, window rules. The keyboard layout is set here.

The shell itself is configured in `~/.config/caelestia/shell.json`. Press
`Super` to open the launcher; the full keybind list is in the
[dots README](https://github.com/caelestia-dots/caelestia#default-keybinds).
Update everything (system and dots) with `caelestia update`.

## Design notes

Things that look odd but are deliberate:

- **Passwords** are written to a root-only `creds` file inside the staged
  installer for the chroot phase (deleted first thing there, and by a trap
  if the chroot never starts), then fed to `chpasswd` on stdin — they never
  appear in argv, the environment, or the log.
- **32-bit GPU drivers are installed before Steam.** `steam` depends on the
  virtual `lib32-vulkan-driver`, and `pacman --noconfirm` picks the first
  provider — `lib32-nvidia-utils`, which pulls the whole NVIDIA userspace
  even on AMD/Intel. Having the right provider installed first avoids that.
  With no Intel/AMD/NVIDIA GPU detected (VMs), only plain `mesa` is installed
  and Steam is skipped: software Vulkan (`vulkan-swrast`) would satisfy the
  dependency, but a 64-bit Vulkan device makes the SDDM theme's video
  background render blank under VirtualBox.
- **Surround upmixing is written twice**, to
  `/etc/pipewire/client.conf.d/` and `/etc/pipewire/pipewire-pulse.conf.d/`.
  PipeWire mixes channels in the client library, so the native path (mpv,
  Zen) and the PulseAudio path each need their own copy — configure one and
  half your applications silently stay stereo. Upmixing is off in stock
  PipeWire: without this, a stereo stream on a 5.1/7.1 card only ever
  reaches front L/R. `lfe-cutoff`/`fc-cutoff` have to be set explicitly too;
  left at their defaults the subwoofer and centre stay silent even with
  `channelmix.upmix = true`. Nothing is set for mpv on purpose — forcing
  `audio-channels=7.1` makes mpv pad the extra channels itself, so PipeWire
  sees 8 channels and skips the upmix.
- **Microcode goes in with `pacstrap`**, so the first initramfs and
  `grub.cfg` already include it and nothing needs regenerating later.
- **The post phase enables SDDM without `--now`.** `sddm.service` conflicts
  with `getty@tty1`; starting it would SIGHUP the very session the phase is
  running in. The reboot starts it.
- **Passwordless `sudo pacman`** exists only during the AUR and Caelestia
  steps (makepkg's own sudo calls don't see the cached ticket) and is removed
  right after, with the EXIT trap as backstop.
- **Caelestia is installed with its own installer**, `caelestia install
  --noconfirm`, instead of copying its packages and configs here, so
  `caelestia update` keeps working. It runs from the tty, before Hyprland
  has ever started: its post-install hooks (`hyprctl reload`, starting the
  shell) only warn there, and Hyprland's own `exec-once` starts the shell
  on first login.
- **`papirus-folders` may run through sudo without a password**
  (`/etc/sudoers.d/50-papirus-folders`), as the Caelestia CLI requires to
  recolour folder icons to match the scheme. That is the only permanent
  sudo exception.
- **The colour scheme is set to `dynamic`** before the wallpaper, so the
  whole desktop takes its colours from `WALLPAPER`.
- The live USB is filtered out of the drive menu, and `udevadm settle`
  runs after partitioning so the new device nodes exist before they're used.

## Annex: installed packages

Grouped as they appear in `config.sh`, which is the source of truth — this
table is a description of those lists, not a second copy of them.

### `BASE_PACKAGES` — pacstrapped onto the new root

| Package | Purpose |
|---|---|
| `base` | Core meta-package for a minimal Arch system (glibc, pacman, systemd) |
| `linux` | The main Linux kernel |
| `linux-firmware` | Firmware blobs for hardware devices (Wi-Fi, GPU, etc.) |
| `btrfs-progs` | Btrfs filesystem tools, needed for the `@`/`@home` subvolumes |
| `grub` | Bootloader |
| `efibootmgr` | UEFI boot manager, required by GRUB in UEFI mode |
| `nano` | Simple text editor, so the installed system is usable before a desktop exists |
| `networkmanager` | Network management daemon (Wi-Fi, Ethernet, VPN) |
| `sudo` | Lets the created user run commands as root |

CPU microcode (`intel-ucode` / `amd-ucode`) is added here too, picked from the
detected vendor — see the design note on why it goes in at this stage.

### GPU drivers — `GPU_PACKAGES_*`, by detected vendor

- **Intel** — `mesa`, `lib32-mesa`, `vulkan-intel`, `lib32-vulkan-intel`,
  `intel-media-driver`: graphics drivers (64- and 32-bit), Vulkan, and
  hardware video decode/encode
- **AMD** — `mesa`, `lib32-mesa`, `vulkan-radeon`, `lib32-vulkan-radeon`,
  `radeontop`: the same, plus a GPU usage monitor
- **NVIDIA** — `nvidia-open`, `nvidia-utils`, `lib32-nvidia-utils`,
  `nvidia-settings`, `opencl-nvidia`: open kernel modules plus the userspace
  driver (64- and 32-bit), config GUI, OpenCL. `nvidia-open` drives Turing
  (RTX 20xx) and newer only; older cards fall back to nouveau, since the
  proprietary package no longer exists in the repos.
- **Fallback** (VMs, unrecognised hardware) — `mesa`, `lib32-mesa` only.
  Deliberately no software Vulkan: see the design note above.

Hybrid setups get every matching vendor. The 32-bit halves are what Steam
needs, and installing them first is what stops pacman pulling the NVIDIA
userspace onto an AMD or Intel machine.

### Caelestia — `caelestia install`

The bulk of the desktop. With the default components (minus `firefox`,
plus `zen` and `vscode` — `CAELESTIA_ENABLE`/`_DISABLE`) this installs:

- **Desktop** — `hyprland`, `caelestia-shell` (Quickshell-based bar,
  launcher, notifications, lock screen, dashboards), `caelestia-cli`,
  `xdg-desktop-portal-hyprland` and `-gtk`
- **Terminal & shell** — `foot`, `fish` (with `starship`, `eza`, `zoxide`),
  `btop`, `micro`, `fastfetch`
- **Files** — `thunar`
- **Theming** — `adw-gtk-theme`, `darkly-bin` (Qt), `papirus-icon-theme`,
  Nerd and Noto fonts
- **System** — `gnome-keyring`, `polkit-gnome`, `bluez`, PipeWire with
  `pwvucontrol`, `wl-clipboard`/`cliphist`, `hyprpicker`, `xdg-user-dirs`
- **Apps** — `zen-browser-bin`, `code` (with Caelestia's theme extension)

The authoritative list is the dots'
[`manifest.toml`](https://github.com/caelestia-dots/caelestia/blob/main/manifest.toml).

### `DESKTOP_PACKAGES` — on top of Caelestia

- `sddm` — Login screen (display manager); Caelestia ships none
- `qt6-svg`, `qt6-virtualkeyboard`, `qt6-multimedia-ffmpeg` — what the
  astronaut SDDM theme needs (KDE used to pull these in)
- `thunar-archive-plugin`, `file-roller` — "Extract here" / "Compress" in Thunar
- `tumbler`, `ffmpegthumbnailer` — image and video thumbnails in Thunar
- `gvfs`, `gvfs-smb` — Trash, removable drives and `smb://` browsing in Thunar
- `featherpad` — Lightweight GUI text editor
- `pipewire-jack` — JACK audio via PipeWire; installed before Steam so
  pacman doesn't pick another JACK provider

### `EXTRA_PACKAGES` — applications and fonts

- `fastfetch` — System information display
- `mpv` — Lightweight, scriptable video player
- `krdc` — Remote desktop client (VNC/RDP)
- `git` — Version control
- `ttf-liberation` — Metric-compatible Arial / Times New Roman / Courier New
- `noto-fonts-cjk` — Chinese, Japanese and Korean coverage
- `ntfs-3g`, `exfatprogs`, `dosfstools` — format and repair NTFS, exFAT and
  FAT32. Only formatting and repair need these; mounting works without them.

### `GAMING_PACKAGES` and `AUR_PACKAGES`

- `steam` — Installed only when a real GPU was detected, and after the 32-bit
  drivers, for the reason in the design notes. Needs the multilib repo, which
  the post phase enables.
- `base-devel` — Build tools, required to compile anything from the AUR
- `paru` (AUR) — AUR helper, built from source so it always matches the
  installed pacman's libalpm; the Rust toolchain is removed again afterwards
- `caelestia-cli` (AUR) — Caelestia's CLI; installed first because it is
  the installer for everything else in the section above
- `qview` (AUR) — Lightweight, fast image viewer
