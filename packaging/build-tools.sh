#!/usr/bin/env bash
# Assemble the helper tools the prefix recipe needs into <out>/tools:
#   bin/winetricks   pinned winetricks
#   bin/cabextract   wrapper around libexec/cabextract with its libmspack
# cabextract is taken from Ubuntu 22.04 packages (run in a container), so it
# runs on the same glibc baseline as our Wine build.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools.env
source "$HERE/tools.env"
OUT=${1:-$HERE/out}
ENGINE=${ENGINE:-$(command -v podman || command -v docker || true)}
TOOLS="$OUT/tools"

rm -rf "$TOOLS"
mkdir -p "$TOOLS/bin" "$TOOLS/libexec" "$TOOLS/lib" "$TOOLS/LICENSES"

echo "==> winetricks $WINETRICKS_VERSION"
curl -fsSL --retry 3 -o "$TOOLS/bin/winetricks" "$WINETRICKS_URL"
sha256sum -c <<<"$WINETRICKS_SHA256  $TOOLS/bin/winetricks"
chmod +x "$TOOLS/bin/winetricks"

echo "==> cabextract from $TOOLS_IMAGE"
# Runs inside the container; expansions are meant for its shell.
# shellcheck disable=SC2016
extract='cd /tmp && apt-get update -qq && apt-get download -qq cabextract libmspack0 &&
    for d in *.deb; do dpkg -x "$d" x; done &&
    cp x/usr/bin/cabextract /out/libexec/ &&
    cp -P x/usr/lib/x86_64-linux-gnu/libmspack.so.0* /out/lib/ &&
    cp x/usr/share/doc/cabextract/copyright /out/LICENSES/cabextract-copyright &&
    cp x/usr/share/doc/libmspack0/copyright /out/LICENSES/libmspack-copyright'
[[ -n "$ENGINE" ]] || { echo "podman or docker is required" >&2; exit 1; }
"$ENGINE" run --rm -v "$TOOLS:/out:Z" "$TOOLS_IMAGE" bash -c "$extract"

cat >"$TOOLS/bin/cabextract" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")/..
LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$here/libexec/cabextract" "$@"
EOF
chmod +x "$TOOLS/bin/cabextract"

"$TOOLS/bin/cabextract" --version
find "$TOOLS" -type f -printf "%8s %P\n" | sort -k2
