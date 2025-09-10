#!/bin/sh
set -e

# Source shared utilities
LOG_TAG="smb"
. "$(dirname "$0")/utils.sh"

# Templates for generated config files
SMB_CLIENT_CONF_CONTENT="$(cat <<EOF
[global]
client min protocol = ${SMB_CLIENT_MIN_PROTO}
client max protocol = ${SMB_CLIENT_MAX_PROTO}
client NTLMv2 auth = ${SMB_CLIENT_NTLMV2}
client lanman auth = ${SMB_CLIENT_LANMAN}
client plaintext auth = no
client use spnego = ${SMB_CLIENT_SPNEGO}
name resolve order = host bcast
EOF
)"

SMBNETFS_CONF_CONTENT="$(cat <<'EOF'
# Minimal smbnetfs configuration; credentials provided via smbnetfs.auth
include "smbnetfs.auth"
EOF
)"

SMBNETFS_AUTH_CONTENT="$(cat <<EOF
auth "${TM_HOST}" "${TM_USER}" "${TM_PASS}"
EOF
)"

unmount_target() {
  # TARGET is a bind mount of the share path
  umount -l "${TARGET}" >/dev/null 2>&1 || true
}

unmount_smbnetfs_root() {
  # Prefer FUSE-aware unmounts for smbnetfs root
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "${SMBNETFS_MOUNT_ROOT}" >/dev/null 2>&1 || true
  elif command -v fusermount >/dev/null 2>&1; then
    fusermount -uz "${SMBNETFS_MOUNT_ROOT}" >/dev/null 2>&1 || true
  else
    umount -l "${SMBNETFS_MOUNT_ROOT}" >/dev/null 2>&1 || true
  fi
}

resolve_share_path() {
  root=$1; host=$2; share=$3
  [ -d "$root" ] || return 1
  for p in "$root/$host/$share" "$root/WORKGROUP/$host/$share" "$root/MSHOME/$host/$share"; do
    [ -d "$p" ] && { echo "$p"; return 0; }
  done
  for d in "$root"/*; do
    [ -d "$d/$host/$share" ] && { echo "$d/$host/$share"; return 0; }
  done
  return 1
}

mount_upstream() {
  mkdir -p /root/.smb
  printf "%s\n" "${SMB_CLIENT_CONF_CONTENT}" > /root/.smb/smb.conf
  printf "%s\n" "${SMBNETFS_CONF_CONTENT}" > /root/.smb/smbnetfs.conf
  printf "%s\n" "${SMBNETFS_AUTH_CONTENT}" > /root/.smb/smbnetfs.auth
  chmod 600 /root/.smb/smbnetfs.auth

  mkdir -p "${SMBNETFS_MOUNT_ROOT}"
  log "Starting smbnetfs on ${SMBNETFS_MOUNT_ROOT} (uid=${SYSTEM_UID},gid=${SYSTEM_GID})"
  if ! pgrep -f "smbnetfs ${SMBNETFS_MOUNT_ROOT}" >/dev/null 2>&1; then
    smbnetfs -o allow_other,uid=${SYSTEM_UID},gid=${SYSTEM_GID} "${SMBNETFS_MOUNT_ROOT}" || die "smbnetfs failed"
  fi

  for i in $(seq 1 30); do
    awk -v m="${SMBNETFS_MOUNT_ROOT}" '$2==m {found=1} END {exit !found}' /proc/self/mounts && break
    sleep 0.2
  done
  awk -v m="${SMBNETFS_MOUNT_ROOT}" '$2==m {found=1} END {exit !found}' /proc/self/mounts || die "smbnetfs root not mounted"

  log "Locating share ${TM_HOST}/${TM_SHARE} inside smbnetfs tree..."
  SHARE_PATH=""
  for i in $(seq 1 50); do
    SHARE_PATH=$(resolve_share_path "${SMBNETFS_MOUNT_ROOT}" "${TM_HOST}" "${TM_SHARE}") && break
    sleep 0.2
  done
  [ -n "${SHARE_PATH}" ] || die "Unable to locate ${TM_HOST}/${TM_SHARE} via smbnetfs"
  log "Found share path: ${SHARE_PATH}"

  if mountpoint -q "${TARGET}"; then
    unmount_target
    mountpoint -q "${TARGET}" && log "Warning: Failed to unmount ${TARGET}"
  fi
  log "Bind-mounting ${SHARE_PATH} -> ${TARGET}"
  mount --bind "${SHARE_PATH}" "${TARGET}"
}

remount_upstream() {
  unmount_target
  unmount_smbnetfs_root
  pkill -f "smbnetfs ${SMBNETFS_MOUNT_ROOT}" >/dev/null 2>&1 || true
  mount_upstream
}

# Perform the mount
mount_upstream

# Post-mount tasks
clean_stale_timemachine_artifacts
start_upstream_keepalive
start_upstream_watchdog
