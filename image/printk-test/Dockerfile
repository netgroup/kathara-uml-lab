# Test image for bpf_printk in UML devices: kathara/base plus bpftool and
# clang (Debian 12 packages), with prog.c built in /printk/prog.o.
FROM kathara/base
RUN apt-get update && apt-get install -y --no-install-recommends bpftool clang libbpf-dev \
	linux-libc-dev && rm -rf /var/lib/apt/lists/*
COPY prog.c /printk/prog.c
RUN clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c /printk/prog.c -o /printk/prog.o
