# TODO: UML devices

## Devices

- [ ] **Images without OpenSSH** (low priority). The UML runs on the
      image of the device, and the Kathara images seen (kathara/base,
      kathara/frr) have the OpenSSH client and server, iproute2 and glibc.
      Only for an image without OpenSSH: a static dropbear copied with
      the helpers (tried as a prototype, not in this repository).
- [ ] **Kernel modules.** UML supports them (`CONFIG_MODULES=y` in
      `arch/um/configs/x86_64_defconfig`); base.fragment turns them off.
      1. build.sh checks every option of every fragment, so a fragment
         with `CONFIG_MODULES=y` after base.fragment (`=n`) fails with
         CONFIG MISMATCH: check, for each option, the last fragment that
         sets it.
      2. With `CONFIG_MODULES=y`, build and install the modules
         (`make modules`, `modules_install` into
         `out/kernel/modules`).
      3. Mount them with the existing volume option,
         `r[volume]="<out>/modules/lib/modules/<release>|/lib/modules/<release>|ro"`,
         and test `modprobe` of a network module in a UML device of a
         lab. Then maybe `r[kernel]` pointing to a directory with
         `linux` and `modules/`.
- [ ] **perf.fragment.** The options of a kernel tuned for speed that may
      help a UML kernel (`SLUB_DEBUG=n`, `CC_OPTIMIZE_FOR_PERFORMANCE`,
      `CPU_MITIGATIONS=n`, ...): keep those that exist on UML, measure
      with `tests/bench-uml.sh`, make it the default only if it helps.
- [ ] **exec of a program in the background.** `kathara exec r "bash -c
      'prog &'"` waits in a UML device as long as `prog` runs (observed:
      still waiting after 20 s, 4 s in a container), because `prog` keeps
      the output of the ssh session open. A fix must keep the output of
      the command while it runs.

## Patches

- [ ] `uml-kernel/patches/7.3` carries "bpf: Build bpf_trace_printk()
      without BPF_EVENTS", not yet submitted to the kernel.
      If it goes upstream, replace it with the upstream commit.

## Upstream Kathara

- [ ] **The helpers as files.** start, init and ushell are bash kept in
      Python strings in UmlHelpers.py, because setup.py has no
      package_data and the PyInstaller spec has `datas=[]`. Ship them as
      files of the package instead, which touches the packaging of
      Kathara.
- [ ] **Fixed values.** The management link, 169.254.77.0/30, and the
      path of the key of ushell are written in the helpers: make them
      settings, or say why they need not be.
- [ ] **Tests in Kathara.** Kathara runs only the pytest tests of the
      fork; the lab tests of this repository run in the test VM. Find out
      what the authors of Kathara would want in their own test suite.
- [ ] **vstart.** `kathara vstart` makes a device from the command line,
      with options such as `--image`, `--mem` and `--sysctl`, but it has
      no option for the kernel.
- [ ] **Remote Docker.** With `remote_url` the kernel is mounted from a
      path of the local host, and a remote Docker looks for it on its own
      host (not tried). Copying the kernel into the container, as the
      helpers are, may work in both cases.
- [ ] **lab.links.** The collision domains of `lab.links` (Kathara 3.9.0:
      point-to-point, hub, external networks) are not tried with UML
      devices.
- [ ] **The proposal.** An Added entry in CHANGELOG.md, and the issue
      with the use cases and the pull request that CONTRIBUTING.md asks
      for a new feature.
- [ ] **Images whose tag is an OCI image manifest** (report it to
      Kathara, not a UML change). Before it pulls an image, Kathara goes
      through `image.attrs['Platforms']` of the registry data
      (`_check_image_architecture()` in `DockerImage.py`, line 201 on
      `develop` at 95328a0). When the tag of the image is an OCI image
      manifest, not an index, Docker gives `Platforms: None`, and lstart
      stops with "'NoneType' object is not iterable". In the test VM,
      with Docker 26.1.5, a test image FROM kathara/base gave its
      platform and started with a Docker v2 manifest, and gave none and
      stopped lstart with the same manifest written with the OCI media
      types.
      Docker 29, with the containerd image store, pushed the image of the
      GOB lab as an OCI image manifest. An OCI index with the platform of
      the image works. Not reported yet: no issue or pull request matched
      in the search of 2026-11-26.

## Elsewhere

- GOB labs (a GOB UML kernel with a gob.fragment, an image with the
  iproute2 that has `ip ioam gobschema`, a lab GOB node, node without
  GOB, GOB node) belong to the GOB repository, which uses this fork.
