#!/usr/bin/env bash
# Assemble the AppDir and build Affinity-Infinity-<version>-x86_64.AppImage.
#   packaging/build-appimage.sh WINE_TARBALL [VERSION]
# WINE_TARBALL comes from wine/build.sh; tools from packaging/build-tools.sh
# (built here if missing). Output: packaging/out/.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
# shellcheck source=tools.env
source "$HERE/tools.env"
# shellcheck source=../versions.env
source "$REPO/versions.env"

WINE_TARBALL=${1:?usage: build-appimage.sh WINE_TARBALL [VERSION]}
VERSION=${2:-$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo dev)}
OUT="$HERE/out"
APPDIR="$OUT/AppDir"
NAME=Affinity-Infinity-$VERSION-x86_64.AppImage

# fetch <url> <sha256> <file>
fetch() {
    if [[ ! -f "$3" ]] || ! sha256sum --status -c <<<"$2  $3"; then
        curl -fsSL --retry 3 -o "$3.part" "$1"
        mv "$3.part" "$3"
    fi
    sha256sum -c <<<"$2  $3"
}

mkdir -p "$OUT"
[[ -x "$OUT/tools/bin/winetricks" ]] || "$HERE/build-tools.sh" "$OUT"
fetch "$APPIMAGETOOL_URL" "$APPIMAGETOOL_SHA256" "$OUT/appimagetool-x86_64.AppImage"
fetch "$RUNTIME_URL" "$RUNTIME_SHA256" "$OUT/runtime-x86_64"
chmod +x "$OUT/appimagetool-x86_64.AppImage"

echo "==> AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/wine" "$APPDIR/licenses"
cp -r "$REPO/bin" "$REPO/lib" "$REPO/share" "$REPO/versions.env" "$REPO/README.md" "$APPDIR/"
cp "$HERE/AppRun" "$APPDIR/AppRun"
tar -C "$APPDIR/wine" --strip-components=1 -xf "$WINE_TARBALL"
cp -r "$OUT/tools" "$APPDIR/tools"
cp -r "$APPDIR/wine/LICENSES" "$APPDIR/licenses/wine"
cp -r "$APPDIR/tools/LICENSES" "$APPDIR/licenses/tools"
[[ -f "$REPO/LICENSE" ]] && cp "$REPO/LICENSE" "$APPDIR/licenses/affinity-infinity-LICENSE"
echo "$VERSION" >"$APPDIR/VERSION"

cp "$REPO/share/affinity-infinity.svg" "$APPDIR/affinity-infinity.svg"
ln -sf affinity-infinity.svg "$APPDIR/.DirIcon"
cat >"$APPDIR/affinity-infinity.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Affinity Infinity
Comment=Run Affinity by Canva on Linux (Wine); installs and updates Affinity from affinity.studio
Icon=affinity-infinity
Exec=affinity-infinity %F
Terminal=false
Categories=Graphics;
X-AppImage-Version=$VERSION
EOF

echo "==> $NAME"
args=(--runtime-file "$OUT/runtime-x86_64" --comp zstd -n)
if [[ -n "$AI_REPO" ]]; then
    args+=(-u "gh-releases-zsync|${AI_REPO%/*}|${AI_REPO#*/}|latest|Affinity-Infinity-*x86_64.AppImage.zsync")
fi
(cd "$OUT" && ARCH=x86_64 VERSION="$VERSION" APPIMAGE_EXTRACT_AND_RUN=1 \
    ./appimagetool-x86_64.AppImage "${args[@]}" "$APPDIR" "$OUT/$NAME")
(cd "$OUT" && sha256sum "$NAME" >"$NAME.sha256")
ls -la "$OUT/$NAME"*
