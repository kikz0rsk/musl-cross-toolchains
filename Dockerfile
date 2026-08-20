# Prepare build environment for musl-cross-make

FROM alpine:3.24

RUN apk add --no-cache bash \
        coreutils \
        build-base \
        xz \
        jq \
        ca-certificates \
        curl \
        git \
        sed \
        bzip2 \
        gzip \
        tar \
        gawk \
        autoconf \
        automake \
        qemu-armeb \
        qemu-aarch64 \
        qemu-x86_64

COPY --link build.sh /work/build.sh
RUN ln -s /bin/mkdir /usr/bin/mkdir

WORKDIR /work
ENTRYPOINT []
CMD ["./build.sh", "build"]
