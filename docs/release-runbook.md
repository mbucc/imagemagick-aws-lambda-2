# Runbook: Cut the ImageMagick AL2023 GitHub release

_July 8, 2026_

Publish a GitHub release on `mbucc/imagemagick-aws-lambda-2` with prebuilt
Lambda layer zips for both architectures (arm64 + x86_64, AL2023, ImageMagick
7.1.2-27, hardened `secure` policy widened for 48 MP photos). Consumers pin the
release assets by URL (e.g. Bazel `http_file`) instead of building the layer.

## Status of the build system

The build is done and lives in the repo:

- `Makefile` — native AL2023 build (no podman); installs to `/opt`, widens the
  secure policy, verifies it, and zips.
- `scripts/build-local.sh` — local build via podman, host arch only.
- `scripts/build-on-ec2.sh <arm64|amd64>` — one-shot matching-arch AL2023 EC2
  build; prints the artifact `sha256`.
- `scripts/secure-policy-allow-48mp.sh` / `scripts/check-policy.sh` — policy
  widening + verification.

What remains is committing your changes, running the two release builds, and
publishing them.

## Step 1: Commit and push your changes

Create the release from a commit that is **already on GitHub**. `gh release
create` (Step 4) tags the latest commit on the remote default branch, so
anything you have not pushed will not be in the release — and if you release
before pushing, the tag lands on the *previous* commit and you must move it
afterward (see [Fixing a tag created too early](#fixing-a-tag-created-too-early)).

```sh
git add -A
git commit -m "…"          # your build / policy / doc changes
git push origin master
git status                 # confirm: "up to date with 'origin/master'"
```

## Step 2: Log in to AWS

The EC2 build uses your **dev** AWS account. Refresh SSO credentials first
(substitute your own profile name for `<dev-profile>`):

```sh
aws sso login --profile <dev-profile>
```

## Step 3: Build both architectures on EC2

Each run launches a one-shot instance, builds natively from your pushed source,
copies the zip back, and terminates the instance.

```sh
cd ./imagemagick-aws-lambda-2
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh arm64
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh amd64
```

Record the `sha256` each run prints. The scripts name the artifacts with the
AWS architecture name, ready for the release:

- `imagemagick-7.1.2-al2023-arm64.zip`
- `imagemagick-7.1.2-al2023-x86_64.zip`

## Step 4: Create the GitHub release

Authenticate the GitHub CLI first (once per machine):

```sh
gh auth login
```

Then create the release. `gh release create` creates the `im-7.1.2-al2023` tag
at the current tip of the remote default branch — i.e. the commit you pushed in
Step 1:

```sh
gh release create im-7.1.2-al2023 \
  imagemagick-7.1.2-al2023-arm64.zip \
  imagemagick-7.1.2-al2023-x86_64.zip \
  -R mbucc/imagemagick-aws-lambda-2 \
  --title "ImageMagick 7.1.2 for AWS Lambda AL2023 (arm64 + x86_64)" \
  --notes "$(cat <<'EOF'
Prebuilt ImageMagick 7.1.2-27 Lambda layers for AL2023, built from source in a
matching-arch environment (NOT from RPMs — dnf installs ImageMagick 6).

Hardened with the `secure` policy (SVG/MSL/MVG/URL and external delegates
disabled), with resource limits widened for 48 MP photos.

## sha256

```
<arm64-sha256>   imagemagick-7.1.2-al2023-arm64.zip
<x86_64-sha256>  imagemagick-7.1.2-al2023-x86_64.zip
```
EOF
)"
```

To update assets on an existing release (e.g. after a rebuild), re-upload with
`--clobber` instead of recreating it:

```sh
gh release upload im-7.1.2-al2023 imagemagick-7.1.2-al2023-*.zip \
  --clobber -R mbucc/imagemagick-aws-lambda-2
```

## Fixing a tag created too early

If you ran `gh release create` before pushing your commit, the tag
`im-7.1.2-al2023` points at the old commit. Move it to the pushed commit and
force-push the tag:

```sh
git tag -f im-7.1.2-al2023 master
git push --force origin refs/tags/im-7.1.2-al2023
```

Refresh the release page to confirm it now shows the correct commit. Doing
Step 1 first avoids ever needing this.
