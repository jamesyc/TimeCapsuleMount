# TimeCapsuleMount
Have an old perfectly fine *Apple AirPort Time Capsule* that's still doing automatic backups for your Mac? Have a Raspberry Pi lying around at home, or some linux machine? Worried about Apple deprecating AFP and SMBv1 on the next version of MacOS, and thus breaking your AirPort Time Capsule?  
**This is for you**.

This allows you to run a tidy little Docker image, which uses good old rock solid AFP to connect to the Time Capsule, and then hosts a modern Samba server which your Mac can connect to.  
It will automatically show up in the Network section of Finder on your Mac via mDNS, without you entering any IP address on your Mac; it can also be easily cleaned up and deleted with a single command.

#### Background Information
Apple is removing AFP and SMBv1 support from MacOS. Both these protocols are outdated and insecure, with SMBv1 infamously responsible for [the WannaCry ransomware attack](https://en.wikipedia.org/wiki/WannaCry_ransomware_attack) (which is also the reason why the Linux kernel's SMBv1 support is usually disabled or even compiled out for some distros). Unfortunately, the Apple Time Capsule only has support for AFP and a SMBv1 server, which means that it will soon cease working with the latest MacOS- even though it's probably been a trusty automatic backup box for years. However, for a typical person in a home environment (running a typical WiFi router with a NAT), using AFP or SMBv1 for a Time Capsule is an acceptable tradeoff in terms of security.

#### Technical Summary 
This creates a Docker container acting as a proxy between your Time Capsule and Mac, which is running both afpfs-ng and a samba server. It connects to your Time Capsule with AFP and mounts it to a folder via FUSE in the Docker container, sets up a Samba server pointing to the FUSE folder mount, and then registers the Samba server with Avahi/mDNS so it automatically shows up in the Network folder of your Mac.  
Alternatively, if you set `UPSTREAM_PROTO=smb`, the container uses smbnetfs (userspace/FUSE) to access an SMBv1-only Time Capsule. This avoids kernel restrictions on insecure NTLMv1 while keeping the mount sandboxed inside the container.

- `entrypoint.sh`: small dispatcher that sets config defaults and delegates work
- `upstream-afp.sh` or `upstream-smb.sh`: mounts the upstream (AFP or SMB)
- `server.sh`: prepares and runs the downstream Samba server (mDNS included)

You can disable the downstream server entirely by setting `SERVER_ENABLED=false`. The upstream mount/healthcheck continues to run in the container.
The Docker container does not run its own Avahi service, instead just using the host's Avahi service (on the Raspberry Pi, or an Arch Linux machine, etc), and just registers the Samba server with avahi-publish via dbus. Requires `avahi-daemon` running on the host and an accessible DBus system socket (these are bind‑mounted by `docker-compose`). Without Avahi on the host, Finder/Bonjour discovery will not work.

## Setup Instructions
Follow these instructions for setup on a Linux machine. Windows and Mac are not supported.

### Docker Compose (Preferred Method)
##### Setup
1. Install Docker on the host machine
2. Pull this repo to a folder on the host machine
3. Copy the file `.env.example` to `.env` and set `TM_HOST`, `TM_USER`, `TM_PASS` (optionally `TM_SHARE`, `SYSTEM_UID`, `SYSTEM_GID`)
4. Run `docker compose up -d`
   
##### Removal
1. Run `docker compose down` to stop the container
2. Delete the folder.

### Useful environment variables
- `UPSTREAM_PROTO`: `afp` (default) or `smb` to pick upstream
- `SERVER_ENABLED`: `true` (default) to export via Samba, `false` to disable
- `SERVER_IMPL`: `samba` (default). Reserved for future swappable servers

Advanced options (commonly tweaked):
- `AVAHI_INSTANCE_NAME`: Bonjour name shown in Finder (default: `Airport Time Capsule`)
- `UPSTREAM_KEEPALIVE`: seconds between keepalive stats to keep FUSE warm (default: `600`)
- `UPSTREAM_WATCHDOG_INTERVAL`: seconds between health checks (default: `60`)
- `UPSTREAM_WATCHDOG_DISABLE`: set to `yes` to disable auto‑remount watchdog
- `SMB_MIMIC_MODEL`: announces a Time Capsule model string to macOS
- `SMB_LOG_LEVEL`: Samba log level (default: `4`)

### Using an external SMB server
This repo’s compose file can be configured to run a time machine host container on a macvlan network (no host configuration required) so that mDNS/Bonjour discovery works cleanly without conflicting with services on the host. Requires ethernet.

How it’s wired:
- Set `SERVER_ENABLED=false` for this container (set this in your `.env`).
- A host path is bind‑mounted into this container at `/mnt/timecapsule` with `rshared` propagation so the AFP/SMB mount inside the container propagates to the host path.
- The mbentley container mounts the same host path at `/opt/timemachine` and serves it via SMB to macOS.
- The mbentley container is attached to a `macvlan` network with its own IP for Avahi/mDNS.

Quick start:
1) Ensure the backing path exists on the host (e.g. `sudo mkdir -p /srv/timecapsule` or your chosen `TIMEMACHINE_BACKING_PATH`)
2) In `.env`, set `SERVER_ENABLED=false` and adjust macvlan defaults if needed (see `.env.example`):
   - `MACVLAN_PARENT` (e.g. `eth0`)
   - `MACVLAN_SUBNET`, `MACVLAN_GATEWAY`, `MACVLAN_IP_RANGE`, `TIMEMACHINE_IP`
3) In `docker-compose.yml`, uncomment the rshared bind‑mount for `/mnt/timecapsule` and set `TIMEMACHINE_BACKING_PATH` to your host path.
4) Start with the SMB profile enabled:
   - `docker compose --profile smb up -d`  (or `COMPOSE_PROFILES=smb docker compose up -d`)

macOS will see the share name from `SHARE_NAME` in the mbentley container (defaults to your `TM_SHARE`, e.g. `Data`).
