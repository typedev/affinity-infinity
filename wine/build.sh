#!/usr/bin/env bash
# Build Wine with the Affinity patches, add vkd3d-proton, and pack a
# relocatable tarball: <out>/$AI_WINE_NAME-x86_64.tar.xz (+ .sha256).
# Runs on the build image (Ubuntu 22.04, for an old glibc baseline), either via
# build-in-container.sh or directly in CI. Dependencies: deps-ubuntu.txt.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=build.env
source "$HERE/build.env"

OUT=${1:-$HERE/out}
WORK=${WORK:-/tmp/wine-build}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$OUT" "$WORK/dl"

log() { printf '\n==> %s\n' "$*"; }

# fetch <url> <sha256> <file>
fetch() {
    local url=$1 sha=$2 file=$3
    if [[ ! -f "$file" ]] || ! sha256sum --status -c <<<"$sha  $file"; then
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    sha256sum -c <<<"$sha  $file"
}

log "fetching sources"
fetch "$WINE_URL" "$WINE_SHA256" "$WORK/dl/wine-$WINE_VERSION.tar.xz"
fetch "$VKD3D_PROTON_URL" "$VKD3D_PROTON_SHA256" "$WORK/dl/vkd3d-proton-$VKD3D_PROTON_VERSION.tar.zst"

log "unpacking and patching Wine $WINE_VERSION"
SRC="$WORK/wine-$WINE_VERSION"
rm -rf "$SRC"
tar -C "$WORK" -xJf "$WORK/dl/wine-$WINE_VERSION.tar.xz"
for p in "$HERE/patches/$WINE_VERSION"/*.patch; do
    echo "  $(basename "$p")"
    patch -d "$SRC" -p1 --forward --quiet <"$p"
done

log "configuring"
BUILD="$WORK/build"
rm -rf "$BUILD"
mkdir -p "$BUILD"
export CFLAGS="-O2 -std=gnu17 -pipe -Wno-discarded-qualifiers -Wno-format -Wno-maybe-uninitialized -Wno-misleading-indentation"
export CROSSCFLAGS="$CFLAGS"
(cd "$BUILD" && "$SRC/configure" \
    --prefix=/opt/wine \
    --enable-archs=i386,x86_64 \
    --enable-opencl \
    --with-wayland \
    --without-oss \
    --disable-tests \
    >configure.log 2>&1) || { tail -60 "$BUILD/configure.log"; exit 1; }
# Report optional features configure could not enable.
grep -E '^configure: (WARNING|OpenCL|Wayland)' "$BUILD/configure.log" || true

log "building with $JOBS jobs"
make -C "$BUILD" -j"$JOBS" >"$BUILD/make.log" 2>&1 || { tail -80 "$BUILD/make.log"; exit 1; }

log "installing"
STAGE="$WORK/stage"
PKG="$STAGE/$AI_WINE_NAME"
rm -rf "$STAGE"
make -C "$BUILD" install DESTDIR="$STAGE" >"$BUILD/install.log" 2>&1
mv "$STAGE/opt/wine" "$PKG"
rm -rf "$STAGE/opt" "$PKG/include" "$PKG/share/man" "$PKG/share/applications"
find "$PKG/bin" "$PKG/lib/wine/x86_64-unix" -type f -exec sh -c 'file -b "$1" | grep -q ELF && strip --strip-unneeded "$1"' _ {} \;

log "adding vkd3d-proton $VKD3D_PROTON_VERSION"
mkdir -p "$PKG/lib/wine/vkd3d-proton/x86_64-windows"
tar -C "$WORK" --zstd -xf "$WORK/dl/vkd3d-proton-$VKD3D_PROTON_VERSION.tar.zst"
cp "$WORK/vkd3d-proton-$VKD3D_PROTON_VERSION/x64/"d3d12*.dll "$PKG/lib/wine/vkd3d-proton/x86_64-windows/"

log "licenses and build info"
mkdir -p "$PKG/LICENSES"
cp "$SRC/COPYING.LIB" "$PKG/LICENSES/wine-COPYING.LIB"
cp "$SRC/LICENSE" "$PKG/LICENSES/wine-LICENSE"
cp "$WORK/vkd3d-proton-$VKD3D_PROTON_VERSION/LICENSE" "$PKG/LICENSES/vkd3d-proton-LICENSE" 2>/dev/null ||
    echo "LGPL-2.1-or-later, https://github.com/HansKristian-Work/vkd3d-proton" >"$PKG/LICENSES/vkd3d-proton-LICENSE"
cp -r "$HERE/patches/$WINE_VERSION" "$PKG/LICENSES/wine-patches"
cp "$HERE/patches/SOURCE.md" "$PKG/LICENSES/wine-patches/"
{
    echo "$AI_WINE_NAME"
    echo "wine $WINE_VERSION ($WINE_URL, sha256 $WINE_SHA256)"
    echo "patches: $(find "$HERE/patches/$WINE_VERSION" -name '*.patch' | wc -l) (see LICENSES/wine-patches)"
    echo "vkd3d-proton $VKD3D_PROTON_VERSION"
    echo "built on $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"
} >"$PKG/BUILD"

log "packing"
TARBALL="$OUT/$AI_WINE_NAME-x86_64.tar.xz"
tar -C "$STAGE" -cf - "$AI_WINE_NAME" | xz -T0 -9 >"$TARBALL"
(cd "$OUT" && sha256sum "$(basename "$TARBALL")" >"$(basename "$TARBALL").sha256")
cp "$PKG/BUILD" "$OUT/BUILD.txt"
ls -la "$OUT"
