# ImageMagick Lambda Layer for Amazon Linux 2023 (arm64)

Static build of ImageMagick for Amazon Linux 2023 (arm64 architecture), packaged as a Lambda layer.
Bundles ImageMagick 7.1.2-10, including convert, mogrify and identify tools
and support for jpeg, gif, png, tiff, webp, and heif formats.

This application provides a single output, `LayerVersion`, which points to a
Lambda Layer ARN you can use with Lambda runtimes based on Amazon Linux 2023 arm64 (such
as the `nodejs18.x`, `nodejs20.x`, `python3.11`, `python3.12` runtimes).

For an example of how to use the layer, check out 
https://github.com/serverlesspub/imagemagick-aws-lambda-2/tree/master/example
