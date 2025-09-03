#!/bin/sh
set -e
# Export all subsequent variable assignments so child scripts inherit defaults
set -a

# -- sane configuration defaults --
# General 
TM_SHARE="${TM_SHARE:-Data}"
SYSTEM_USER="${SYSTEM_USER:-timemachine}"
SYSTEM_GROUP="${SYSTEM_GROUP:-timemachine}"
SYSTEM_UID="${SYSTEM_UID:-1000}"
SYSTEM_GID="${SYSTEM_GID:-${SYSTEM_UID}}"
TARGET="${TARGET:-/mnt/timecapsule}"

# Upstream config for afp (afpfs-ng) and smb (smbnetfs)
TM_HOST="${TM_HOST:-${AFP_HOST}}"
TM_USER="${TM_USER:-${AFP_USER:-}}"
TM_PASS="${TM_PASS:-${AFP_PASS:-}}"
UPSTREAM_PROTO="${UPSTREAM_PROTO:-afp}"
UPSTREAM_KEEPALIVE="${UPSTREAM_KEEPALIVE:-600}"
UPSTREAM_WATCHDOG_INTERVAL="${UPSTREAM_WATCHDOG_INTERVAL:-60}"
UPSTREAM_BACKOFF="${UPSTREAM_BACKOFF:-5}"
UPSTREAM_WATCHDOG_DISABLE="${UPSTREAM_WATCHDOG_DISABLE:-no}"
UPSTREAM_HEALTHCHECK_RETRIES="${UPSTREAM_HEALTHCHECK_RETRIES:-1}"
UPSTREAM_HEALTHCHECK_DELAY="${UPSTREAM_HEALTHCHECK_DELAY:-1}"
CLEAN_STALE_BUNDLE_LOCKS="${CLEAN_STALE_BUNDLE_LOCKS:-yes}"

# AFP client defaults (if UPSTREAM_PROTO=afp)
AFP_MOUNT_OPTS="${AFP_MOUNT_OPTS:-user=${SYSTEM_USER},group=${SYSTEM_GROUP}}"
AFP_URL=${AFP_URL:-"afp://${TM_USER}:${TM_PASS}@${TM_HOST}/${TM_SHARE}"}

# SMBNETFS client defaults (if UPSTREAM_PROTO=smb)
SMBNETFS_MOUNT_ROOT="${SMBNETFS_MOUNT_ROOT:-/mnt/.smbnet}"
SMB_CLIENT_MIN_PROTO="${SMB_CLIENT_MIN_PROTO:-NT1}"
SMB_CLIENT_MAX_PROTO="${SMB_CLIENT_MAX_PROTO:-NT1}"
SMB_CLIENT_NTLMV2="${SMB_CLIENT_NTLMV2:-no}"
SMB_CLIENT_LANMAN="${SMB_CLIENT_LANMAN:-yes}"
SMB_CLIENT_SPNEGO="${SMB_CLIENT_SPNEGO:-no}"

# Server toggles
SERVER_ENABLED="${SERVER_ENABLED:-true}"
SERVER_IMPL="${SERVER_IMPL:-samba}"
CUSTOM_SMB_CONF="${CUSTOM_SMB_CONF:-false}"
SMB_SERVER_PASS="${SMB_SERVER_PASS:-${TM_PASS:-}}"

# SMB conf defaults
SMB_HIDE_SHARES="${SMB_HIDE_SHARES:-yes}"
SMB_INHERIT_PERMISSIONS="${SMB_INHERIT_PERMISSIONS:-no}"
SMB_LOG_LEVEL="${SMB_LOG_LEVEL:-4}"
SMB_PORT="${SMB_PORT:-445}"
WORKGROUP="${WORKGROUP:-WORKGROUP}"
SMB_NFS_ACES="${SMB_NFS_ACES:-no}"
SMB_MIMIC_MODEL="${SMB_MIMIC_MODEL:-TimeCapsule8,119}"
SMB_METADATA="${SMB_METADATA:-netatalk}"
SMB_FRUIT_RESOURCE="${SMB_FRUIT_RESOURCE:-file}"
SMB_FRUIT_ENCODING="${SMB_FRUIT_ENCODING:-native}"
SMB_EA_SUPPORT="${SMB_EA_SUPPORT:-no}"
SMB_KEEPALIVE="${SMB_KEEPALIVE:-60}"
SMB_DEADTIME="${SMB_DEADTIME:-0}"
SMB_SMB2_LEASES="${SMB_SMB2_LEASES:-no}"
SMB_DURABLE_HANDLES="${SMB_DURABLE_HANDLES:-no}"
SMB_STREAMS_XATTR_PREFIX="${SMB_STREAMS_XATTR_PREFIX:-user.}"
SMB_AIO_READ_SIZE="${SMB_AIO_READ_SIZE:-0}"
SMB_AIO_WRITE_SIZE="${SMB_AIO_WRITE_SIZE:-0}"
SMB_FORCE_USER="${SMB_FORCE_USER:-${SYSTEM_USER}}"

# SMB share defaults
SMB_VFS_OBJECTS="${SMB_VFS_OBJECTS:-catia fruit streams_xattr}"
VOLUME_SIZE_LIMIT="${VOLUME_SIZE_LIMIT:-0}"

# Avahi setup
AVAHI_INSTANCE_NAME="${AVAHI_INSTANCE_NAME:-Airport Time Capsule}"

# ----- logging (via shared utils) -----
LOG_TAG="init"
. "$(dirname "$0")/utils.sh"

# Basic input checks for upstream side
if [ "$UPSTREAM_PROTO" = "afp" ] || [ "$UPSTREAM_PROTO" = "smb" ]; then
  [ -n "${TM_SHARE}" ] || die "TM_SHARE missing"
  [ -n "${TM_HOST}" ] || die "TM_HOST missing"
  [ -n "${TM_USER}" ] || die "TM_USER missing"
  [ -n "${TM_PASS}" ] || die "TM_PASS missing"
  [ -n "${SYSTEM_USER}" ] || die "SYSTEM_USER missing"
  [ -n "${SYSTEM_GROUP}" ] || die "SYSTEM_GROUP missing"
  [ -n "${SYSTEM_UID}" ] || die "SYSTEM_UID missing"
  [ -n "${SYSTEM_GID}" ] || die "SYSTEM_GID missing"
else
  die "Unsupported UPSTREAM_PROTO='${UPSTREAM_PROTO}' (expected 'afp' or 'smb')"
fi

# Ensure mount prereqs exist (for both upstream variants)
mkdir -p "${TARGET}"
ensure_system_identities

# Mount the upstream AFP or SMB share
if [ "$UPSTREAM_PROTO" = "afp" ]; then
  /usr/local/bin/upstream-afp.sh || die "AFP upstream mount failed"
elif [ "$UPSTREAM_PROTO" = "smb" ]; then
  /usr/local/bin/upstream-smb.sh || die "SMB upstream mount failed"
else
  die "Unsupported UPSTREAM_PROTO='${UPSTREAM_PROTO}'"
fi
log "Mounted upstream (${UPSTREAM_PROTO}) to ${TARGET}"

# Setup and run downstream server if disabled
if [ "${SERVER_ENABLED}" != "true" ]; then
  log "SERVER_ENABLED=false; skipping downstream server. Keeping container alive."
  # If a command was provided AND it is not the default smbd, run it
  if [ "$#" -gt 0 ] && [ "$1" != "smbd" ]; then
    exec "$@"
  fi
  exec sleep infinity
fi
[ -n "${SMB_SERVER_PASS}" ] || die "SMB_SERVER_PASS missing"
if [ "$SERVER_IMPL" = "samba" ]; then
  exec /usr/local/bin/server.sh "$@"  # accepts custom CMD or defaults internally
else
  die "Unsupported SERVER_IMPL='${SERVER_IMPL}'"
fi
