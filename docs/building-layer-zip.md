---
date: December 14, 2025
author: Mark Bucciarelli
title: Building the Lambda Layer ZIP File
---

# Overview

This document describes how to build a standalone Lambda layer ZIP file that can be used in other projects.

# Quick Start

To build the layer ZIP file:

```bash
make imagemagick-layer.zip
```

This creates `imagemagick-layer.zip` in the project root (26MB).

# What Gets Built

The ZIP file contains the complete `/opt` directory structure that AWS Lambda expects for layers:

- `/opt/bin/` - ImageMagick command-line tools (convert, identify, etc.)
- `/opt/lib/` - Shared libraries
- `/opt/etc/` - Configuration files
- `/opt/include/` - Header files
- `/opt/share/` - Locale and other shared data

# Using in Other Projects

## As a Git Submodule

Other projects can include this as a git submodule and build the layer on demand:

```bash
# Add submodule (one time)
git submodule add <url> external/imagemagick-aws-lambda-2
git submodule update --init --recursive

# Build the layer
cd external/imagemagick-aws-lambda-2
make imagemagick-layer.zip

# Copy to your project's deploy directory
cp imagemagick-layer.zip ../../deploy/
```

## Integration Script Example

A parent project can automate this with a shell script:

```bash
#!/bin/sh
set -e

SUBMODULE_DIR="external/imagemagick-aws-lambda-2"
OUTPUT_ZIP="deploy/imagemagick-layer.zip"

if [ ! -d "$SUBMODULE_DIR" ]; then
    echo "Error: Submodule not found"
    exit 1
fi

cd "$SUBMODULE_DIR"
make imagemagick-layer.zip
cd - > /dev/null

cp "$SUBMODULE_DIR/imagemagick-layer.zip" "$OUTPUT_ZIP"
echo "Layer copied to $OUTPUT_ZIP"
```

# File Format

The ZIP file uses the `-y` flag to preserve symlinks. ImageMagick has many symlinks (convert, mogrify, etc. all link to the main `magick` binary), and preserving them keeps the layer size smaller.

# Build Prerequisites

Before running `make imagemagick-layer.zip`, you must have:

1. Built the container image: `make build-image`
2. Compiled the binaries: `make all`

The `imagemagick-layer.zip` target depends on `result/bin/identify`, which triggers the full build if needed.

# Clean Up

To remove the generated ZIP file:

```bash
make clean
```

This removes `build/`, `result/`, and `imagemagick-layer.zip`.
