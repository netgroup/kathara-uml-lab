# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Test image for tc and XDP in UML devices: kathara/base plus clang
# (Debian 12 packages), with xdp_drop.c and tc_drop.c built in /net.
FROM kathara/base
RUN apt-get update && apt-get install -y --no-install-recommends clang libbpf-dev linux-libc-dev && \
	rm -rf /var/lib/apt/lists/*
COPY xdp_drop.c tc_drop.c /net/
RUN for prog in xdp_drop tc_drop; do \
		clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c /net/$prog.c -o /net/$prog.o; \
	done
