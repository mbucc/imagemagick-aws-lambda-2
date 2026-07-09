PROJECT_ROOT = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Where ImageMagick is installed. This MUST be /opt: ImageMagick bakes this
# path in at compile time and looks there for policy.xml (its security config)
# at runtime, and a Lambda layer is unzipped to /opt. See the README "Security
# policy" section.
#
# This Makefile is the build itself and assumes it is ALREADY running on an
# Amazon Linux 2023 environment where it may write /opt. Getting onto AL2023 is
# the wrapper's job -- podman for local dev (scripts/build-local.sh) or a
# matching-arch EC2 box for releases (scripts/build-on-ec2.sh). Podman is
# intentionally NOT invoked here.
TARGET_DIR ?= /opt

.PHONY: all libs check clean

build:
	mkdir $@

# Compile ImageMagick and its bundled image libraries, installing everything
# under $(TARGET_DIR) (the configure --prefix). The actual compile lives in
# Makefile_ImageMagick, run from the build/ working dir.
all libs: build
	cd build && $(MAKE) TARGET_DIR=$(TARGET_DIR) -f ../Makefile_ImageMagick $@

$(TARGET_DIR)/bin/identify: all

# Verify the built binary actually loaded the hardened + 48 MP-widened policy,
# using ImageMagick's own `identify -list policy`. Fails loudly if the policy
# is missing -- which would otherwise mean a silently unrestricted ImageMagick.
# Only meaningful on AL2023 (the binary is a Linux executable); run it via the
# same wrapper as the build.
check: $(TARGET_DIR)/bin/identify
	$(TARGET_DIR)/bin/identify -list policy | sh scripts/check-policy.sh

imagemagick-layer.zip: $(TARGET_DIR)/bin/identify
	# The build installs the `secure` policy (--with-security-policy=secure);
	# widen its resource limits so 48 MP iPhone photos are not rejected...
	sh scripts/secure-policy-allow-48mp.sh $(TARGET_DIR)
	# ...then confirm the built binary actually loaded it before we ship.
	$(TARGET_DIR)/bin/identify -list policy | sh scripts/check-policy.sh
	# imagemagick has a ton of symlinks; -y stores them as symlinks instead of
	# packaging each target as a separate file (aws/aws-cli#2900).
	@echo "Creating layer zip at $(PROJECT_ROOT)imagemagick-layer.zip"
	cd $(TARGET_DIR) && zip -ry $(PROJECT_ROOT)imagemagick-layer.zip *

clean:
	rm -rf build imagemagick-layer.zip
