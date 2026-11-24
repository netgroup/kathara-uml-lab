# The router lab

The smallest lab with a UML device: a and b are containers, on the
kernel of the host, and r, the router between them, runs on its own
kernel, the prebuilt Linux 7.3.5 of
[uml-kernel/prebuilt](../../uml-kernel/prebuilt).

    a --A-- r --B-- b
    10.0.1.1/24   10.0.1.2/24 (eth0)
                  10.0.2.2/24 (eth1)   10.0.2.1/24

## Files

- [lab.conf](lab.conf): the collision domains A and B, and the two lines
  that make r a UML device, `r[kernel]="kernel/linux"` and
  `r[image]="kathara/base"`.
- `kernel`: a link to `../../uml-kernel/prebuilt`, so that the kernel
  path of lab.conf is relative to this lab. `kernel/linux` is itself a
  link to the kernel of the moment, `linux-7.3.5`.
- [a.startup](a.startup), [b.startup](b.startup): the address and the
  default route of each container.
- [r.startup](r.startup): the addresses of r, IPv4 forwarding, and a line
  with the kernel that the startup ran on. Kathara runs it inside the
  UML, through the shell of the device.

## Run it

With the Kathara of the [kathara](../../kathara) submodule:

```
cd examples/router
kathara lstart --noterminals
kathara exec r "uname -r"                 # 7.3.5: the UML kernel of r
kathara exec a "uname -r"                 # the kernel of the host
kathara exec a "ping -c 3 10.0.2.1"       # from a to b, through r
kathara exec r "cat /var/log/startup.log" # r.startup ran on 7.3.5
kathara lclean
```

`kathara connect r` opens the shell of r, inside the UML. The console of
the UML kernel is in `/var/log/uml-console.log` of the container of r.

## Other kernels

To run r on another kernel, point the link elsewhere, for example to a
kernel built by [uml-kernel/build.sh](../../uml-kernel/build.sh):

```
ln -sfn ../../out/kernel kernel
```

or give r another path in lab.conf. Kathara refuses, at lstart, a file
that is not a UML kernel for the host, and fails with the console of the
UML when its kernel does not boot.

## Test

[tests/check-router.sh](../../tests/check-router.sh) runs this lab and
checks that r is a UML device, that exec runs in the UML of r and in the
containers of a and b, the exit codes, the startup of r, the ping and its
first hop, connect and lclean.
