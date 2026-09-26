#!/usr/bin/env bash
# Build Wine locally in a podman (or docker) container on the pinned build image.
# Output lands in wine/out/, downloads and the build tree are kept in wine/.cache/.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=build.env
source "$HERE/build.env"
ENGINE=${ENGINE:-$(command -v podman || command -v docker)}
IMAGE=localhost/affinity-infinity-wine-builder:$(sha256sum "$HERE/deps-ubuntu.txt" | cut -c1-12)

mkdir -p "$HERE/out" "$HERE/.cache"

if ! "$ENGINE" image exists "$IMAGE" 2>/dev/null; then
    echo "==> building builder image $IMAGE"
    "$ENGINE" build -t "$IMAGE" -f - "$HERE" <<EOF
FROM $BUILD_IMAGE
COPY deps-ubuntu.txt /tmp/
RUN apt-get update && DEBIAN_FRONTEND=noninteractive xargs -a /tmp/deps-ubuntu.txt apt-get install -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
EOF
fi

exec "$ENGINE" run --rm \
    -v "$HERE:/src:ro,Z" \
    -v "$HERE/out:/out:Z" \
    -v "$HERE/.cache:/cache:Z" \
    -e WORK=/cache/work -e JOBS="${JOBS:-$(nproc)}" \
    "$IMAGE" bash /src/build.sh /out
