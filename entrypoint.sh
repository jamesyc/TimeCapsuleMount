#!/bin/sh
set -e

# build URL lazily from env vars
AFP_URL=${AFP_URL:-"afp://$AFP_USER:$AFP_PASS@$AFP_HOST/Data"}

echo "Mounting $AFP_URL -> /mnt/timecapsule/Data ..."
mount_afp -o allow_other "$AFP_URL" /mnt/timecapsule/Data

# setup Samba user and services
echo "Adding Samba user afpuser"
(echo "$AFP_PASS"; echo "$AFP_PASS") | smbpasswd -s -a timemachine
echo "Starting Samba services"
nmbd --foreground --no-process-group &
smbd --foreground --no-process-group &

sudo tee /etc/avahi/services/samba-tm.service >/dev/null <<'EOF'
<?xml version="1.0" standalone='no'?><service-group>
  <name replace-wildcards="yes">%h _adisk._tcp</name>
  <service>
    <type>_adisk._tcp</type><port>9</port>
    <txt-record>sys=adVF=0x100</txt-record>
    <txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record>
  </service>
</service-group>
EOF
sudo systemctl restart avahi-daemon

exec "$@"   # default CMD keeps the container alive
