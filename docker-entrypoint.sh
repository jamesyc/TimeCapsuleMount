#!/bin/sh
set -e

# set default values
SET_PERMISSIONS="${SET_PERMISSIONS:-false}"
SHARE_NAME="${SHARE_NAME:-TimeMachine}"
CUSTOM_SMB_AUTH="${CUSTOM_SMB_AUTH:-no}"
CUSTOM_SMB_CONF="${CUSTOM_SMB_CONF:-false}"
CUSTOM_SMB_PROTO="${CUSTOM_SMB_PROTO:-SMB2}"
SMB_PORT="${SMB_PORT:-445}"
CUSTOM_USER="${CUSTOM_USER:-false}"
TM_USERNAME="${TM_USERNAME:-timemachine}"
TM_GROUPNAME="${TM_GROUPNAME:-timemachine}"
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





set_password() {
  # check to see what the password should be set to
  if [ "${PASSWORD}" = "timemachine" ]
  then
      echo "INFO: Using default password: timemachine"
  else
      echo "INFO: Setting password from environment variable"
  fi

  # set the password
  printf "INFO: "
  echo "${TM_USERNAME}":"${PASSWORD}" | chpasswd
}

samba_user_setup() {
  # set up user in Samba
  printf "INFO: Samba - Created "
  smbpasswd -L -a -n "${TM_USERNAME}"
  printf "INFO: Samba - "
  smbpasswd -L -e -n "${TM_USERNAME}"
  printf "INFO: Samba - setting password\n"
  printf "%s\n%s\n" "${PASSWORD}" "${PASSWORD}" | smbpasswd -L -s "${TM_USERNAME}"
}

create_user_directory() {
  # ensure FUSE mountpoint exists (idempotent)
  mkdir -p "/mnt/timecapsule"
}

createdir() {
  # create directory, if needed
  if [ ! -d "${1}" ]
  then
    echo "INFO: Creating ${1}"
    mkdir -p "${1}"
  fi

  # set permissions, if needed
  if [ -n "${2}" ]
  then
    chmod "${2}" "${1}"
  fi
}

ensure_system_user_group() {
  # Ensure Linux group and user exist for mount_afp uid/gid mapping
  if [ "${CUSTOM_USER}" != "true" ]; then
    # group
    if grep -q -E "^${TM_GROUPNAME}:" /etc/group > /dev/null 2>&1; then
      echo "INFO: Group ${TM_GROUPNAME} exists; skipping creation"
    else
      if awk -F ':' '{print $3}' /etc/group | grep -q "^${TM_GID}$"; then
        EXISTING_GROUP="$(grep ":${TM_GID}:" /etc/group | awk -F ':' '{print $1}')"
        echo "INFO: Group already exists with a different name; renaming '${EXISTING_GROUP}' to '${TM_GROUPNAME}'..."
        sed -i "s/^${EXISTING_GROUP}:/${TM_GROUPNAME}:/g" /etc/group
      else
        echo "INFO: Group ${TM_GROUPNAME} doesn't exist; creating..."
        addgroup --gid "${TM_GID}" "${TM_GROUPNAME}"
      fi
    fi
    # user
    if id -u "${TM_USERNAME}" > /dev/null 2>&1; then
      echo "INFO: User ${TM_USERNAME} exists; skipping creation"
    else
      echo "INFO: User ${TM_USERNAME} doesn't exist; creating..."
      adduser --uid "${TM_UID}" --gid "${TM_GID}" --home "/home/${TM_USERNAME}" --shell /bin/false --disabled-password "${TM_USERNAME}"
    fi
  fi
}

create_smb_user() {
  # validate that none of the required environment variables are empty
  if [ -z "${TM_USERNAME}" ] || [ -z "${TM_GROUPNAME}" ] || [ -z "${PASSWORD}" ] || [ -z "${SHARE_NAME}" ] || [ -z "${TM_UID}" ] || [ -z "${TM_GID}" ]
  then
    echo "ERROR: Missing one or more of the following variables; unable to create user"
    echo "  Hint: Is the variable missing or not set in ${USER_FILE}?"
    echo "  TM_USERNAME=${TM_USERNAME}"
    echo "  TM_GROUPNAME=${TM_GROUPNAME}"
    echo "  PASSWORD=$(if [ -n "${PASSWORD}" ]; then printf "<value reddacted but present>";fi)"
    echo "  SHARE_NAME=${SHARE_NAME}"
    echo "  TM_UID=${TM_UID}"
    echo "  TM_GID=${TM_GID}"
    exit 1
  fi

  # create custom user, group, and directories if CUSTOM_USER is not true
  if [ "${CUSTOM_USER}" != "true" ]
  then
    # check to see if group exists; if not, create it
    if grep -q -E "^${TM_GROUPNAME}:" /etc/group > /dev/null 2>&1
    then
      echo "INFO: Group ${TM_GROUPNAME} exists; skipping creation"
    else
      # make sure the group doesn't already exist with a different name
      if awk -F ':' '{print $3}' /etc/group | grep -q "^${TM_GID}$"
      then
        EXISTING_GROUP="$(grep ":${TM_GID}:" /etc/group | awk -F ':' '{print $1}')"
        echo "INFO: Group already exists with a different name; renaming '${EXISTING_GROUP}' to '${TM_GROUPNAME}'..."
        sed -i "s/^${EXISTING_GROUP}:/${TM_GROUPNAME}:/g" /etc/group
      else
        echo "INFO: Group ${TM_GROUPNAME} doesn't exist; creating..."
        # create the group
        addgroup --gid "${TM_GID}" "${TM_GROUPNAME}"
      fi
    fi
    # check to see if user exists; if not, create it
    if id -u "${TM_USERNAME}" > /dev/null 2>&1
    then
      echo "INFO: User ${TM_USERNAME} exists; skipping creation"
    else
      echo "INFO: User ${TM_USERNAME} doesn't exist; creating..."
      # create the user
      adduser --uid "${TM_UID}" --gid "${TM_GID}" --home "/home/${TM_USERNAME}" --shell /bin/false --disabled-password "${TM_USERNAME}"

      # set the user's password if necessary
      echo "INFO: Setting password..."
      set_password
    fi

    # create user directory if necessary
    create_user_directory
  else
    echo "INFO: CUSTOM_USER=true; skipping user, group, and data directory creation; using pre-existing values in /etc/passwd, /etc/group, and /etc/shadow"
  fi

  # write smb.conf if CUSTOM_SMB_CONF is not true
  if [ "${CUSTOM_SMB_CONF}" != "true" ]
  then
    echo "INFO: CUSTOM_SMB_CONF=false; generating [${SHARE_NAME}] section of /etc/samba/smb.conf..."
    echo "
[${SHARE_NAME}]
   path = /mnt/timecapsule
   inherit permissions = ${SMB_INHERIT_PERMISSIONS}
   read only = no
   valid users = ${TM_USERNAME}
   vfs objects = ${SMB_VFS_OBJECTS}
   fruit:time machine = yes
   fruit:time machine max size = ${VOLUME_SIZE_LIMIT}" >> /etc/samba/smb.conf
  else
    # CUSTOM_SMB_CONF was specified; make sure the file exists
    if [ -f "/etc/samba/smb.conf" ]
    then
      echo "INFO: CUSTOM_SMB_CONF=true; skipping generating smb.conf and using provided /etc/samba/smb.conf"
    else
      # there is no /etc/samba/smbp.conf; exit
      echo "ERROR: CUSTOM_SMB_CONF=true but you did not bind mount a config to /etc/samba/smb.conf; exiting."
      exit 1
    fi
  fi

  # set up user in Samba
  samba_user_setup

  # set user permissions
  set_permissions
}

set_permissions() {
  # set ownership and permissions, if requested
  if [ "${SET_PERMISSIONS}" = "true" ]
  then
    # set the ownership of the directory time machine will use
    printf "INFO: "
    chown -v "${TM_USERNAME}":"${TM_GROUPNAME}" "/mnt/timecapsule"

    # change the permissions of the directory time machine will use
    printf "INFO: "
    chmod -v 770 "/mnt/timecapsule"
  else
    echo "INFO: SET_PERMISSIONS=false; not setting ownership and permissions for /mnt/timecapsule"
  fi
}






# Build URL lazily from env vars (support TM_USER/TM_PASS or USER/PASS)
AFP_USER=${TM_USER:-${USER:-}}
AFP_PASS=${TM_PASS:-${PASS:-}}
AFP_URL=${AFP_URL:-"afp://${AFP_USER}:${AFP_PASS}@${AFP_HOST}/Data"}

# Ensure mountpoint exists before mounting
create_user_directory

# Ensure Linux user/group exist before mounting with uid/gid mapping
ensure_system_user_group

# Set up afpfs-ng mount to /mnt/timecapsule using specified uid/gid
echo "Mounting ${AFP_URL} -> /mnt/timecapsule as user=${TM_USERNAME},group=${TM_GROUPNAME} ..."
mount_afp -o user=${TM_USERNAME},group=${TM_GROUPNAME} "${AFP_URL}" "/mnt/timecapsule"
echo "Mounted ${AFP_URL} -> /mnt/timecapsule successfully."









# Create samba config
echo "[global]
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
fruit:delete_empty_adfiles = yes" > /etc/samba/smb.conf
createdir /var/lib/samba/private 700
createdir /var/log/samba/cores 700

create_smb_user

# cleanup PID files
for PIDFILE in nmbd samba-bgqd smbd
do
if [ -f /run/samba/${PIDFILE}.pid ]
then
    echo "INFO: ${PIDFILE} PID exists; removing..."
    rm -v /run/samba/${PIDFILE}.pid
fi
done

# start Samba in foreground (SMB over TCP/445 only)
echo "Starting smbd..."
exec smbd -F --no-process-group --configfile=/etc/samba/smb.conf
