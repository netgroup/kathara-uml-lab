# UML devices: a device on its own Linux kernel

Kathara devices are containers, so they all share the kernel of the host.
With this branch a device can run on its own kernel instead: a
[User-Mode Linux](https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html)
(UML) kernel, which runs as a process inside the device's container. The
rest of the lab does not change: the other devices are plain containers,
and `lab.conf`, `.startup` files, `kathara exec`, `kathara connect` and the
shared folders work as for any device.

Use it to put different kernels in the same network: a patched kernel next
to a stock one, two kernel versions, a feature that only some nodes have.

## Usage

One line in `lab.conf`:

```
r[0]="A"
r[1]="B"
r[image]="kathara-uml/base-ssh"
r[kernel]="/path/to/linux"
```

`kernel` is a UML kernel binary. A relative path is relative to the
directory `kathara` runs in, as for `volume`. `image` must have an ssh
client (see [Image](#image)).

[examples/router](examples/router) is a complete lab: `a` and `b` are
containers, `r` is a router on a UML kernel, and its `r.startup` is a
normal startup file that configures `eth0` and `eth1`.

## How it works

For a device with `kernel`, Kathara
([DockerMachine.py](../src/Kathara/manager/docker/DockerMachine.py)):

1. creates the container with the kernel mounted read-only in
   `/kathara-uml-kernel`, the entrypoint `/kathara-uml/start`, the shell
   `/kathara-uml/ushell`, the label `uml` and `KATHARA_UML_IFACES` (the
   number of interfaces), and copies the helpers of
   [UmlHelpers.py](../src/Kathara/manager/docker/UmlHelpers.py) into
   `/kathara-uml`;
2. after attaching every interface, touches `/run/kathara-uml.go`;
3. runs `kathara exec` through the device shell.

In the container, `start` waits for that file, adds a management veth
(`um0`, 169.254.77.1/30, for the container; `um1` for the UML) and boots
the kernel:

- the root filesystem of the UML is the container's own `/`, through
  hostfs (`rootfstype=hostfs rootflags=/`): the image, the device files,
  `/shared`, `/hosthome` and the volumes are all there;
- every `ethN` of the container becomes `ethN` of the UML (vector driver,
  raw transport on the container's interface); the management veth
  becomes `kmgmt` (169.254.77.2);
- `init`, PID 1 of the UML, mounts `/proc`, `/sys`, `/dev`, `/run`, sets
  the interfaces up and starts `sshd` on `kmgmt`.

`ushell` is ssh to the UML over `kmgmt`. Kathara runs the startup as
`shell -c ...` and `connect` as `shell`, so both land in the UML. The
container's own interfaces carry no address: the UML kernel routes.

The device does not need privileged mode: the capabilities Kathara gives
every device (`NET_ADMIN`, `NET_RAW`, ...) are enough.

## seccomp or ptrace

UML runs its processes in one of two modes, chosen at boot with its
`seccomp=` option. In the ptrace mode, the default of the kernel
(`seccomp=off`), the UML kernel traces its processes like a debugger:
every syscall stops the process and wakes the UML kernel. In the seccomp
mode a seccomp filter turns each syscall into a signal, handled by a stub
of UML inside the process, with fewer context switches.

A UML device boots with `seccomp=auto`: the seccomp mode where it works,
the ptrace mode otherwise. The kernel's help for the option calls the
seccomp mode insecure, because a process in the UML could read and write
the memory of the UML kernel, and says to use it only with a trusted
userspace. In a UML device the processes are the lab's own and the UML is
itself a process of the container. To use the kernel default:

```
r[env]="KATHARA_UML_SECCOMP=off"
```

`/var/log/uml-start.log` of the container shows the option given, and
`/var/log/uml-console.log` the mode the UML took ("Checking that seccomp
filters can be installed...OK" for seccomp).

## The kernel

[kernel/build.sh](kernel/build.sh) builds it in a podman container,
nothing is installed on the host:

```
uml/kernel/build.sh --fetch 6.18                        # kernel.org release
uml/kernel/build.sh --src ~/linux --fragment my.fragment
```

The config is `make ARCH=um defconfig`, then
[base.fragment](kernel/base.fragment) (hostfs, vector network, devtmpfs,
tmpfs, IPv4/IPv6, ptys), then the given fragments. The build fails if an
option of a fragment does not stick. The result is `uml/out/kernel/linux`,
stripped, with `linux.config` and `BUILD-INFO`.

The builder is Debian 12 on purpose. UML is a dynamic binary: linked on a
newer glibc it fails on bookworm based images such as `kathara/base`
("GLIBC_2.38 not found"). Built on Debian 12 it needs GLIBC_2.34 at most.
A static UML is not an option: `STATIC_LINK` depends on
`!MAY_HAVE_RUNTIME_DEPS`, which the vector driver selects.

## Image

`ushell` needs an ssh client in the image, and the UML needs `sshd`,
`ip` and `bash`. `kathara/base` has `sshd` but no client:
[image/Dockerfile](image/Dockerfile) adds it.

```
docker build -t kathara-uml/base-ssh uml/image
```

## Test VM

[vm/vm.sh](vm/vm.sh) runs the tests in a Debian VM under KVM (QEMU in a
podman container), with Docker, this tree and the image installed inside
the VM, so the host's Docker and network are not touched:

```
uml/kernel/build.sh --fetch 6.18
uml/vm/vm.sh start
uml/vm/vm.sh install
uml/vm/vm.sh test
uml/vm/vm.sh stop
```

[tests/check-router.sh](tests/check-router.sh) checks the router lab
(UML label, no privileged mode, `exec` in the UML and in a container, exit
codes, startup in the UML, ping and first hop, `connect`, `lclean`).
[tests/check-shared.sh](tests/check-shared.sh) checks `/shared` from the
host, from the UML and from a container.

## Things to know

- The UML console goes to `/var/log/uml-console.log` of the container,
  and its stdin is kept open. UML stops early in the boot, before mounting
  its root, when its stdout is a pipe or its stdin reaches end of file.
- hostfs does not see changes made outside the UML to files it holds in
  its cache (see the hostfs section of the UML howto). The shared folder
  tests read each file with a new process and saw every change; a file
  kept open or mapped in the UML while the host changes it was not tested.
- `kathara exec` never runs a shell, for any device: pipes and redirections
  need `bash -c '...'`.
