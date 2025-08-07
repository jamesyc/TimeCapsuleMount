#!/bin/sh
set -e

# build URL lazily from env vars
AFP_URL=${AFP_URL:-"afp://$TM_USER:$TM_PASS@$AFP_HOST/Data"}

echo "Mounting $AFP_URL -> /mnt/timecapsule/Data ..."
mount_afp -o allow_other "$AFP_URL" /mnt/timecapsule/Data

exec "$@"   # default CMD keeps the container alive
