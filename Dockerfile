# ---------- build stage ----------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

ARG AFPFS_NG_SRC_PATH=/src/afpfs-ng

# Tool-chain + all libs the upstream build expects
RUN set -eux; \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
        g++ make autoconf automake libtool pkg-config dh-autoreconf \
        libfuse-dev libncurses5-dev libedit-dev libgcrypt20-dev \
        libreadline-dev git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the repo already cloned beside this Dockerfile
COPY afpfs-ng ${AFPFS_NG_SRC_PATH}
WORKDIR ${AFPFS_NG_SRC_PATH}

# Make autotools recognise modern CPUs (aarch64 etc.)
RUN cp /usr/share/misc/config.guess ./ && \
    cp /usr/share/misc/config.sub   ./

# Stub-in identify.c if the snapshot lacks it
RUN test -f lib/identify.c || { \
        echo '/* stubbed by Docker build - original file absent */'  \
             > lib/identify.c && \
        echo 'int identify_server(void* a, void* b){ (void)a; (void)b; return "Time Capsule"; }' \
             >> lib/identify.c ; \
    }

# Regenerate autotools metadata & build
RUN autoreconf -fi && \
    ./configure CFLAGS='-O2 -fcommon' --prefix=/usr && \
    make -j1 V=1 2>&1 | tee build.log && \
    make install

# ---------- runtime stage ----------
FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS runtime

# Install afpfs-ng runtime dependencies; clean up apt caches
RUN set -eux; \
    apt update && \
    apt install -y --no-install-recommends \
        fuse3 libgcrypt20 libedit2 && \
    rm -rf /var/lib/apt/lists/*

# Copy afpfs-ng from the build stage
COPY --from=builder /usr/bin/ /usr/bin/
COPY --from=builder /usr/lib/ /usr/lib/
COPY --from=builder /usr/share/man/ /usr/share/man/

# prepare FUSE
RUN groupadd -r fuse && \
    echo "user_allow_other" >> /etc/fuse.conf

# Install Samba server; clean up apt caches
RUN set -eux; \
    apt update; \
    apt install -y --no-install-recommends \
        attr samba samba-common-bin samba-vfs-modules smbclient \
        smbnetfs avahi-utils; \
    rm -rf /var/lib/apt/lists/*

# Prepare Samba
RUN set -eux; \
    touch /etc/samba/lmhosts; \
    rm -f /etc/samba/smb.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY upstream-afp.sh /usr/local/bin/upstream-afp.sh
COPY upstream-smb.sh /usr/local/bin/upstream-smb.sh
COPY server.sh /usr/local/bin/server.sh
COPY utils.sh /usr/local/bin/utils.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/upstream-afp.sh /usr/local/bin/upstream-smb.sh /usr/local/bin/server.sh /usr/local/bin/utils.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Report unhealthy when upstream mount’s keepalive file can’t be accessed
HEALTHCHECK --interval=45s --timeout=15s --start-period=60s --retries=5 \
CMD ["sh","-c","stat /mnt/timecapsule/.upstream_keepalive >/dev/null 2>&1"]
# Default command handed to the entrypoint
CMD ["smbd","-F","--no-process-group","--configfile=/etc/samba/smb.conf"]
