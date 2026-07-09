#!/bin/sh -e
# Build the ImageMagick Lambda layer locally, inside a podman container that
# matches the Lambda runtime (Amazon Linux 2023).
#
# The Makefile is a plain native AL2023 build; this wrapper's only job is to
# provide that environment. We build for the developer's OWN CPU (Apple Silicon
# -> arm64, Intel/AMD -> amd64) so there is no QEMU emulation. The other
# architecture is built on a matching-arch EC2 box via scripts/build-on-ec2.sh.
#
# Output: imagemagick-layer.zip in the repo root.
# Prereq: podman running.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# Docker/OCI platform name for the host CPU. We only ever build the native
# arch here -- no QEMU.
case "$(uname -m)" in
    x86_64)        PLATFORM=linux/amd64 ;;
    arm64|aarch64) PLATFORM=linux/arm64 ;;
    *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

IMAGE="imagemagick-lambda-builder:al2023"

echo "==> Building layer locally via podman ($PLATFORM)"

# Build the deps image (gcc, make, zip, ...) from the Dockerfile.
podman build --platform "$PLATFORM" -t "$IMAGE" .

# Run the native Makefile inside the container. Mount ONLY the repo at
# /var/task: sources go in and the finished imagemagick-layer.zip is written
# back out there. ImageMagick installs to the container's ephemeral /opt -- the
# path it bakes in as its config/policy location -- exactly as it will on the
# EC2 build and in Lambda.
#
# --entrypoint /bin/sh overrides the base image's Lambda bootstrap entrypoint
# (which otherwise treats our command as a handler name and errors with
# "entrypoint requires the handler name to be the first argument").
podman run --rm -t \
    --platform "$PLATFORM" \
    -v "$REPO_ROOT":/var/task \
    -w /var/task \
    --entrypoint /bin/sh \
    "$IMAGE" \
    -c "make imagemagick-layer.zip"

echo ""
echo "==> Done. Layer: $REPO_ROOT/imagemagick-layer.zip"
echo "    sha256: $(shasum -a 256 "$REPO_ROOT/imagemagick-layer.zip" | cut -d' ' -f1)"
