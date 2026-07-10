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

Authenticate the GitHub CLI and set the default repo for this directory
(once per machine; stored in `.git/config`, not global):

```sh
gh auth login
gh repo set-default mbucc/imagemagick-aws-lambda-2
```

Each release gets its own **immutable** tag — never reuse one. The tag encodes
the ImageMagick version (read from `Makefile_ImageMagick`) plus a build
revision. Bump the revision (`r1` → `r2` → …) whenever you rebuild the *same*
ImageMagick version with different options (e.g. the Q16→Q8 change); reset to
`r1` on a new ImageMagick version.

`scripts/release.sh` reads the version from `Makefile_ImageMagick`, computes
sha256 checksums for both zips, creates an annotated git tag with the release
notes as its message, pushes the tag, and publishes the GitHub release:

```sh
scripts/release.sh r2
```

If you need to correct a release, bump to the next revision (`r3`, `r4`, …)
and run the script again — never reuse an existing tag.

`scripts/release.sh` enforces this: it checks that HEAD is on an origin
branch before creating the tag, and exits with an error if not.
