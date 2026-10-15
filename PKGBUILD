# Maintainer: Custom Linux Build System <user@archlinux.local>

pkgbase=linux-patched
pkgname=(
  "$pkgbase"
  "$pkgbase-headers"
)
pkgver=7.2.10.arch1
pkgrel=1
pkgdesc='Linux kernel compiled with custom touchpad patches for ASUS E200HA'
url='https://github.com/archlinux/linux'
arch=(x86_64)
license=(GPL-2.0-only)
makedepends=(
  bc
  binutils
  cpio
  gettext
  glibc
  libelf
  libgcc
  openssl
  pahole
  perl
  python
  rust
  rust-bindgen
  rust-src
  tar
  xxhash
  xz
  zlib
  zstd
)
options=(
  !debug
  !strip
)

_srcname=linux-${pkgver%.*}
_srctag=v${pkgver%.*}-${pkgver##*.}

source=(
  https://cdn.kernel.org/pub/linux/kernel/v${pkgver%%.*}.x/${_srcname}.tar.xz
  $url/releases/download/$_srctag/linux-$_srctag.patch.zst
  config.x86_64
  linux-patched.preset
)

b2sums=('f6fa406d0764f0ab9ed199747420e45c422f1cb1a74e5eff1d488b8ad8aa33660440dab2bf15303638e70a9798574ac49550e0fa03bc7550284028548c34cdce'
        'ba40e6b37149194c8b953ba904666643a1471331d260ec910fa5038d76453bebfa1c0f5acd12607253f590469a5ce27248f93a308ebb94899902ec7b8ed596f1'
        '53a7ef5bba888f06edae13c6734bde853d675e8298eb8aeea8c13744f8f9d4dd804994ea9cb6ca56ac3153d70792fecddecca23e1525be0551c14590d628b322'
        '05f71c70e82f3e320645067c5d42af00fa3b516316766dcf56bb61981b9b45de5b87cbe02441fff0189adbf8928a9a919553e44c79c59e1aed9ca54de0bd194c')

export KBUILD_BUILD_HOST=archlinux
export KBUILD_BUILD_USER=$pkgbase
export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

prepare() {
  cd "$srcdir/$_srcname"

  echo "Setting local kernel release identifier..."
  echo "-$pkgrel" > localversion.10-pkgrel
  echo "-patched" > localversion.20-pkgname

  echo "Applying standard Arch Linux patch set..."
  local src
  for src in "${source[@]}"; do
    src="${src%%::*}"
    src="${src##*/}"
    src="${src%.zst}"
    if [[ "$src" == linux-*.patch ]]; then
      echo "Applying Arch patch $src..."
      patch -Np1 < "$srcdir/$src"
    fi
  done

  # Dynamically search and apply custom patches placed in patches/
  local patch_file
  if [[ -d "$startdir/patches" ]]; then
    for patch_file in "$startdir/patches"/*.patch; do
      if [[ -f "$patch_file" ]]; then
        local patch_name="$(basename "$patch_file")"
        echo "=========================================="
        echo "Checking custom patch: $patch_name"
        # Detect if patch is already present in upstream code (e.g. Linux 7.4+)
        if patch -p1 -R --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
          echo "[✓] ALREADY MERGED UPSTREAM! Skipping $patch_name."
        elif patch -p1 -N --dry-run -s < "$patch_file" >/dev/null 2>&1; then
          echo "[+] Applying custom patch: $patch_name"
          patch -Np1 < "$patch_file"
        else
          echo "[!] Warning: Dry-run check inconclusive. Attempting apply..."
          patch -Np1 < "$patch_file" || true
        fi
        echo "=========================================="
      fi
    done
  fi

  echo "Configuring kernel build..."
  cp "$srcdir/config.x86_64" .config
  make olddefconfig

  make -s kernelrelease > version
  echo "Prepared $pkgbase version $(<version)"
}

build() {
  cd "$srcdir/$_srcname"
  make all
}

package_linux-patched() {
  pkgdesc="The $pkgdesc kernel and modules"
  depends=(
    coreutils
    initramfs
    kmod
  )
  optdepends=(
    "$pkgbase-headers: headers and scripts for building modules"
    'linux-firmware: firmware images needed for some devices'
    'wireless-regdb: to set the correct wireless channels'
  )
  provides=(
    linux
    linux-touchpad
  )
  conflicts=(
    linux-patched
  )

  cd "$srcdir/$_srcname"
  local modulesdir="$pkgdir/usr/lib/modules/$(<version)"

  echo "Installing kernel image..."
  install -Dm644 "$(make -s image_name)" "$pkgdir/boot/vmlinuz-linux-patched"
  install -Dm644 "$(make -s image_name)" "$modulesdir/vmlinuz"

  echo "Installing mkinitcpio preset..."
  install -Dm644 "$srcdir/linux-patched.preset" "$pkgdir/etc/mkinitcpio.d/linux-patched.preset"

  # Used by mkinitcpio to name the kernel
  echo "$pkgbase" | install -Dm644 /dev/stdin "$modulesdir/pkgbase"

  echo "Installing kernel modules..."
  ZSTD_CLEVEL=19 make INSTALL_MOD_PATH="$pkgdir/usr" INSTALL_MOD_STRIP=1 \
    DEPMOD=/doesnt/exist modules_install

  # Remove build link
  rm -f "$modulesdir"/build
}

package_linux-patched-headers() {
  pkgdesc="Headers and scripts for building modules for the $pkgdesc kernel"
  depends=(
    binutils
    glibc
    libelf
    libgcc
    openssl
    pahole
    xxhash
    zlib
    zstd
  )
  provides=(LINUX-HEADERS)
  conflicts=(linux-patched-headers)

  cd "$srcdir/$_srcname"
  local builddir="$pkgdir/usr/lib/modules/$(<version)/build"

  local karch=x86

  echo "Installing build files..."
  install -Dt "$builddir" -m644 .config Makefile Module.symvers System.map \
    localversion.* version vmlinux
  install -Dt "$builddir/kernel" -m644 kernel/Makefile
  install -Dt "$builddir/arch/$karch" -m644 arch/$karch/Makefile
  cp -t "$builddir" -a scripts
  ln -srt "$builddir" "$builddir/scripts/gdb/vmlinux-gdb.py"

  if [[ $(scripts/config -s CONFIG_HAVE_STACK_VALIDATION) = y ]]; then
    install -Dt "$builddir/tools/objtool" tools/objtool/objtool
  fi

  if [[ $(scripts/config -s CONFIG_DEBUG_INFO_BTF_MODULES) = y ]]; then
    install -Dt "$builddir/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids
  fi

  echo "Installing headers..."
  cp -t "$builddir" -a include
  cp -t "$builddir/arch/$karch" -a arch/$karch/include
  install -Dt "$builddir/arch/$karch/kernel" -m644 arch/$karch/kernel/asm-offsets.s

  echo "Installing KConfig files..."
  find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;

  echo "Cleaning up loose build objects..."
  find "$builddir" -type f -name '*.o' -printf 'Removing %P\n' -delete

  mkdir -p "$pkgdir/usr/src"
  ln -sr "$builddir" "$pkgdir/usr/src/$pkgbase"
}

# vim:set ts=8 sts=2 sw=2 et:
