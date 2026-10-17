#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
PATCHES_DIR="${SCRIPT_DIR}/patches"

log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_step()  { echo -e "\n\033[1;36m==>\033[0m \033[1m$*\033[0m"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

trap 'log_error "Publishing failed at line $LINENO: $BASH_COMMAND"' ERR

echo "========================================================"
echo "  GitHub Releases Pacman Repository Publisher           "
echo "  Deploy Kernel & Database to GitHub Releases           "
echo "========================================================"

# Check dependencies
for tool in gh repo-add git; do
  if ! command -v "$tool" &>/dev/null; then
    log_error "Missing required tool: $tool"
    exit 1
  fi
done

# Ensure GitHub CLI is logged in
if ! gh auth status &>/dev/null; then
  log_error "GitHub CLI is not authenticated. Run 'gh auth login' first."
  exit 1
fi

REPO_NAME=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "ppanzenboeck/linux")
log_info "Target GitHub repository: $REPO_NAME"

# 1. Identify packages to publish
LATEST_KERNEL=$(ls -1v "$OUTPUT_DIR"/linux-patched-[0-9]*.pkg.tar.zst 2>/dev/null | tail -n 1 || true)

if [ -z "$LATEST_KERNEL" ] || [ ! -f "$LATEST_KERNEL" ]; then
  log_error "No compiled kernel package found in $OUTPUT_DIR!"
  echo "Please compile first by running: ./build.sh"
  exit 1
fi

# Extract version from filename (e.g. linux-patched-7.2.11.arch1-1-x86_64.pkg.tar.zst -> 7.2.11.arch1-1)
PKG_FILENAME=$(basename "$LATEST_KERNEL")
PKGVER=$(echo "$PKG_FILENAME" | sed -E 's/^linux-patched-([0-9].*)-x86_64\.pkg\.tar\.zst$/\1/')
KERNEL_MAJOR_MINOR=$(echo "$PKGVER" | cut -d'.' -f1,2)

log_ok "Identified latest package version: $PKGVER (Kernel series: $KERNEL_MAJOR_MINOR)"

PKGS_TO_PUBLISH=("$LATEST_KERNEL")
LATEST_HEADERS=$(ls -1v "$OUTPUT_DIR"/linux-patched-headers-[0-9]*.pkg.tar.zst 2>/dev/null | tail -n 1 || true)
if [ -n "$LATEST_HEADERS" ] && [ -f "$LATEST_HEADERS" ]; then
  PKGS_TO_PUBLISH+=("$LATEST_HEADERS")
fi

log_step "Step 1: Generating Pacman repository database in output/..."
REPO_DB_NAME="panz"
DB_TAR_ZST="${OUTPUT_DIR}/${REPO_DB_NAME}.db.tar.zst"
FILES_TAR_ZST="${OUTPUT_DIR}/${REPO_DB_NAME}.files.tar.zst"

# Remove existing database files before generating clean index
rm -f "$DB_TAR_ZST" "$FILES_TAR_ZST" "${OUTPUT_DIR}/${REPO_DB_NAME}.db" "${OUTPUT_DIR}/${REPO_DB_NAME}.files"

log_info "Running repo-add for: ${PKGS_TO_PUBLISH[*]}"
repo-add "$DB_TAR_ZST" "${PKGS_TO_PUBLISH[@]}"

# GitHub release assets do not support symlinks; replace them with hard copies
log_info "Resolving database symlinks for GitHub Releases..."
cp --remove-destination -f "$DB_TAR_ZST" "${OUTPUT_DIR}/${REPO_DB_NAME}.db"
cp --remove-destination -f "$FILES_TAR_ZST" "${OUTPUT_DIR}/${REPO_DB_NAME}.files"
log_ok "Pacman database successfully created ($REPO_DB_NAME.db)."

log_step "Step 2: Checking patch status for release description..."
PATCH_MERGED_UPSTREAM=0

# Detect if the touchpad patch is merged upstream in this kernel version
if [ -d "linux-git" ]; then
  (
    cd linux-git
    git fetch --tags stable &>/dev/null || true
    TAG_TO_CHECK="v${PKGVER%.arch*}"
    if git rev-parse "$TAG_TO_CHECK" &>/dev/null; then
      git checkout -q "$TAG_TO_CHECK"
      if [ -f "$PATCHES_DIR/0001-fix-asus-touchpad-7.1-regression.patch" ]; then
        if git apply --check --reverse "$PATCHES_DIR/0001-fix-asus-touchpad-7.1-regression.patch" &>/dev/null; then
          PATCH_MERGED_UPSTREAM=1
        fi
      fi
    fi
  )
fi

# Dynamic release metadata: omit mention once natively in Linux 7.4+
if [ $PATCH_MERGED_UPSTREAM -eq 1 ]; then
  RELEASE_TITLE="Linux $PKGVER"
  RELEASE_NOTES="Arch Linux custom kernel release **$PKGVER**.\n\n*Note: ASUS touchpad fix is natively integrated upstream.*"
  log_ok "Patch is already upstream. Using standard title: $RELEASE_TITLE"
else
  RELEASE_TITLE="Linux $PKGVER (with ASUS Touchpad Fix)"
  RELEASE_NOTES="Arch Linux custom kernel release **$PKGVER** with the out-of-tree ASUS touchpad hardware probe fix."
  log_info "Patch was applied. Using title: $RELEASE_TITLE"
fi

FILES_TO_UPLOAD=(
  "${PKGS_TO_PUBLISH[@]}"
  "$DB_TAR_ZST"
  "$FILES_TAR_ZST"
  "${OUTPUT_DIR}/${REPO_DB_NAME}.db"
  "${OUTPUT_DIR}/${REPO_DB_NAME}.files"
)

log_step "Step 3: Deploying Pacman repository to GitHub Releases..."
ROLLING_TAG="packages"

# Check if the rolling 'packages' release already exists
if gh release view "$ROLLING_TAG" &>/dev/null; then
  log_info "Updating existing release: $ROLLING_TAG..."
  gh release edit "$ROLLING_TAG" --title "Pacman Repository (Current: $PKGVER)" --notes - <<< "$RELEASE_NOTES"
  log_info "Uploading package assets to $ROLLING_TAG (clobbering old assets)..."
  gh release upload "$ROLLING_TAG" "${FILES_TO_UPLOAD[@]}" --clobber
else
  log_info "Creating new rolling release tag '$ROLLING_TAG'..."
  gh release create "$ROLLING_TAG" "${FILES_TO_UPLOAD[@]}" \
    --title "Pacman Repository (Current: $PKGVER)" \
    --notes "$RELEASE_NOTES"
fi
log_ok "Published to rolling release tag '$ROLLING_TAG'!"

# Also create a permanent version release tag (e.g. v7.2.11.arch1-1)
VERSION_TAG="v${PKGVER}"
log_info "Checking permanent release tag '$VERSION_TAG'..."
if ! gh release view "$VERSION_TAG" &>/dev/null; then
  log_info "Creating permanent version release: $VERSION_TAG..."
  gh release create "$VERSION_TAG" "${FILES_TO_UPLOAD[@]}" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"
  log_ok "Created version release $VERSION_TAG."
else
  log_info "Version release $VERSION_TAG already exists; updating assets..."
  gh release upload "$VERSION_TAG" "${FILES_TO_UPLOAD[@]}" --clobber
fi

echo ""
echo "========================================================"
echo -e "\033[0;32m  Pacman Repository Successfully Deployed! \033[0m"
echo "========================================================"
echo ""
echo "Your custom pacman repository is live on GitHub Releases!"
echo "URL: https://github.com/${REPO_NAME}/releases/tag/packages"
echo ""
echo "--------------------------------------------------------"
echo "Instructions for your other machines & your friends:"
echo "--------------------------------------------------------"
echo "Add these 3 lines to the bottom of /etc/pacman.conf:"
echo ""
echo "  [panz]"
echo "  SigLevel = Optional TrustAll"
echo "  Server = https://github.com/${REPO_NAME}/releases/download/packages"
echo ""
echo "Then simply update and install from any machine:"
echo "  sudo pacman -Syu linux-patched linux-patched-headers"
echo "--------------------------------------------------------"
