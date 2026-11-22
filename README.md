# UML devices: a device on its own Linux kernel

Kathara devices are containers, so they all share the kernel of the host.
With the Kathara of [kathara](kathara) a device can run on its own kernel
instead: a
[User-Mode Linux](https://docs.kernel.org/virt/uml/user_mode_linux_howto_v2.html)
(UML) kernel, which runs as a process inside the device's container. The
rest of the lab does not change: the other devices are plain containers,
and `lab.conf`, `.startup` files, `kathara exec`, `kathara connect` and the
shared folders work as for any device.

Use it to put different kernels in the same network: a patched kernel next
to a stock one, two kernel versions, a feature that only some nodes have.

[kathara](kathara) is a submodule: a fork of Kathara, branch `uml-kernel`,
with the changes to Kathara itself. The rest of this repository builds
what a UML device needs (kernel, image) and tests it. Clone it with the
submodule:

```
git clone --recurse-submodules <this repository>
```

## Usage

One line in `lab.conf`:

```
r[0]="A"
r[1]="B"
r[image]="kathara/base"
r[kernel]="/path/to/linux"
```

`kernel` is a UML kernel binary. A relative path is relative to the lab
directory, as the other files of the lab. `image` must have the
OpenSSH client and server, as `kathara/base` has (see [Image](#image)).

[examples/router](examples/router) is a complete lab: `a` and `b` are
containers, `r` is a router on a UML kernel, and its `r.startup` is a
normal startup file that configures `eth0` and `eth1`. Its
`r[kernel]="kernel/linux"` goes through `kernel`, a link to
`../../out/kernel`: point the link elsewhere (`ln -sfn`) to run `r` on
another kernel. Links in the path are resolved before the mount.

## How it works

For a device with `kernel`, Kathara
([DockerMachine.py](kathara/src/Kathara/manager/docker/DockerMachine.py)):

1. creates the container with the kernel mounted read-only in
   `/kathara-uml-kernel`, the entrypoint `/kathara-uml/start`, the shell
   `/kathara-uml/ushell`, the label `uml` and `KATHARA_UML_IFACES` (the
   number of interfaces), and copies the helpers of
   [UmlHelpers.py](kathara/src/Kathara/manager/docker/UmlHelpers.py) into
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
filters can be installed...OK" for seccomp). See [Measurements](#measurements)
for what each mode costs.

## eBPF and bpf_printk

UML has no `PERF_EVENTS`, so no `BPF_EVENTS`. Without them a kernel does
not build `bpf_trace_printk()`, and the verifier refuses every program
that calls `bpf_printk()`:

```
program of this type cannot use helper bpf_trace_printk#6
```

[uml-kernel/patches/7.3](uml-kernel/patches/7.3) carries a patch that builds the
helper with `BPF_SYSCALL` and `EVENT_TRACING` instead, and
[trace.fragment](uml-kernel/trace.fragment) turns them on:

```
uml-kernel/build.sh --fetch 7.3.5 --fragment uml-kernel/trace.fragment
```

In a device on that kernel the lines of `bpf_printk()` are in the trace
buffer of the UML kernel: mount tracefs on `/sys/kernel/tracing` and read
`trace`. [image/printk-test](image/printk-test) is a device
image with bpftool, clang and a socket filter that calls `bpf_printk()`,
used by the tests below.

## The kernel

[uml-kernel/build.sh](uml-kernel/build.sh) builds it in a podman container,
nothing is installed on the host:

```
uml-kernel/build.sh --fetch 7.3.5                       # kernel.org release
uml-kernel/build.sh --src ~/linux --fragment my.fragment
```

The config is `make ARCH=um defconfig`, then
[base.fragment](uml-kernel/base.fragment) (hostfs, vector network, devtmpfs,
tmpfs, IPv4/IPv6, ptys), then the given fragments. The build fails if an
option of a fragment does not stick. The result is `out/kernel/linux`,
stripped, with `linux.config` and `BUILD-INFO`.

The builder is Debian 12 on purpose. UML is a dynamic binary: linked on a
newer glibc it fails on bookworm based images such as `kathara/base`
("GLIBC_2.38 not found"). Built on Debian 12 it needs GLIBC_2.34 at most.
A static UML is not an option: `STATIC_LINK` depends on
`!MAY_HAVE_RUNTIME_DEPS`, which the vector driver selects.

With `--fetch X.Y.Z`, build.sh applies the patches listed in
`uml-kernel/patches/X.Y/series`, in order, if that directory exists; a patch
that does not apply stops the build. `--no-patches` builds the release as
it is. With `--src` no patch is applied: the tree is the caller's.
`BUILD-INFO` lists the patches applied.

## Image

`ushell` runs the ssh client of the image, and the UML runs its `sshd`,
`ip` and `bash`. `kathara/base` has them all: openssh-client and
openssh-server 9.2p1-2+deb12u7 in the `kathara/base` of 2026-03-22
(`sha256:8a2e70ac8f51`), with its host keys in `/etc/ssh`. An image
without OpenSSH does not work yet (see [TODO.md](TODO.md)).

## Test VM

[vm/vm.sh](vm/vm.sh) runs the tests in a Debian VM under KVM (QEMU in a
podman container), with Docker, this tree, the Kathara of its submodule
and the image installed inside the VM, so the host's Docker and network
are not touched:

```
uml-kernel/build.sh --fetch 7.3.5
vm/vm.sh start
vm/vm.sh install
vm/vm.sh test
vm/vm.sh stop
```

[tests/check-router.sh](tests/check-router.sh) checks the router lab
(UML label, no privileged mode, `exec` in the UML and in a container, exit
codes, startup in the UML, ping and first hop, `connect`, `lclean`).
[tests/check-shared.sh](tests/check-shared.sh) checks `/shared` from the
host, from the UML and from a container.
[tests/check-printk.sh](tests/check-printk.sh) boots a UML kernel in a
container and checks that `bpf_printk()` works (`printk`) or is refused
because of the helper (`refused`).
[tests/check-printk-lab.sh](tests/check-printk-lab.sh) checks it from
inside a UML device of a lab, through `kathara exec`. Both take the
kernel as argument:

```
uml-kernel/build.sh --fetch 7.3.5 --fragment uml-kernel/trace.fragment --out out/printk
vm/vm.sh install
vm/vm.sh ssh 'mkdir -p /opt/kathara-uml/out/printk &&
	cat > /opt/kathara-uml/out/printk/linux && chmod 755 /opt/kathara-uml/out/printk/linux' < out/printk/linux
vm/vm.sh ssh bash /opt/kathara-uml/tests/check-printk-lab.sh /opt/kathara-uml/out/printk/linux
```

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
- UML is fast under KVM and slow under emulation (TCG): see below.

## Measurements

2026-11-21, host with 64 cores, Debian 13 test VM with 4 vCPUs and 6 to
8 GB under KVM. Single runs unless said otherwise.

Test VM, UML from kernel.org with base.fragment:

| Step | UML 6.18 | UML 7.3.5 |
|---|---|---|
| `uml-kernel/build.sh --fetch` | 1 min 44 s, download included | 68 s, tarball already there |
| `kathara lstart` of the router lab | 4.1 to 7.7 s | 5.2 s |
| `kathara lclean` | 4.4 to 4.5 s | 3.6 s |

[tests/bench-uml.sh](tests/bench-uml.sh) in the test VM (KVM), UML 6.18
with base.fragment, three runs each (lowest and highest):

| Test | Container | UML, ptrace | UML, seccomp |
|---|---|---|---|
| 200000 syscalls (`dd bs=1`, 100000 bytes) | 0.10 to 0.12 s | 13.49 to 13.59 s | 12.21 to 12.65 s |
| 300 fork + exec of `/bin/true` | 0.93 to 0.96 s | 13.38 to 13.75 s | 8.52 to 9.17 s |
| 200 MB through a `dd` buffer (page faults) | 0.16 to 0.49 s | 0.50 to 0.62 s | 0.42 to 0.46 s |
| computation only (awk loop) | 0.08 to 0.12 s | 0.24 to 0.26 s | 0.19 to 0.20 s |

A syscall in UML costs 60 to 70 microseconds against about 0.6 in a
container.
The seccomp mode cuts fork + exec by about a third and a syscall by less
than a tenth: it is why UML devices boot with `seccomp=auto`.

Micro-tests run in a guest under QEMU TCG (no KVM), first in the guest
and then inside UML in the same guest:

| Test | Guest | UML (ptrace) | Ratio |
|---|---|---|---|
| 200000 syscalls (`dd bs=1`, 100000 bytes) | 0.18 s | 26.3 s | 145 |
| 300 fork + exec of `/bin/true` | 1.10 s | 23.6 s | 21 |
| page faults: python zero-fills 200 MB | 0.73 s | 35.7 s | 49 |
| computation only (awk loop) | 1.87 s | 2.17 s | 1.16 |

Computation costs about the same; every syscall and page fault of a
process in UML goes through the UML kernel and costs much more. Under TCG
the seccomp mode of UML, meant to cut that cost, does not start:
`failed to fetch registers: -22` (from `get_stub_state()`, when
`get_fpstate()` returns NULL in `arch/x86/um/os-Linux/mcontext.c`), so
only the ptrace mode is left. The cause under TCG was not found.
