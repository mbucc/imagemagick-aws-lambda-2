---
date: December 14, 2025
updated: July 8, 2026
author: Mark Bucciarelli
title: Building the Lambda Layer ZIP File
---

# Overview

This document describes how to build the standalone Lambda layer ZIP file that
other projects consume.

# Quick Start

The `Makefile` is a native Amazon Linux 2023 build and does not invoke podman
itself; a wrapper provides the AL2023 environment. Do not run `make` directly
on a laptop — use a wrapper:

```bash
# Local build, for your laptop's own architecture (via podman):
scripts/build-local.sh

# Release build, for a specific architecture (via a one-shot EC2 instance):
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh arm64
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh amd64
```

`build-local.sh` writes `imagemagick-layer.zip` to the project root.
`build-on-ec2.sh` writes `imagemagick-7.1.2-al2023-<arch>.zip` and prints its
`sha256`.

# What Gets Built

The ZIP contains the complete `/opt` directory structure that AWS Lambda
expects for layers:

- `/opt/bin/` - ImageMagick command-line tools (convert, identify, etc.)
- `/opt/lib/` - Shared libraries
- `/opt/etc/` - Configuration files, including the hardened `policy.xml`
- `/opt/include/` - Header files
- `/opt/share/` - Locale and other shared data

# Security policy

The build compiles with `--with-security-policy=secure` and then widens only
the resource limits (via `scripts/secure-policy-allow-48mp.sh`) so 48 MP photos
are allowed. `make imagemagick-layer.zip` verifies the built binary actually
loaded that policy (`scripts/check-policy.sh`) and fails the build otherwise.
See the README "Security policy" section for details.

# Using in Other Projects

The layers are published as GitHub release assets. A consuming project pins a
release asset by URL — for example a Bazel `http_file` with the recorded
`sha256` — and attaches it as a Lambda layer. There is no build step, git
submodule, or copy-back in the consuming project. See the README "Installing
the layer" section.

# File Format

The ZIP uses the `-y` flag to preserve symlinks. ImageMagick has many symlinks
(convert, mogrify, etc. all link to the main `magick` binary), and preserving
them keeps the layer size smaller.

# Clean Up

To remove the local build artifacts:

```bash
make clean
```

This removes `build/` and `imagemagick-layer.zip`. (On the EC2 build the
install tree lives in the instance's `/opt` and is discarded when the one-shot
instance terminates.)
