---
date: December 13, 2025
author: Mark Bucciarelli
title: Migration Plan - AWS Lambda Base Images + Podman + Latest ImageMagick
---

# Overview

Migrate the ImageMagick Lambda layer build process from:

- **FROM:** lambci/lambda-base-2:build (unofficial, Docker)
- **TO:** public.ecr.aws/lambda/provided:al2023-arm64 (official AWS, Podman)

# Requirements

1. Use AWS official Lambda base image for arm64 architecture
2. Replace Docker with Podman across all build scripts
3. Update to latest ImageMagick version compatible with AL2023
4. Update GitHub Actions workflow for Podman

# Critical Files to Modify

## 1. Create New Dockerfile

**File:** `imagemagick-aws-lambda-2/Dockerfile`

Currently no Dockerfile exists. Need to create one based on:

```dockerfile
FROM public.ecr.aws/lambda/provided:al2023-arm64

# Install build tools and dependencies for AL2023
RUN dnf install -y \
    gcc \
    gcc-c++ \
    make \
    cmake \
    autoconf \
    automake \
    libtool \
    pkgconfig \
    tar \
    gzip \
    bzip2 \
    xz \
    curl \
    zip

WORKDIR /var/task
```

Key considerations:

- AL2023 uses `dnf` package manager (not yum)
- Need gcc, make, autoconf, cmake for compiling from source
- arm64 architecture for Lambda Graviton2 processors

## 2. Update Main Makefile

**File:** `imagemagick-aws-lambda-2/Makefile`

Changes required:

- **Line 3:** Change `DOCKER_IMAGE` from `lambci/lambda-base-2:build` to custom built image
- **Line 9:** Change `DOCKER` variable from `docker run` to `podman run`
- Add target to build the Dockerfile locally
- Update all docker references to podman

Current structure:

```makefile
DOCKER_IMAGE ?= lambci/lambda-base-2:build  # Change to custom image name
DOCKER = docker run -t --rm -w=/var/task/build  # Change to podman
```

New structure:

```makefile
IMAGE_NAME ?= imagemagick-lambda-builder
IMAGE_TAG ?= al2023-arm64
PODMAN = podman run -t --rm -w=/var/task/build --platform linux/arm64

.PHONY: build-image
build-image:
	podman build --platform linux/arm64 -t $(IMAGE_NAME):$(IMAGE_TAG) .
```

## 3. Update ImageMagick Version

**File:** `imagemagick-aws-lambda-2/Makefile_ImageMagick`

Version updates needed:

- **Line 7:** IMAGEMAGICK_VERSION from `7.1.0-52` to latest `7.1.1-x`
  - Research latest stable release from https://github.com/ImageMagick/ImageMagick/releases
  - Verify compatibility with AL2023 arm64

Optional dependency updates (if needed for compatibility):

- **Line 1:** LIBPNG_VERSION (currently 1.6.37)
- **Line 2:** LIBJPG_VERSION (currently 9c)
- **Line 4:** LIBTIFF_VERSION (currently 4.0.9)
- **Line 6:** LIBWEBP_VERSION (currently 0.6.1)
- **Line 8:** LIBHEIF_VERSION (currently 1.13.0)

Strategy: Start with only ImageMagick update, update deps only if build fails.

## 4. Update GitHub Actions Workflow

**File:** `imagemagick-aws-lambda-2/.github/workflows/build.yml`

Changes required:

- Add step to install Podman on ubuntu-latest runner
- Update deployment steps to build Docker image first
- Ensure arm64 support in GitHub Actions

Add new step after "Install python dependencies" (around line 90):

```yaml
- name: Install Podman
  shell: bash
  run: |
    echo "Installing Podman..."
    sudo apt-get update
    sudo apt-get -y install podman
    podman --version
```

Update deploy steps (lines 94-104) to include:

```yaml
- name: Build container image
  shell: bash
  run: |
    make build-image
```

## 5. Update Documentation

**Files to update:**

- `imagemagick-aws-lambda-2/README.md`
  - Update prerequisites (Podman instead of Docker)
  - Update base image reference
  - Update ImageMagick version
  - Add arm64 architecture note

- `imagemagick-aws-lambda-2/README-SAR.md`
  - Update version from 7.0.8-45 to new version
  - Update Lambda runtime compatibility

# Implementation Steps

## Phase 1: Local Setup

1. Create Dockerfile with AL2023 arm64 base image
2. Add build-image target to Makefile
3. Update DOCKER_IMAGE and PODMAN variables in Makefile
4. Update all docker commands to podman in Makefile

## Phase 2: Version Updates

1. Research latest ImageMagick 7.1.1.x stable release
2. Update IMAGEMAGICK_VERSION in Makefile_ImageMagick
3. Test build locally with: `make build-image && make all`
4. If build fails, update dependency library versions as needed

## Phase 3: GitHub Actions

1. Add Podman installation step to workflow
2. Add container image build step before make all
3. Test workflow in non-prod environment first

## Phase 4: Testing & Validation

1. Build locally with Podman on arm64 (if available) or use QEMU emulation
2. Verify result/bin/identify exists and works
3. Test layer deployment to dev environment
4. Run example Lambda function to validate layer functionality
5. Compare layer size (AL2023 should be smaller than AL2)

## Phase 5: Documentation

1. Update README.md with new prerequisites and versions
2. Update README-SAR.md with current ImageMagick version
3. Document arm64 architecture requirement

# Risks & Challenges

## 1. Cross-platform Build

**Issue:** Building arm64 images on x86_64 development machines

**Solution:**

- Podman supports multi-arch builds with QEMU
- Use `--platform linux/arm64` flag
- GitHub Actions runners are x86_64, will use emulation

## 2. AL2023 Package Availability

**Issue:** Some build dependencies may have different names in AL2023

**Solution:**

- DNF search for equivalent packages
- May need to adjust package names in Dockerfile
- AL2023 is newer, should have updated versions

## 3. ImageMagick Compatibility

**Issue:** Latest ImageMagick may have different configure flags or dependencies

**Solution:**

- Start with closest stable release (7.1.1.x series)
- Review ImageMagick changelog for breaking changes
- Test configure step carefully

## 4. Static Linking on arm64

**Issue:** Library paths or linking may differ on arm64

**Solution:**

- Keep existing CONFIGURE flags in Makefile_ImageMagick
- Monitor build logs for linking errors
- May need to adjust LDFLAGS

## 5. Podman vs Docker Differences

**Issue:** Minor behavioral differences between Podman and Docker

**Solution:**

- Podman is designed to be drop-in replacement
- Most docker commands work with podman
- Test thoroughly before CI/CD migration

# Success Criteria

1. ✅ Build completes successfully with Podman
2. ✅ Result contains /opt/bin/identify binary
3. ✅ Lambda layer deploys to AWS
4. ✅ Example Lambda function can use the layer
5. ✅ ImageMagick version is 7.1.1.x or later
6. ✅ Layer size is optimized (AL2023 minimal image benefit)
7. ✅ GitHub Actions workflow succeeds
8. ✅ Documentation updated

# Rollback Plan

If migration fails:

1. Revert Makefile changes to use docker
2. Revert DOCKER_IMAGE to lambci/lambda-base-2:build
3. Keep existing ImageMagick version
4. Delete Dockerfile

Git provides easy rollback via:

```bash
git checkout -- Makefile Makefile_ImageMagick .github/workflows/build.yml
rm Dockerfile
```

# Additional Notes

- **Architecture choice:** Using arm64 for better Lambda performance and cost
- **AL2023 benefits:** Smaller image size (~40MB vs ~109MB), updated libraries, longer support (until 2029)
- **Podman benefits:** Daemonless, rootless, more secure than Docker
- **ImageMagick versions:** Moving from 7.1.0-52 (2022) to 7.1.1.x (2024/2025)
