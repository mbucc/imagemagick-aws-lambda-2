# ImageMagick for AWS Lambda

Scripts to compile ImageMagick utilities for AWS Lambda instances powered by Amazon Linux 2023, for both `arm64` (Graviton) and `x86_64`, compatible with modern Lambda runtimes such as `nodejs20.x`, `python3.12`, and other AL2023-based runtimes.

When Amazon moved Lambda to Amazon Linux 2023, they dropped [ImageMagick](https://imagemagick.org) from the base image, so its `convert`, `mogrify`, and `identify` tools are no longer available on the instance. This project builds them back as a Lambda layer.

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
step widens just the **dimension** ceilings — everything else in `secure` stays:

| Resource           | `secure` default | Widened to | Why                   |
|--------------------|------------------|------------|-----------------------|
| `width` / `height` | 8KP              | 16KP       | 48 MP is 8064 × 6048  |
| `area`             | 8KP              | 256MP      | ≫ 48 MP with headroom |

The `memory` limit is left at the `secure` default. This is a Q8, non-HDRI build
(see [Precision](#precision-q8-non-hdri)), so a 48 MP image decodes to only
~186 MiB — comfortably under the default, so no widening is needed.

### Sizing the Lambda's memory

A **channel** is one color component of a pixel — Red, Green, Blue, plus Alpha
(opacity). Q8, non-HDRI stores each channel in one byte, so a decoded RGBA pixel
is 4 bytes. Worked example for a 48 MP photo (8064 × 6048):

```
pixels        = 8064 × 6048           = 48,771,072   (~48.8 MP)
decoded cache = 48,771,072 × 4 bytes  = 195,084,288 bytes  ≈ 186 MiB
```

`convert` holds the full source cache while it resizes, so budget for that
~186 MiB plus a working copy and your runtime's own heap. A single 48 MP image
fits easily: **≥ 512 MiB** is a sane floor, and 1 GiB leaves ample room.
ImageMagick's own `memory` cap (the `secure` default, 768 MiB) already sits well
above the ~186 MiB need. Verify the active policy in a running layer with
`identify -list policy`.

## Precision: Q8, non-HDRI

> _Caveat: I'm not an imaging expert. Much of the analysis in this section was
> worked out with Claude (Opus), and I welcome corrections or comments from
> anyone with more expertise in this area._

This layer is built **Q8, non-HDRI** (`--with-quantum-depth=8 --disable-hdri`),
which trades color precision for roughly **4× less memory** and more speed than
ImageMagick's default Q16 HDRI build. Two terms:

- **Quantum depth** — how many bits ImageMagick keeps per channel *internally*
  while working. **Q8** = 8 bits (256 levels, 0–255), the precision of a
  standard JPEG and of ordinary 8-bit ("SDR") web images. **Q16** = 16 bits
  (65,536 levels), for finer intermediate math.
- **HDRI** (High Dynamic Range Imaging) — stores each channel as a
  floating-point number so intermediate values may briefly dip *below black* or
  rise *above white* instead of being clipped. It roughly doubles memory again
  on top of the depth.

For the most common job — decode an 8-bit photo (JPEG/PNG/WebP), resize it,
re-encode to 8-bit — this build is effectively lossless. Input and output are
both 8-bit; the resize arithmetic runs in floating point regardless of quantum
depth (quantum depth sets how pixels are *stored*, not the precision of the
*math*); and a single operation leaves no room for rounding error to build up.
**Can the eye see the difference from Q16?** No — for an 8-bit output the Q8 and
Q16 results differ by at most about one level in a handful of pixels, below what
the eye can resolve and far below what a lossy encoder (JPEG/WebP quality)
already discards. This holds even on a 10-bit display (a MacBook Pro XDR, a
recent iPhone OLED): the delivered file is 8-bit, so the display's extra
precision has no Q8-vs-Q16 difference to reveal — the output format is the
ceiling, not the screen.

### What this build is NOT good for

Rebuild with Q16 HDRI (ImageMagick's default — just remove the two flags) for
any of the following, where 8-bit precision can produce visible artifacts:

- **Long chains of operations.** Every step in a Q8 pipeline rounds back to 8
  bits. Resize → sharpen → color-correct → composite → … lets that rounding
  accumulate into **banding** — visible steps in what should be a smooth
  gradient, like a clear sky or a soft shadow. One resize is fine; a dozen
  chained edits are not.

- **Linear-light resizing.** Images normally store brightness on a curve (called
  *gamma*) that spends more values on dark tones, matching human vision. The
  technically-correct way to shrink an image is to first undo that curve — work
  in "linear light" — resize, then re-apply it. In linear light, 8 bits crowds
  the dark tones together and produces **shadow banding**, so it needs Q16+. (A
  plain resize skips this and works in the stored gamma space — unaffected, at
  the cost of slightly less accurate edges.)

- **More-than-8-bit sources or outputs.** 16-bit TIFF/PNG, camera RAW, OpenEXR,
  or any 10-bit/HDR content you want to keep above 8 bits. Q8 discards the extra
  bits on load.

- **Tone mapping, exposure, or heavy filtering.** Operations that push values
  past black or white mid-computation (strong blur/sharpen with negative filter
  weights, exposure changes, HDR tone mapping) rely on HDRI to hold those
  out-of-range values instead of clipping them.

- **Scientific or measurement work.** Anywhere exact pixel values matter and
  8-bit quantization is unacceptable.

For plain thumbnailing and format conversion of ordinary 8-bit photos, none of
these apply, and Q8/non-HDRI is the leaner, faster choice.

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

## Authors

* Gojko Adzic <https://gojko.net> — original author (2019)
* Rémi Cartier — HEIC support and CI/deploy (2021)
* Mark Bucciarelli <mkbucc@gmail.com> — Amazon Linux 2023 rework (2025)

## License

* These scripts: [MIT](https://opensource.org/licenses/MIT)
* ImageMagick: https://imagemagick.org/script/license.php
* Contained libraries all have separate licenses, check the respective web sites for more information
