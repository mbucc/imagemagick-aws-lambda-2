# Multi-arch tag: podman's --platform (set by the Makefile to the host arch)
# selects the matching arm64 or amd64 image from this manifest list.
FROM public.ecr.aws/lambda/provided:al2023

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
    zip \
    zlib-devel \
    && dnf clean all

WORKDIR /var/task
