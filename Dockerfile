# ---------- build stage ----------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

ARG AFPFS_NG_SRC_PATH=/src/afpfs-ng

# tool-chain + all libs the upstream build expects
RUN apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
        g++ make autoconf automake libtool pkg-config dh-autoreconf \
        libfuse-dev libncurses5-dev libedit-dev libgcrypt20-dev \
        libreadline-dev git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# copy the repo already cloned beside this Dockerfile
COPY afpfs-ng ${AFPFS_NG_SRC_PATH}
WORKDIR ${AFPFS_NG_SRC_PATH}

# make autotools recognise modern CPUs (aarch64 etc.)
RUN cp /usr/share/misc/config.guess ./ && \
    cp /usr/share/misc/config.sub   ./

# stub-in identify.c if the snapshot lacks it
RUN test -f lib/identify.c || { \
        echo '/* stubbed by Docker build – original file absent */'  \
             > lib/identify.c && \
        echo 'int identify_server(void* a, void* b){ (void)a; (void)b; return "Time Capsule"; }' \
             >> lib/identify.c ; \
    }

# regenerate autotools metadata & build
RUN autoreconf -fi && \
    ./configure CFLAGS='-O2 -fcommon' --prefix=/usr && \
    make -j1 V=1 2>&1 | tee build.log && \
    make install

# ---------- runtime stage ----------
FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS runtime
RUN apt update && \
    apt install -y --no-install-recommends \
        fuse3 libgcrypt20 libedit2 && \
    rm -rf /var/lib/apt/lists/*

# Install Samba server + tools, s6, and attr; clean up apt caches
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        attr \
        samba \
        samba-common-bin \
        s6 \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    touch /etc/samba/lmhosts; \
    rm -f /etc/samba/smb.conf

COPY --from=builder /usr/bin/ /usr/bin/
COPY --from=builder /usr/lib/ /usr/lib/
COPY --from=builder /usr/share/man/ /usr/share/man/

# prepare FUSE
RUN groupadd -r fuse && useradd -r -g fuse afpuser && \
    mkdir -p /mnt/timecapsule/Data && chown afpuser:fuse /mnt/timecapsule/Data && \
    echo "user_allow_other" >> /etc/fuse.conf

COPY s6 /etc/s6
COPY entrypoint.sh /

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["tail","-f","/dev/null"]

