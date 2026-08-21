#!/usr/bin/env bash
#
# build.sh - build and package musl cross toolchains.
#
#   host    : x86_64 Linux (from Windows/macOS use docker builder)
#   targets : x86_64-linux-musl, armv7l-linux-musleabihf, aarch64-linux-musl
# 
# Wrapper around richfelker/musl-cross-make (https://github.com/richfelker/musl-cross-make).
# Component versions can be set via environment variables. If unset,
# the latest supported version is used.
#
# Everything needed for a release is put into dist/.
#

set -euo pipefail

unset CDPATH

ROOT=$(dirname "$(readlink -f "$0")")

: "${MCM_REPO:=https://github.com/richfelker/musl-cross-make.git}"
: "${MCM_REF:=master}"
: "${JOBS:=$(nproc 2>/dev/null || echo 4)}"
: "${SLIM:=1}" # 1 = drop debug info and strip binaries

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
MCM_DIR="$BUILD_DIR/musl-cross-make"
SRC_DIR="$BUILD_DIR/sources"
OUT_DIR="$BUILD_DIR/out"
LOG_DIR="$BUILD_DIR/logs"

RECORDS_DIR="$DIST_DIR/records"

DEFAULT_TARGETS="x86_64-linux-musl armv7l-linux-musleabihf aarch64-linux-musl"

MCM_COMMIT="unknown"

# ------------------------------------------------------------------ output --

if [ -t 1 ]; then
	F_BOLD=$'\e[1m'; F_GREEN=$'\e[32m'; F_YELLOW=$'\e[33m'; F_RED=$'\e[31m'; C_0=$'\e[0m'
else
	F_BOLD=; F_GREEN=; F_YELLOW=; F_RED=; C_0=
fi

log()  { printf '%s==>%s %s\n' "$F_GREEN$F_BOLD" "$C_0" "$*"; }
step() { printf '%s ->%s %s\n' "$F_BOLD" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$F_YELLOW$F_BOLD" "$C_0" "$*" >&2; }
error() { printf '%serror:%s %s\n' "$F_RED$F_BOLD" "$C_0" "$*" >&2; }
die()  { error "$@"; exit 1; }

format_size() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

target_gcc_config() {
	case $1 in
		x86_64-linux-musl)       printf '%s' '--with-arch=x86-64 --with-tune=generic' ;;
		armv7l-linux-musleabihf) printf '%s' '--with-arch=armv7-a --with-fpu=vfpv3-d16 --with-mode=thumb' ;;
		aarch64-linux-musl)      printf '%s' '--with-arch=armv8-a' ;;
		*)                       printf '%s' '' ;;
	esac
}

# Expected "Machine:" substring in readelf -h output, used by the test
target_elf_machine() {
	case $1 in
		x86_64-linux-musl)       printf '%s' 'X86-64' ;;
		armv7l-linux-musleabihf) printf '%s' 'ARM' ;;
		aarch64-linux-musl)      printf '%s' 'AArch64' ;;
		*)                       printf '%s' '' ;;
	esac
}

# qemu runtime binaries to use for the tests
target_qemu() {
	case $1 in
		x86_64-linux-musl)       printf '%s' 'qemu-x86_64' ;;
		armv7l-linux-musleabihf) printf '%s' 'qemu-arm' ;;
		aarch64-linux-musl)      printf '%s' 'qemu-aarch64' ;;
		*)                       printf '%s' '' ;;
	esac
}

target_desc() {
	case $1 in
		x86_64-linux-musl)       printf '%s' '64-bit x86 (x86-64 baseline)' ;;
		armv7l-linux-musleabihf) printf '%s' '32-bit ARMv7-A hard float (VFPv3-D16, Thumb-2)' ;;
		aarch64-linux-musl)      printf '%s' '64-bit ARMv8-A (AArch64)' ;;
		*)                       printf '%s' "$1" ;;
	esac
}

is_known_target() {
	case " $DEFAULT_TARGETS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

require_linux_host() {
	case $(uname -s) in
		Linux) ;;
		*) die "builds must run on Linux; please use inside the docker builder" ;;
	esac
}

sync_mcm() {
	log "syncing musl-cross-make"
	mkdir -p "$BUILD_DIR" "$SRC_DIR"
	if [ -d "$MCM_DIR/.git" ]; then
		step "updating musl-cross-make ($MCM_REF)"
		git -C "$MCM_DIR" fetch --quiet --tags origin
	else
		step "cloning musl-cross-make ($MCM_REF)"
		git clone --quiet "$MCM_REPO" "$MCM_DIR"
		git -C "$MCM_DIR" fetch --quiet --tags origin
	fi
	git -C "$MCM_DIR" checkout --quiet --detach "origin/$MCM_REF" 2>/dev/null \
		|| git -C "$MCM_DIR" checkout --quiet --detach "$MCM_REF"
	MCM_COMMIT=$(git -C "$MCM_DIR" rev-parse --short HEAD)

	# Setup tarballs cache
	if [ ! -L "$MCM_DIR/sources" ]; then
		step "linking sources"
		rm -rf "$MCM_DIR/sources"
		ln -s ../sources "$MCM_DIR/sources"
	fi
	step "musl-cross-make at $MCM_COMMIT"
}

# newest_supported <pkg> [patched]
#
# Scans hashes/ for `pkg`.
# With "patched", only versions for which the patch is present in patches/ is returned.
newest_supported() {
	local pkg=$1 require=${2:-} f base ver best=
	for f in "$MCM_DIR"/hashes/"$pkg"-*.sha1; do
		[ -e "$f" ] || continue

		base=${f##*/}
		base=${base%.sha1}
		ver=${base#"$pkg"-}
		ver=${ver%%.tar.*}

		# skip git snapshots
		case $ver in ''|*[!0-9.]*) continue ;; esac

		if [ "$require" = "patched" ] && [ ! -d "$MCM_DIR/patches/$pkg-$ver" ]; then
			continue
		fi
		if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$ver" | sort -V | tail -n1)" = "$ver" ]; then
			best=$ver
		fi
	done
	printf '%s' "$best"
}

resolve_versions() {
	GCC_VER=${GCC_VER:-$(newest_supported gcc patched)}
	BINUTILS_VER=${BINUTILS_VER:-$(newest_supported binutils patched)}
	MUSL_VER=${MUSL_VER:-$(newest_supported musl patched)}

	GMP_VER=${GMP_VER-$(newest_supported gmp)}
	MPC_VER=${MPC_VER-$(newest_supported mpc)}
	MPFR_VER=${MPFR_VER-$(newest_supported mpfr)}
	ISL_VER=${ISL_VER-$(newest_supported isl)}
	LINUX_VER=${LINUX_VER-$(newest_supported linux)}

	[ -n "$GCC_VER" ]      || die "no supported gcc version found under $MCM_DIR"
	[ -n "$BINUTILS_VER" ] || die "no supported binutils version found under $MCM_DIR"
	[ -n "$MUSL_VER" ]     || die "no supported musl version found under $MCM_DIR"

	TOOLCHAIN_ID="gcc$GCC_VER-musl$MUSL_VER"
}

print_versions() {
	printf '  %-10s %s\n' \
		binutils "$BINUTILS_VER" \
		gcc      "$GCC_VER" \
		musl     "$MUSL_VER" \
		gmp      "${GMP_VER:-(system)}" \
		mpc      "${MPC_VER:-(system)}" \
		mpfr     "${MPFR_VER:-(system)}" \
		isl      "${ISL_VER:-(disabled)}" \
		linux    "${LINUX_VER:-(no kernel headers)}"
}

write_config_mak() {
	local target=$1 
	local output=$2
	local cflags='-fuse-ld=mold'
	local cxxflags='-fuse-ld=mold'
	local ldflags=''
	
	if [ "$SLIM" = 1 ]; then
		cflags="$cflags -g0 -O2"
		cxxflags="$cxxflags -g0 -O2"
		ldflags="-s"
	fi
	local common="COMMON_CONFIG += CFLAGS=\"$cflags\" CXXFLAGS=\"$cxxflags\" LDFLAGS=\"$ldflags\""

	cat > "$MCM_DIR/config.mak" <<EOF
# Generated by build.sh
TARGET = $target
OUTPUT = $output

BINUTILS_VER = $BINUTILS_VER
GCC_VER = $GCC_VER
MUSL_VER = $MUSL_VER
GMP_VER = $GMP_VER
MPC_VER = $MPC_VER
MPFR_VER = $MPFR_VER
ISL_VER = $ISL_VER
LINUX_VER = $LINUX_VER

# some options to handle errors better
DL_CMD = curl -L -f --retry 6 --retry-delay 2 -o

COMMON_CONFIG += CC="gcc -static --static" CXX="g++ -static --static"
COMMON_CONFIG += --disable-nls
COMMON_CONFIG += --with-debug-prefix-map=\$(CURDIR)=
$common

# ftpmirror most of the time would not work...
GNU_SITE = https://ftp.gnu.org/gnu/

GCC_CONFIG += --enable-languages=c,c++
GCC_CONFIG += --enable-lto
GCC_CONFIG += $(target_gcc_config "$target")
EOF
}

build_target() {
	local target=$1
	local output=$OUT_DIR/$target-cross
	local logfile=$LOG_DIR/$target.log

	is_known_target "$target" || warn "$target is not one of the default targets"
	mkdir -p "$OUT_DIR" "$LOG_DIR"
	rm -rf "$output"

	log "building $F_BOLD$target$C_0 - $(target_desc "$target")"
	write_config_mak "$target" "$output"
	step "make -j$JOBS all && make install (log: ${logfile#"$ROOT"/})"

	if ! ( cd "$MCM_DIR" && make -j"$JOBS" all && make install ) >"$logfile" 2>&1; then
		printf '\n%s--- last 40 lines of %s ---%s\n' "$F_RED" "$logfile" "$C_0" >&2
		tail -n 40 "$logfile" >&2
		die "build failed for $target"
	fi

	[ -x "$output/bin/$target-gcc" ] || die "$target-gcc missing from $output/bin"
	step "installed $(du -sh "$output" | cut -f1) into ${output#"$ROOT"/}"
}

verify_target() {
	local target=$1
	local output=$OUT_DIR/$target-cross
	local cc=$output/bin/$target-gcc
	local cxx=$output/bin/$target-g++
	local readelf=$output/bin/$target-readelf
	local work machine qemu pie_note=

	[ -x "$cc" ] || die "no toolchain at $output - build it first"
	work=$(mktemp -d)
	
	# shellcheck disable=SC2064
	trap "rm -rf '$work'" RETURN

	log "verifying $F_BOLD$target$C_0"
	step "$("$cc" --version | head -n1) / $("$output/bin/$target-ld" --version | head -n1)"

	cat > "$work/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) { printf("c ok\n"); return EXIT_SUCCESS; }
EOF
	
	cat > "$work/hello.cc" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
int main() {
    std::vector<std::string> v{"c++", "ok"};
    for (auto const &s : v) std::cout << s;
    std::cout << std::endl;
    return 0;
}
EOF

	"$cc"  -O2 "$work/hello.c"  -o "$work/c-dyn"              || die "$target: C dynamic compilation failed"
	"$cc"  -O2 "$work/hello.c"  -o "$work/c-static" -static   || die "$target: C static compilation failed"
	"$cxx" -O2 "$work/hello.cc" -o "$work/cxx-dyn"            || die "$target: C++ dynamic compilation failed"
	"$cxx" -O2 "$work/hello.cc" -o "$work/cxx-static" -static || die "$target: C++ static compilation failed"
	if "$cc" -O2 "$work/hello.c" -o "$work/c-pie" -static-pie 2>/dev/null; then
		pie_note=" + static-pie"
	else
		warn "$target: -static-pie not available"
	fi
	step "compiled C and C++, dynamic + static$pie_note"

	machine=$(target_elf_machine "$target")
	if [ -n "$machine" ]; then
		"$readelf" -h "$work/c-static" | grep -q "Machine:.*$machine" \
			|| die "$target: unexpected ELF machine, expected $machine"
		step "ELF machine is $machine"
	fi
	if [ "$target" = armv7l-linux-musleabihf ]; then
		"$readelf" -A "$work/c-static" | grep -qi 'Tag_ABI_VFP_args' \
			|| die "$target: not a hard-float binary (no Tag_ABI_VFP_args)"
		step "hard-float ABI confirmed (Tag_ABI_VFP_args present)"
	fi

	qemu=$(target_qemu "$target")
	if [ -z "$qemu" ]; then
		step "no qemu runtime for $target - skipping execution test"
	elif ! command -v "$qemu" >/dev/null 2>&1; then
		warn "$qemu not found - skipping execution test for $target"
	else
		[ "$("$qemu" "$work/c-static")"   = "c ok"  ] || die "$target: static C binary unexpected output"
		[ "$("$qemu" "$work/cxx-static")" = "c++ok" ] || die "$target: static C++ binary unexpected output"
		step "binaries ran correctly under $qemu"
	fi
}

package_target() {
	local target=$1
	local output=$OUT_DIR/$target-cross
	local name=$target-cross-$TOOLCHAIN_ID.tar.gz
	local tarball=$DIST_DIR/$name
	local sum size

	[ -d "$output" ] || die "nothing to package at $output"
	mkdir -p "$DIST_DIR" "$RECORDS_DIR"

	log "packaging $F_BOLD$target$C_0"
	step "compressing into dist/$name"
	tar -C "$OUT_DIR" --owner=0 --group=0 --numeric-owner \
		-czf "$tarball" "$target-cross"

	sum=$(sha256sum "$tarball" | cut -d' ' -f1)
	size=$(wc -c < "$tarball")
	printf '%s  %s\n' "$sum" "$name" > "$tarball.sha256"
	step "$(format_size "$size"), sha256 ${sum:0:16}..."

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$target" "$name" "$size" "$sum" \
		"$GCC_VER" "$BINUTILS_VER" "$MUSL_VER" "$MCM_COMMIT" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RECORDS_DIR/$target.tsv"
}

# Emits every record on stdout, sorted by target. Fails if there are none.
records() {
	local f any=1
	for f in "$RECORDS_DIR"/*.tsv; do
		[ -e "$f" ] || continue
		any=0
		cat "$f"
	done
	return $any
}

# Generates SHA256SUMS and manifest.json from the records.
gen_manifest() {
	records >/dev/null || die "no records under ${RECORDS_DIR#"$ROOT"/} - run './build.sh build' first"

	local target name size sum gccv binv muslv mcm built

	records | sort | awk -F'\t' '{printf "%s  %s\n", $4, $2}' > "$DIST_DIR/SHA256SUMS"

	json=$(echo "{}" | jq -c ". + {generated: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", toolchains: []}")
	while IFS=$'\t' read -r target name size sum gccv binv muslv mcm built; do
		[ -n "$target" ] || continue
		entry=$(echo "{}" | jq -c ". + {target: \"$target\", file: \"$name\", size: $size, sha256: \"$sum\", gcc: \"$gccv\", binutils: \"$binv\", musl: \"$muslv\", musl_cross_make: \"$mcm\", built: \"$built\"}")
		json=$(echo "$json" | jq -c ".toolchains += [$entry]")
	done < <(records | sort)
	echo "$json" | jq -c . > "$DIST_DIR/manifest.json"

	step "wrote SHA256SUMS, manifest.json into ${DIST_DIR#"$ROOT"/}"
}

usage() {
	local t
	cat <<EOF
build.sh - build and package musl cross toolchains

usage: ./build.sh <command> [args]

commands:
  build [target...]     build, verify and package toolchains (default: all)
  verify [target...]    re-run the tests against an existing build
  package [target...]   re-create dist/ tarballs from an existing build
  manifest              write SHA256SUMS and manifest.json
  versions              show the component versions that will be used
  clean                 remove build trees, keep the source tarball cache
  distclean             remove build/ and dist/ entirely

targets:
EOF
	for t in $DEFAULT_TARGETS; do
		printf '  %-24s %s\n' "$t" "$(target_desc "$t")"
	done
	cat <<EOF

environment:
  JOBS=$JOBS             parallel make jobs
  SLIM=$SLIM             strip binaries and drop debug info
  MCM_REF=$MCM_REF       musl-cross-make ref to build from
  GCC_VER, BINUTILS_VER, MUSL_VER, GMP_VER, MPC_VER, MPFR_VER, ISL_VER,
  LINUX_VER             pin a component; empty disables the optional ones

Release assets are produced in dist/.
EOF
}

main() {
	local cmd=${1:-help} t targets
	[ $# -eq 0 ] || shift

	case $cmd in
		build)
			require_linux_host
			sync_mcm
			resolve_versions
			log "component versions"
			print_versions
			targets="${*:-$DEFAULT_TARGETS}"
			for t in $targets; do
				build_target "$t"
				verify_target "$t"
				package_target "$t"
			done
			gen_manifest
			log "done - $(echo "$targets" | wc -w) toolchain(s) in ${DIST_DIR#"$ROOT"/}"
			;;
		verify)
			require_linux_host
			sync_mcm
			resolve_versions
			for t in "${@:-$DEFAULT_TARGETS}"; do verify_target "$t"; done
			;;
		package)
			sync_mcm
			resolve_versions
			for t in "${@:-$DEFAULT_TARGETS}"; do package_target "$t"; done
			gen_manifest
			;;
		manifest)
			gen_manifest
			;;
		versions)
			sync_mcm
			resolve_versions
			log "resolved component versions"
			print_versions
			;;
		clean)
			log "removing build trees, keeping ${SRC_DIR#"$ROOT"/}"
			step rm -rf "$OUT_DIR" "$LOG_DIR" "$MCM_DIR"
			rm -rf "$OUT_DIR" "$LOG_DIR" "$MCM_DIR"
			;;
		distclean)
			log "removing ${BUILD_DIR#"$ROOT"/} and ${DIST_DIR#"$ROOT"/}"
			step rm -rf "$BUILD_DIR" "$DIST_DIR"
			rm -rf "$BUILD_DIR" "$DIST_DIR"
			;;
		help|-h|--help)
			usage
			;;
		*)
			die "unknown command: $cmd. use 'build.sh help' for usage."
			;;
	esac
}

main "$@"
