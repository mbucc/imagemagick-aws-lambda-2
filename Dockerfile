FROM public.ecr.aws/lambda/provided:al2023-arm64

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
