# ImageMagick for AWS Lambda

Scripts to compile ImageMagick utilities for AWS Lambda instances powered by Amazon Linux 2023, for both `arm64` (Graviton) and `x86_64`, compatible with modern Lambda runtimes such as `nodejs20.x`, `python3.12`, and other AL2023-based runtimes.

Amazon Linux 2023 instances for Lambda no longer contain system utilities, so `convert`, `mogrify` and `identify` from the [ImageMagick](https://imagemagick.org) package are no longer available. 

## Prerequisites

* Podman (for local builds)
* AWS CLI with credentials for your **dev** account (for the EC2 builds)
* A Unix shell (the wrappers are POSIX `sh`)

## How the build is structured

The [`Makefile`](Makefile) is a plain **native** Amazon Linux 2023 build — it
assumes it is already running on AL2023 and does not invoke podman itself. The
actual per-library compile lives in
[`Makefile_ImageMagick`](Makefile_ImageMagick).

Getting *onto* AL2023 is the job of two thin wrapper scripts. Both run the
identical Makefile; they differ only in how they provide the environment, and
each builds **natively for its host CPU** (no QEMU emulation):

| Script | Environment | Builds |
|--------|-------------|--------|
| [`scripts/build-local.sh`](scripts/build-local.sh) | podman container on your laptop | your laptop's own arch |
| [`scripts/build-on-ec2.sh`](scripts/build-on-ec2.sh) | a matching-arch AL2023 EC2 box | `arm64` or `amd64`, whichever you pass |

### Building locally

```bash
scripts/build-local.sh
```

Builds for your laptop's architecture inside an AL2023 podman container and
writes `imagemagick-layer.zip` to the project root.

### Building a release (both architectures)

```bash
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh arm64
AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh amd64
```

Each invocation launches a one-shot AL2023 instance of the matching
architecture, builds natively, copies the zip back as
`imagemagick-7.1.2-al2023-<arch>.zip`, and terminates the instance. See the
script header for env overrides (`INSTANCE_TYPE`, `AWS_DEFAULT_REGION`,
`KEEP_INSTANCE`).

The resulting zip contains the `/opt` directory structure (binaries,
libraries, and the hardened `policy.xml`), ready to publish as a Lambda layer.

### Configuring the build

The layer installs to `/opt` (the `TARGET_DIR` variable). This must stay `/opt`:
ImageMagick bakes that path in at compile time and a Lambda layer unzips there
— see [Security policy](#security-policy) for why it matters to `policy.xml`.

The local build uses the official multi-arch AWS Lambda base image
`public.ecr.aws/lambda/provided:al2023` (see the [`Dockerfile`](Dockerfile));
podman's `--platform` selects the arch matching your laptop.

Current ImageMagick version: **7.1.2-27** (July 5, 2026)

Modify the versions of libraries or ImageMagick directly in [`Makefile_ImageMagick`](Makefile_ImageMagick).

### Experimenting

These `make` targets run inside the build environment (via a wrapper, or on the
EC2 box), since they execute the freshly built Linux binaries:

* `make libs` — build only the libraries, useful when adding a new format
* `make check` — print the built binary's active security policy and verify it matches expectations (see [`scripts/check-policy.sh`](scripts/check-policy.sh))

### Bundled libraries

This is not a full-blown ImageMagick setup you can expect on a regular Linux box, it's a slimmed down version to save space that works with the most common formats. You can add more formats by including another library into the build process in [`Makefile_ImageMagick`](Makefile_ImageMagick).

These libraries are currently bundled:

* libpng
* libtiff
* libjpeg
* openjpeg2
* libwebp
* libheif (+ libde265)
* lcms2

## Security policy

The build hardens ImageMagick by compiling with
`--with-security-policy=secure` (see ImageMagick's
[security policy guide](https://imagemagick.org/security-policy/#gsc.tab=0)).
This installs a `policy.xml` (shipped in the layer at
`/opt/etc/ImageMagick-7/policy.xml` and loaded automatically at runtime) that
disables the coders and delegates most often abused in image-processing
exploits — `SVG`, `MSL`, `MVG`, `URL`/`HTTP`/`HTTPS`, and external delegates —
while leaving the ordinary raster formats (JPEG/PNG/WebP/TIFF/HEIC) working.

The `secure` profile also clamps resource usage hard: its default
`width`/`height` limit of `8KP` (8000 px) **rejects a full-resolution 48 MP
iPhone photo** (8064 × 6048). So after the build, the
[`scripts/secure-policy-allow-48mp.sh`](scripts/secure-policy-allow-48mp.sh)
step widens just the resource ceilings — everything else in `secure` stays:

| Resource           | `secure` default | Widened to | Why                                  |
|--------------------|------------------|------------|--------------------------------------|
| `width` / `height` | 8KP              | 16KP       | 48 MP is 8064 × 6048                  |
| `area`             | 8KP              | 256MP      | ≫ 48 MP with headroom                |
| `memory`           | 768MiB           | 1GiB       | 48 MP at Q16 HDRI ≈ 372 MiB decoded  |

### Sizing the Lambda's memory

This is a **Q16 HDRI** build, so every pixel is RGBA at 16 bits = 4 channels ×
2 bytes = **8 bytes/pixel** in the decoded pixel cache. Worked example for an
iPhone 17 48 MP photo:

```
pixels        = 8064 × 6048            = 48,771,072   (~48.8 MP)
decoded cache = 48,771,072 × 8 bytes   = 390,168,576 bytes  ≈ 372 MiB
```

`convert` holds the full source cache while it resizes, so budget for roughly
that 372 MiB **plus** a working copy and the JVM handler's own heap. Practical
floor: give the Lambda **≥ 1024 MiB** (1 GiB) for a single 48 MP image; 1536
MiB is comfortable if the handler does other work. The `memory` limit in
`policy.xml` (1 GiB above) is ImageMagick's own cap and should stay at or below
the Lambda's configured memory. Verify the active policy in a running layer
with `magick -list policy`.

## Publishing the layer

The two zips (`imagemagick-7.1.2-al2023-arm64.zip` and
`imagemagick-7.1.2-al2023-x86_64.zip`) are published as a GitHub release. Each
`build-on-ec2.sh` run prints the artifact's `sha256`; record both in the
release notes so consumers can pin and verify them.

```sh
gh release create im-7.1.2-al2023 \
  imagemagick-7.1.2-al2023-arm64.zip \
  imagemagick-7.1.2-al2023-x86_64.zip \
  --title "ImageMagick 7.1.2 for AWS Lambda AL2023 (arm64 + x86_64)"
```

Downstream projects pin a release asset by URL (for example, a Bazel
`http_file` with the recorded `sha256`) and attach it as a Lambda layer — no
build step in the consuming project.

## Installing the layer

Attach a released zip to a Lambda function as a layer. **The layer's
architecture must match the function's architecture** (`arm64` layer for a
Graviton function, `x86_64` layer for an x86 function).

1. Download the asset for your architecture from the GitHub release — e.g.
   `imagemagick-7.1.2-al2023-arm64.zip` — or pin its URL in your IaC.

2. Publish it as a Lambda layer version:

   ```sh
   aws lambda publish-layer-version \
     --layer-name imagemagick \
     --zip-file fileb://imagemagick-7.1.2-al2023-arm64.zip \
     --compatible-architectures arm64 \
     --compatible-runtimes provided.al2023 nodejs20.x python3.12
   ```

3. Attach the returned `LayerVersionArn` to your function — via the console,
   `aws lambda update-function-configuration --function-name <fn> --layers <arn>`,
   or your IaC (CDK/Terraform/etc.).

At runtime the binaries live under `/opt/bin` (`/opt/bin/convert`,
`/opt/bin/identify`, …) and the hardened `policy.xml` loads automatically from
`/opt/etc/ImageMagick-7/`. Confirm the policy is active with
`/opt/bin/identify -list policy`.

## Info on scripts

For more information, check out:

* https://imagemagick.org/script/install-source.php
* http://www.linuxfromscratch.org/blfs/view/cvs/general/imagemagick.html

## Author

Gojko Adzic <https://gojko.net>

## License

* These scripts: [MIT](https://opensource.org/licenses/MIT)
* ImageMagick: https://imagemagick.org/script/license.php
* Contained libraries all have separate licenses, check the respective web sites for more information
