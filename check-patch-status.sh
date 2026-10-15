#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "  ASUS Touchpad Patch Status Tracker      "
echo "  Author: Panz Dev <panz.development@gmail.com>"
echo "=========================================="

PATCH_TITLE="HID: asus: do not send keyboard init reports to touchpads"
AUTHOR_EMAIL="panz.development@gmail.com"

# 1. Check upstream hid.git branches
echo "-> Checking hid.git (Subsystem tree)..."
if [ -d "linux-git" ]; then
  cd linux-git
  
  # Fetch latest refs from hid.git quietly
  git fetch -q https://git.kernel.org/pub/scm/linux/kernel/git/hid/hid.git \
    for-next for-linus "for-7.*/asus" "for-7.*/upstream-fixes" 2>/dev/null || true

  FOUND_COMMIT=$(git log FETCH_HEAD --author="$AUTHOR_EMAIL" --oneline -n 1 2>/dev/null || true)
  if [ -z "$FOUND_COMMIT" ]; then
    FOUND_COMMIT=$(git log FETCH_HEAD --grep="$PATCH_TITLE" --oneline -n 1 2>/dev/null || true)
  fi

  if [ -n "$FOUND_COMMIT" ]; then
    echo -e "\033[0;32m[✓] MERGED IN HID SUBSYSTEM TREE!\033[0m"
    echo "    Commit: $FOUND_COMMIT"
    echo "    Branch: Queued in hid.git for next Linus pull request."
    echo ""
  else
    echo "[-] Not yet merged into hid.git (currently under review in Denis's v5 series)."
  fi

  # 2. Check Linus Torvalds' mainline tree
  echo "-> Checking Linus Torvalds mainline tree..."
  git fetch -q origin master 2>/dev/null || true
  MAINLINE_COMMIT=$(git log origin/master --author="$AUTHOR_EMAIL" --oneline -n 1 2>/dev/null || true)
  if [ -n "$MAINLINE_COMMIT" ]; then
    echo -e "\033[0;32m[✓] OFFICIALLY MERGED INTO LINUX MAINLINE!\033[0m"
    echo "    Commit: $MAINLINE_COMMIT"
    echo "    URL: https://github.com/torvalds/linux/commit/${MAINLINE_COMMIT%% *}"
  else
    echo "[-] Not yet in Linus's tree."
  fi
  cd "$SCRIPT_DIR"
fi

echo ""
echo "-> Tracking Links:"
echo "   • Patchwork (linux-input): https://patchwork.kernel.org/project/linux-input/list/?series=v5"
echo "   • Your GitHub Commits:     https://github.com/torvalds/linux/commits?author=$AUTHOR_EMAIL"
echo "=========================================="
