#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Print colored status messages
log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_step()  { echo -e "\n\033[1;36m==>\033[0m \033[1m$*\033[0m"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Catch and report exact failing line
trap 'log_error "Command failed at line $LINENO: $BASH_COMMAND"' ERR

echo "========================================================"
echo "  Arch Linux Kernel Auto-Updater (Verbose Mode)         "
echo "  Custom Patched Kernel Sync & Upstream Tracker         "
echo "========================================================"

log_step "Step 1: Checking required host tools..."
REQUIRED_TOOLS=(git curl updpkgsums makepkg patch)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    log_ok "Found tool: $tool ($(command -v "$tool"))"
  else
    log_error "Missing required tool: $tool"
    echo "Please install via: sudo pacman -S --needed git curl pacman-contrib base-devel"
    exit 1
  fi
done

# Parse flags from arguments
FORCE=0
CHECK_PATCHES=0
for arg in "$@"; do
  if [ "$arg" == "--force" ]; then
    FORCE=1
  elif [ "$arg" == "--check-patches" ]; then
    CHECK_PATCHES=1
  fi
done

log_step "Step 2: Querying Arch Linux upstream for latest release tag..."
ARCH_REPO="https://github.com/archlinux/linux"
log_info "Querying latest release from $ARCH_REPO..."

# Method 1: GitHub release redirect (fastest, lightweight, avoids git-upload-pack hangs and API rate limits)
LATEST_TAG=$(curl -sI -m 10 "${ARCH_REPO}/releases/latest" 2>/dev/null | grep -i '^location:' | sed -E 's#.*tag/([^[:space:]\r\n]+).*#\1#' | tr -d '\r\n' || true)

# Method 2: GitHub API fallback
if [ -z "$LATEST_TAG" ]; then
  log_info "Falling back to GitHub Releases API..."
  LATEST_TAG=$(curl -sL -m 10 "https://api.github.com/repos/archlinux/linux/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | tr -d '\r\n' || true)
fi

# Method 3: git ls-remote fallback with a strict timeout
if [ -z "$LATEST_TAG" ]; then
  log_info "Falling back to git ls-remote (with timeout)..."
  LATEST_TAG=$(timeout 15 git ls-remote --tags --sort=v:refname "${ARCH_REPO}.git" "v*-arch*" 2>/dev/null | grep -v '\^{}' | tail -n 1 | awk '{print $2}' | sed 's#refs/tags/##' || true)
fi

if [ -z "$LATEST_TAG" ]; then
  log_error "Failed to retrieve release tags from $ARCH_REPO"
  exit 1
fi

log_ok "Discovered latest upstream tag: $LATEST_TAG"

# Parse tag into PKGBUILD pkgver (e.g. v7.2.10-arch1 -> 7.2.10.arch1)
RAW_VER="${LATEST_TAG#v}"
PKGVER="${RAW_VER/-/.}"
KERNEL_VER="${PKGVER%.arch*}"

CURRENT_PKGVER=$(grep "^pkgver=" PKGBUILD | cut -d'=' -f2)

log_info "Current local PKGBUILD pkgver : $CURRENT_PKGVER"
log_info "Target upstream PKGBUILD pkgver: $PKGVER (Kernel: $KERNEL_VER)"

MAJOR_VER="${KERNEL_VER%%.*}"
TARBALL_FILE="linux-${KERNEL_VER}.tar.xz"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/${TARBALL_FILE}"

PATCH_FILE="linux-${LATEST_TAG}.patch.zst"
PATCH_URL="https://github.com/archlinux/linux/releases/download/${LATEST_TAG}/${PATCH_FILE}"

log_step "Step 3: Checking if PKGBUILD needs updating..."
if [ "$CURRENT_PKGVER" == "$PKGVER" ] && [ -f "$TARBALL_FILE" ] && [ -f "$PATCH_FILE" ] && [ $FORCE -eq 0 ] && [ $CHECK_PATCHES -eq 0 ]; then
  log_ok "PKGBUILD is already at the latest upstream version ($PKGVER)."
  log_ok "All sources ($TARBALL_FILE, $PATCH_FILE) exist locally."
  echo ""
  echo "========================================================"
  log_ok "Already fully up to date! Nothing to update."
  echo "========================================================"
  log_info "Tip: Pass --force or --check-patches if you want to re-verify patches anyway."
  exit 0
fi

if [ "$CURRENT_PKGVER" != "$PKGVER" ]; then
  log_info "Updating PKGBUILD version: $CURRENT_PKGVER -> $PKGVER..."
  sed -i "s/^pkgver=.*/pkgver=$PKGVER/" PKGBUILD
  sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
  log_ok "PKGBUILD updated."
else
  log_ok "PKGBUILD is already configured for $PKGVER."
fi

NEEDS_DOWNLOAD=0
if [ "$CURRENT_PKGVER" != "$PKGVER" ] || [ ! -f "$TARBALL_FILE" ] || [ ! -f "$PATCH_FILE" ] || [ $FORCE -eq 1 ]; then
  NEEDS_DOWNLOAD=1
fi

if [ $NEEDS_DOWNLOAD -eq 0 ]; then
  log_ok "All sources ($TARBALL_FILE, $PATCH_FILE) already exist locally. Skipping download."
  log_info "(Pass --force to re-download files and regenerate checksums anyway)."
else
  log_step "Step 4: Downloading kernel sources and Arch patch set..."
  # Automatically remove obsolete kernel tarballs and patches from older versions
  for old_tar in linux-*.tar.xz; do
    if [ "$old_tar" != "$TARBALL_FILE" ] && [ -f "$old_tar" ]; then
      log_info "Removing obsolete tarball: $old_tar"
      rm -f "$old_tar"
    fi
  done
  for old_patch in linux-v*.patch.zst; do
    if [ "$old_patch" != "$PATCH_FILE" ] && [ -f "$old_patch" ]; then
      log_info "Removing obsolete patch set: $old_patch"
      rm -f "$old_patch"
    fi
  done

  if [ -f "$TARBALL_FILE" ] && [ $FORCE -eq 0 ]; then
    log_ok "$TARBALL_FILE already exists locally ($(du -h "$TARBALL_FILE" | cut -f1)). Skipping download."
  else
    log_info "Downloading $TARBALL_FILE from $TARBALL_URL..."
    curl -L --progress-bar -o "$TARBALL_FILE" "$TARBALL_URL"
    log_ok "Downloaded $TARBALL_FILE successfully."
  fi

  if [ -f "$PATCH_FILE" ] && [ $FORCE -eq 0 ]; then
    log_ok "$PATCH_FILE already exists locally ($(du -h "$PATCH_FILE" | cut -f1)). Skipping download."
  else
    log_info "Downloading $PATCH_FILE from $PATCH_URL..."
    curl -L --progress-bar -o "$PATCH_FILE" "$PATCH_URL"
    log_ok "Downloaded $PATCH_FILE successfully."
  fi

  log_step "Step 5: Generating and verifying b2sums with updpkgsums..."
  updpkgsums
  log_ok "Checksums updated in PKGBUILD."
fi

log_step "Step 6: Verifying custom patches against kernel v${KERNEL_VER}..."
if [ -d "linux-git" ]; then
  log_info "Found local linux-git repository for upstream validation."
  (
    cd linux-git
    log_info "Fetching stable tags into linux-git..."
    git fetch --tags stable 2>&1 | while read -r line; do echo "    [git] $line"; done || true
    
    if git rev-parse "v${KERNEL_VER}" &>/dev/null; then
      log_info "Checking out tag v${KERNEL_VER} in linux-git..."
      git checkout -q "v${KERNEL_VER}"
      
      for patch_file in "$SCRIPT_DIR/patches"/*.patch; do
        if [ -f "$patch_file" ]; then
          patch_name="$(basename "$patch_file")"
          echo "--------------------------------------------------------"
          log_info "Testing status of: $patch_name"
          
          # Check 1: Is it already present in upstream code?
          if git apply --check --reverse "$patch_file" 2>/dev/null; then
            log_ok "ALREADY MERGED UPSTREAM in Linux v${KERNEL_VER}!"
            log_info "The fix is now natively present in the kernel code."
            log_info "PKGBUILD prepare() will automatically detect this and skip applying it."
          # Check 2: Can it apply cleanly?
          elif git apply --check "$patch_file" 2>/dev/null; then
            log_warn "NOT YET MERGED upstream in Linux v${KERNEL_VER}."
            log_ok "Patch applies cleanly as an out-of-tree fix."
            log_info "PKGBUILD prepare() will apply this patch during compilation."
          # Check 3: Does it conflict?
          else
            log_error "CONFLICT DETECTED! Patch fails to apply to v${KERNEL_VER}:"
            git apply --check "$patch_file" 2>&1 | while read -r err_line; do
              echo "    [git apply error] $err_line"
            done
          fi
        fi
      done
      echo "--------------------------------------------------------"
    else
      log_warn "Tag v${KERNEL_VER} not yet available in linux-git; skipping git simulation check."
    fi
  )
else
  log_info "No linux-git folder found; skipping git simulation check."
fi

echo ""
echo "========================================================"
echo -e "\033[0;32m  Update Check Completed Successfully! \033[0m"
echo "========================================================"
BUILD_ARGS=()
for arg in "$@"; do
  if [ "$arg" == "--install" ] || [ "$arg" == "--fallback" ] || [ "$arg" == "--publish" ]; then
    BUILD_ARGS+=("$arg")
  fi
done

if [[ " $* " == *" --build "* ]] || [[ " $* " == *" --install "* ]] || [[ " $* " == *" --publish "* ]]; then
  log_step "Proceeding directly to compilation..."
  ./build.sh "${BUILD_ARGS[@]}"
else
  echo "To start compilation now, run:"
  echo "   ./build.sh"
  echo ""
  echo "Or to compile AND install automatically in one step:"
  echo "   ./build.sh --install"
  echo ""
  echo "Or to compile AND publish to GitHub Releases Pacman repo:"
  echo "   ./build.sh --publish"
  echo ""
  echo "Or full update + compile + publish:"
  echo "   ./update.sh --build --publish"
fi
