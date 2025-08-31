#!/bin/sh
set -e

# ----- configuration defaults -----
TM_SHARE_NAME="${TM_SHARE_NAME:-Data}"
CUSTOM_SMB_AUTH="${CUSTOM_SMB_AUTH:-no}"
CUSTOM_SMB_CONF="${CUSTOM_SMB_CONF:-false}"
CUSTOM_SMB_PROTO="${CUSTOM_SMB_PROTO:-SMB3}"
SMB_PORT="${SMB_PORT:-445}"
SMB_DISABLE_NETBIOS="${SMB_DISABLE_NETBIOS:-yes}"
CUSTOM_USER="${CUSTOM_USER:-false}"
TM_USERNAME="${TM_USERNAME:-timemachine}"
TM_GROUPNAME="${TM_GROUPNAME:-timemachine}"
TM_PASSWORD="${TM_PASSWORD:-${AFP_PASS:-}}"
VOLUME_SIZE_LIMIT="${VOLUME_SIZE_LIMIT:-0}"
WORKGROUP="${WORKGROUP:-WORKGROUP}"
HIDE_SHARES="${HIDE_SHARES:-no}"
SMB_VFS_OBJECTS="${SMB_VFS_OBJECTS:-fruit streams_xattr}"
SMB_INHERIT_PERMISSIONS="${SMB_INHERIT_PERMISSIONS:-no}"
SMB_NFS_ACES="${SMB_NFS_ACES:-no}"
SMB_METADATA="${SMB_METADATA:-stream}"
MIMIC_MODEL="${MIMIC_MODEL:-TimeCapsule8,119}"
# Bonjour instance name
#AVAHI_INSTANCE_NAME="${AVAHI_INSTANCE_NAME:-${HOSTNAME:-TimeMachine}}"
AVAHI_INSTANCE_NAME="${AVAHI_INSTANCE_NAME:-Airport Time Capsule}"

# AFP/Samba share tunables
AFP_KEEPALIVE="${AFP_KEEPALIVE:-60}"
SMB_KEEPALIVE="${SMB_KEEPALIVE:-60}"
SMB_DEADTIME="${SMB_DEADTIME:-0}"
SMB_SMB2_LEASES="${SMB_SMB2_LEASES:-yes}"
SMB_DURABLE_HANDLES="${SMB_DURABLE_HANDLES:-yes}"
SMB_AIO_READ_SIZE="${SMB_AIO_READ_SIZE:-}"
SMB_AIO_WRITE_SIZE="${SMB_AIO_WRITE_SIZE:-}"
SMB_LOG_LEVEL="${SMB_LOG_LEVEL:-3}"
SMB_FRUIT_RESOURCE="${SMB_FRUIT_RESOURCE:-stream}"
SMB_FRUIT_ENCODING="${SMB_FRUIT_ENCODING:-native}"
SMB_STREAMS_XATTR_PREFIX="${SMB_STREAMS_XATTR_PREFIX:-user.}"
SMB_EA_SUPPORT="${SMB_EA_SUPPORT:-yes}"
SMB_FORCE_USER="${SMB_FORCE_USER:-${TM_USERNAME}}"
CLEAN_STALE_BUNDLE_LOCKS="${CLEAN_STALE_BUNDLE_LOCKS:-yes}"

# support both PUID/TM_UID and PGID/TM_GID
PUID="${PUID:-1000}"
PGID="${PGID:-${PUID}}"
TM_UID="${TM_UID:-${PUID}}"
TM_GID="${TM_GID:-${PGID:-${TM_UID}}}"

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
  [ "${CUSTOM_USER}" = "true" ] && { log "CUSTOM_USER=true; using existing user/group"; return; }

  # group
  if grep -q -E "^${TM_GROUPNAME}:" /etc/group >/dev/null 2>&1; then
    log "Group ${TM_GROUPNAME} exists; skipping"
  else
    if awk -F ':' '{print $3}' /etc/group | grep -q "^${TM_GID}$"; then
      EXISTING_GROUP="$(grep ":${TM_GID}:" /etc/group | awk -F ':' '{print $1}')"
      log "Group with GID ${TM_GID} exists as '${EXISTING_GROUP}'; renaming to '${TM_GROUPNAME}'"
      sed -i "s/^${EXISTING_GROUP}:/${TM_GROUPNAME}:/g" /etc/group
    else
      log "Creating group ${TM_GROUPNAME} (${TM_GID})"
      addgroup --gid "${TM_GID}" "${TM_GROUPNAME}"
    fi
  fi

  # user
  if id -u "${TM_USERNAME}" >/dev/null 2>&1; then
    log "User ${TM_USERNAME} exists; skipping"
  else
    log "Creating user ${TM_USERNAME} (${TM_UID}:${TM_GID})"
    adduser --uid "${TM_UID}" --gid "${TM_GID}" --home "/home/${TM_USERNAME}" --shell /bin/false --disabled-password "${TM_USERNAME}"
    if [ -n "${TM_PASSWORD}" ]; then
      log "Setting local password for ${TM_USERNAME}"
      echo "${TM_USERNAME}:${TM_PASSWORD}" | chpasswd
    fi
  fi
}

write_smb_global() {
  cat > /etc/samba/smb.conf <<EOF
[global]
access based share enum = ${HIDE_SHARES}
hide unreadable = ${HIDE_SHARES}
inherit permissions = ${SMB_INHERIT_PERMISSIONS}
load printers = no
log file = /var/log/samba/log.%m
logging = file
max log size = 1000
log level = ${SMB_LOG_LEVEL}
security = user
server min protocol = ${CUSTOM_SMB_PROTO}
ntlm auth = ${CUSTOM_SMB_AUTH}
server role = standalone server
smb ports = ${SMB_PORT}
disable netbios = ${SMB_DISABLE_NETBIOS}
netbios name = ${AVAHI_INSTANCE_NAME}
workgroup = ${WORKGROUP}
vfs objects = ${SMB_VFS_OBJECTS}
fruit:aapl = yes
fruit:nfs_aces = ${SMB_NFS_ACES}
fruit:model = ${MIMIC_MODEL}
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
EOF
}

append_smb_share() {
  log "Generating share section [${TM_SHARE_NAME}]"
  cat >> /etc/samba/smb.conf <<EOF

[${TM_SHARE_NAME}]
   path = /mnt/timecapsule
   inherit permissions = ${SMB_INHERIT_PERMISSIONS}
   read only = no
   valid users = ${TM_USERNAME}
   vfs objects = ${SMB_VFS_OBJECTS}
   fruit:time machine = yes
   fruit:time machine max size = ${VOLUME_SIZE_LIMIT}
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
        stat /mnt/timecapsule/.afp_keepalive >/dev/null 2>&1 || true
        sleep "${AFP_KEEPALIVE}"
      done
    } &
    log "AFP keepalive started (interval=${AFP_KEEPALIVE}s)"
  else
    log "AFP keepalive disabled"
  fi
}

# Configure mDNS/Bonjour advertisement using host Avahi (DBus)
setup_avahi() {
  if command -v avahi-publish >/dev/null 2>&1 && [ -S /run/dbus/system_bus_socket ]; then
    log "Publishing mDNS/Bonjour services via host Avahi (DBus)"
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _smb._tcp ${SMB_PORT} &
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _device-info._tcp 0 "model=${MIMIC_MODEL}" &
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _adisk._tcp 9 \
      "dk0=adVN=${TM_SHARE_NAME},adVF=0x82" \
      "sys=waMa=0,adVF=0x82" &
  else
    log "avahi-publish or DBus socket unavailable; skipping mDNS/Bonjour advertising"
  fi
}

# Required samba inputs (may have defaults)
[ -n "${TM_USERNAME}" ] || die "TM_USERNAME missing"
[ -n "${TM_GROUPNAME}" ] || die "TM_GROUPNAME missing"
[ -n "${TM_PASSWORD}" ] || die "TM_PASSWORD missing"
[ -n "${TM_SHARE_NAME}" ] || die "TM_SHARE_NAME missing"
[ -n "${TM_UID}" ] || die "TM_UID missing"
[ -n "${TM_GID}" ] || die "TM_GID missing"

# Set up system
mkdir -p /mnt/timecapsule
ensure_unix_identities

# Set up AFP mount point
AFP_URL=${AFP_URL:-"afp://${AFP_USER}:${AFP_PASS}@${AFP_HOST}/${AFP_SHARE}"}
log "Mounting ${AFP_URL} -> /mnt/timecapsule as user=${TM_USERNAME},group=${TM_GROUPNAME}"
mount_afp -o user=${TM_USERNAME},group=${TM_GROUPNAME} "${AFP_URL}" /mnt/timecapsule
log "Mounted ${AFP_URL}"

# Clean up any stale TM artefacts before exporting via SMB
clean_stale_timemachine_artifacts

# Start AFP keepalive loop
start_afp_keepalive

# Set up Samba
prepare_samba_config
setup_avahi
mkdir -p /var/lib/samba/private /var/log/samba/cores
chmod 0700 /var/log/samba/cores || true
chown root:root /var/log/samba/cores 2>/dev/null || true
log "Provisioning Samba user ${TM_USERNAME}"
smbpasswd -L -a -n "${TM_USERNAME}"
smbpasswd -L -e -n "${TM_USERNAME}"
printf "%s\n%s\n" "${TM_PASSWORD}" "${TM_PASSWORD}" | smbpasswd -L -s "${TM_USERNAME}"
chown -v "${TM_USERNAME}":"${TM_GROUPNAME}" /mnt/timecapsule
chmod -v 777 /mnt/timecapsule

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
