#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_step()  { echo -e "\n\033[1;36m==>\033[0m \033[1m$*\033[0m"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

trap 'log_error "Installation failed at line $LINENO: $BASH_COMMAND"' ERR

ENABLE_FALLBACK=0
BOOTLOADER_ONLY=0
for arg in "$@"; do
  if [ "$arg" == "--fallback" ]; then
    ENABLE_FALLBACK=1
  elif [ "$arg" == "--bootloader-only" ]; then
    BOOTLOADER_ONLY=1
  fi
done

echo "========================================================"
echo "  Linux Patched Automatic Kernel Installer              "
echo "  Pacman + mkinitcpio + Safe Bootloader Setup           "
echo "========================================================"

if [ $ENABLE_FALLBACK -eq 1 ]; then
  log_info "Fallback mode ENABLED (--fallback passed). Will generate fallback initramfs."
else
  log_info "Fallback mode DISABLED (default). Only standard initramfs will be built."
fi

if [ $BOOTLOADER_ONLY -eq 1 ]; then
  log_info "Bootloader-only mode requested. Skipping package installation."
else
  # Check if local compiled packages exist in output/
  LATEST_KERNEL=$(ls -1v "$OUTPUT_DIR"/linux-patched-[0-9]*.pkg.tar.zst 2>/dev/null | tail -n 1 || true)

  if [ -n "$LATEST_KERNEL" ] && [ -f "$LATEST_KERNEL" ]; then
    log_step "Step 1: Installing latest locally compiled kernel package(s)..."
    PKGS=("$LATEST_KERNEL")
    LATEST_HEADERS=$(ls -1v "$OUTPUT_DIR"/linux-patched-headers-[0-9]*.pkg.tar.zst 2>/dev/null | tail -n 1 || true)
    if [ -n "$LATEST_HEADERS" ] && [ -f "$LATEST_HEADERS" ]; then
      PKGS+=("$LATEST_HEADERS")
    fi
    for p in "${PKGS[@]}"; do
      log_info "  -> $(basename "$p")"
    done
    sudo pacman -U --noconfirm "${PKGS[@]}"
    log_ok "Local kernel package(s) installed."
  else
    log_step "Step 1: No local build artifacts found; using Pacman repository..."
    
    # Check if [panz] repository is configured in /etc/pacman.conf
    if ! grep -q "^\[panz\]" /etc/pacman.conf 2>/dev/null; then
      log_info "Adding [panz] repository to /etc/pacman.conf..."
      sudo bash -c 'cat >> /etc/pacman.conf' << 'EOF'

[panz]
SigLevel = Optional TrustAll
Server = https://github.com/ppanzenboeck/linux/releases/download/packages
EOF
      log_ok "[panz] repository added to /etc/pacman.conf."
    fi

    log_info "Installing linux-patched and linux-patched-headers via pacman..."
    sudo pacman -Sy --noconfirm linux-patched linux-patched-headers
    log_ok "Repository kernel package(s) installed."
  fi
fi

log_step "Step 2: Configuring mkinitcpio presets..."
PRESET_FILE="/etc/mkinitcpio.d/linux-patched.preset"
if [ -f "$PRESET_FILE" ]; then
  if [ $ENABLE_FALLBACK -eq 1 ]; then
    sudo sed -i "s/^PRESETS=.*/PRESETS=('default' 'fallback')/" "$PRESET_FILE"
    log_info "Configured preset for: default + fallback"
  else
    sudo sed -i "s/^PRESETS=.*/PRESETS=('default')/" "$PRESET_FILE"
    log_info "Configured preset for: default only"
    
    # Remove any existing fallback files to preserve /boot space
    if [ -f "/boot/initramfs-linux-patched-fallback.img" ]; then
      log_info "Removing old fallback initramfs image to free ~200MB in /boot..."
      sudo rm -f "/boot/initramfs-linux-patched-fallback.img"
    fi
    if [ -f "/boot/loader/entries/linux-patched-fallback.conf" ]; then
      sudo rm -f "/boot/loader/entries/linux-patched-fallback.conf"
    fi
  fi
fi

log_step "Step 3: Generating initramfs via mkinitcpio..."
sudo mkinitcpio -p linux-patched
log_ok "Initramfs generated successfully."

log_step "Step 4: Checking bootloader configuration..."
BOOTLOADER_UPDATED=0

# Detection A: systemd-boot
if [ -d "/boot/loader/entries" ]; then
  log_info "Detected systemd-boot."
  ENTRY_FILE="/boot/loader/entries/linux-patched.conf"
  
  if [ -f "$ENTRY_FILE" ]; then
    log_ok "Boot entry $ENTRY_FILE already exists. Leaving untouched."
    BOOTLOADER_UPDATED=1
  else
    log_info "Creating new systemd-boot entry: $ENTRY_FILE..."
    
    # Extract options from an existing non-fallback entry
    EXISTING_ENTRY=$(ls -1 /boot/loader/entries/*.conf 2>/dev/null | grep -v 'fallback' | head -n 1 || true)
    OPTIONS="rw"
    UCODE=""
    if [ -n "$EXISTING_ENTRY" ] && [ -f "$EXISTING_ENTRY" ]; then
      OPTIONS=$(grep '^options' "$EXISTING_ENTRY" | sed 's/^options[[:space:]]*//' || echo "rw")
    fi

    # Detect microcode
    if [ -f "/boot/intel-ucode.img" ]; then
      UCODE="initrd  /intel-ucode.img"
    elif [ -f "/boot/amd-ucode.img" ]; then
      UCODE="initrd  /amd-ucode.img"
    fi

    sudo bash -c "cat > '$ENTRY_FILE'" <<EOF
title   Arch Linux Patched
linux   /vmlinuz-linux-patched
${UCODE}
initrd  /initramfs-linux-patched.img
options ${OPTIONS}
EOF
    log_ok "Created $ENTRY_FILE safely alongside your other boot entries."
    BOOTLOADER_UPDATED=1
  fi

  # Handle fallback entry if requested
  ENTRY_FB="/boot/loader/entries/linux-patched-fallback.conf"
  if [ $ENABLE_FALLBACK -eq 1 ]; then
    if [ ! -f "$ENTRY_FB" ]; then
      sudo bash -c "cat > '$ENTRY_FB'" <<EOF
title   Arch Linux Patched (fallback initramfs)
linux   /vmlinuz-linux-patched
${UCODE}
initrd  /initramfs-linux-patched-fallback.img
options ${OPTIONS}
EOF
      log_ok "Created fallback entry $ENTRY_FB"
    fi
  else
    sudo rm -f "$ENTRY_FB"
  fi
fi

# Detection B: GRUB
if [ -f "/boot/grub/grub.cfg" ]; then
  log_info "Detected GRUB bootloader. Updating grub.cfg..."
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  log_ok "GRUB configuration updated."
  BOOTLOADER_UPDATED=1
fi

echo ""
echo "========================================================"
echo -e "\033[0;32m  Installation Completed Successfully! \033[0m"
echo "========================================================"
echo "Active kernel images:"
echo " • Kernel:    /boot/vmlinuz-linux-patched"
echo " • Initramfs: /boot/initramfs-linux-patched.img"
if [ $ENABLE_FALLBACK -eq 1 ]; then
  echo " • Fallback:  /boot/initramfs-linux-patched-fallback.img"
fi
echo ""
echo "All other custom boot entries remain completely untouched."
echo "You can now reboot whenever you are ready: sudo reboot"
