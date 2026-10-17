# Linux Mainline Kernel Builder & Patch Manager

A complete, automated toolchain to compile the latest mainline Arch Linux kernel from scratch with custom kernel patches, automatic upstream synchronization, and safe bootloader installation.

---

## Features

- **Automated Upstream Sync (`update.sh`)**: Automatically discovers the latest Arch Linux kernel release tag, downloads release sources, updates `PKGBUILD`, and recalculates checksums.
- **Intelligent Patch Detection**: Automatically tests custom patches before compiling. If a patch is **already merged upstream** (such as the ASUS touchpad fix approved for Linux 7.4+), it automatically skips applying it without breaking the build.
- **Fast Multithreaded Compilation (`build.sh`)**: Compiles with all CPU cores and packages flashable Zstandard `.pkg.tar.zst` packages into `output/`.
- **Safe Bootloader & Initramfs Installer (`install.sh`)**:
  - Automatically installs the latest compiled packages via `pacman`.
  - Generates initramfs via `mkinitcpio`.
  - Non-destructively configures **systemd-boot** (or **GRUB**) while keeping all other custom kernel entries and settings completely untouched.
  - Generates compact, space-saving initramfs images by default (with opt-in `--fallback` support).

---

## Repository Structure

```text
.
├── PKGBUILD               # Arch Linux kernel packaging recipe with auto patch detection
├── config.x86_64          # Kernel compilation configuration (.config)
├── linux-patched.preset   # Initramfs mkinitcpio preset
├── patches/               # Active patches applied during build
│   └── 0001-fix-asus-touchpad-7.1-regression.patch
├── build.sh               # 1-click script to compile the kernel
├── update.sh              # Upstream sync tool (fetches latest Arch Linux releases)
├── install.sh             # Automatic pacman + mkinitcpio + bootloader installer
├── publish.sh             # Deploys packages and pacman db to GitHub Releases
└── check-patch-status.sh  # Quick status checker against hid.git and mainline
```

---

## Quick Start

### 1. Build the Latest Kernel
```bash
./build.sh
```

### 2. Install on Your Machine
```bash
./install.sh
```

### 3. Deploy to Your Own Pacman Repository (GitHub Releases)
To share pre-compiled packages with your other laptops, desktops, or friends:
```bash
./publish.sh
```
Or build and publish in one command:
```bash
./build.sh --publish
```

### 4. Subscribe to the Repository from Any Machine
Add these 3 lines to the bottom of `/etc/pacman.conf` on any Arch Linux machine:
```ini
[panz]
SigLevel = Optional TrustAll
Server = https://github.com/ppanzenboeck/linux/releases/download/packages
```
Then update your kernel anytime alongside official packages:
```bash
sudo pacman -Syu linux-patched linux-patched-headers
```

---

### 5. Update to Future Kernel Releases
Whenever Arch Linux releases a new kernel version (e.g. 7.2.11, 7.3, 7.4):
```bash
# Update PKGBUILD and verify patches:
./update.sh

# Or update, compile, and publish in a single command:
./update.sh --build --publish
```

---

## Included Custom Patches

- **`0001-fix-asus-touchpad-7.1-regression.patch`**:
  Fixes a regression introduced in Linux 7.1 where sending keyboard feature initialization reports to ASUS I2C touchpads (such as on ASUS E200HA and VivoBook Flip models) corrupts the hardware probe state and disables the touchpad.
  - **Status**: Approved by ASUS driver maintainers and queued for upstream inclusion in Linux 7.4.
  - **Auto-Detection**: The build system tests for upstream presence and will automatically skip this patch once Linux 7.4 is reached.

---

## License

GPL-2.0
