#!/bin/bash
# Build a UML kernel for Kathara devices, in a podman container (nothing is
# installed on the host). The result is a stripped `linux` binary that a
# lab uses with dev[kernel]="<path>".
#
#   build.sh --src <kernel tree> [--fragment <file>]... [--out <dir>]
#   build.sh --fetch <version>   [--fragment <file>]... [--out <dir>]
#
# --src      an existing kernel tree, mounted read-only (it is not touched:
#            the build goes to <out>/build with O=).
# --fetch    download linux-<version>.tar.xz from kernel.org into <out>
#            and build that (for example --fetch 6.18).
# --fragment Kconfig fragments merged on top of `make ARCH=um defconfig`,
#            in the given order. base.fragment (next to this script) is
#            always the first one. Every option of every fragment must stick,
#            or the build fails.
# --out      output directory, default uml/out/kernel. Holds linux,
#            linux.config, BUILD-INFO, make.log and, with --fetch, the
#            tarball; the objects and the unpacked sources are removed.
#
# UML_LAB_WORK sets where podman keeps its storage (default uml/out).
set -o pipefail

die() { echo "build.sh: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
UML_DIR=$(dirname "$HERE")
WORK=${UML_LAB_WORK:-$UML_DIR/out}
OUT=$WORK/kernel
SRC= FETCH=
FRAGS=("$HERE/base.fragment")

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC=$(cd "$2" 2>/dev/null && pwd) || die "no directory $2"; shift 2 ;;
	--fetch) FETCH=$2; shift 2 ;;
	--fragment) [ -f "$2" ] || die "no fragment $2"; FRAGS+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done
[ -n "$SRC" ] || [ -n "$FETCH" ] || die "give --src <tree> or --fetch <version>"
[ -n "$SRC" ] && [ -n "$FETCH" ] && die "--src and --fetch exclude each other"

mkdir -p "$OUT" "$WORK/podman" "$WORK/tmp" || die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
export TMPDIR=$WORK/tmp
PM=(podman --root "$WORK/podman/storage" --runroot "$WORK/podman/run")
IMAGE=localhost/kathara-uml-kernel-builder

"${PM[@]}" build -q -t $IMAGE "$HERE" > "$OUT/image.log" 2>&1 ||
	{ cat "$OUT/image.log"; die "builder image failed"; }

# The fragments go into the container as /frag/<n>-<name>, in order.
mounts=(-v "$OUT:/out:Z")
i=0
for f in "${FRAGS[@]}"; do
	mounts+=(-v "$f:/frag/$i-$(basename "$f"):ro,Z")
	i=$((i + 1))
done
if [ -n "$SRC" ]; then
	mounts+=(-v "$SRC:/src:ro,Z")
fi

"${PM[@]}" run --rm -e FETCH="$FETCH" -e JOBS="${JOBS:-$(nproc)}" "${mounts[@]}" $IMAGE bash -c '
set -o pipefail
die() { echo "build.sh (container): $*" >&2; exit 1; }
S=/src
if [ -n "$FETCH" ]; then
	major=${FETCH%%.*}
	tarball=linux-$FETCH.tar.xz
	# Keep only the tarball of this version.
	find /out -maxdepth 1 -name "linux-*.tar.xz" ! -name $tarball -delete
	[ -f /out/$tarball ] ||
		curl -sfL -o /out/$tarball https://cdn.kernel.org/pub/linux/kernel/v$major.x/$tarball ||
		die "download of $tarball failed"
	rm -rf /out/src && mkdir -p /out/src && tar -C /out/src -xf /out/$tarball || die "untar failed"
	S=/out/src/linux-$FETCH
fi
# A fresh build directory: objects of another tree or version could look
# newer than the sources and not be rebuilt.
O=/out/build
rm -rf $O && mkdir -p $O
make -C $S O=$O ARCH=um defconfig >/dev/null || die "defconfig failed"
$S/scripts/kconfig/merge_config.sh -m -O $O $O/.config $(ls /frag/* | sort -n -t/ -k3) >/dev/null ||
	die "merge_config failed"
make -C $S O=$O ARCH=um olddefconfig >/dev/null || die "olddefconfig failed"
bad=0
for f in $(ls /frag/* | sort -n -t/ -k3); do
	while IFS== read -r k v; do
		case "$k" in CONFIG_*) ;; *) continue ;; esac
		got=$(grep -E "^$k=|^# $k is not set" $O/.config)
		if [ "$v" = n ]; then
			case "$got" in "# $k is not set"|"") continue ;; esac
		elif [ "$got" = "$k=$v" ]; then
			continue
		fi
		echo "CONFIG MISMATCH ($f): want $k=$v, got ${got:-nothing}"
		bad=1
	done < $f
done
[ $bad = 0 ] || die "config mismatch"
make -C $S O=$O ARCH=um -j$JOBS linux > /out/make.log 2>&1 || { tail -20 /out/make.log; die "build failed"; }
strip -o /out/linux $O/linux && cp $O/.config /out/linux.config || die "strip failed"
glibc=$(objdump -T /out/linux | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)
{
	echo "release: $(make -s -C $S O=$O ARCH=um kernelrelease)"
	echo "source: ${FETCH:+kernel.org linux-$FETCH}$(git -C $S describe --always --dirty 2>/dev/null)"
	echo "fragments: $(cd /frag && ls | sort -n | tr "\n" " ")"
	echo "glibc needed: $glibc"
	echo "built in: $(. /etc/os-release; echo $PRETTY_NAME), $(gcc --version | head -1)"
	sha256sum /out/linux | sed "s|/out/||"
} > /out/BUILD-INFO
cat /out/BUILD-INFO
# The result is linux, linux.config and BUILD-INFO: drop the objects, and
# the sources unpacked from the tarball.
rm -rf $O
if [ -n "$FETCH" ]; then rm -rf /out/src; fi
' || die "build failed, see $OUT/make.log"
echo "kernel: $OUT/linux"
