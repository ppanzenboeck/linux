#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
PATCHES_DIR="${SCRIPT_DIR}/patches"
export PATH="${SCRIPT_DIR}/bin:$PATH"

# Color helpers
log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_step()  { echo -e "\n\033[1;36m==>\033[0m \033[1m$*\033[0m"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Catch and report exact failing line
trap 'log_error "Build script failed at line $LINENO: $BASH_COMMAND"' ERR

echo "========================================================"
echo "  Linux Patched Package Builder (Verbose Mode)          "
echo "  Kernel Generator with Auto Upstream Patch Detection   "
echo "========================================================"

START_TIME=$(date +%s)

log_step "Step 1: Checking build dependencies..."
REQUIRED_TOOLS=(makepkg updpkgsums git patch gcc bc flex bison pahole)
MISSING_DEPS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING_DEPS+=("$tool")
  else
    log_ok "Found tool: $tool"
  fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
  log_error "Missing required build tools: ${MISSING_DEPS[*]}"
  echo "Please install them via: sudo pacman -S --needed base-devel git bc flex bison pahole pacman-contrib"
  exit 1
fi

log_step "Step 2: Preparing output directory..."
mkdir -p "$OUTPUT_DIR"
log_ok "Output directory ready at: $OUTPUT_DIR"

log_step "Step 3: Discovering custom patches in patches/..."
PATCH_COUNT=0
if [ -d "$PATCHES_DIR" ]; then
  for p in "$PATCHES_DIR"/*.patch; do
    if [ -f "$p" ]; then
      log_info "Found patch: $(basename "$p")"
      PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
  done
fi

if [ $PATCH_COUNT -eq 0 ]; then
  log_warn "No .patch files found in patches/. Kernel will build purely stock."
else
  log_ok "Found $PATCH_COUNT patch(es) ready to be tested/applied by PKGBUILD prepare()."
fi

log_step "Step 4: Ensuring source checksums match in PKGBUILD..."
cd "$SCRIPT_DIR"
updpkgsums

log_step "Step 5: Starting kernel compilation with makepkg..."
CPU_CORES=$(nproc)
log_info "Compiling on all $CPU_CORES threads using MAKEFLAGS=\"-j$CPU_CORES\"..."
log_info "Package compression: zstandard (.pkg.tar.zst)"
export MAKEFLAGS="-j${CPU_CORES}"

PKGEXT='.pkg.tar.zst' makepkg -fdc --noconfirm

log_step "Step 6: Collecting generated packages into output/..."
MOVED_COUNT=0
for pkg in *.pkg.tar.zst *.pkg.tar.xz; do
  if [ -f "$pkg" ]; then
    log_info "Moving artifact: $pkg -> $OUTPUT_DIR/"
    mv -f "$pkg" "$OUTPUT_DIR/"
    MOVED_COUNT=$((MOVED_COUNT + 1))
  fi
done

if [ $MOVED_COUNT -eq 0 ]; then
  log_warn "No new .pkg.tar.* files found in root directory (they might already be in output/)."
else
  log_ok "Collected $MOVED_COUNT artifact(s) into $OUTPUT_DIR/"
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "========================================================"
echo -e "\033[0;32m  Build Completed Successfully in ${ELAPSED}s! \033[0m"
echo "========================================================"
echo "Flashable artifacts generated in output/:"
ls -lh "$OUTPUT_DIR"/*.pkg.tar.* 2>/dev/null || echo "No artifacts found in output/"
echo ""
echo "Next Steps to Install on your Machine:"
echo "• Run the all-in-one automatic installer (handles pacman + mkinitcpio + bootloader):"
echo "   ./install.sh"
echo ""
echo "• Or publish to your GitHub Releases Pacman repository:"
echo "   ./publish.sh"
echo ""

if [[ " $* " == *" --publish "* ]]; then
  log_step "Proceeding directly to repository publishing (--publish requested)..."
  ./publish.sh
fi

if [[ " $* " == *" --install "* ]]; then
  INSTALL_ARGS=()
  if [[ " $* " == *" --fallback "* ]]; then
    INSTALL_ARGS+=("--fallback")
  fi
  log_step "Proceeding directly to installation (--install requested)..."
  ./install.sh "${INSTALL_ARGS[@]}"
fi
