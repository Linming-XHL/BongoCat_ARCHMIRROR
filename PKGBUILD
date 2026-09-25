# Maintainer: Linming-XHL <linmingxhl@users.noreply.github.com>
#
# Builds BongoCat from the sources of the matching upstream release tag.
# .github/workflows/build-repo.yml keeps pkgver in sync with upstream and
# publishes the result as a signed pacman repository on Cloudflare Pages.

pkgname=bongocat
pkgver=1.13.1
pkgrel=1
pkgdesc='Desktop pet that reacts to your keyboard and mouse input (Live2D on SDL3 and OpenGL)'
arch=('x86_64')
url='https://github.com/vladelaina/BongoCat'
license=('AGPL-3.0-only')
depends=('curl' 'fontconfig' 'gcc-libs' 'libglvnd' 'libx11' 'libxfixes' 'libxi')
makedepends=('cmake' 'ninja' 'pkgconf')
optdepends=(
  'alsa-lib: ALSA backend for motion sounds'
  'pipewire-pulse: PulseAudio backend provided by PipeWire'
  'pulseaudio: PulseAudio backend for motion sounds'
  'noto-fonts-cjk: glyphs for the Chinese, Japanese and Korean interface'
)
conflicts=('bongocat-bin' 'bongocat-git')
# No split debug package and no makepkg-managed LTO: the build drives its own
# release optimisation (see cmake/ReleaseOptimize.cmake upstream).
options=('!debug' '!lto')

# The Live2D Cubism SDK for Native and GLEW are downloaded from their official
# distribution points at build time, exactly like the upstream release pipeline,
# and are not redistributed by this PKGBUILD. The Cubism SDK is proprietary
# software governed by the Live2D Proprietary Software License Agreement.
_cubism_ver='5-r.5'
_glew_ver='2.2.0'

source=(
  "$pkgname-$pkgver.tar.gz::https://github.com/vladelaina/BongoCat/archive/refs/tags/v$pkgver.tar.gz"
  "CubismSdkForNative-$_cubism_ver.zip::https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-$_cubism_ver.zip"
  "glew-$_glew_ver.zip::https://github.com/nigels-com/glew/releases/download/glew-$_glew_ver/glew-$_glew_ver.zip"
)
# GitHub regenerates tag archives on demand, so their digest is not stable
# enough to pin. build() asserts that the extracted tree declares pkgver itself,
# which is the same guard the upstream release pipeline uses.
sha256sums=('SKIP'
            '7ff3a4bbc19c0a8728965aa522ab77eb11b252916453e68a8a78d3b71188bb12'
            'a9046a913774395a095edcc0b0ac2d81c3aacca61787b39839b941e9be14e0d4')
noextract=("CubismSdkForNative-$_cubism_ver.zip" "glew-$_glew_ver.zip")

_archive_name() { printf 'BongoCat-%s' "$pkgver"; }

prepare() {
  cd "$(_archive_name)"

  local sdk_header glew_header sdk_root glew_root
  rm -rf "$srcdir/cubism-sdk" "$srcdir/glew"
  mkdir -p "$srcdir/cubism-sdk" "$srcdir/glew"
  bsdtar -xf "$srcdir/CubismSdkForNative-$_cubism_ver.zip" -C "$srcdir/cubism-sdk"
  bsdtar -xf "$srcdir/glew-$_glew_ver.zip" -C "$srcdir/glew"

  # Locate the SDK root instead of trusting the archive's directory name.
  sdk_header=$(find "$srcdir/cubism-sdk" -type f -path '*/Core/include/Live2DCubismCore.h' -print -quit)
  [[ -n $sdk_header ]] || { error 'The Cubism SDK archive has no Core/include tree'; return 1; }
  sdk_root=${sdk_header%/Core/include/Live2DCubismCore.h}

  glew_header=$(find "$srcdir/glew" -type f -path '*/include/GL/glew.h' -print -quit)
  [[ -n $glew_header ]] || { error 'The GLEW archive has no include/GL tree'; return 1; }
  glew_root=${glew_header%/include/GL/glew.h}

  # cmake/Cubism.cmake expects the SDK at vendor/CubismSdkForNative with GLEW
  # vendored under Samples/OpenGL/thirdParty/glew.
  mkdir -p vendor/CubismSdkForNative
  cp -a "$sdk_root/." vendor/CubismSdkForNative/
  mkdir -p vendor/CubismSdkForNative/Samples/OpenGL/thirdParty/glew
  cp -a "$glew_root/." vendor/CubismSdkForNative/Samples/OpenGL/thirdParty/glew/

  local required=(
    Core/include/Live2DCubismCore.h
    Core/lib/linux/x86_64/libLive2DCubismCore.a
    Framework/CMakeLists.txt
    Samples/OpenGL/thirdParty/glew/src/glew.c
  )
  local rel
  for rel in "${required[@]}"; do
    [[ -e vendor/CubismSdkForNative/$rel ]] || {
      error "Incomplete Cubism SDK: vendor/CubismSdkForNative/$rel is missing"; return 1; }
  done
}

build() {
  cd "$(_archive_name)"

  grep -q "set(BONGO_CAT_VERSION \"$pkgver\")" CMakeLists.txt || {
    error "CMakeLists.txt does not declare version $pkgver"; return 1; }

  # SDL is built X11-only (see -DSDL_WAYLAND below), so the optional native
  # Wayland input-shape code can never run. Upstream's release pipeline builds
  # without Wayland headers and therefore leaves it out; a build machine that
  # happens to have wayland installed would otherwise link libwayland-client for
  # nothing, which would make the package depend on a library it cannot use.
  # This wrapper keeps pkg-config from advertising that one module, so the
  # configuration is the same everywhere. -U below drops the cached probe result
  # so an existing build tree from an earlier revision is re-checked instead of
  # silently keeping its old answer (pkg_check_modules caches its findings).
  local pkg_config_wrapper="$srcdir/pkg-config-no-wayland" real_pkgconfig
  real_pkgconfig=$(command -v pkg-config || command -v pkgconf || true)
  [[ -n $real_pkgconfig ]] || { error 'pkg-config is required to configure the build'; return 1; }
  cat >"$pkg_config_wrapper" <<WRAPPER
#!/bin/sh
case " \$* " in
  *wayland-client*) exit 1 ;;
esac
exec "$real_pkgconfig" "\$@"
WRAPPER
  chmod 755 "$pkg_config_wrapper"

  # Mirrors the options the upstream release pipeline builds with, so the
  # package behaves like the official Linux archives: the Live2D runtime is
  # required (a missing SDK must fail instead of falling back to the diagnostic
  # backend) and the X11 driver is used, which is what makes absolute window
  # placement and input shapes work (also under XWayland on Wayland sessions).
  # BONGO_CAT_WARNINGS_AS_ERRORS stays off: the rolling compilers in an Arch
  # build container report warnings that the upstream CI compiler does not.
  cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_TESTING=OFF \
    -DBONGO_CAT_FETCH_DEPS=ON \
    -DBONGO_CAT_REQUIRE_CUBISM=ON \
    -DBONGO_CAT_OPTIMIZE_RELEASE_SIZE=ON \
    -DBONGO_CAT_OPTIMIZE_RELEASE_IPO=ON \
    -DPKG_CONFIG_EXECUTABLE="$pkg_config_wrapper" \
    -DSDL_WAYLAND=OFF \
    -U "__pkg_config_checked_*"
  cmake --build build --parallel "$(nproc)"
}

# Structural checks run at the end of package() on purpose: makepkg calls
# check() before package(), where $pkgdir does not exist yet. The runtime
# resolves its assets next to the executable, so the layout is load bearing, and
# ldd proves the declared depends are complete, which is what catches a new
# upstream release that pulls in another shared library.
package() {
  cd "$(_archive_name)"

  # Upstream installs the executable and assets/ side by side; the runtime
  # resolves assets through SDL_GetBasePath(), which follows /proc/self/exe, so
  # the symlink keeps /usr/bin clean without breaking asset discovery.
  cmake --install build --component Runtime --prefix "$pkgdir/usr/lib/bongocat"
  install -d "$pkgdir/usr/bin"
  ln -s /usr/lib/bongocat/BongoCat "$pkgdir/usr/bin/bongocat"

  install -Dm644 packaging/linux/bongocat.desktop \
    "$pkgdir/usr/share/applications/bongocat.desktop"
  sed -i 's/^Exec=BongoCat$/Exec=bongocat/' "$pkgdir/usr/share/applications/bongocat.desktop"
  install -Dm644 resources/assets/bongocat.png \
    "$pkgdir/usr/share/icons/hicolor/512x512/apps/bongocat.png"

  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 LICENSE-MIT "$pkgdir/usr/share/licenses/$pkgname/LICENSE-MIT"
  install -Dm644 resources/assets/models/LICENSE \
    "$pkgdir/usr/share/licenses/$pkgname/LICENSE-models"

  _verify_layout
}

_verify_layout() {
  local libdir="$pkgdir/usr/lib/bongocat"
  [[ -x $libdir/BongoCat ]] || { error 'Missing /usr/lib/bongocat/BongoCat'; return 1; }
  [[ ! -e $libdir/DiagnosticBuildNotice.txt ]] || {
    error 'The diagnostic backend was built instead of the Live2D runtime'; return 1; }

  local asset
  for asset in bongocat.png ui-symbols.png ui-symbols@4x.png catime.png vlaina.jpg \
    locales/en-US.json models/standard/cat.model3.json models/standard/demomodel.moc3 \
    models/standard/demomodel.1024/texture_00.png; do
    [[ -s $libdir/assets/$asset ]] || { error "Missing asset: assets/$asset"; return 1; }
  done

  local unresolved
  unresolved=$(LC_ALL=C ldd "$libdir/BongoCat" 2>/dev/null | grep 'not found' || true)
  [[ -z $unresolved ]] || { error "Unresolved shared libraries:\n$unresolved"; return 1; }

  # Every directly needed soname must be provided by a package in depends.
  # LC_ALL=C keeps the readelf/ldd output parseable in any locale.
  local -a sonames
  mapfile -t sonames < <(LC_ALL=C readelf -d "$libdir/BongoCat" \
    | awk '/NEEDED/ { if (match($0, /\[[^]]+\]/)) print substr($0, RSTART + 1, RLENGTH - 2) }')
  (( ${#sonames[@]} )) || { error 'Cannot read the shared library list of the executable'; return 1; }

  local soname path owner expected missing=()
  for soname in "${sonames[@]}"; do
    path=$(ldconfig -p | awk -v soname="$soname" '$1 == soname { print $NF; exit }')
    owner=$(pacman -Qoq "$path" 2>/dev/null | head -n1)
    # The C and C++ runtime libraries have more than one provider (some systems
    # split libstdc++/libgcc out of gcc-libs), so map them by name instead of by
    # whichever package happens to own the file.
    case $soname in
      libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2) continue ;;  # glibc, always present
      libstdc++.so.6 | libgcc_s.so.1) expected=gcc-libs ;;
      *) expected=$owner ;;
    esac
    if [[ -z $expected || " ${depends[*]} " != *" $expected "* ]]; then
      missing+=("$soname (provided by ${owner:-nothing})")
    fi
  done
  (( ${#missing[@]} == 0 )) || {
    error "Undefined depends entries for: ${missing[*]}"; return 1; }
}
