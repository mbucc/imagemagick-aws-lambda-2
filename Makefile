PROJECT_ROOT = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

IMAGE_NAME ?= imagemagick-lambda-builder
IMAGE_TAG ?= al2023-arm64
TARGET ?=/opt/

MOUNTS = -v $(PROJECT_ROOT):/var/task \
	-v $(PROJECT_ROOT)result:$(TARGET)

PODMAN = podman run -t --rm -w=/var/task/build --platform linux/arm64

.PHONY: build-image
build-image:
	podman build --platform linux/arm64 -t $(IMAGE_NAME):$(IMAGE_TAG) .

build result:
	mkdir $@

clean:
	rm -rf build result imagemagick-layer.zip

list-formats:
	$(PODMAN) $(MOUNTS) --entrypoint /opt/bin/identify $(IMAGE_NAME):$(IMAGE_TAG) -list format

bash:
	$(PODMAN) $(MOUNTS) --entrypoint /bin/bash $(IMAGE_NAME):$(IMAGE_TAG)

all libs: build result
	$(PODMAN) $(MOUNTS) --entrypoint /usr/bin/make $(IMAGE_NAME):$(IMAGE_TAG) TARGET_DIR=$(TARGET) -f ../Makefile_ImageMagick $@


STACK_NAME ?= imagemagick-layer 

result/bin/identify: all

imagemagick-layer.zip: result/bin/identify
	# imagemagick has a ton of symlinks, and just using the source dir in the template
	# would cause all these to get packaged as individual files.
	# (https://github.com/aws/aws-cli/issues/2900)
	#
	# This is why we zip outside, using -y to store them as symlinks
	@echo "Creating layer zip at $(PROJECT_ROOT)imagemagick-layer.zip"
	cd result && zip -ry ../imagemagick-layer.zip *

/tmp/layer.zip: result/bin/identify build
	# imagemagick has a ton of symlinks, and just using the source dir in the template
	# would cause all these to get packaged as individual files.
	# (https://github.com/aws/aws-cli/issues/2900)
	#
	# This is why we zip outside, using -y to store them as symlinks

	cd result && zip -ry $@ *

/tmp/output.yaml: cleanup template.yaml /tmp/layer.zip
	aws cloudformation package --template template.yaml --s3-bucket $(DEPLOYMENT_BUCKET) --output-template-file $@

deploy: /tmp/output.yaml
	aws cloudformation deploy --template $< --stack-name $(STACK_NAME)
	aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query Stacks[].Outputs --output table

deploy-example: deploy
	cd example && \
		make deploy DEPLOYMENT_BUCKET=$(DEPLOYMENT_BUCKET) IMAGE_MAGICK_STACK_NAME=$(STACK_NAME)

cleanup:
	@echo cleaning up old files
	rm -rf /tmp/output.yaml /tmp/layer.zip