#!/bin/sh
set -e

# Tag logs and source shared utilities
LOG_TAG="afp"
. "$(dirname "$0")/utils.sh"

unmount_target() {
  # Try AFP client unmount if available
  command -v afp_client >/dev/null 2>&1 && afp_client unmount "${TARGET}" >/dev/null 2>&1 || true
  # Prefer FUSE-aware unmounts, then fall back to lazy umount
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "${TARGET}" >/dev/null 2>&1 || true
  elif command -v fusermount >/dev/null 2>&1; then
    fusermount -uz "${TARGET}" >/dev/null 2>&1 || true
  fi
  umount -l "${TARGET}" >/dev/null 2>&1 || true
}

mount_upstream() {
  if mountpoint -q "${TARGET}"; then
    unmount_target
    mountpoint -q "${TARGET}" && log "Warning: Failed to unmount ${TARGET}"
  fi
  log "Mounting ${AFP_URL} -> ${TARGET}"
  mount_afp -o "${AFP_MOUNT_OPTS}" "${AFP_URL}" "${TARGET}"
}

remount_upstream() {
  unmount_target
  mount_upstream
}

# Perform the mount
mount_upstream

# Post-mount tasks
clean_stale_timemachine_artifacts
start_upstream_keepalive
start_upstream_watchdog
