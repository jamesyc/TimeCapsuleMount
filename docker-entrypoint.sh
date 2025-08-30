#!/bin/sh
set -e

# ----- configuration defaults -----
SHARE_NAME="${SHARE_NAME:-TimeMachine}"
CUSTOM_SMB_AUTH="${CUSTOM_SMB_AUTH:-no}"
CUSTOM_SMB_CONF="${CUSTOM_SMB_CONF:-false}"
CUSTOM_SMB_PROTO="${CUSTOM_SMB_PROTO:-SMB2}"
SMB_PORT="${SMB_PORT:-445}"
CUSTOM_USER="${CUSTOM_USER:-false}"
TM_USERNAME="${TM_USERNAME:-timemachine}"
TM_GROUPNAME="${TM_GROUPNAME:-timemachine}"
PASSWORD="${PASSWORD:-${AFP_PASS:-}}"
VOLUME_SIZE_LIMIT="${VOLUME_SIZE_LIMIT:-0}"
WORKGROUP="${WORKGROUP:-WORKGROUP}"
HIDE_SHARES="${HIDE_SHARES:-no}"
SMB_VFS_OBJECTS="${SMB_VFS_OBJECTS:-fruit streams_xattr}"
SMB_INHERIT_PERMISSIONS="${SMB_INHERIT_PERMISSIONS:-no}"
SMB_NFS_ACES="${SMB_NFS_ACES:-no}"
SMB_METADATA="${SMB_METADATA:-stream}"
MIMIC_MODEL="${MIMIC_MODEL:-TimeCapsule8,119}"

# support both PUID/TM_UID and PGID/TM_GID
PUID="${PUID:-1000}"
PGID="${PGID:-${PUID}}"
TM_UID="${TM_UID:-${PUID}}"
TM_GID="${TM_GID:-${PGID:-${TM_UID}}}"

# ----- small helpers -----
log() { echo "INFO: $*"; }
err() { echo "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

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
    if [ -n "${PASSWORD}" ]; then
      log "Setting local password for ${TM_USERNAME}"
      echo "${TM_USERNAME}:${PASSWORD}" | chpasswd
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
security = user
server min protocol = ${CUSTOM_SMB_PROTO}
ntlm auth = ${CUSTOM_SMB_AUTH}
server role = standalone server
smb ports = ${SMB_PORT}
workgroup = ${WORKGROUP}
vfs objects = ${SMB_VFS_OBJECTS}
fruit:aapl = yes
fruit:nfs_aces = ${SMB_NFS_ACES}
fruit:model = ${MIMIC_MODEL}
fruit:metadata = ${SMB_METADATA}
fruit:veto_appledouble = no
fruit:posix_rename = yes
fruit:zero_file_id = yes
fruit:wipe_intentionally_left_blank_rfork = yes
fruit:delete_empty_adfiles = yes
EOF
  mkdir -p /var/lib/samba/private /var/log/samba/cores
}

append_smb_share() {
  log "Generating share section [${SHARE_NAME}]"
  cat >> /etc/samba/smb.conf <<EOF

[${SHARE_NAME}]
   path = /mnt/timecapsule
   inherit permissions = ${SMB_INHERIT_PERMISSIONS}
   read only = no
   valid users = ${TM_USERNAME}
   vfs objects = ${SMB_VFS_OBJECTS}
   fruit:time machine = yes
   fruit:time machine max size = ${VOLUME_SIZE_LIMIT}
EOF
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

# Required samba inputs (may have defaults)
[ -n "${TM_USERNAME}" ] || die "TM_USERNAME missing"
[ -n "${TM_GROUPNAME}" ] || die "TM_GROUPNAME missing"
[ -n "${PASSWORD}" ] || die "PASSWORD missing"
[ -n "${SHARE_NAME}" ] || die "SHARE_NAME missing"
[ -n "${TM_UID}" ] || die "TM_UID missing"
[ -n "${TM_GID}" ] || die "TM_GID missing"

# Set up system
mkdir -p /mnt/timecapsule
ensure_unix_identities

# Set up AFP mount point
AFP_URL=${AFP_URL:-"afp://${AFP_USER}:${AFP_PASS}@${AFP_HOST}/Data"}
log "Mounting ${AFP_URL} -> /mnt/timecapsule as user=${TM_USERNAME},group=${TM_GROUPNAME}"
mount_afp -o user=${TM_USERNAME},group=${TM_GROUPNAME} "${AFP_URL}" /mnt/timecapsule
log "Mounted ${AFP_URL}"

# Set up Samba
prepare_samba_config
log "Provisioning Samba user ${TM_USERNAME}"
smbpasswd -L -a -n "${TM_USERNAME}"
smbpasswd -L -e -n "${TM_USERNAME}"
printf "%s\n%s\n" "${PASSWORD}" "${PASSWORD}" | smbpasswd -L -s "${TM_USERNAME}"
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