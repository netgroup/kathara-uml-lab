#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Test of a UML device on the kernel of its image. An image FROM
# kathara/base carries the UML kernel given, with the label
# org.kathara.uml.kernel on its path: r of the router lab, on that image
# and without the kernel option, must run on it. With the kernel option
# too, r must run on the kernel of the option, and on kathara/base without
# it r must be a container. An image whose label is not an absolute path,
# names a missing file or a file that is not a UML kernel must stop lstart
# with the reason and leave no container of r behind.
#
# It uses copies of examples/router in temporary directories, so a lab
# already running is not touched, and removes the images it builds. Run
# it where Kathara is, for example in the test VM:
# `vm/vm.sh ssh bash /opt/kathara-uml/tests/check-image-kernel.sh`.
#
#   check-image-kernel.sh [UML kernel]   (default: uml-kernel/prebuilt/linux)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=$(realpath "${1:-$HERE/../uml-kernel/prebuilt/linux}")
IMAGE=kathara-uml/image-kernel-test
IN_IMAGE=/usr/lib/kathara-uml/linux
LABEL=org.kathara.uml.kernel
LABS=()
IMAGES=()

# Builds the image name FROM kathara/base with the label given, and with
# the kernel in IN_IMAGE if with_kernel is yes.
build_image()
{
	local name=$1 label=$2 with_kernel=$3 dir

	dir=$(mktemp -d)
	LABS+=("$dir")
	IMAGES+=("$name")
	echo "FROM kathara/base" > "$dir/Dockerfile"
	if [ "$with_kernel" = yes ]; then
		cp "$KERNEL" "$dir/linux"
		echo "COPY linux $IN_IMAGE" >> "$dir/Dockerfile"
	fi
	echo "LABEL $LABEL=$label" >> "$dir/Dockerfile"
	docker build -q -t "$name" "$dir" > /dev/null
}

# A copy of the router lab, with r on the image given and, if kernel is
# set, on that kernel, in NEW_LAB. It is not printed for a $(...): LABS,
# which clean_up reads, must grow in this shell.
new_lab()
{
	local image=$1 kernel=$2

	NEW_LAB=$(mktemp -d)
	LABS+=("$NEW_LAB")
	cp -r "$HERE/../examples/router/." "$NEW_LAB"
	rm -f "$NEW_LAB/kernel"
	sed -i "s|^r\[image\]=.*|r[image]=\"$image\"|" "$NEW_LAB/lab.conf"
	if [ -n "$kernel" ]; then
		sed -i "s|^r\[kernel\]=.*|r[kernel]=\"$kernel\"|" "$NEW_LAB/lab.conf"
	else
		sed -i '/^r\[kernel\]=/d' "$NEW_LAB/lab.conf"
	fi
}

# shellcheck disable=SC2317 # called from the EXIT trap
clean_up()
{
	local lab

	for lab in "${LABS[@]}"; do
		kathara lclean -d "$lab" >/dev/null 2>&1
		rm -rf "$lab"
	done
	if [ ${#IMAGES[@]} -gt 0 ]; then
		docker rmi -f "${IMAGES[@]}" >/dev/null 2>&1
	fi
}

# The container of r.
container_r()
{
	docker ps -q --filter label=name=r | head -1
}

# The value of the environment variable given in the container of r, or
# none.
container_env()
{
	local name=$1 value

	value=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_r)" |
		sed -n "s|^$name=||p")
	echo "${value:-none}"
}

# yes if the container of r has a mount on /kathara-uml-kernel, else no.
kernel_mounted()
{
	if docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$(container_r)" |
		grep -qx /kathara-uml-kernel; then
		echo yes
	else
		echo no
	fi
}

# lstart of NEW_LAB, which must succeed; its output, joined on one line,
# in LSTART_OUT.
lstart_ok()
{
	local what=$1

	LSTART_OUT=$(kathara lstart --noterminals -d "$NEW_LAB" 2>&1)
	check "$what: lstart" "$?" 0
	LSTART_OUT=$(tr -s ' \n' ' ' <<< "$LSTART_OUT")
}

# The ping of the router lab, from a to b through r.
ping_through_r()
{
	kathara exec -d "$NEW_LAB" a "ping -c 2 -W 2 10.0.2.1" 2>&1 | grep -o '[0-9]* received' | cut -d' ' -f1
}

# lstart of NEW_LAB, which must fail with MachineOptionError and the words
# given, an extended regular expression, and leave no container of r.
check_lstart_fails()
{
	local what=$1 words=$2 out

	out=$(kathara lstart --noterminals -d "$NEW_LAB" 2>&1)
	check "$what: lstart fails" "$?" 1
	out=$(tr -s ' \n' ' ' <<< "$out")
	check "$what: the error is MachineOptionError" "$(grep -c "(MachineOptionError)" <<< "$out")" 1
	check "$what: the error says \"$words\"" "$(grep -cE "$words" <<< "$out")" 1
	check "$what: no container of r is left" "$(docker ps -a -q --filter label=name=r | wc -l)" 0
	kathara lclean -d "$NEW_LAB" >/dev/null 2>&1
}

if [ ! -f "$KERNEL" ]; then
	echo "usage: $0 [UML kernel]" >&2
	exit 1
fi
if [ -n "$(docker ps -q --filter label=app=kathara)" ]; then
	echo "a Kathara lab is running: its devices would be counted by this test" >&2
	exit 1
fi
trap clean_up EXIT

build_image "$IMAGE" "$IN_IMAGE" yes
build_image "$IMAGE-missing" /usr/lib/kathara-uml/missing no
build_image "$IMAGE-relative" usr/lib/kathara-uml/linux yes
build_image "$IMAGE-not-uml" /bin/bash no

new_lab "$IMAGE"
lstart_ok "kernel of the image"
check "kernel of the image: lstart says so" \
	"$(grep -c "Device \`r\` runs on the UML kernel of image \`$IMAGE\`" <<< "$LSTART_OUT")" 1
check "kernel of the image: r is a UML device" "$(docker inspect -f '{{index .Config.Labels "uml"}}' "$(container_r)")" 1
check "kernel of the image: KATHARA_UML_KERNEL" "$(container_env KATHARA_UML_KERNEL)" "$IN_IMAGE"
check "kernel of the image: no kernel mounted" "$(kernel_mounted)" no
check "kernel of the image: r runs on its own kernel" \
	"$(other_kernel "$(kathara exec -d "$NEW_LAB" r "uname -r" 2>/dev/null | tr -d '\r')")" yes
check "kernel of the image: ping from a to b through r" "$(ping_through_r)" 2
kathara lclean -d "$NEW_LAB" >/dev/null 2>&1

new_lab "$IMAGE" "$KERNEL"
lstart_ok "kernel option on the image"
check "kernel option on the image: lstart does not name the kernel of the image" \
	"$(grep -c "runs on the UML kernel of image" <<< "$LSTART_OUT")" 0
check "kernel option on the image: the kernel is mounted" "$(kernel_mounted)" yes
check "kernel option on the image: no KATHARA_UML_KERNEL" "$(container_env KATHARA_UML_KERNEL)" none
check "kernel option on the image: r runs on its own kernel" \
	"$(other_kernel "$(kathara exec -d "$NEW_LAB" r "uname -r" 2>/dev/null | tr -d '\r')")" yes
kathara lclean -d "$NEW_LAB" >/dev/null 2>&1

new_lab kathara/base
lstart_ok "image without the label"
check "image without the label: r is a container" \
	"$(docker inspect -f '{{index .Config.Labels "uml"}}' "$(container_r)")" ""
check "image without the label: r runs on the host kernel" \
	"$(kathara exec -d "$NEW_LAB" r "uname -r" 2>/dev/null | tr -d '\r')" "$(uname -r)"
kathara lclean -d "$NEW_LAB" >/dev/null 2>&1

new_lab "$IMAGE-missing"
check_lstart_fails "label on a missing file" "the image has no such file"
new_lab "$IMAGE-relative"
check_lstart_fails "label not absolute" "must be an absolute path"
new_lab "$IMAGE-not-uml"
check_lstart_fails "label on a file that is not a UML kernel" "it is not a UML kernel"

finish IMAGE_KERNEL
