# Alpine musl cross toolchains

Builds GCC self-contained, statically linked cross-compiling toolchains targeting Alpine [musl libc](https://musl.libc.org/) for three major architectures using
[richfelker/musl-cross-make](https://github.com/richfelker/musl-cross-make). The pre-built toolchains are published as GitHub release assets.

Even though the toolchains are already pre-built, you can easily use these scripts to build them yourself. All logic is in [`build.sh`](build.sh) and the `Dockerfile` provides a unified build environment, which the CI workflow uses.

## Targets

Host architecture for toolchains is `x86_64 Linux`. The toolchains produced are:

| Target triple | Architecture |
| --- | --- |
| `x86_64-linux-musl` | 64-bit x86 |
| `armv7l-linux-musleabihf` | 32-bit ARMv7-A, hard float (VFPv3-D16, Thumb-2) |
| `aarch64-linux-musl` | 64-bit ARMv8-A (AArch64) |

Each toolchain is statically linked & ships Linux kernel headers in its sysroot.

## Component versions

Versions are configurable. On every run `build.sh` scans the musl-cross-make checkout and picks the newest components it supports. Check the `patches/` and `hashes/` directories of [musl-cross-make](https://github.com/richfelker/musl-cross-make) for supported versions.

Run `./build.sh versions` to print what the current settings resolve to. New
upstream releases are picked up automatically as musl-cross-make adds support
for them.

Pin anything you like from the environment:

```sh
GCC_VER=14.3.0 ./build.sh build          # older gcc
ISL_VER= ./build.sh build                # empty value disables an optional component
MCM_REF=<commit> ./build.sh build        # pin musl-cross-make itself
```

## Quick start

### Docker
This is the easiest way. Requires Docker installed.

Run the pre-configured docker compose

```sh
docker compose run --rm --build build build
```

or, run the container manually

```sh
docker build -t musl-cross-toolchains .
docker run --rm -v ./:/work musl-cross-toolchains build
```

The image's entrypoint is pre-configured to `build.sh`.

### Linux host

```sh
./build.sh build                         # all three targets
./build.sh build aarch64-linux-musl      # just one
```

Required packages for build are listed in [`Dockerfile`](Dockerfile). Installing QEMU runtime binaries is optional, but recommended for testing the produced static binaries.

## Installing a built toolchain

```sh
wget https://github.com/kikz0rsk/musl-cross-toolchains/releases/latest/download/aarch64-linux-musl-cross-gcc15.1.0-musl1.2.6.tar.gz
wget https://github.com/kikz0rsk/musl-cross-toolchains/releases/latest/download/aarch64-linux-musl-cross-gcc15.1.0-musl1.2.6.tar.gz.sha256
sha256sum -c aarch64-linux-musl-cross-gcc15.1.0-musl1.2.6.tar.gz.sha256
tar -C /opt -xf aarch64-linux-musl-cross-gcc15.1.0-musl1.2.6.tar.gz
export PATH="/opt/aarch64-linux-musl-cross/bin:$PATH"

aarch64-linux-musl-gcc -O2 -static hello.c -o hello
```

The tarballs are relocatable - the sysroot is found relative to the compiler, so
`/opt` above is only an example.

## Commands

| Command | Purpose |
| --- | --- |
| `build [target...]` | build, verify and package (default: all targets) |
| `verify [target...]` | re-run smoke tests against an existing build |
| `package [target...]` | re-create `dist/` tarballs from an existing build |
| `manifest` | write `SHA256SUMS` and `manifest.json` |
| `versions` | show the resolved component versions |
| `clean` | drop build trees, keep the downloaded source tarballs |
| `distclean` | drop `build/` and `dist/` |

## Verification

Every target is smoke-tested straight after it is built, before packaging:

* C and C++ compile and link, dynamically, `-static` and `-static-pie`
* the emitted ELF reports the expected machine type
* hard-float ABI check for ARMv7 binaries
* with appropriate qemu runtime present, the static binaries are executed and their output is checked

A failure at any of these steps aborts the build for that target.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `JOBS` | `nproc` | parallel make jobs |
| `SLIM` | `1` | build with `-g0` and strip binaries |
| `MCM_REPO` / `MCM_REF` | upstream / `master` | musl-cross-make source |
| `BUILD_DIR` / `DIST_DIR` | `build/` / `dist/` | output locations |
| `GCC_VER`, `BINUTILS_VER`, `MUSL_VER`, `GMP_VER`, `MPC_VER`, `MPFR_VER`, `ISL_VER`, `LINUX_VER` | auto | pin a component; empty disables an optional one |

## Layout

```
build/
  musl-cross-make/           upstream checkout, config.mak written per target
  sources/                   downloaded tarball cache
  out/<target>-cross/        installed toolchain prefix
  logs/<target>.log          full build log
dist/
  *.tar.gz, *.sha256         release assets
  records/<target>.tsv       per-target metadata
  SHA256SUMS, manifest.json  other metadata
```
