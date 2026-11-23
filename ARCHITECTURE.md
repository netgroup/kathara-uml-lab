# Architecture of a UML device

How a Kathara device runs on its own User-Mode Linux (UML) kernel: what
Kathara does, what runs in the container, how packets reach the UML, what
the UML boot options are for, how the settings of the device reach the
UML, and how the files and the shell of the device get into it.

The rule behind it: a process in the UML finds what it would find in the
container of the device. Kathara keeps building the container as for any
device; the helpers hand its settings to the UML kernel.

Line numbers refer to the Kathara of the `kathara` submodule
(`src/Kathara/manager/docker/`, at 20dad86, on Kathara's `develop`) and,
for the kernel, to a tree at v7.4-rc2-492-g533ec433efdc, not to the 7.3.5
sources the test kernel is built from. The outputs under "Observed" come
from the router lab in the test VM: those of the packet sockets and of
the console from 2026-11-21, with Kathara 3.8.4 and the helpers as they
were then (the boot options of the UML did not change), the others from
2026-11-22, with the Kathara of the submodule.

## The pieces

```
 lab.conf: r[kernel]="kernel/linux"
     |
     v
 Kathara (kathara/, Docker manager)          helpers and settings (UmlHelpers.py)
   DockerMachine.create()  ---- copies ---->   /kathara-uml/start   entrypoint of the container
   DockerMachine.start()                       /kathara-uml/init    PID 1 of the UML
   DockerMachine.exec()                        /kathara-uml/ushell  shell of the device
                                               /kathara-uml/sysctl.conf, environment,
                                                 shell, ulimit.conf: the settings
     |
     | mounts read-only
     v
 /kathara-uml-kernel  = the UML kernel, a normal x86-64 ELF program
                        (built by uml-kernel/build.sh)
```

A UML kernel is a Linux kernel built with `ARCH=um`: it runs as a process
of the host, here as PID 1 of the device's container. Its own processes
are processes of the container too.

## What Kathara does

For a device with the `kernel` option, `DockerMachine.create()`:

- builds the sysctls of the container as for any device, and keeps a copy
  for the UML before the interface ones go to the network driver
  (`DockerMachine.py:306`);
- resolves the path of the kernel: relative to the lab directory, through
  the lab filesystem, with links resolved (`:345-347`); the file must
  exist (`:348-349`);
- refuses a file that is not a UML kernel for the host (`:350-353`):
  `uml_kernel_error()`, in `UmlHelpers.py`, wants an ELF file with the
  section `.uml.setup.init`, which a UML kernel has and a `vmlinux` does
  not, and with the ELF class and machine of the host, which must be x86;
- refuses the `entrypoint` and `args` options (`:355-360`), see
  [Settings of a device](#settings-of-a-device);
- mounts the kernel read-only on `/kathara-uml-kernel` (`:362`) and sets
  `KATHARA_UML_IFACES` to the number of interfaces and, for a bridged
  device, `KATHARA_UML_BRIDGED_IFACE` to the number of the bridged one
  (`:363-365`);
- keeps the shell of the device, then sets the label `uml`, the shell
  label to `/kathara-uml/ushell` and the entrypoint to
  `/kathara-uml/start` (`:401-404`);
- copies the three helpers and the settings files into `/kathara-uml`
  (`:440-443`).

`DockerMachine.start()` starts the container, then connects the
interfaces after the first one, which Kathara does only after the start,
and the bridged one (`:581-594`), then touches `/run/kathara-uml.ready`
(`:597-599`), then waits until the UML has booted (`:600`, see
[Boot sequence](#boot-sequence)), then runs the startup commands as
`<shell> -c <commands>` (`:621`). `connect` runs the shell label
(`:799-800`), and `exec` of a UML device runs the command as
`<shell> -c <command>` (`:931-932`). With the shell label set to
`ushell`, all three go into the UML.

## Boot sequence

```
 Kathara                         container r                        UML kernel
 -------                         -----------                        ----------
 create(): mount kernel,
   entrypoint start,
   copy helpers and
   the settings files
 start(): container start  --->  start: ssh key, unmount
                                 /etc/hosts and resolv.conf,
                                 wait for the ready file
 connect eth1.. ethN,
   the bridged interface
 touch kathara-uml.ready   --->  start: veth um0/um1, MACs,
                                 bridged address, memory,
                                 exec /kathara-uml-kernel ... -->   boot, mount / (hostfs),
                                                                    vecK interfaces,
                                                                    run /kathara-uml/init
                                                                    init: filesystems,
                                                                    vecK -> ethK, bridged,
                                                                    sysctls, ulimits,
                                                                    last -> kmgmt, sshd,
                                                                    touch kathara-uml.booted
 wait for the booted file  <--------------------------------------  (in /run, the container's)
 startup: ushell -c CMDS   --->  ushell: waits for the key,
                                 ssh 169.254.77.2 -------------->   sshd: <shell> -c CMDS
                                 (ssh retries the connect           with the environment
                                 until sshd answers)                (r.startup)
```

`start` (`UmlHelpers.py:20-184`) makes the key of `ushell` first
(`:139-148`), unmounts the `/etc/hosts` and `/etc/resolv.conf` that Docker
mounts in a container (`:50-54`, `:149`), then waits for the ready file,
that is until Kathara has attached every interface: 600 checks 0.1 s
apart (`:58-66`, `:150`). It builds the `vecK` boot options from those
interfaces (`:157-166`).

Kathara runs the startup through `ushell` once the UML has booted. `init`
touches `/run/kathara-uml.booted` once `sshd` runs (`UmlHelpers.py:331`),
in the `/run` of the container, and `DockerMachine._wait_uml_boot()`
(`DockerMachine.py:642-684`) waits for it up to 120 s, reading the UML
console too. If the container exits, the kernel panics (with
`panic_timeout` 0, the default, a kernel stays in `panic()`) or the time
runs out, it removes the container and raises `MachineBootError` with
the reason and the line of the panic, or else the last lines of the
console. `ushell` (`UmlHelpers.py:339-406`) waits for the key (`:363-371`, `:399`),
up to 600 checks 0.1 s apart, then runs one ssh (`:354-357`,
`:401-405`). While the UML boots, ssh retries only the TCP connect, once
a second, up to `ConnectionAttempts=120` times (`sshconnect.c:461-518` of
OpenSSH 9.2p1), so a startup or an `exec` issued then waits for `sshd`,
and a command never runs twice. `ConnectTimeout=10` bounds each connect
and the ssh banner exchange (`kex.c:1275-1282`).

## Network

```
    collision domain A                            collision domain B
     (Kathara bridge)                              (Kathara bridge)
             |                                             |
+------------|----------------- container r ---------------|---------------+
|          eth0 no address                               eth1 no address   |
|           | ^                                           | ^              |
|        rx | | tx          AF_PACKET sockets          rx | | tx           |
|           v |                                           v |              |
|  +--------|-|------------- UML kernel (PID 1) ----------|-|-----------+  |
|  |  vec0 = eth0  10.0.1.2/24              vec1 = eth1  10.0.2.2/24    |  |
|  |  routing, netfilter, eBPF ... of the UML kernel                    |  |
|  |                                                                    |  |
|  |  vec2 = kmgmt  169.254.77.2/30  <-- sshd                           |  |
|  +--------|-|---------------------------------------------------------+  |
|           | ^                                                            |
|        rx v | tx                                                         |
|          um1  veth peer of um0                                           |
|          um0  169.254.77.1/30  <-- ushell (ssh client)                   |
+--------------------------------------------------------------------------+
```

### Collision domain interfaces

Kathara attaches the container to its collision domains as for any
device: `eth0`, `eth1`, ... are veth interfaces of the container, and the
network plugin of Kathara gives each the MAC address of `lab.conf`, if
there is one. `start` gives each one to the UML (`add_vector`,
`UmlHelpers.py:90-101`, `take_mac`, `:78-85`, used at `:157-159`):

- the UML interface takes the MAC address of the container interface,
  and the container interface a random one (`random_mac`, `:69-73`), so
  that the stack of the container takes the frames for the UML as not
  its own;
- it disables IPv6 on the container interface and sets it up; the
  container interface has no address: it is only a wire for the UML;
- it adds `vecK:transport=raw,ifname=ethK,depth=128,gro=1,mac=...` to the
  boot options.

The UML vector driver, with the raw transport, opens two packet sockets
on that interface (`arch/um/drivers/vector_user.c:521-560`):

- a receive socket, `socket(AF_PACKET, SOCK_RAW, ETH_P_ALL)` bound to the
  interface with `ETH_P_ALL` (`:533`, `:167-195`), "Every packet"
  (`include/uapi/linux/if_ether.h:138`);
- a transmit socket created with protocol 0, "Turn off RX on this fd",
  and bound with `ETH_P_IP` (`:538`).

Observed, `/proc/net/packet` of the container: two sockets on each of
ifindex 71 (`eth0`), 72 (`eth1`) and 2 (`um1`), one with protocol 0003
(`ETH_P_ALL`) and one with 0800.

### Packet path

```
 transmit: UML stack -> vec0 queue -> sendmmsg(tx socket) -> eth0 of the container
           -> veth peer on the bridge of A -> other devices of A

 receive:  frame on the bridge of A -> eth0 of the container
           -> rx socket (ETH_P_ALL) -> recvmmsg() in the UML
           -> napi_gro_receive() -> UML stack
```

- The driver sends with `uml_vector_sendmmsg()` (`vector_kern.c:427`) and
  receives with `uml_vector_recvmmsg()` (`vector_kern.c:973`), wrappers
  of `sendmmsg()` and `recvmmsg()` (`vector_user.c:806-832`): up to
  `depth` frames per system call.
- A received frame goes up the UML stack through `napi_gro_receive()`
  (`vector_kern.c:1025`).
- For the raw transport the driver asks for `PACKET_QDISC_BYPASS`
  (`vector_kern.c:246-247`, `:1288-1290`); if the socket refuses it, it
  attaches to the receive socket a BPF filter that drops the frames whose
  source MAC is the one of the UML interface (`vector_kern.c:1289-1296`,
  `vector_user.c:860-889`). Inference, not checked further: both keep the
  UML from receiving the frames it sent itself.
- The container's own stack also receives the frames of `eth0`, but the
  interface has no IPv4 address, IPv6 is off on it, and the frames for
  the UML carry a MAC address that is no longer the one of the
  container. The router test (`tests/check-router.sh`) checks that the
  container's `eth0` has no address and that the first hop from `a` to
  `b` is the address of the UML.

### Bridged interface and published ports

With the `bridged` option Docker connects the container to its bridge
network on one more interface, after the others, with an address, a
default route and a MAC address of its own, and publishes the ports of
the `port` option to that address (`DockerMachine.py:272-273`,
`:593-594`). `start` moves the address and the default route to
`/var/lib/kathara-uml/bridged.conf` and removes them from the container
(`take_bridged_config`, `UmlHelpers.py:106-115`), and gives the interface
to the UML with its MAC address (`:160-165`). `init` sets the address and
the route on the same interface of the UML (`configure_bridged`,
`:245-267`). Docker sends the traffic of the published ports to that
address and MAC, which are now the UML's.

Observed: in the UML `eth2` had `172.17.0.2/16`, `default via
172.17.0.1` and the MAC that Docker gave the container interface
(`02:42:ac:11:00:02`), the container interface had no address, and an
HTTP server started inside the UML answered on the published port of the
host.

### Management link

`start` adds a veth pair inside the container (`UmlHelpers.py:152-153`):
`um0` keeps 169.254.77.1/30 in the container, `um1` is given to the UML
as its last vector interface (`:166`). `init` renames that one `kmgmt`,
gives it 169.254.77.2/30 (`:237-239`) and starts `sshd` on that address,
without PAM (`:325-328`). `ushell` is ssh from the container to
`root@169.254.77.2` (`:339-406`), with a key that `start` creates in
`/var/lib/kathara-uml/id` and copies to `/root/.ssh/authorized_keys`
(`make_key`, `:139-146`); the UML reads that file through hostfs.

The address of the management link is fixed, named in each helper
(`MGMT_CONTAINER`, `:42`, `MGMT_UML`, `:197`, `:351`; a test checks that
they agree). In the container it cannot clash with anything: each
container has its own network namespace. In the UML it sits in the same
network stack as the interfaces of the lab, so 169.254.77.0/30 is
reserved in a UML device: it is link-local, in a range a lab does not
use.

## Settings of a device

Docker applies the settings of a device to its container. The UML has
its own kernel, network stack, limits and filesystems, so each setting
needs a way in. Kathara writes the settings that live inside the
container into files of `/kathara-uml`, next to the helpers
(`UmlSettings`, `UmlHelpers.py:434-460`), and the helpers apply them in
the UML.

| Kathara option | In a container | In a UML device | Where |
|---|---|---|---|
| `sysctl`, `ipv6`, the defaults of Kathara | Docker sets them in the network namespace | Kathara writes them, the interface ones included, to `sysctl.conf`; `init` applies them once the interfaces have their names, and logs to `/var/log/uml-sysctl.log` those the UML kernel refuses | `DockerMachine.py:306`, `apply_sysctls`, `UmlHelpers.py:273-286` |
| MAC address of an interface | the network plugin sets it | the UML interface takes it, the container interface gets a random one | `take_mac`, `:78-85` |
| `mem` | limit of the container | the UML gets three quarters of the limit, the rest is left to the UML process; without a limit 256M; `KATHARA_UML_MEM` overrides it | `uml_memory`, `:120-134` |
| `cpus` | limit of the container | the same limit holds the UML process | Docker |
| `env` | environment of the container | Kathara writes it to `environment`; `ushell` exports it, quoted, in front of each command and of the shell of `connect` | `exports`, `:376-386` |
| `shell`, `device_shell` | the shell of `exec`, `connect` and the startup | Kathara writes it to `shell`; `ushell` runs each command as `<shell> -c <command>` and opens it for `connect` | `DockerMachine.py:401`, `device_shell`, `UmlHelpers.py:390-397` |
| `ulimit` | limits of the processes of the container | Kathara writes them to `ulimit.conf`; `init` sets them on itself with `prlimit` before it starts `sshd`, and logs to `/var/log/uml-ulimit.log` those it cannot set | `apply_ulimits`, `:292-305` |
| `bridged`, `port` | one more interface on the bridge of Docker, ports published to its address | the interface goes to the UML with its address, route and MAC | [above](#bridged-interface-and-published-ports) |
| `exec`, the `.startup` file | run in the container | run in the UML through `ushell` | `DockerMachine.py:621` |
| `volume`, `/shared`, `/hosthome` | bind mounts | the same files, through hostfs | [Files](#files) |
| `entrypoint`, `args` | the main process of the container | refused: the UML kernel is the main process of the container | `DockerMachine.py:355-360` |
| `privileged` | privileged container | the UML does not need it; in the UML everything runs as root of its own kernel | |

Why `entrypoint` and `args` are refused: the entrypoint of a container is
its main process, and the container lives as long as it does. In a UML
device that process is the UML kernel. A program given as entrypoint
could only run inside the UML as one more process, which would not keep
the device alive and would start at a moment of its own: it would look
like an entrypoint without behaving as one. Kathara used to replace the
option without a word. Programs and daemons go in the startup file
instead, which runs inside the UML: a daemon started there, or a program
in the background with `&`, keeps running (observed: a second `sshd` and
`sleep` started from the startup were still running after it).

One difference is left: `kathara exec r "bash -c 'prog &'"` waits as
long as `prog` runs, because `prog` keeps the output of the ssh session
open (observed: the exec was still waiting after 20 s, while the same
exec in a container returned in 4 s). Detach it:
`nohup prog > /dev/null 2>&1 &`.

`tests/check-settings.sh` gives the same options to a container and to a
UML device and checks that both see the same.

## Boot options of the UML

The command `start` runs (`UmlHelpers.py:180-183`):

```
env TMPDIR=/tmp/uml /kathara-uml-kernel mem=256M \
    root=/dev/root rootfstype=hostfs rootflags=/ rw init=/kathara-uml/init \
    con0=fd:0,fd:1 con=null seccomp=auto \
    vec0:transport=raw,ifname=eth0,depth=128,gro=1,mac=02:42:ac:11:00:0b ... \
    < /tmp/uml/stdin > /var/log/uml-console.log 2>&1
```

| Option | What it does | Source |
|---|---|---|
| `TMPDIR=/tmp/uml` | the directory where UML creates the file that backs its memory | `arch/um/os-Linux/mem.c:83-90`, `:131-146`, `:212` |
| `mem=256M` | the memory of the UML kernel, from `uml_memory` (see [Settings of a device](#settings-of-a-device)) | `arch/um/kernel/physmem.c:120-136`, `UmlHelpers.py:170` |
| `root=/dev/root` | only a name: `parse_root_device()` returns 0 when no block device has the name, and with `rootfstype` set the kernel then mounts a filesystem that needs no device, with the name as source (observed: "VFS: Mounted root (hostfs filesystem)") | `init/do_mounts.c:428-452`, `:394-397`, `:339-364` |
| `rootfstype=hostfs` | the root filesystem is hostfs, which shows a directory of the host (here, of the container) | `init/do_mounts.c:122`, `fs/hostfs/hostfs_kern.c:1023-1026` |
| `rootflags=/` | the mount data, for hostfs the host directory to show: `/` of the container | `init/do_mounts.c:121`, `fs/hostfs/hostfs_kern.c:1006-1020` |
| `rw` | mount the root read-write; the default is read-only | `init/do_mounts.c:31`, `:45-54` |
| `init=/kathara-uml/init` | the first process of the UML: the `init` helper | `UmlHelpers.py:186-337` |
| `con0=fd:0,fd:1` | console 0 reads fd 0 and writes fd 1 of the UML process | UML howto ("fd channel") |
| `con=null` | the other consoles discard input and output | UML howto ("null channel") |
| `seccomp=auto` | run the UML processes in the seccomp mode if it works, else in the ptrace mode; `KATHARA_UML_SECCOMP` changes it | `arch/um/os-Linux/start_up.c:424-489`, `UmlHelpers.py:169` |
| `vecK:transport=raw` | a network interface `vecK` on raw packet sockets | UML howto ("raw socket transport"), `vector_user.c:521-560` |
| `ifname=ethK` | the interface of the container the sockets bind to | UML howto ("Shared Options") |
| `depth=128` | frames read or written per system call; the default is 64 | UML howto ("Common options"), `vector_kern.c:81` |
| `gro=1` | receive/transmit offloads; the howto says it must match the host side and that veth has GRO on | UML howto ("Common options") |
| `mac=...` | the MAC address of the interface | UML howto ("Common options") |

The UML howto is `Documentation/virt/uml/user_mode_linux_howto_v2.rst`
of the kernel tree.

`mem=` and `seccomp=` are options of UML itself: UML parses its own
options first and leaves out of the kernel command line those whose
handler sets `*add = 0` (`arch/um/kernel/um_arch.c:396-403`), as
`uml_mem_setup()` (`arch/um/kernel/physmem.c:124`) and
`uml_seccomp_config()` (`arch/um/os-Linux/start_up.c:428`) do. So the
console prints a command line without them. Observed:

```
Kernel command line: root=/dev/root rootfstype=hostfs rootflags=/ rw init=/kathara-uml/init con0=fd:0,fd:1 con=null vec0:transport=raw,ifname=eth0,depth=128,gro=1 ...
VFS: Mounted root (hostfs filesystem) on device 0:17.
```

stdin is a FIFO kept open by `sleep infinity`, and the console goes to a
file (`UmlHelpers.py:174-183`): with a pipe on stdout or stdin at end of
file the UML stops early in the boot (see README, "Things to know").

The seccomp mode: see README, "seccomp or ptrace", for what it changes and
what it costs. Observed with `seccomp=auto` under KVM:
`Checking that seccomp filters can be installed...OK`. UML 6.12.118 has
no seccomp mode, and runs in the ptrace one.

## Files

```
 image layers (read-only, e.g. kathara/base)   \
 upper layer of the container (read-write)      >  overlay2 = / of the container
 bind mounts: /shared, /hosthome, volumes,     /
              /kathara-uml-kernel (ro)
                         |
                         |  hostfs, rootflags=/
                         v
                    / of the UML
```

The UML has no disk: its root is the container's own `/`, through hostfs.
The image, the files Kathara copies into the container, `/run`,
`/shared`, `/hosthome` and the volumes are all there. A file the UML
writes goes where a write of the container goes. Observed: a file
written from the UML (`kathara exec r "bash -c 'echo from-uml >
/root/arch-probe'"`) was in the upper directory of the container's
overlay2.

On top of it `init` mounts what Docker mounts in a container, from the
UML kernel and with the options Docker gives them in a Kathara device
(`mount_filesystems`, `UmlHelpers.py:210-224`): `/proc`, `/sys`,
`/dev/pts`, `/dev/shm` (tmpfs, 64 MB), `/dev/mqueue` and `/sys/fs/cgroup`
(read-only), plus, for BPF programs, `/sys/fs/bpf` and, when the kernel
has tracefs, `/sys/kernel/tracing`, where the lines of `bpf_printk()`
are read, mounted as systemd mounts it on a host. `/dev` is the devtmpfs
of the UML kernel, with its own devices. Observed, mount points and
types in a container device and in the UML of a UML device: the same,
but for `/` (overlay against hostfs), `/dev` (tmpfs against devtmpfs),
the bind mounts, which the UML sees as files of its `/`, the masks of
`/proc` and `/sys` that Docker adds to a container, and `/sys/fs/bpf`
and `/sys/kernel/tracing`, which a container does not have.

`/etc/hosts` and `/etc/resolv.conf`: Docker mounts its own in a
container, and the startup of Kathara unmounts them first, so that the
device finds the files of the image and Kathara writes its `/etc/hosts`.
In a UML device that startup runs inside the UML, where they are not
mounts, so `start` unmounts them in the container before the UML boots
(`:50-54`). Observed: `/etc/hosts` and `/etc/resolv.conf` were the same
in a container device and in a UML device.

The hostfs caveat of the howto applies ("Hostfs Caveats"): if a file is
changed outside the UML, the UML does not know it, and its in-memory cache
of the file may be corrupt. The shared folder test
(`tests/check-shared.sh`) reads each file with a new process; a file kept
open in the UML while the host changes it was not tested.

## Shell, exec and startup

```
 kathara exec r "ip -br addr"
   -> exec(): ["/kathara-uml/ushell", "-c", "ip -br addr"]      DockerMachine.py:931-932
   -> docker exec in container r
   -> ushell: ssh -T root@169.254.77.2 -- \
        "export VAR=...; exec <shell> -c 'ip -br addr'"          UmlHelpers.py:401-404
   -> sshd in the UML runs it, the output and the exit code come back

 kathara connect r
   -> the shell label: /kathara-uml/ushell                     DockerMachine.py:799-800
   -> ushell: ssh -t root@169.254.77.2 -- "export ...; exec <shell>"
                                                                UmlHelpers.py:405
```

The startup commands of Kathara (`STARTUP_COMMANDS`,
`DockerMachine.py:51`), the device's `.startup` file among them, run in
the UML in the same way. They read the lab files from the same paths as
for a container, because the UML sees the container's files.

## Observed processes and interfaces

In the container (`docker exec <r> ps -eo pid,args`): PID 1 is
`/kathara-uml-kernel mem=256M root=/dev/root ...`, then `sleep infinity`
(the stdin of the console) and the `uml-userspace` processes of UML.

```
container r                         UML of r
lo     127.0.0.1/8                  lo     127.0.0.1/8
um0    169.254.77.1/30              eth0   10.0.1.2/24
um1    (no address)                 eth1   10.0.2.2/24
eth0   (no address)                 kmgmt  169.254.77.2/30
eth1   (no address)                 dummy0, sit0 (down)
```

To look at a running device:

```
kathara exec r "ip -br addr"                                   # the UML side
docker exec $(docker ps -qf name=_r_) ip -br addr              # the container side
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-start.log
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-console.log
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-sysctl.log
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-ulimit.log
docker exec $(docker ps -qf name=_r_) cat /proc/net/packet
docker exec $(docker ps -qf name=_r_) cat /var/tmp/uml-status  # written by init every 2 s
```
