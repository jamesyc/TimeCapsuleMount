###### Build Stage #####
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

ARG AFPFS_NG_SRC_PATH=/src/afpfs-ng
ARG DEBIAN_FRONTEND=noninteractive

# Tool-chain + all libs the upstream build expects
RUN set -eux; \
    apt update; \
    apt install -y --no-install-recommends \
        g++ make autoconf automake libtool pkg-config dh-autoreconf \
        libfuse-dev libncurses5-dev libedit-dev libgcrypt20-dev \
        libreadline-dev; \
    rm -rf /var/lib/apt/lists/*

# Copy the repo already cloned beside this Dockerfile
COPY afpfs-ng ${AFPFS_NG_SRC_PATH}
WORKDIR ${AFPFS_NG_SRC_PATH}

# Make autotools recognise modern CPUs (aarch64 etc.)
RUN set -eux; \
    cp /usr/share/misc/config.guess ./; \
    cp /usr/share/misc/config.sub   ./

# Stub-in identify.c if the snapshot lacks it
RUN set -eux; \
    test -f lib/identify.c || { \
        echo '/* stubbed by Docker build - original file absent */'  \
             > lib/identify.c; \
        echo 'int identify_server(void* a, void* b){ (void)a; (void)b; return "Time Capsule"; }' \
             >> lib/identify.c; \
    }

# Regenerate autotools metadata & build (stage into /out)
RUN set -eux; \
    autoreconf -fi; \
    ./configure CFLAGS='-O2 -fcommon' --prefix=/usr; \
    make -j1 V=1; \
    make install DESTDIR=/out

###### Runtime Stage #####
FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS runtime
ARG DEBIAN_FRONTEND=noninteractive

# Install runtime deps, prepare FUSE and Samba in one layer
RUN set -eux; \
    apt update; \
    apt install -y --no-install-recommends \
        fuse3 libgcrypt20 libedit2 \
        attr samba samba-common-bin samba-vfs-modules smbclient smbnetfs avahi-utils; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -r fuse; \
    echo "user_allow_other" >> /etc/fuse.conf; \
    touch /etc/samba/lmhosts; \
    rm -f /etc/samba/smb.conf

# Copy only the built outputs
COPY --from=builder /out/usr/ /usr/

# Install scripts with correct permissions
COPY --chmod=0755 \
    entrypoint.sh \
    upstream-afp.sh \
    upstream-smb.sh \
    server.sh \
    utils.sh \
    /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Report unhealthy when upstream mount’s keepalive file can’t be accessed
HEALTHCHECK --interval=45s --timeout=15s --start-period=60s --retries=5 \
CMD ["sh","-c","stat /mnt/timecapsule/.upstream_keepalive >/dev/null 2>&1"]

# Default command handed to the entrypoint
CMD ["smbd","-F","--no-process-group","--configfile=/etc/samba/smb.conf"]
