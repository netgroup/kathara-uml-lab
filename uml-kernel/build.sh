#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Build a UML kernel for Kathara devices, in a podman container (nothing is
# installed on the host). The result is a stripped `linux` binary that a
# lab uses with dev[kernel]="<path>".
#
#   build.sh --src <kernel tree> [--fragment <file>]... [--out <dir>]
#   build.sh --fetch <version>   [--fragment <file>]... [--out <dir>] [--no-patches]
#
# --src      an existing kernel tree, mounted read-only (it is not touched:
#            the build goes to <out>/build with O=).
# --fetch    download linux-<version>.tar.xz from kernel.org into <out>
#            and build that (for example --fetch 7.3.5), with the patches of
#            patches/<major>.<minor>/series (next to this script) applied in
#            order, if that directory exists.
# --no-patches  with --fetch, apply none of them. With --src no patch is
#            applied either: the tree is the caller's.
# --fragment Kconfig fragments merged on top of `make ARCH=um defconfig`,
#            in the given order. base.fragment (next to this script) is
#            always the first one. Every option of every fragment must stick,
#            or the build fails.
# --out      output directory, default out/kernel. Holds linux,
#            linux.config, BUILD-INFO, make.log and, with --fetch, the
#            tarball; the objects and the unpacked sources are removed.
#
# UML_LAB_WORK sets where podman keeps its storage (default out). The build
# itself is build-in-container.sh, run in the builder container.
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${UML_LAB_WORK:-$(dirname "$HERE")/out}
IMAGE=localhost/kathara-uml-kernel-builder
OUT=$WORK/kernel
SRC=
FETCH=
NO_PATCHES=
FRAGS=("$HERE/base.fragment")

die()
{
	echo "build.sh: $*" >&2
	exit 1
}

parse_args()
{
	while [ $# -gt 0 ]; do
		case "$1" in
		--src)
			SRC=$(cd "$2" 2>/dev/null && pwd) || die "no directory $2"
			shift 2
			;;
		--fetch)
			FETCH=$2
			shift 2
			;;
		--fragment)
			if [ ! -f "$2" ]; then
				die "no fragment $2"
			fi
			FRAGS+=("$(realpath "$2")")
			shift 2
			;;
		--out)
			OUT=$2
			shift 2
			;;
		--no-patches)
			NO_PATCHES=1
			shift
			;;
		*)
			die "unknown argument $1"
			;;
		esac
	done
	if [ -z "$SRC" ] && [ -z "$FETCH" ]; then
		die "give --src <tree> or --fetch <version>"
	fi
	if [ -n "$SRC" ] && [ -n "$FETCH" ]; then
		die "--src and --fetch exclude each other"
	fi
}

# The mounts of the builder container: the output directory, the build
# script, the patches if there are any, the fragments as /frag/<n>-<name>
# in their order, and the tree with --src.
container_mounts()
{
	local i

	mounts=(-v "$OUT:/out:Z" -v "$HERE/build-in-container.sh:/build-in-container.sh:ro,Z")
	if [ -d "$HERE/patches" ]; then
		mounts+=(-v "$HERE/patches:/patches:ro,Z")
	fi
	for i in "${!FRAGS[@]}"; do
		mounts+=(-v "${FRAGS[$i]}:/frag/$i-$(basename "${FRAGS[$i]}"):ro,Z")
	done
	if [ -n "$SRC" ]; then
		mounts+=(-v "$SRC:/src:ro,Z")
	fi
}

parse_args "$@"

mkdir -p "$OUT" "$WORK/podman" "$WORK/tmp" || die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
export TMPDIR=$WORK/tmp
PM=(podman --root "$WORK/podman/storage" --runroot "$WORK/podman/run")

if ! "${PM[@]}" build -q -t "$IMAGE" "$HERE" > "$OUT/image.log" 2>&1; then
	cat "$OUT/image.log"
	die "builder image failed"
fi

container_mounts
"${PM[@]}" run --rm -e FETCH="$FETCH" -e NO_PATCHES="$NO_PATCHES" -e JOBS="${JOBS:-$(nproc)}" \
	"${mounts[@]}" "$IMAGE" bash /build-in-container.sh || die "build failed, see $OUT/make.log"
echo "kernel: $OUT/linux"
