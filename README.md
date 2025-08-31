# TimeCapsuleMount
Have an old perfectly fine *Apple AirPort Time Capsule* that's still doing automatic backups for your Mac? Have a Raspberry Pi lying around at home, or some linux machine? Worried about Apple deprecating AFP and SMBv1 on the next version of MacOS, and thus breaking your AirPort Time Capsule?  
**This is for you**.

This allows you to run a tidy little Docker image, which uses good old rock solid AFP to connect to the Time Capsule, and then hosts a modern Samba server which your Mac can connect to.  
It will automatically show up in the Network section of Finder on your Mac via mDNS, without you entering any IP address on your Mac; it can also be easily cleaned up and deleted with a single command.

#### Background Information
Apple is removing AFP and SMBv1 support from MacOS. Both these protocols are outdated and insecure, with SMBv1 infamously responsible for [the WannaCry ransomware attack](https://en.wikipedia.org/wiki/WannaCry_ransomware_attack) (which is also the reason why the Linux kernel's SMBv1 support is usually disabled or even compiled out for some distros). Unfortunately, the Apple Time Capsule only has support for AFP and a SMBv1 server, which means that it will soon cease working with the latest MacOS- even though it's probably been a trusty automatic backup box for years. However, for a typical person in a home environment (running a typical WiFi router with a NAT), using AFP or SMBv1 for a Time Capsule is an acceptable tradeoff in terms of security.

#### Technical Summary 
This creates a Docker container acting as a proxy between your Time Capsule and Mac, which is running both afpfs-ng and a samba server. It connects to your Time Capsule with AFP and mounts it to a folder via FUSE in the Docker container, sets up a Samba server pointing to the FUSE folder mount, and then registers the Samba server with Avahi/mDNS so it automatically shows up in the Network folder of your Mac.  
The Docker container does not run its own Avahi service, instead just using the host's Avahi service (on the Rasbperry Pi, or a Arch Linux machine, etc), and just registers the Samba server with avahi-publish via dbus. 

## Setup Instructions

#### Setup with Docker Compose (Preferred Method)
1. Install Docker on the host machine
2. Pull this repo to a folder on the host machine
3. Copy the file `.env.example` to `.env` and set your username and password
4. Run `docker compose up -d`

#### Docker Compose Removal
1. Run `docker compose down` to stop the container
2. Delete the folder.

