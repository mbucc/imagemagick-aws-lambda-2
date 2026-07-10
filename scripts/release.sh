#!/bin/sh -e
# Create the GitHub release for an ImageMagick Lambda layer build.
# Both arch zips must already exist in the repo root (produced by build-on-ec2.sh).
# The ImageMagick version is read from Makefile_ImageMagick.
# Release notes come from the annotated git tag message (--notes-from-tag).
#
# Usage:
#   scripts/release.sh [--dry-run] <revision>
#
# Example:
#   scripts/release.sh r2
#   scripts/release.sh --dry-run r2

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

REVISION="${1:-}"
if [ -z "$REVISION" ]; then
    printf 'usage: %s [--dry-run] <revision>   e.g. r2\n' "$0" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

printf 'reading ImageMagick version from Makefile_ImageMagick ...\n'
MATCH_COUNT=$(grep -c '^IMAGEMAGICK_VERSION' "$REPO_ROOT/Makefile_ImageMagick")
if [ "$MATCH_COUNT" -ne 1 ]; then
    printf 'error: expected exactly one IMAGEMAGICK_VERSION line in Makefile_ImageMagick, found %s\n' \
        "$MATCH_COUNT" >&2
    exit 1
fi
VERSION=$(grep '^IMAGEMAGICK_VERSION' "$REPO_ROOT/Makefile_ImageMagick" \
    | sed 's/.*?= *//')
printf 'ImageMagick version: %s\n' "$VERSION"

printf 'generating release tag ...\n'
TAG="im-$VERSION-al2023-$REVISION"
printf 'release tag: %s\n' "$TAG"

printf 'checking for uncommitted changes ...\n'
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    printf 'error: uncommitted changes in repo; commit or stash before releasing\n' >&2
    exit 1
fi
printf 'working tree is clean.\n'

printf 'checking HEAD has been pushed to origin ...\n'
if ! git -C "$REPO_ROOT" branch -r --contains HEAD | grep -q 'origin/'; then
    printf 'error: HEAD commit is not on any origin branch; push before releasing\n' >&2
    exit 1
fi
printf 'HEAD is on origin.\n'

printf 'checking tag %s does not already exist locally ...\n' "$TAG"
if git -C "$REPO_ROOT" rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
    printf 'error: tag %s already exists locally\n' "$TAG" >&2
    exit 1
fi
printf 'tag %s does not exist yet.\n' "$TAG"

ARM64_ZIP="$REPO_ROOT/imagemagick-$VERSION-al2023-arm64.zip"
X86_64_ZIP="$REPO_ROOT/imagemagick-$VERSION-al2023-x86_64.zip"

printf 'checking zip files exist ...\n'
for f in "$ARM64_ZIP" "$X86_64_ZIP"; do
    [ -f "$f" ] || { printf 'error: missing %s\n' "$f" >&2; exit 1; }
done
printf 'found: %s\n' "$ARM64_ZIP"
printf 'found: %s\n' "$X86_64_ZIP"

printf 'computing sha256 checksums ...\n'
ARM64_SHA=$(shasum -a 256 "$ARM64_ZIP" | cut -d' ' -f1)
X86_64_SHA=$(shasum -a 256 "$X86_64_ZIP" | cut -d' ' -f1)
printf 'arm64:  %s\n' "$ARM64_SHA"
printf 'x86_64: %s\n' "$X86_64_SHA"

printf 'generating release notes ...\n'
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT

cat > "$NOTES" <<EOF
Prebuilt ImageMagick Lambda layers for AL2023, built from source in a
matching-arch environment (NOT from RPMs -- dnf installs ImageMagick 6).

Hardened with the \`secure\` policy (SVG/MSL/MVG/URL and external delegates
disabled), with resource limits widened for 48 MP photos.

## sha256

\`\`\`
$ARM64_SHA  imagemagick-$VERSION-al2023-arm64.zip
$X86_64_SHA  imagemagick-$VERSION-al2023-x86_64.zip
\`\`\`
EOF
printf 'release notes generated.\n'

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n--- DRY RUN: tag and release notes preview ---\n\n'
    printf 'tag: %s\n\n' "$TAG"
    cat "$NOTES"
    printf '\n--- DRY RUN complete, no tag created or pushed ---\n'
    exit 0
fi

printf 'creating annotated git tag %s ...\n' "$TAG"
git -C "$REPO_ROOT" tag -a "$TAG" -F "$NOTES"
printf 'tag %s created.\n' "$TAG"

printf 'pushing tag %s to origin ...\n' "$TAG"
git -C "$REPO_ROOT" push origin "refs/tags/$TAG"
printf 'tag %s pushed.\n' "$TAG"

printf 'creating GitHub release %s ...\n' "$TAG"
gh release create "$TAG" \
    "$ARM64_ZIP" \
    "$X86_64_ZIP" \
    -R mbucc/imagemagick-aws-lambda-2 \
    --title "$TAG" \
    --verify-tag \
    --notes-from-tag \
    --fail-on-no-commits
printf 'release created: https://github.com/mbucc/imagemagick-aws-lambda-2/releases/tag/%s\n' "$TAG"
