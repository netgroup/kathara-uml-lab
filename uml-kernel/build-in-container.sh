#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# The part of build.sh that runs in the builder container: get the
# sources, configure, check the fragments, build, strip, write BUILD-INFO.
#
# build.sh mounts the output directory on /out, the fragments on
# /frag/<n>-<name> in their order, the per-version patches on /patches (if
# there are any) and, with --src, the kernel tree on /src. It passes FETCH
# (the version with --fetch), NO_PATCHES and JOBS in the environment.
set -o pipefail

OUT=/out
BUILD=$OUT/build
SRC=/src
frags=()
patches=()

die()
{
	echo "build.sh (container): $*" >&2
	exit 1
}

# Downloads linux-$FETCH.tar.xz from kernel.org into /out, unless it is
# there already, and unpacks it. Other versions of the tarball go.
fetch_source()
{
	local major=${FETCH%%.*} tarball=linux-$FETCH.tar.xz

	find "$OUT" -maxdepth 1 -name 'linux-*.tar.xz' ! -name "$tarball" -delete
	if [ ! -f "$OUT/$tarball" ]; then
		curl -sfL -o "$OUT/$tarball" "https://cdn.kernel.org/pub/linux/kernel/v$major.x/$tarball" ||
			die "download of $tarball failed"
	fi
	rm -rf "$OUT/src"
	mkdir -p "$OUT/src"
	tar -C "$OUT/src" -xf "$OUT/$tarball" || die "untar failed"
	SRC=$OUT/src/linux-$FETCH
}

# Applies the patches listed in patches/<major>.<minor>/series, in order.
apply_patches()
{
	local dir p

	dir=/patches/$(echo "$FETCH" | cut -d. -f1-2)
	if [ ! -f "$dir/series" ]; then
		return
	fi
	while read -r p; do
		case "$p" in
		'' | '#'*)
			continue
			;;
		esac
		git -C "$SRC" apply "$dir/$p" || die "patch $p does not apply"
		patches+=("$p")
	done < "$dir/series"
}

# defconfig, then the fragments merged in their order. A fresh build
# directory: objects of another tree or version could look newer than the
# sources and not be rebuilt.
configure()
{
	rm -rf "$BUILD"
	mkdir -p "$BUILD"
	make -C "$SRC" O="$BUILD" ARCH=um defconfig >/dev/null || die "defconfig failed"
	"$SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "$BUILD/.config" "${frags[@]}" >/dev/null ||
		die "merge_config failed"
	make -C "$SRC" O="$BUILD" ARCH=um olddefconfig >/dev/null || die "olddefconfig failed"
}

# Whether option k, set to v in a fragment, has that value in the config,
# whose line for it is got. An option set to n may also be absent.
option_sticks()
{
	local k=$1 v=$2 got=$3

	if [ "$v" = n ]; then
		[ "$got" = "# $k is not set" ] || [ -z "$got" ]
	else
		[ "$got" = "$k=$v" ]
	fi
}

# Every option of every fragment must have its value in the config.
check_fragments()
{
	local f k v got bad=0

	for f in "${frags[@]}"; do
		while IFS='=' read -r k v; do
			if [[ $k != CONFIG_* ]]; then
				continue
			fi
			got=$(grep -E "^$k=|^# $k is not set" "$BUILD/.config")
			if ! option_sticks "$k" "$v" "$got"; then
				echo "CONFIG MISMATCH ($f): want $k=$v, got ${got:-nothing}"
				bad=1
			fi
		done < "$f"
	done
	if [ "$bad" != 0 ]; then
		die "config mismatch"
	fi
}

compile()
{
	if ! make -C "$SRC" O="$BUILD" ARCH=um -j"$JOBS" linux > "$OUT/make.log" 2>&1; then
		tail -20 "$OUT/make.log"
		die "build failed"
	fi
	strip -o "$OUT/linux" "$BUILD/linux" || die "strip failed"
	cp "$BUILD/.config" "$OUT/linux.config" || die "copy of the config failed"
}

# The name of the distribution of the builder, from /etc/os-release.
os_name()
{
	# shellcheck source=/dev/null # /etc/os-release of the builder image
	. /etc/os-release
	echo "$PRETTY_NAME"
}

write_build_info()
{
	local glibc

	glibc=$(objdump -T "$OUT/linux" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
	{
		echo "release: $(make -s -C "$SRC" O="$BUILD" ARCH=um kernelrelease)"
		echo "source: ${FETCH:+kernel.org linux-$FETCH}$(git -C "$SRC" describe --always --dirty 2>/dev/null)"
		echo "fragments: ${frags[*]##*/} "
		if [ ${#patches[@]} -gt 0 ]; then
			echo "patches: ${patches[*]}"
		else
			echo "patches: none"
		fi
		echo "glibc needed: $glibc"
		echo "built in: $(os_name), $(gcc --version | head -1)"
		(cd "$OUT" && sha256sum linux)
	} > "$OUT/BUILD-INFO"
}

# The result is linux, linux.config and BUILD-INFO: the objects go, and
# the sources unpacked from the tarball.
clean_up()
{
	rm -rf "$BUILD"
	if [ -n "$FETCH" ]; then
		rm -rf "$OUT/src"
	fi
}

if [ -n "$FETCH" ]; then
	fetch_source
	if [ -z "$NO_PATCHES" ]; then
		apply_patches
	fi
fi
mapfile -t frags < <(printf '%s\n' /frag/* | sort -n -t/ -k3)
configure
check_fragments
compile
write_build_info
cat "$OUT/BUILD-INFO"
clean_up
