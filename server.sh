#!/bin/sh
set -e

# Use shared utils for logging and helpers
LOG_TAG="server"
. "$(dirname "$0")/utils.sh"

# Global smb.conf section
SMB_GLOBAL_CONF="$(cat <<EOF
[global]
  # Identity/networking
  server role = standalone server
  workgroup = ${WORKGROUP}
  netbios name = ${AVAHI_INSTANCE_NAME}
  disable netbios = yes
  smb ports = ${SMB_PORT}
  # Protocol auth
  security = user
  server min protocol = SMB3
  ntlm auth = no
  # macOS support (fruit baseline)
  vfs objects = catia fruit
  fruit:aapl = yes
  fruit:model = ${SMB_MIMIC_MODEL}
  fruit:encoding = ${SMB_FRUIT_ENCODING}
  fruit:posix_rename = yes
  fruit:veto_appledouble = no
  fruit:zero_file_id = yes
  fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes
  fruit:metadata = ${SMB_METADATA}
  fruit:resource = ${SMB_FRUIT_RESOURCE}
  # File/locking semantics (good for FUSE backend)
  kernel oplocks = no
  posix locking = no
  strict locking = no
  kernel change notify = no
  smb2 leases = ${SMB_SMB2_LEASES}
  durable handles = ${SMB_DURABLE_HANDLES}
  use sendfile = no
  # Visibility
  access based share enum = ${SMB_HIDE_SHARES}
  map hidden = no
  map system = no
  map archive = no
  map readonly = no
  # Logging
  keepalive = ${SMB_KEEPALIVE}
  deadtime = ${SMB_DEADTIME}
  logging = file
  log level = ${SMB_LOG_LEVEL}
  log file = /var/log/samba/log.%m
  max log size = 1000
  load printers = no
EOF
)"

# Share section for smb.conf 
SMB_SHARE_CONF="$(cat <<EOF
[${TM_SHARE}]
  path = ${TARGET}
  browseable = yes
  read only = no
  valid users = ${SYSTEM_USER}
  # macOS Time Machine
  vfs objects = catia fruit
  fruit:time machine = yes
  fruit:time machine max size = ${VOLUME_SIZE_LIMIT}
  spotlight = no
  # Permissions
  force user = ${SMB_FORCE_USER}
  inherit permissions = ${SMB_INHERIT_PERMISSIONS}
  use sendfile = no
  create mask = 0660
  directory mask = 0770
EOF
)"

write_smb_global() {
  printf "%s\n" "${SMB_GLOBAL_CONF}" > /etc/samba/smb.conf
}

append_smb_share() {
  printf "%s\n" "${SMB_SHARE_CONF}" >> /etc/samba/smb.conf
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

setup_avahi() {
  if command -v avahi-publish >/dev/null 2>&1 && [ -S /run/dbus/system_bus_socket ]; then
    log "Publishing mDNS/Bonjour (_smb._tcp, _device-info._tcp, _adisk._tcp)"
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _smb._tcp "${SMB_PORT}" &
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _device-info._tcp 0 "model=${SMB_MIMIC_MODEL}" &
    # Use 0x100 to avoid duplicate share bug
    avahi-publish -s "${AVAHI_INSTANCE_NAME}" _adisk._tcp 9 \
      "dk0=adVN=${TM_SHARE},adVF=0x100" \
      "sys=waMa=0,adVF=0x100" &
  else
    log "avahi-publish or DBus socket unavailable; skipping mDNS/Bonjour advertising"
  fi
}

# Prepare system for Samba
mkdir -p "${TARGET}"
ensure_system_identities
prepare_samba_config
setup_avahi

mkdir -p /var/lib/samba/private /var/log/samba/cores
chmod 0700 /var/log/samba/cores || true

log "Provisioning Samba user ${SYSTEM_USER}"
smbpasswd -L -a -n "${SYSTEM_USER}" || true
log "Enabling Samba user ${SYSTEM_USER}"
smbpasswd -L -e -n "${SYSTEM_USER}" || true
printf "%s\n%s\n" "${SMB_SERVER_PASS}" "${SMB_SERVER_PASS}" | smbpasswd -L -s "${SYSTEM_USER}"

for PIDFILE in nmbd samba-bgqd smbd; do
  if [ -f "/run/samba/${PIDFILE}.pid" ]; then
    log "Removing stale PID /run/samba/${PIDFILE}.pid"
    rm -f "/run/samba/${PIDFILE}.pid"
  fi
done

log "Starting smbd..."
if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec smbd -F --no-process-group --configfile=/etc/samba/smb.conf
fi
