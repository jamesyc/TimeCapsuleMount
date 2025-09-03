#!/bin/sh
# Shared utilities for upstream scripts

# Set LOG_TAG (e.g. "afp" or "smb") in the caller to prefix messages.
log() { if [ -n "${LOG_TAG}" ]; then echo "INFO[${LOG_TAG}]: $*"; else echo "INFO: $*"; fi; }
err() { if [ -n "${LOG_TAG}" ]; then echo "ERROR[${LOG_TAG}]: $*" >&2; else echo "ERROR: $*" >&2; fi; }
die() { err "$*"; exit 1; }

# Create group and user (if needed)
ensure_system_identities() {
  [ -n "${SYSTEM_USER}" ] || die "SYSTEM_USER missing"
  [ -n "${SYSTEM_GROUP}" ] || die "SYSTEM_GROUP missing"
  [ -n "${SYSTEM_UID}" ] || die "SYSTEM_UID missing"
  [ -n "${SYSTEM_GID}" ] || die "SYSTEM_GID missing"

  # group
  if getent group "${SYSTEM_GROUP}" >/dev/null 2>&1; then
    gid=$(getent group "${SYSTEM_GROUP}" | awk -F: '{print $3}')
    [ "${gid}" = "${SYSTEM_GID}" ] || die "Group ${SYSTEM_GROUP} exists with gid=${gid}, expected ${SYSTEM_GID}"
  else
    # GID must be free
    if getent group | awk -F: -v gid="${SYSTEM_GID}" '$3==gid {exit 0} END {exit 1}'; then
      die "GID ${SYSTEM_GID} already in use by a different group"
    fi
    log "Creating group ${SYSTEM_GROUP} (${SYSTEM_GID})"
    addgroup --gid "${SYSTEM_GID}" "${SYSTEM_GROUP}"
  fi

  # user
  if id -u "${SYSTEM_USER}" >/dev/null 2>&1; then
    uid=$(id -u "${SYSTEM_USER}")
    gid_u=$(id -g "${SYSTEM_USER}")
    [ "${uid}" = "${SYSTEM_UID}" ] || die "User ${SYSTEM_USER} exists with uid=${uid}, expected ${SYSTEM_UID}"
    [ "${gid_u}" = "${SYSTEM_GID}" ] || die "User ${SYSTEM_USER} exists with gid=${gid_u}, expected ${SYSTEM_GID}"
  else
    # UID must be free
    if awk -F: -v uid="${SYSTEM_UID}" '$3==uid {exit 0} END {exit 1}' /etc/passwd; then
      die "UID ${SYSTEM_UID} already in use by a different user"
    fi
    log "Creating user ${SYSTEM_USER} (${SYSTEM_UID}:${SYSTEM_GID})"
    adduser --uid "${SYSTEM_UID}" --gid "${SYSTEM_GID}" --home "/home/${SYSTEM_USER}" --shell /bin/false --disabled-password "${SYSTEM_USER}"
    if [ -n "${SYSTEM_PASS}" ]; then
      echo "${SYSTEM_USER}:${SYSTEM_PASS}" | chpasswd
    fi
  fi
  log "SYSTEM_USER=${SYSTEM_USER}, SYSTEM_GROUP=${SYSTEM_GROUP}, SYSTEM_UID=${SYSTEM_UID}, SYSTEM_GID=${SYSTEM_GID}"
}

# Delete stale sparsebundle artifacts that may prevent Time Machine from working
clean_stale_timemachine_artifacts() {
  [ "${CLEAN_STALE_BUNDLE_LOCKS}" = "yes" ] || { log "Stale bundle cleanup disabled"; return; }
  [ -d "${TARGET}" ] || return
  for bundle in "${TARGET}"/*.sparsebundle; do
    [ -d "${bundle}" ] || continue
    if [ -e "${bundle}/lock" ]; then
      rm -f "${bundle}/lock" 2>/dev/null || true
      : > "${bundle}/lock" 2>/dev/null || true
      chmod u+w "${bundle}/lock" 2>/dev/null || true
      rm -f "${bundle}/lock" 2>/dev/null || true
    fi
    if [ -e "${bundle}/com.apple.TimeMachine.MachineID.plist.tmp" ]; then
      rm -f "${bundle}/com.apple.TimeMachine.MachineID.plist.tmp" 2>/dev/null || true
    fi
  done
}

# Keepalive touches/reads a file in TARGET to keep FUSE connections warm
start_upstream_keepalive() {
  if [ "${UPSTREAM_KEEPALIVE}" -gt 0 ] 2>/dev/null; then
    {
      touch "${TARGET}/.upstream_keepalive" 2>/dev/null || true
      while true; do
        stat "${TARGET}/.upstream_keepalive" >/dev/null 2>&1 || true
        sleep "${UPSTREAM_KEEPALIVE}"
      done
    } &
    log "Keepalive started (interval=${UPSTREAM_KEEPALIVE}s)"
  else
    log "Keepalive disabled"
  fi
}

# Basic upstream mount health check
upstream_mount_healthy() {
  awk -v m="${TARGET}" '$2==m {found=1} END {exit !found}' /proc/self/mounts || return 1
  for _ in $(seq 1 "${UPSTREAM_HEALTHCHECK_RETRIES}"); do
    stat "${TARGET}/.upstream_keepalive" >/dev/null 2>&1 && return 0
    sleep "${UPSTREAM_HEALTHCHECK_DELAY}"
  done
  return 1
}

# Background watchdog that remounts when unhealthy.
# Requires the caller to implement remount_upstream().
start_upstream_watchdog() {
  [ "${UPSTREAM_WATCHDOG_DISABLE}" = "yes" ] && { log "Watchdog disabled"; return; }
  {
    while true; do
      sleep "${UPSTREAM_WATCHDOG_INTERVAL}"
      if ! upstream_mount_healthy; then
        log "$(date -Is) Watchdog: mount unhealthy; remounting"
        if remount_upstream >/dev/null 2>&1; then
          log "$(date -Is) Watchdog: remounted successfully"
        else
          err "$(date -Is) Watchdog: remount failed; retrying in ${UPSTREAM_BACKOFF}s"
          sleep "${UPSTREAM_BACKOFF}"
        fi
      fi
    done
  } &
  log "Watchdog started (interval=${UPSTREAM_WATCHDOG_INTERVAL}s)"
}
