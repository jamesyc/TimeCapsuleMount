#!/bin/sh
set -e

# Tag logs and source shared utilities
LOG_TAG="afp"
. "$(dirname "$0")/utils.sh"

mount_upstream() {
  log "Mounting ${AFP_URL} -> ${TARGET}"
  mount_afp -o "${AFP_MOUNT_OPTS}" "${AFP_URL}" "${TARGET}"
}

remount_upstream() {
  command -v afp_client >/dev/null 2>&1 && afp_client unmount "${TARGET}" >/dev/null 2>&1 || true
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "${TARGET}" >/dev/null 2>&1 || true
  else
    umount -l "${TARGET}" >/dev/null 2>&1 || true
  fi
  mount_upstream
}

# Perform the mount
mount_upstream

# Post-mount tasks
clean_stale_timemachine_artifacts
start_upstream_keepalive
start_upstream_watchdog
