#!/bin/sh
set -e

# General sane configuration defaults
TM_SHARE="${TM_SHARE:-Data}"

# AFP setup
AFP_KEEPALIVE="${AFP_KEEPALIVE:-60}"
CLEAN_STALE_BUNDLE_LOCKS="${CLEAN_STALE_BUNDLE_LOCKS:-yes}"
AFP_WATCHDOG_INTERVAL="${AFP_WATCHDOG_INTERVAL:-15}"
AFP_BACKOFF="${AFP_REMOUNT_BACKOFF:-5}"
AFP_MOUNT_OPTS="${AFP_MOUNT_OPTS:-user=${SMB_USER},group=${SMB_GROUP}}"

# SMB setup defaults
CUSTOM_SMB_CONF="${CUSTOM_SMB_CONF:-false}"
SMB_USER="${SMB_USER:-timemachine}"
SMB_GROUP="${SMB_GROUP:-timemachine}"
SMB_PASS="${SMB_PASS:-${AFP_PASS:-}}"

# SMB conf defaults
SMB_HIDE_SHARES="${SMB_HIDE_SHARES:-yes}"
SMB_INHERIT_PERMISSIONS="${SMB_INHERIT_PERMISSIONS:-no}"
SMB_LOG_LEVEL="${SMB_LOG_LEVEL:-4}"
SMB_PORT="${SMB_PORT:-445}"
WORKGROUP="${WORKGROUP:-WORKGROUP}"
SMB_NFS_ACES="${SMB_NFS_ACES:-no}"
SMB_MIMIC_MODEL="${SMB_MIMIC_MODEL:-TimeCapsule8,119}"
SMB_METADATA="${SMB_METADATA:-stream}"
SMB_FRUIT_RESOURCE="${SMB_FRUIT_RESOURCE:-file}"
SMB_FRUIT_ENCODING="${SMB_FRUIT_ENCODING:-native}"
SMB_EA_SUPPORT="${SMB_EA_SUPPORT:-yes}"
SMB_KEEPALIVE="${SMB_KEEPALIVE:-60}"
SMB_DEADTIME="${SMB_DEADTIME:-0}"
SMB_SMB2_LEASES="${SMB_SMB2_LEASES:-yes}"
SMB_DURABLE_HANDLES="${SMB_DURABLE_HANDLES:-yes}"
SMB_STREAMS_XATTR_PREFIX="${SMB_STREAMS_XATTR_PREFIX:-user.}"

# Samba conf optionals
SMB_AIO_READ_SIZE="${SMB_AIO_READ_SIZE:-0}"
SMB_AIO_WRITE_SIZE="${SMB_AIO_WRITE_SIZE:-0}"
SMB_FORCE_USER="${SMB_FORCE_USER:-${SMB_USER}}"

# SMB share defaults
SMB_VFS_OBJECTS="${SMB_VFS_OBJECTS:-catia fruit streams_xattr}"
VOLUME_SIZE_LIMIT="${VOLUME_SIZE_LIMIT:-0}"

# Avahi setup
#AVAHI_INSTANCE_NAME="${AVAHI_INSTANCE_NAME:-${HOSTNAME:-TimeMachine}}"
AVAHI_INSTANCE_NAME="${AVAHI_INSTANCE_NAME:-Airport Time Capsule}"

# Support both PUID/SMB_UID and PGID/SMB_GID
PUID="${PUID:-1000}"
PGID="${PGID:-${PUID}}"
SMB_UID="${SMB_UID:-${PUID}}"
SMB_GID="${SMB_GID:-${PGID:-${SMB_UID}}}"

# ----- small helpers -----
log() { echo "INFO: $*"; }
err() { echo "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

clean_stale_timemachine_artifacts() {
  [ "${CLEAN_STALE_BUNDLE_LOCKS}" = "yes" ] || { log "Stale bundle cleanup disabled"; return; }

  BASE="/mnt/timecapsule"
  [ -d "${BASE}" ] || return

  for bundle in "${BASE}"/*.sparsebundle; do
    [ -d "${bundle}" ] || continue
    name="$(basename "${bundle}")"

    # Remove zero-byte/leftover lock file if present
    if [ -e "${bundle}/lock" ]; then
      sz=$(wc -c < "${bundle}/lock" 2>/dev/null || echo "?")
      log "Found lock in ${name} (size=${sz}); attempting cleanup"
      # Be defensive around FUSE oddities: try multiple strategies, ignore errors
      rm -f "${bundle}/lock" 2>/dev/null || true
      : > "${bundle}/lock" 2>/dev/null || true
      chmod u+w "${bundle}/lock" 2>/dev/null || true
      rm -f "${bundle}/lock" 2>/dev/null || true
    fi

    # Remove leftover temp MachineID file if present
    if [ -e "${bundle}/com.apple.TimeMachine.MachineID.plist.tmp" ]; then
      log "Removing leftover MachineID .tmp in ${name}"
      rm -f "${bundle}/com.apple.TimeMachine.MachineID.plist.tmp" 2>/dev/null || true
    fi
  done
}

ensure_unix_identities() {
  # group
  if grep -q -E "^${SMB_GROUP}:" /etc/group >/dev/null 2>&1; then
    log "Group ${SMB_GROUP} exists; skipping"
  else
    if awk -F ':' '{print $3}' /etc/group | grep -q "^${SMB_GID}$"; then
      EXISTING_GROUP="$(grep ":${SMB_GID}:" /etc/group | awk -F ':' '{print $1}')"
      log "Group with GID ${SMB_GID} exists as '${EXISTING_GROUP}'; renaming to '${SMB_GROUP}'"
      sed -i "s/^${EXISTING_GROUP}:/${SMB_GROUP}:/g" /etc/group
    else
      log "Creating group ${SMB_GROUP} (${SMB_GID})"
      addgroup --gid "${SMB_GID}" "${SMB_GROUP}"
    fi
  fi

  # user
  if id -u "${SMB_USER}" >/dev/null 2>&1; then
    log "User ${SMB_USER} exists; skipping"
  else
    log "Creating user ${SMB_USER} (${SMB_UID}:${SMB_GID})"
    adduser --uid "${SMB_UID}" --gid "${SMB_GID}" --home "/home/${SMB_USER}" --shell /bin/false --disabled-password "${SMB_USER}"
    if [ -n "${SMB_PASS}" ]; then
      log "Setting local password for ${SMB_USER}"
      echo "${SMB_USER}:${SMB_PASS}" | chpasswd
    fi
  fi
}

write_smb_global() {
  cat > /etc/samba/smb.conf <<EOF
[global]
access based share enum = ${SMB_HIDE_SHARES}
hide unreadable = ${SMB_HIDE_SHARES}
inherit permissions = ${SMB_INHERIT_PERMISSIONS}
load printers = no
log file = /var/log/samba/log.%m
logging = file
max log size = 1000
log level = ${SMB_LOG_LEVEL}
security = user
server min protocol = SMB3
ntlm auth = no
server role = standalone server
use sendfile = no
strict locking = no
posix locking = no
smb ports = ${SMB_PORT}
disable netbios = yes
netbios name = ${AVAHI_INSTANCE_NAME}
workgroup = ${WORKGROUP}
kernel oplocks = no
kernel change notify = no
fruit:aapl = yes
fruit:nfs_aces = ${SMB_NFS_ACES}
fruit:model = ${SMB_MIMIC_MODEL}
fruit:metadata = ${SMB_METADATA}
fruit:resource = ${SMB_FRUIT_RESOURCE}
fruit:encoding = ${SMB_FRUIT_ENCODING}
fruit:veto_appledouble = no
fruit:posix_rename = yes
fruit:zero_file_id = yes
fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes
  ea support = ${SMB_EA_SUPPORT}
  keepalive = ${SMB_KEEPALIVE}
  deadtime = ${SMB_DEADTIME}
  smb2 leases = ${SMB_SMB2_LEASES}
  durable handles = ${SMB_DURABLE_HANDLES}
  streams_xattr:prefix = ${SMB_STREAMS_XATTR_PREFIX}
  streams_xattr:store_stream_type = no
EOF
}

append_smb_share() {
  log "Generating share section [${TM_SHARE}]"
  cat >> /etc/samba/smb.conf <<EOF

[${TM_SHARE}]
   path = /mnt/timecapsule
   inherit permissions = ${SMB_INHERIT_PERMISSIONS}
   read only = no
   valid users = ${SMB_USER}
   vfs objects = ${SMB_VFS_OBJECTS}
   fruit:time machine = yes
   fruit:time machine max size = ${VOLUME_SIZE_LIMIT}
   spotlight = no
   strict sync = yes
EOF

  # Append optional AIO settings if provided
  if [ -n "${SMB_AIO_READ_SIZE}" ]; then
    echo "   aio read size = ${SMB_AIO_READ_SIZE}" >> /etc/samba/smb.conf
  fi
  if [ -n "${SMB_AIO_WRITE_SIZE}" ]; then
    echo "   aio write size = ${SMB_AIO_WRITE_SIZE}" >> /etc/samba/smb.conf
  fi
  if [ -n "${SMB_FORCE_USER}" ]; then
    echo "   force user = ${SMB_FORCE_USER}" >> /etc/samba/smb.conf
  fi
}

prepare_samba_config() {
  if [ "${CUSTOM_SMB_CONF}" = "true" ]; then
    [ -f /etc/samba/smb.conf ] || die "CUSTOM_SMB_CONF=true but /etc/samba/smb.conf not provided"
    log "Using provided /etc/samba/smb.conf"
  else
    write_smb_global
    append_smb_share
  fi
}

# Keep AFP session alive to avoid idle disconnects on some devices
start_afp_keepalive() {
  # Numeric and greater than zero
  if [ "${AFP_KEEPALIVE}" -gt 0 ] 2>/dev/null; then
    {
      touch /mnt/timecapsule/.afp_keepalive 2>/dev/null || true
      while true; do
        # Probe inside the mount (not just the mountpoint) to detect ENOTCONN
        stat /mnt/timecapsule/.afp_keepalive >/dev/null 2>&1 || true
        sleep "${AFP_KEEPALIVE}"
      done
    } &
    log "AFP keepalive started (interval=${AFP_KEEPALIVE}s)"
  else
    log "AFP keepalive disabled"
  fi
}

# Return 0 if the AFP mount appears healthy, 1 otherwise
afp_mount_healthy() {
  local target="${1:-/mnt/timecapsule}"
  # Must be listed in mounts
  if ! awk -v m="$target" '$2==m {found=1} END {exit !found}' /proc/self/mounts; then
    return 1
  fi
  # Check an operation within the mount to catch FUSE "Transport endpoint" states
  stat "$target/.afp_keepalive" >/dev/null 2>&1
}

# Watch for a broken AFP FUSE mount and auto-remount
start_afp_watchdog() {
  TARGET="/mnt/timecapsule"
  URL="${AFP_URL}"

  {
    while true; do
      sleep "${AFP_WATCHDOG_INTERVAL}"
      # If the mount is unhealthy (e.g., Transport endpoint is not connected), try to remount
      if ! afp_mount_healthy "${TARGET}"; then
        log "AFP watchdog: mount unhealthy; attempting remount"
        # Prefer FUSE unmount helpers when available; fall back to lazy umount
        if command -v afp_client >/dev/null 2>&1; then
          afp_client unmount "${TARGET}" >/dev/null 2>&1 || true
        fi
        if command -v fusermount3 >/dev/null 2>&1; then
          fusermount3 -uz "${TARGET}" >/dev/null 2>&1 || true
        fi
        umount -l "${TARGET}" >/dev/null 2>&1 || true

        if mount_afp -o "${AFP_MOUNT_OPTS}" "${URL}" "${TARGET}" >/dev/null 2>&1; then
          log "AFP watchdog: remounted successfully"
        else
          err "AFP watchdog: remount failed; retrying in ${AFP_BACKOFF}s"
          sleep "${AFP_BACKOFF}"
        fi
      fi
    done
  } &
  log "AFP watchdog started (interval=${AFP_WATCHDOG_INTERVAL}s, backoff=${AFP_BACKOFF}s)"
}

# Configure mDNS/Bonjour advertisement using host Avahi (DBus)
setup_avahi() {
  if command -v avahi-publish >/dev/null 2>&1 && [ -S /run/dbus/system_bus_socket ]; then
    log "Publishing mDNS/Bonjour services via host Avahi (DBus)"
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _smb._tcp ${SMB_PORT} &
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _device-info._tcp 0 "model=${SMB_MIMIC_MODEL}" &
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _adisk._tcp 9 \
      "dk0=adVN=${TM_SHARE},adVF=0x82" \
      "sys=waMa=0,adVF=0x82" &
  else
    log "avahi-publish or DBus socket unavailable; skipping mDNS/Bonjour advertising"
  fi
}

# Required samba inputs (may have defaults)
[ -n "${TM_SHARE}" ] || die "TM_SHARE missing"
[ -n "${SMB_USER}" ] || die "SMB_USER missing"
[ -n "${SMB_GROUP}" ] || die "SMB_GROUP missing"
[ -n "${SMB_PASS}" ] || die "SMB_PASS missing"
[ -n "${SMB_UID}" ] || die "SMB_UID missing"
[ -n "${SMB_GID}" ] || die "SMB_GID missing"

# Set up system
mkdir -p /mnt/timecapsule
ensure_unix_identities

# Set up AFP mount point
AFP_URL=${AFP_URL:-"afp://${AFP_USER}:${AFP_PASS}@${AFP_HOST}/${TM_SHARE}"}
log "Mounting ${AFP_URL} -> /mnt/timecapsule as user=${SMB_USER},group=${SMB_GROUP}"
mount_afp -o "${AFP_MOUNT_OPTS}" "${AFP_URL}" /mnt/timecapsule
log "Mounted ${AFP_URL}"

# Clean up any stale TM artifacts before exporting via SMB
clean_stale_timemachine_artifacts

# Start AFP keepalive loop
start_afp_keepalive
start_afp_watchdog

# Set up Samba config
prepare_samba_config
setup_avahi
# Set up Samba permissions
mkdir -p /var/lib/samba/private /var/log/samba/cores
chmod 0700 /var/log/samba/cores || true
log "Provisioning Samba user ${SMB_USER}"
smbpasswd -L -a -n "${SMB_USER}"
log "Enabling Samba user ${SMB_USER}"
smbpasswd -L -e -n "${SMB_USER}"
printf "%s\n%s\n" "${SMB_PASS}" "${SMB_PASS}" | smbpasswd -L -s "${SMB_USER}"

# Clean up any stale samba PID files
for PIDFILE in nmbd samba-bgqd smbd; do
  if [ -f "/run/samba/${PIDFILE}.pid" ]; then
    log "Removing stale PID /run/samba/${PIDFILE}.pid"
    rm -f "/run/samba/${PIDFILE}.pid"
  fi
done

# Start smbd
log "Starting smbd..."
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec smbd -F --no-process-group --configfile=/etc/samba/smb.conf
fi
